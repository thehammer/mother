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
# Mother stops a worker parked here by terminating the worker process (the supervisor's give-up);
# the TERM trap just removes the .held marker.

set -u

job_id="${MOTHER_JOB_ID:-}"
[ -n "$job_id" ] || exit 0

mother_root="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}"
hold_file="$mother_root/runner/$job_id.hold"
held_file="$mother_root/runner/$job_id.held"

[ -f "$hold_file" ] || exit 0

max_s="${MOTHER_LIMITER_HOOK_MAX_S:-}"
case "$max_s" in ''|*[!0-9]*) max_s=840 ;; esac
poll_s="${MOTHER_LIMITER_HOOK_POLL_S:-2}"
case "$poll_s" in ''|*[!0-9.]*) poll_s=2 ;; esac

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
# (the braces keep the shell's own "Permission denied" for a failed redirect off stderr: never print)
{ printf '{"at": %s, "pid": %s}\n' "$start" "$$" > "$held_file.tmp.$$" \
    && mv "$held_file.tmp.$$" "$held_file"; } 2>/dev/null || { rm -f "$held_file.tmp.$$" 2>/dev/null; exit 0; }

while [ -f "$hold_file" ]; do
    now=$(date +%s 2>/dev/null) || break
    [ $((now - start)) -lt "$max_s" ] || break
    sleep "$poll_s" 2>/dev/null &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null
    sleep_pid=""
done
_cleanup
exit 0
