#!/usr/bin/env bash
# mother-limiter-hold.sh — PreToolUse hook that parks a worker at a tool-call boundary while the
# backpressure limiter wants its job held (L4).
#
# Wired in by mother-run-job's job-scoped --settings file whenever the limiter mode is not `off`.
# In observe mode nothing ever writes the flag file, so this is a no-op.
#
# Contract:
#   - No $root/runner/<job>.hold flag -> exit 0 at once (the fast path: no jq, no stdin read).
#   - Flag present -> write $root/runner/<job>.held ({"at": <epoch>, "pid": <this pid>}), then poll
#     every 2 s (MOTHER_LIMITER_HOOK_POLL_S, tests only). When the flag is gone, remove .held, exit 0.
#   - Fails OPEN: exits 0 once its own elapsed time reaches MOTHER_LIMITER_HOOK_MAX_S (the settings
#     file passes grace + 240), and on any missing/garbled input. It never blocks a tool call and
#     never prints to stdout.
#
#   - Park marker: before the supervisor gives a held worker up it writes $root/runner/<job>.park
#     ({"pid": <supervisor pid>, "at": <epoch>}). While that marker exists AND its pid is alive, the hook
#     keeps blocking even if .hold is gone or MOTHER_LIMITER_HOOK_MAX_S has passed, so the supervisor's
#     terminate lands only on a blocked worker. The extension is bounded: the hook never blocks past
#     MAX_S + MOTHER_LIMITER_HOOK_PARK_CAP_S (default 120 s; the supervisor's whole park sequence is a
#     lock wait of at most 10 s plus a few file writes, so it is well inside the cap). A .park whose
#     pid is dead (supervisor crashed) is ignored: the hook fails open as before.
#
#   - In-flight tracking: every tool call is recorded in $root/runner/<job>.calls/<tool_use_id> as
#     {"state": "running"|"blocked", "pid": <hook pid>, "at": <epoch>} when its PreToolUse hook starts (even
#     with no .hold), and removed by `mother-limiter-hold.sh post` (wired as PostToolUse and
#     PostToolUseFailure). While this hook blocks it marks its call `blocked`; on release it goes back to
#     `running` (the tool then executes). The supervisor parks a worker only when at least one call is
#     blocked in a live hook and no call is running, so a parallel or subagent tool call that passed its
#     hook earlier is never killed mid-request. Input without a tool_use_id, or a failed record write, is not
#     recorded; in enforce mode (limiter/mode.json) it drops $root/runner/<job>.calls/_unidentified instead,
#     which stops the supervisor parking the worker until the next spawn.
#
#   - Observe mode runs this hook (and `post`) on every tool call: one stdin read, one date, one small
#     atomic write. No behaviour change: with no .hold it exits 0 straight after the record.
#
# Mother stops a worker parked here by terminating the worker process (the supervisor's give-up);
# the TERM trap just removes the .held marker.

set -u

job_id="${MOTHER_JOB_ID:-}"
[ -n "$job_id" ] || exit 0

mother_root="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}"
hold_file="$mother_root/runner/$job_id.hold"
held_file="$mother_root/runner/$job_id.held"
park_file="$mother_root/runner/$job_id.park"

calls_dir="$mother_root/runner/$job_id.calls"

# The tool call's id, from the hook's JSON on stdin (builtins only: this is the hot path). Empty when absent.
call_id=""
if IFS= read -r -d '' -t 5 _input; then :; fi
if [[ "${_input:-}" =~ \"tool_use_id\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9_-]+)\" ]]; then call_id="${BASH_REMATCH[1]}"; fi
unset _input

# _mark_unidentified — enforce mode only: this call could not be recorded (no tool_use_id, or the record write
# failed), so the supervisor can't know it is not running. Drop $calls_dir/_unidentified; _hold_calls_safe then
# refuses to park until the next spawn clears the directory. Silent on failure (fail open). Fail-open also covers
# an unreadable or garbled limiter/mode.json: no marker is dropped, because enforce must be positively configured. Runs only on the
# failure path, so the mode file is never read on the normal hot path.
_mark_unidentified() {
    grep -q '"mode": *"enforce"' "$mother_root/limiter/mode.json" 2>/dev/null || return 0
    { [ -d "$calls_dir" ] || mkdir -p "$calls_dir"; } 2>/dev/null || return 0
    : > "$calls_dir/_unidentified" 2>/dev/null
    return 0
}

# _call_write <state> <at> — atomic; failure leaves the call unrecorded (marked unidentified in enforce mode).
_call_write() {
    [ -n "$call_id" ] || { _mark_unidentified; return 0; }
    { [ -d "$calls_dir" ] || mkdir -p "$calls_dir"; } 2>/dev/null || { _mark_unidentified; return 0; }
    { printf '{"state": "%s", "pid": %s, "at": %s}\n' "$1" "$$" "$2" > "$calls_dir/$call_id.tmp.$$" \
        && mv "$calls_dir/$call_id.tmp.$$" "$calls_dir/$call_id.json"; } 2>/dev/null \
        || { rm -f "$calls_dir/$call_id.tmp.$$" 2>/dev/null; _mark_unidentified; }
    return 0
}

if [ "${1:-}" = "post" ]; then
    [ -z "$call_id" ] || rm -f "$calls_dir/$call_id.json" 2>/dev/null
    exit 0
fi

# _park_live — the supervisor's park marker exists and its pid is alive.
_park_live() {
    local pp
    [ -f "$park_file" ] || return 1
    pp=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$park_file" 2>/dev/null)
    case "$pp" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pp" 2>/dev/null
}

# Record the call BEFORE looking at .hold/.park: the supervisor's recheck then either sees this call or this
# hook sees the park.
call_start=$(date +%s 2>/dev/null) || call_start=0
_call_write running "$call_start"

[ -f "$hold_file" ] || _park_live || exit 0

max_s="${MOTHER_LIMITER_HOOK_MAX_S:-}"
case "$max_s" in ''|*[!0-9]*) max_s=840 ;; esac
poll_s="${MOTHER_LIMITER_HOOK_POLL_S:-2}"
case "$poll_s" in ''|*[!0-9.]*) poll_s=2 ;; esac

park_cap_s="${MOTHER_LIMITER_HOOK_PARK_CAP_S:-}"
case "$park_cap_s" in ''|*[!0-9]*) park_cap_s=120 ;; esac

sleep_pid=""
# Remove .held only while it is still ours (a later worker's hook may have written its own), and stop the
# sleep child we started so nothing outlives us. Never signal the process group: it holds the worker.
_cleanup() {
    [ -z "$sleep_pid" ] || kill "$sleep_pid" 2>/dev/null
    if [ "$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$held_file" 2>/dev/null)" = "$$" ]; then
        rm -f "$held_file" 2>/dev/null
    fi
}
trap '_cleanup; exit 0' TERM INT HUP

start=$(date +%s 2>/dev/null) || exit 0

# _write_held — (the braces keep the shell's own "Permission denied" for a failed redirect off stderr: never print)
_write_held() {
    { printf '{"at": %s, "pid": %s}\n' "$start" "$$" > "$held_file.tmp.$$" \
        && mv "$held_file.tmp.$$" "$held_file"; } 2>/dev/null || { rm -f "$held_file.tmp.$$" 2>/dev/null; return 1; }
}

# _blocking — keep holding the tool call? A live park marker wins over .hold and MAX_S (up to the cap).
_blocking() {
    local now
    now=$(date +%s 2>/dev/null) || return 1
    if _park_live; then [ $((now - start)) -lt $((max_s + park_cap_s)) ]; return; fi
    [ -f "$hold_file" ] && [ $((now - start)) -lt "$max_s" ]
}

_call_write blocked "$call_start"
_write_held || exit 0

while :; do
    while _blocking; do
        sleep "$poll_s" 2>/dev/null &
        sleep_pid=$!
        wait "$sleep_pid" 2>/dev/null
        sleep_pid=""
    done
    # Release: drop .held first, then look at .park once more. A supervisor that wrote .park and then saw
    # our .held before this rm is covered here: the park is visible now, so we keep blocking.
    _cleanup
    _call_write running "$call_start"
    _blocking || break
    _call_write blocked "$call_start"
    _write_held || break
done
exit 0
