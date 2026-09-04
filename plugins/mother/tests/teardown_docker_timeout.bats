#!/usr/bin/env bats
# teardown_docker_timeout.bats — regression coverage for _docker_reachable,
# the timeout-guarded probe `_teardown_docker` uses in place of a bare
# `docker info` call.
#
# Incident: a wedged Docker Desktop backend (socket alive, daemon
# unresponsive — as opposed to "not running", which fails fast) caused
# `docker info --format '{{.ServerVersion}}'` to block forever. Every
# caller of `_teardown_docker` inherited the hang, including
# `mother archive <id>` run interactively with no watchdog of its own —
# concretely, the `mother-switcher` fzf popup's `ctrl-d` binding, which
# runs that command via `execute-silent` and froze the whole popup with no
# feedback. See .claude/bug-reports/ (resolved) for the incident writeup.
#
# `_docker_reachable` (lib/teardown.sh) now races the probe against a
# `MOTHER_DOCKER_PROBE_TIMEOUT`-second watchdog, mirroring the background-
# race pattern `_maybe_archive` (mother-runner) already uses for its own
# hourly-sweep watchdog.

load 'test_helper'

# Shell snippet that sources the libs needed to call lib/teardown.sh
# functions directly, in the order bin/mother would. Mirrors
# teardown.bats's helper of the same name.
_source_teardown_libs() {
    printf "source '%s/state.sh'; source '%s/worktree.sh'; source '%s/teardown.sh';" \
        "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR"
}

# Run a lib/teardown.sh call and capture its exit status into $status.
#
# Deliberately NOT using bats' `run` here: it captures output via command
# substitution (a pipe), and that pipe only reports EOF once every process
# holding its write end has closed it — including the watchdog subshell
# _docker_reachable backgrounds internally. Even though _docker_reachable
# kills and reaps that watchdog itself before returning, its stdout fd was
# inherited from the pipe, and in practice `run` still blocked for the full
# MOTHER_DOCKER_PROBE_TIMEOUT before reporting output, defeating the point
# of these tests (confirmed empirically while writing this file). Redirecting
# to a real file sidesteps it entirely — same fix archive_watchdog.bats
# applies to the analogous _maybe_archive sweep-watchdog tests, for the same
# underlying reason.
# Usage: _run_teardown_fn <call-expression>
_run_teardown_fn() {
    local call="$1"
    local outfile="$MOTHER_ROOT/fn.out"
    # bats runs test bodies with errexit, so a plain `cmd; status=$?` would
    # abort the test right at `cmd` for any nonzero exit (which is exactly
    # what several of these tests expect) before `status` is ever set. The
    # if/else form checks the exit status without tripping errexit.
    if bash -c "$(_source_teardown_libs) $call" > "$outfile" 2>&1; then
        status=0
    else
        status=$?
    fi
    output="$(cat "$outfile")"
}

# Install a fake `docker` on PATH ahead of the real one.
# Usage: _install_fake_docker <mode>
#   hang -> `docker info` sleeps far past any timeout under test
#   ok   -> `docker info` exits 0 immediately
#   fail -> `docker info` exits 1 immediately (fast failure, not a hang)
# `ps`/`volume`/`network` always echo nothing and exit 0 (nothing to
# remove), matching _install_mock_docker in teardown.bats, so a full
# _teardown_docker call can run past the reachability check without erroring.
_install_fake_docker() {
    local mode="$1"
    cat > "$_MOCK_BIN/docker" <<EOF
#!/usr/bin/env bash
case "\$1" in
    info)
        case "$mode" in
            hang) sleep 100 ;;
            ok)   exit 0 ;;
            fail) exit 1 ;;
        esac
        ;;
    ps|volume|network)
        echo ""
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
    chmod +x "$_MOCK_BIN/docker"
}

# Minimal facts blob for a standalone _teardown_docker call.
# Usage: _facts_json <id> <work_dir>
_facts_json() {
    local id="$1" work_dir="$2"
    jq -nc --arg id "$id" --arg work_dir "$work_dir" \
        '{id: $id, repo: "testrepo", repo_path: "/tmp/testrepo", branch: "b",
          work_dir: $work_dir, isolation: "worktree", pr_url: null,
          state: "succeeded", no_pr: false, events_path: ""}'
}

setup() {
    setup_mother_env
}

teardown() {
    # Best-effort reap of any leftover fake `docker info` sleep the watchdog
    # could only partially reach (see the doc comment on _docker_reachable
    # for why: killing the probe's immediate pid does not reach a stuck
    # grandchild it may have spawned).
    pkill -f "$_MOCK_BIN/docker" 2>/dev/null || true
    teardown_mother_env
}

@test "_docker_reachable: a wedged docker info is killed at the timeout instead of hanging" {
    _install_fake_docker hang
    export MOTHER_DOCKER_PROBE_TIMEOUT=2

    local start_epoch elapsed
    start_epoch=$(date +%s)
    _run_teardown_fn "_docker_reachable"
    elapsed=$(( $(date +%s) - start_epoch ))

    [ "$status" -ne 0 ]
    # Bounded by MOTHER_DOCKER_PROBE_TIMEOUT (2s), not by the fake docker's
    # 100s sleep.
    [ "$elapsed" -lt 10 ]
}

@test "_teardown_docker: a wedged docker info defers (returns 2) within a bounded time" {
    _install_fake_docker hang
    export MOTHER_DOCKER_PROBE_TIMEOUT=2
    local facts
    facts=$(_facts_json "job-hang" "/tmp/wt-hang")

    local start_epoch elapsed
    start_epoch=$(date +%s)
    _run_teardown_fn "_teardown_docker '$facts'"
    elapsed=$(( $(date +%s) - start_epoch ))

    [ "$status" -eq 2 ]
    [ "$elapsed" -lt 10 ]
}

@test "_docker_reachable: docker responding successfully returns 0 promptly" {
    _install_fake_docker ok
    export MOTHER_DOCKER_PROBE_TIMEOUT=5

    local start_epoch elapsed
    start_epoch=$(date +%s)
    _run_teardown_fn "_docker_reachable"
    elapsed=$(( $(date +%s) - start_epoch ))

    [ "$status" -eq 0 ]
    # Resolves as soon as the probe exits, not after the watchdog window.
    [ "$elapsed" -lt 5 ]
}

@test "_teardown_docker: docker responding successfully proceeds past the reachability check" {
    _install_fake_docker ok
    export MOTHER_DOCKER_PROBE_TIMEOUT=5
    local facts
    facts=$(_facts_json "job-ok" "/tmp/wt-ok")

    _run_teardown_fn "_teardown_docker '$facts'"

    # Not 2 (defer) -- the reachability check passed, so _teardown_docker
    # moved on to the compose/label sweep and returned its normal 0 (clean).
    [ "$status" -eq 0 ]
}

@test "_docker_reachable: docker info failing fast returns 1 without waiting for the timeout window" {
    _install_fake_docker fail
    export MOTHER_DOCKER_PROBE_TIMEOUT=5

    local start_epoch elapsed
    start_epoch=$(date +%s)
    _run_teardown_fn "_docker_reachable"
    elapsed=$(( $(date +%s) - start_epoch ))

    [ "$status" -ne 0 ]
    # The race should resolve as soon as the probe subshell exits (fast
    # failure), not only once the watchdog fires at MOTHER_DOCKER_PROBE_TIMEOUT.
    [ "$elapsed" -lt 5 ]
}

@test "_teardown_docker: docker info failing fast defers (returns 2) without waiting for the timeout window" {
    _install_fake_docker fail
    export MOTHER_DOCKER_PROBE_TIMEOUT=5
    local facts
    facts=$(_facts_json "job-fail" "/tmp/wt-fail")

    local start_epoch elapsed
    start_epoch=$(date +%s)
    _run_teardown_fn "_teardown_docker '$facts'"
    elapsed=$(( $(date +%s) - start_epoch ))

    [ "$status" -eq 2 ]
    [ "$elapsed" -lt 5 ]
}
