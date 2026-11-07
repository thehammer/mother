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
# Mother stops a worker parked here by terminating the worker process (the supervisor's give-up);
# the TERM trap just removes the .held marker.

set -u

job_id="${MOTHER_JOB_ID:-}"
[ -n "$job_id" ] || exit 0

mother_root="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}"
hold_file="$mother_root/runner/$job_id.hold"
held_file="$mother_root/runner/$job_id.held"
park_file="$mother_root/runner/$job_id.park"

[ -f "$hold_file" ] || exit 0

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

# _park_live — the supervisor's park marker exists and its pid is alive.
_park_live() {
    local pp
    [ -f "$park_file" ] || return 1
    pp=$(sed -n 's/.*"pid": *\([0-9]*\).*/\1/p' "$park_file" 2>/dev/null)
    case "$pp" in ''|*[!0-9]*) return 1 ;; esac
    kill -0 "$pp" 2>/dev/null
}

# _blocking — keep holding the tool call? A live park marker wins over .hold and MAX_S (up to the cap).
_blocking() {
    local now
    now=$(date +%s 2>/dev/null) || return 1
    if _park_live; then [ $((now - start)) -lt $((max_s + park_cap_s)) ]; return; fi
    [ -f "$hold_file" ] && [ $((now - start)) -lt "$max_s" ]
}

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
    _blocking || break
    _write_held || break
done
exit 0
