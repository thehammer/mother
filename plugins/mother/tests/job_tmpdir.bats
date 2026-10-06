#!/usr/bin/env bats
# job_tmpdir.bats — every worker gets its own scratch directory, and teardown removes it.
#
# Incident shape: workers (cargo, go, npm, test fixtures, tool sockets) dump
# gigabytes into the shared system temp dir, where nothing can tell whose it is
# or when it is safe to delete. Mother now gives each job a private TMPDIR,
# $MOTHER_ROOT/tmp/<job-id>, so removing exactly that job's leftovers is trivial.
#
# Contract under test:
#   * mother-run-job creates $MOTHER_ROOT/tmp/<job-id> before the worker starts
#     and the worker's environment has TMPDIR equal to that path.
#   * A teardown that completes (worktree removed, or skipped as main_dir /
#     already_absent — including the docker-pending park) removes that directory
#     and only that directory.
#   * A deferred teardown (PR still open, unsafe worktree, ...) and a --dry-run
#     teardown leave it alone.

load 'test_helper'

# ---------------------------------------------------------------------------
# Fixtures & helpers
# ---------------------------------------------------------------------------

_make_teardown_repo() {
    local repo_dir="$1"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
    local _origin_bare="${repo_dir}.origin.git"
    git init -q --bare "$_origin_bare"
    git -C "$repo_dir" remote add origin "$_origin_bare"
    git -C "$repo_dir" push -q origin HEAD:refs/heads/main
}

# Real repo + real worktree + job record. Echoes the worktree path.
_make_teardown_job() {
    local id="$1" state="$2" extra="${3:-.}"
    local repo_dir="$MOTHER_ROOT/repo-$id"
    local wt_dir="$MOTHER_ROOT/wt-$id"
    local branch="feature/$id"
    _make_teardown_repo "$repo_dir"
    git -C "$repo_dir" worktree add -q -b "$branch" "$wt_dir"
    make_job "$id" "$state" \
        ".repo_path = \"$repo_dir\" | .branch = \"$branch\" | .work_dir = \"$wt_dir\" | .isolation = \"worktree\" | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | ($extra)"
    echo "$wt_dir"
}

_facts_for() {
    jq -c '{id, repo, repo_path, branch, work_dir, isolation, pr_url, state,
            no_pr: (.no_pr // false), events_path: ""}' "$JOBS_DIR/$1.json"
}

_source_teardown_libs() {
    printf "source '%s/state.sh'; source '%s/worktree.sh'; [ -r '%s/prdetect.sh' ] && source '%s/prdetect.sh'; source '%s/teardown.sh';" \
        "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR"
}

_td_execute() {
    local id="$1" dry="${2:-0}" facts out="$MOTHER_ROOT/exec.out"
    facts=$(_facts_for "$id")
    bash -c "$(_source_teardown_libs) _teardown_execute '$facts' $dry; rc=\$?; echo \"RESULT RC=\$rc STATUS=\$TEARDOWN_LAST_STATUS REASON=\$TEARDOWN_LAST_REASON\"" \
        > "$out" 2>&1 || true
    RC=$(sed -n 's/^RESULT RC=\([0-9]*\) .*/\1/p' "$out" | tail -n1)
    STATUS_OUT=$(sed -n 's/^RESULT .* STATUS=\([a-z_]*\) REASON=.*/\1/p' "$out" | tail -n1)
    REASON_OUT=$(sed -n 's/^RESULT .* REASON=\(.*\)$/\1/p' "$out" | tail -n1)
}

# Give a job a populated scratch dir, as a finished worker would leave it.
_job_tmp() {
    mkdir -p "$MOTHER_ROOT/tmp/$1/build/cache"
    head -c 2000 /dev/zero > "$MOTHER_ROOT/tmp/$1/build/cache/blob"
    echo "sock" > "$MOTHER_ROOT/tmp/$1/tool.sock"
}

_install_mocks() {
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-gh-calls"
case "$*" in
    *"pr view"*createdAt*) echo "2026-09-01T00:00:00Z" ;;
    *"pr view"*state*)     printf '%s\n' "${MOCK_GH_STATE:-MERGED}" ;;
    *)                     echo "" ;;
esac
exit 0
GH
    cat > "$_MOCK_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-docker-args"
case "$1" in
    info) exit "${MOCK_DOCKER_INFO_EXIT:-0}" ;;
    ps|volume|network) echo ""; exit 0 ;;
    *) exit 0 ;;
esac
DOCKER
    chmod +x "$_MOCK_BIN/gh" "$_MOCK_BIN/docker"
}

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_DOCKER_PROBE_TIMEOUT=1
    export MOTHER_POSTURE_ENABLED=0
    _install_mocks

    # A real repo for end-to-end worker runs.
    export TEST_REPO_DIR="$MOTHER_ROOT/e2e-repo"
    mkdir -p "$TEST_REPO_DIR"
    (
        cd "$TEST_REPO_DIR"
        git init -q -b main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add .
        git commit -q -m "init"
    ) >/dev/null 2>&1
}

teardown() {
    teardown_mother_env
}

# A main-dir, no_pr job against TEST_REPO_DIR, runnable by mother-run-job
# (same shape as worker_lifecycle.bats).
_make_runnable_job() {
    local id="$1"
    git -C "$TEST_REPO_DIR" branch -f "feature/test-$id" main
    git -C "$TEST_REPO_DIR" checkout -q "feature/test-$id"
    git -C "$TEST_REPO_DIR" commit -q --allow-empty -m "seed for $id"
    git -C "$TEST_REPO_DIR" checkout -q main
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo_path = "'"$TEST_REPO_DIR"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"
}

# ===========================================================================
# E1. The worker runs with a job-scoped TMPDIR
# ===========================================================================

@test "mother-run-job gives the worker TMPDIR=\$MOTHER_ROOT/tmp/<job-id>, and the directory exists when the worker starts" {
    _make_runnable_job "jt-env"
    mkdir -p "$MOTHER_ROOT/ambient-tmp"
    export MOCK_CLAUDE_ENV_FILE="$MOTHER_ROOT/worker-env-jt-env"

    TMPDIR="$MOTHER_ROOT/ambient-tmp" run mother-run-job "jt-env"
    [ "$status" -eq 0 ]

    [ -f "$MOCK_CLAUDE_ENV_FILE" ]
    [ "$(sed -n 's/^TMPDIR=//p' "$MOCK_CLAUDE_ENV_FILE")" = "$MOTHER_ROOT/tmp/jt-env" ]
    [ "$(sed -n 's/^TMPDIR_EXISTS=//p' "$MOCK_CLAUDE_ENV_FILE")" = "yes" ]
    [ -d "$MOTHER_ROOT/tmp/jt-env" ]
}

@test "mother-run-job gives each job its own TMPDIR" {
    _make_runnable_job "jt-one"
    _make_runnable_job "jt-two"

    MOCK_CLAUDE_ENV_FILE="$MOTHER_ROOT/worker-env-one" run mother-run-job "jt-one"
    [ "$status" -eq 0 ]
    MOCK_CLAUDE_ENV_FILE="$MOTHER_ROOT/worker-env-two" run mother-run-job "jt-two"
    [ "$status" -eq 0 ]

    [ "$(sed -n 's/^TMPDIR=//p' "$MOTHER_ROOT/worker-env-one")" = "$MOTHER_ROOT/tmp/jt-one" ]
    [ "$(sed -n 's/^TMPDIR=//p' "$MOTHER_ROOT/worker-env-two")" = "$MOTHER_ROOT/tmp/jt-two" ]
}

# ===========================================================================
# E2. Teardown removes the job's scratch directory
# ===========================================================================

@test "a teardown that removes the worktree also removes the job's TMPDIR" {
    local wt_dir
    wt_dir=$(_make_teardown_job "jt-td" "failed")
    _job_tmp "jt-td"

    _td_execute "jt-td"

    [ "$STATUS_OUT" = "torn_down" ]
    [ ! -d "$wt_dir" ]
    [ ! -e "$MOTHER_ROOT/tmp/jt-td" ]
}

@test "teardown removes only that job's TMPDIR, never a sibling's or the tmp root" {
    _make_teardown_job "jt-mine" "failed" >/dev/null
    _job_tmp "jt-mine"
    _job_tmp "jt-sibling"
    echo "stray" > "$MOTHER_ROOT/tmp/stray-file"

    _td_execute "jt-mine"

    [ ! -e "$MOTHER_ROOT/tmp/jt-mine" ]
    [ -f "$MOTHER_ROOT/tmp/jt-sibling/tool.sock" ]
    [ -f "$MOTHER_ROOT/tmp/stray-file" ]
}

@test "a teardown that skips the worktree step (main-dir job) still removes the job's TMPDIR" {
    local repo_dir="$MOTHER_ROOT/repo-jt-main"
    _make_teardown_repo "$repo_dir"
    make_job "jt-main" "failed" \
        ".repo_path = \"$repo_dir\" | .branch = \"main\" | .isolation = \"main-dir\" | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    _job_tmp "jt-main"

    _td_execute "jt-main"

    [ "$STATUS_OUT" = "skipped" ]
    [ -d "$repo_dir/.git" ]
    [ ! -e "$MOTHER_ROOT/tmp/jt-main" ]
}

@test "a teardown whose worktree is already gone still removes the job's TMPDIR" {
    local wt_dir
    wt_dir=$(_make_teardown_job "jt-absent" "failed")
    git -C "$MOTHER_ROOT/repo-jt-absent" worktree remove --force "$wt_dir"
    _job_tmp "jt-absent"

    _td_execute "jt-absent"

    [ "$STATUS_OUT" = "skipped" ]
    [ ! -e "$MOTHER_ROOT/tmp/jt-absent" ]
}

@test "the docker-pending park (docker down, worktree removed) also removes the job's TMPDIR" {
    export MOCK_DOCKER_INFO_EXIT=1
    local wt_dir
    wt_dir=$(_make_teardown_job "jt-dockerdown" "failed")
    _job_tmp "jt-dockerdown"

    _td_execute "jt-dockerdown"

    [ "$STATUS_OUT" = "deferred" ]
    [ ! -d "$wt_dir" ]
    [ ! -e "$MOTHER_ROOT/tmp/jt-dockerdown" ]
}

@test "mother archive <id> removes the job's TMPDIR when the teardown completes" {
    export MOCK_GH_STATE="MERGED"
    local wt_dir
    wt_dir=$(_make_teardown_job "jt-archive" "succeeded" '.pr_url = "https://github.com/x/y/pull/51"')
    _job_tmp "jt-archive"

    run mother archive "jt-archive"
    [ "$status" -eq 0 ]

    [ ! -d "$wt_dir" ]
    [ ! -e "$MOTHER_ROOT/tmp/jt-archive" ]
}

# ===========================================================================
# E3. Teardown that does not complete leaves it alone
# ===========================================================================

@test "a deferred teardown (PR still open) leaves the job's TMPDIR in place" {
    export MOCK_GH_STATE="OPEN"
    local wt_dir
    wt_dir=$(_make_teardown_job "jt-pr-open" "succeeded" '.pr_url = "https://github.com/x/y/pull/52"')
    _job_tmp "jt-pr-open"

    _td_execute "jt-pr-open"

    [ "$STATUS_OUT" = "deferred" ]
    [ -d "$wt_dir" ]
    [ -f "$MOTHER_ROOT/tmp/jt-pr-open/tool.sock" ]
    [ -f "$MOTHER_ROOT/tmp/jt-pr-open/build/cache/blob" ]
}

@test "a teardown deferred for an unsafe worktree leaves the job's TMPDIR in place" {
    local wt_dir
    wt_dir=$(_make_teardown_job "jt-unsafe" "failed")
    echo "unsaved" > "$wt_dir/uncommitted.txt"
    _job_tmp "jt-unsafe"

    _td_execute "jt-unsafe"

    [ "$REASON_OUT" = "unsafe_worktree" ]
    [ -f "$wt_dir/uncommitted.txt" ]
    [ -f "$MOTHER_ROOT/tmp/jt-unsafe/tool.sock" ]
}

@test "a --dry-run teardown leaves the job's TMPDIR in place" {
    local wt_dir
    wt_dir=$(_make_teardown_job "jt-dry" "failed")
    _job_tmp "jt-dry"

    _td_execute "jt-dry" 1

    [ -d "$wt_dir" ]
    [ -f "$MOTHER_ROOT/tmp/jt-dry/tool.sock" ]
    [ -f "$MOTHER_ROOT/tmp/jt-dry/build/cache/blob" ]
}

@test "mother archive <id> --dry-run leaves the job's TMPDIR in place" {
    export MOCK_GH_STATE="MERGED"
    _make_teardown_job "jt-archive-dry" "succeeded" '.pr_url = "https://github.com/x/y/pull/53"' >/dev/null
    _job_tmp "jt-archive-dry"

    run mother archive "jt-archive-dry" --dry-run
    [ "$status" -eq 0 ]

    [ -f "$MOTHER_ROOT/tmp/jt-archive-dry/tool.sock" ]
}
