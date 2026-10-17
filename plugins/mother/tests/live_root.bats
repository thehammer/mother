#!/usr/bin/env bats
# live_root.bats — MOTHER_LIVE_ROOT: how a worker finds the real state tree
# without exporting MOTHER_ROOT (which test harnesses then inherit and delete).
#
# Contract under test:
#   * Default root resolution is ${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}.
#     An explicit MOTHER_ROOT beats MOTHER_LIVE_ROOT.
#   * The worker wrapper mother-run-job generates exports MOTHER_LIVE_ROOT and
#     never `export MOTHER_ROOT=`.
#   * setup_mother_env scrubs an inherited MOTHER_LIVE_ROOT and marks the run
#     as a test (MOTHER_TEST_ROOT=1).

load 'test_helper'

setup() {
    setup_mother_env
    # Resolve-from-env tests: HOME is an empty throwaway so a broken
    # resolution can never touch the real ~/.mother.
    FAKE_HOME="$MOTHER_ROOT/fake-home"
    LIVE="$MOTHER_ROOT/live-tree"
    mkdir -p "$FAKE_HOME" "$LIVE"
    export MOTHER_NOTIFY_TRANSPORT=none
}

teardown() {
    # Tests scrub MOTHER_ROOT; restore it so the helper can remove its own tree.
    if [ -z "${MOTHER_ROOT:-}" ] && [ -n "${_MOTHER_TEST_ROOT:-}" ]; then
        export MOTHER_ROOT="$_MOTHER_TEST_ROOT"
    fi
    teardown_mother_env
}

# Drop every exported state-path var so the CLI must resolve the root itself.
_scrub_state_env() {
    unset MOTHER_ROOT JOBS_DIR EVENTS_DIR LOGS_DIR DRAFTS_DIR CURSORS_DIR \
          RUNNER_DIR ARCHIVE_DIR TEARDOWN_DIR RESIDUE_DIR MOTHER_LIVE_ROOT
    export HOME="$FAKE_HOME"
    export MOTHER_TEST_ROOT=1
}

# Write a minimal job record into <root>/jobs without touching the env.
_job_in() {
    local root="$1" id="$2"
    mkdir -p "$root/jobs"
    JOBS_DIR="$root/jobs" make_job "$id" ready
}

# ---------------------------------------------------------------------------
# Root resolution
# ---------------------------------------------------------------------------

@test "with MOTHER_ROOT unset, the CLI reads jobs from MOTHER_LIVE_ROOT" {
    _job_in "$LIVE" "from-live-root"
    _scrub_state_env
    export MOTHER_LIVE_ROOT="$LIVE"

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"from-live-root"* ]]
}

@test "with only MOTHER_LIVE_ROOT set, state directories are created under it, not under HOME" {
    _scrub_state_env
    export MOTHER_LIVE_ROOT="$LIVE"

    run mother list
    [ "$status" -eq 0 ]

    [ -d "$LIVE/jobs" ]
    [ -d "$LIVE/events" ]
    [ ! -e "$FAKE_HOME/.mother" ]
}

@test "an explicit MOTHER_ROOT beats MOTHER_LIVE_ROOT" {
    local explicit="$MOTHER_ROOT/explicit-tree"
    _job_in "$explicit" "job-in-explicit"
    _job_in "$LIVE" "job-in-live"
    _scrub_state_env
    export MOTHER_ROOT="$explicit"
    export MOTHER_LIVE_ROOT="$LIVE"

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"job-in-explicit"* ]]
    [[ "$output" != *"job-in-live"* ]]
}

@test "with neither variable set the CLI falls back to HOME/.mother" {
    _job_in "$FAKE_HOME/.mother" "from-home-default"
    _scrub_state_env

    run mother list
    [ "$status" -eq 0 ]
    [[ "$output" == *"from-home-default"* ]]
}

@test "mother status also resolves through MOTHER_LIVE_ROOT" {
    _job_in "$LIVE" "status-live-job"
    _scrub_state_env
    export MOTHER_LIVE_ROOT="$LIVE"

    run mother status status-live-job
    [ "$status" -eq 0 ]
    [[ "$output" == *"status-live-job"* ]]
    [ ! -e "$FAKE_HOME/.mother" ]
}

# ---------------------------------------------------------------------------
# Test harness hygiene
# ---------------------------------------------------------------------------

@test "setup_mother_env discards an inherited MOTHER_LIVE_ROOT and flags the run as a test" {
    teardown_mother_env
    export MOTHER_LIVE_ROOT="/nonexistent/inherited-live-root"
    unset MOTHER_TEST_ROOT

    setup_mother_env

    [ -z "${MOTHER_LIVE_ROOT:-}" ]
    [ "${MOTHER_TEST_ROOT:-}" = "1" ]
}

# ---------------------------------------------------------------------------
# Worker wrapper
# ---------------------------------------------------------------------------

@test "the generated worker wrapper exports MOTHER_LIVE_ROOT and never exports MOTHER_ROOT" {
    local repo id="wrap-live-root"
    repo="$(mktemp -d)"
    (
        cd "$repo"
        git init -b main >/dev/null 2>&1 || git init >/dev/null 2>&1
        git checkout -b main >/dev/null 2>&1 || true
        git config user.email t@example.com
        git config user.name T
        echo r > README.md
        git add . && git commit -q -m init
        git checkout -q -B "feature/test-$id" main
        git commit -q --allow-empty -m seed
        git checkout -q main
    ) >/dev/null 2>&1
    printf '#!/usr/bin/env bash\nexit 0\n' > "$_MOCK_BIN/gh"; chmod +x "$_MOCK_BIN/gh"
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=30
    export MOTHER_RESULT_GRACE_SECONDS=5

    make_job "$id" ready \
        '.isolation = "main-dir"
         | .repo_path = "'"$repo"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"t"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"t"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"t"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"t"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"

    # The worker stand-in snapshots the wrapper script that launched it.
    cat > "$_MOCK_BIN/claude" <<EOF
#!/usr/bin/env bash
cp "$RUNNER_DIR/$id.wrap" "$MOTHER_ROOT/captured.wrap" 2>/dev/null
env | grep -E '^MOTHER_(ROOT|LIVE_ROOT)=' > "$MOTHER_ROOT/captured.env" || true
exit 0
EOF
    chmod +x "$_MOCK_BIN/claude"

    run mother-run-job "$id"
    rm -rf "$repo"

    [ -s "$MOTHER_ROOT/captured.wrap" ]
    grep -qF "export MOTHER_LIVE_ROOT=\"$MOTHER_ROOT\"" "$MOTHER_ROOT/captured.wrap"
    ! grep -q 'export MOTHER_ROOT=' "$MOTHER_ROOT/captured.wrap"
    # Behavioural: MOTHER_ROOT is exported into this test (as it would be for a
    # daemon started with it set). The worker must still not inherit it.
    [ -s "$MOTHER_ROOT/captured.env" ]
    grep -qx "MOTHER_LIVE_ROOT=$MOTHER_ROOT" "$MOTHER_ROOT/captured.env"
    ! grep -q '^MOTHER_ROOT=' "$MOTHER_ROOT/captured.env"
}
