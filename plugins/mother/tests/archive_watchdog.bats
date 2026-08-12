#!/usr/bin/env bats
# archive_watchdog.bats — tests for _maybe_archive's timeout watchdog.
#
# Regression coverage for: mother-runner's hourly archive sweep
# (`"$MOTHER_BIN_DIR/mother" archive ...`) ran inline in the single-threaded
# `_loop`, with no timeout. On 2026-08-12 a sweep wedged (bash-level pipe
# deadlock in the `2>&1 | while read` logging pipeline, root cause
# undetermined) and sat idle for ~4 hours, silently blocking every
# subsequent tick — no new jobs were dispatched, no auto-resume, no
# escalation, nothing, and none of it showed up anywhere because the
# daemon's stderr is discarded. `_maybe_archive` now races the sweep
# against a `MOTHER_ARCHIVE_TIMEOUT`-second watchdog that kills it, so a
# wedged sweep costs the daemon at most that many seconds instead of
# forever. See .claude/bugs/ (resolved) for the incident writeup.

load 'test_helper'

setup() {
    setup_mother_env
    # Swap in a fake `mother` binary so these tests control exactly how long
    # the "sweep" takes, instead of exercising the real cmd_archive (already
    # covered by teardown.bats). Put it on a directory ahead of the real
    # MOTHER_BIN_DIR and point MOTHER_BIN_DIR there, matching how
    # `_maybe_archive` resolves the binary it shells out to.
    _FAKE_BIN="$MOTHER_ROOT/fake-bin"
    mkdir -p "$_FAKE_BIN"
    export MOTHER_BIN_DIR="$_FAKE_BIN"
}

teardown() {
    # Best-effort reap of any orphaned fake-sweep process a "wedged sweep"
    # test left behind (the watchdog only kills the top-level wrapper
    # subshell, by design — see the comment in _maybe_archive — so the fake
    # `mother` process and its `sleep` can outlive the test itself).
    pkill -f "$_FAKE_BIN/mother" 2>/dev/null || true
    teardown_mother_env
}

# Usage: install_fake_mother <body>
# <body> is the shell source for what `mother archive ...` should do.
install_fake_mother() {
    local body="$1"
    cat > "$_FAKE_BIN/mother" <<EOF
#!/usr/bin/env bash
$body
EOF
    chmod +x "$_FAKE_BIN/mother"
}

@test "archive watchdog: a fast sweep runs to completion, no timeout fires" {
    install_fake_mother 'echo "archived: 1, teardown-only: 0, skipped: 0 (cutoff: 2000-01-01T00:00:00Z)"'
    export MOTHER_ARCHIVE_INTERVAL=0
    export MOTHER_ARCHIVE_TIMEOUT=10

    run mother-runner --archive-tick
    [ "$status" -eq 0 ]
    [[ "$output" == *"running archive sweep"* ]]
    [[ "$output" == *"archive: archived: 1, teardown-only: 0, skipped: 0"* ]]
    [[ "$output" != *"exceeded"* ]]

    # Marker was written so the interval gate doesn't re-fire immediately.
    [ -f "$RUNNER_DIR/last-archive.ts" ]
}

@test "archive watchdog: a wedged sweep is killed at the timeout and the tick still returns" {
    # Simulate the real incident: the fake sweep never exits on its own.
    # Deliberately NOT using bats' `run` here: it captures output via
    # command substitution (a pipe), and the watchdog's kill only reaches
    # the top-level wrapper subshell — the fake `mother` process and its
    # `sleep` are orphaned, not killed, and would keep the pipe's write end
    # open, hanging the capture for the full sleep duration regardless of
    # whether mother-runner itself already exited. Redirecting to a real
    # file and `wait`-ing on the specific pid sidesteps that; it's also
    # closer to production, where _log's fd is a log FILE, not a pipe.
    install_fake_mother 'sleep 15'
    export MOTHER_ARCHIVE_INTERVAL=0
    export MOTHER_ARCHIVE_TIMEOUT=2

    local outfile="$MOTHER_ROOT/archive-tick.out"
    local start_epoch elapsed
    start_epoch=$(date +%s)

    mother-runner --archive-tick > "$outfile" 2>&1 &
    local tick_pid=$!
    # Guard against a regression back to "hangs forever": if the fix breaks,
    # fail this test in ~15s instead of wedging the whole suite the way the
    # real incident wedged the daemon.
    ( sleep 15; kill -9 "$tick_pid" 2>/dev/null ) &
    local guard_pid=$!

    wait "$tick_pid" 2>/dev/null || true
    elapsed=$(( $(date +%s) - start_epoch ))
    kill "$guard_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true

    local output
    output="$(cat "$outfile")"
    [[ "$output" == *"exceeded 2s"* ]]
    [[ "$output" == *"dispatch resumes"* ]]
    # Bounded by MOTHER_ARCHIVE_TIMEOUT, not by the fake sweep's 15s sleep
    # or the test's own 15s guard.
    [ "$elapsed" -lt 10 ]
}

@test "archive watchdog: the interval gate skips a sweep entirely when not due" {
    install_fake_mother 'echo "should not run"'
    echo "$(date +%s)" > "$RUNNER_DIR/last-archive.ts"
    export MOTHER_ARCHIVE_INTERVAL=3600

    run mother-runner --archive-tick
    [ "$status" -eq 0 ]
    [[ "$output" != *"running archive sweep"* ]]
    [[ "$output" != *"should not run"* ]]
}
