#!/usr/bin/env bats
# teardown_docker_down.bats — teardown must not wait on Docker.
#
# Incident shape: Docker Desktop was down for days, and `_teardown_execute`
# parked every finished job as `docker_unreachable` BEFORE touching the
# worktree, so multi-GB worktrees (node_modules, target/) piled up on disk
# waiting for a daemon that is irrelevant to freeing them.
#
# Contract under test:
#   * docker unreachable no longer blocks the worktree step. The unsafe-worktree
#     guard and the race guard apply exactly as before.
#   * When the worktree was removed but docker was unreachable, the job is
#     parked as deferred / docker_unreachable_worktree_done with a pending
#     record carrying docker_pending + worktree_removed. No teardown_completed
#     yet.
#   * When the worktree step was skipped (main_dir / already_absent) and docker
#     was unreachable: parked as docker_unreachable with docker_pending set.
#   * A worktree error keeps today's failed / worktree_error park.
#   * A later drain of a docker_pending record runs ONLY the docker half: no
#     gate (no gh), no race check, no unsafe probe, no worktree step. Reachable
#     docker -> teardown_completed + record deleted. Still unreachable -> stays
#     parked silently (no new teardown_deferred event) while stall counters
#     keep counting.
#   * `mother teardowns` and the needs-attention item say so in words.

load 'test_helper'

# ---------------------------------------------------------------------------
# Fixtures & helpers (same conventions as teardown.bats)
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
# Usage: _make_teardown_job <id> <state> [extra-jq-filter]
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

# Facts blob for an existing job record (what cmd_archive would hand teardown).
_facts_for() {
    jq -c '{id, repo, repo_path, branch, work_dir, isolation, pr_url, state,
            no_pr: (.no_pr // false), events_path: ""}' "$JOBS_DIR/$1.json"
}

_source_teardown_libs() {
    printf "source '%s/state.sh'; source '%s/worktree.sh'; [ -r '%s/prdetect.sh' ] && source '%s/prdetect.sh'; source '%s/teardown.sh';" \
        "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR"
}

# Run _teardown_execute for a job and publish its outcome as $RC / $STATUS_OUT
# / $REASON_OUT. Output goes through a file, not a pipe: _docker_reachable's
# watchdog sleep can hold a pipe's write end open (see teardown_docker_timeout.bats).
# Usage: _td_execute <id> [dry_run]
_td_execute() {
    local id="$1" dry="${2:-0}" facts out="$MOTHER_ROOT/exec.out"
    facts=$(_facts_for "$id")
    bash -c "$(_source_teardown_libs) _teardown_execute '$facts' $dry; rc=\$?; echo \"RESULT RC=\$rc STATUS=\$TEARDOWN_LAST_STATUS REASON=\$TEARDOWN_LAST_REASON\"" \
        > "$out" 2>&1 || true
    RC=$(sed -n 's/^RESULT RC=\([0-9]*\) .*/\1/p' "$out" | tail -n1)
    STATUS_OUT=$(sed -n 's/^RESULT .* STATUS=\([a-z_]*\) REASON=.*/\1/p' "$out" | tail -n1)
    REASON_OUT=$(sed -n 's/^RESULT .* REASON=\(.*\)$/\1/p' "$out" | tail -n1)
    EXEC_OUTPUT=$(cat "$out")
}

# Compact JSON lines of every event of <kind> in a job's live events file.
_events_of_kind() {
    local f="$EVENTS_DIR/$1.jsonl"
    [ -f "$f" ] || return 0
    jq -c --arg k "$2" 'select(.kind == $k)' "$f"
}

_event_count() {
    local n
    n=$(_events_of_kind "$1" "$2" | wc -l | tr -d ' ')
    echo "${n:-0}"
}

_install_mock_gh() {
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-gh-calls"
case "$*" in
    *"pr view"*createdAt*) echo "2026-09-01T00:00:00Z" ;;
    *"pr view"*state*)     printf '%s\n' "${MOCK_GH_STATE:-OPEN}" ;;
    *)                     echo "" ;;
esac
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
}

_install_mock_docker() {
    cat > "$_MOCK_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-docker-args"
case "$1" in
    info) exit "${MOCK_DOCKER_INFO_EXIT:-0}" ;;
    ps|volume|network) echo ""; exit 0 ;;
    *) exit 0 ;;
esac
DOCKER
    chmod +x "$_MOCK_BIN/docker"
}

_pending() { echo "$TEARDOWN_DIR/$1.json"; }

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    # Keep the (watchdogged) docker probe quick when docker is "down".
    export MOTHER_DOCKER_PROBE_TIMEOUT=1
    _install_mock_gh
    _install_mock_docker
    export MOCK_DOCKER_INFO_EXIT=1
}

teardown() {
    teardown_mother_env
}

# ===========================================================================
# A1. Worktree is removed even though docker is unreachable
# ===========================================================================

@test "docker unreachable: the worktree is still removed and the job is parked as docker_unreachable_worktree_done" {
    local wt_dir
    wt_dir=$(_make_teardown_job "dd-wtdone" "failed")

    _td_execute "dd-wtdone"

    [ ! -d "$wt_dir" ]
    [ "$STATUS_OUT" = "deferred" ]
    [ "$REASON_OUT" = "docker_unreachable_worktree_done" ]
    [ "$RC" -eq 1 ]
}

@test "docker unreachable: the pending record says the worktree is gone and only docker is outstanding" {
    _make_teardown_job "dd-record" "failed" >/dev/null

    _td_execute "dd-record"

    [ -f "$(_pending dd-record)" ]
    [ "$(jq -r '.docker_pending' "$(_pending dd-record)")" = "true" ]
    [ "$(jq -r '.worktree_removed' "$(_pending dd-record)")" = "true" ]
    [ "$(jq -r '.last_reason' "$(_pending dd-record)")" = "docker_unreachable_worktree_done" ]
}

@test "docker unreachable: a teardown_deferred event carries the worktree-done detail, and teardown_completed is NOT emitted yet" {
    local wt_dir
    wt_dir=$(_make_teardown_job "dd-event" "failed")

    _td_execute "dd-event"

    local ev
    ev=$(_events_of_kind "dd-event" "teardown_deferred" | tail -n1)
    [ -n "$ev" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.reason')" = "docker_unreachable_worktree_done" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.worktree_removed')" = "true" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.docker_pending')" = "true" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.worktree_path')" = "$wt_dir" ]

    [ "$(_event_count dd-event teardown_completed)" = "0" ]
}

@test "docker unreachable: the unsafe-worktree guard still protects unrecovered work" {
    local wt_dir
    wt_dir=$(_make_teardown_job "dd-unsafe" "failed")
    echo "precious" > "$wt_dir/uncommitted.txt"

    _td_execute "dd-unsafe"

    [ -d "$wt_dir" ]
    [ -f "$wt_dir/uncommitted.txt" ]
    [ "$STATUS_OUT" = "deferred" ]
    [ "$REASON_OUT" = "unsafe_worktree" ]
}

@test "docker unreachable: the race guard still defers while another live job shares the branch" {
    local wt_dir
    wt_dir=$(_make_teardown_job "dd-race" "failed")
    make_job "dd-racer" "running" \
        ".repo_path = \"$MOTHER_ROOT/repo-dd-race\" | .branch = \"feature/dd-race\""

    _td_execute "dd-race"

    [ -d "$wt_dir" ]
    [ "$STATUS_OUT" = "deferred" ]
    [ "$REASON_OUT" = "race" ]
}

@test "docker unreachable: an unmerged-PR gate still defers before anything is touched" {
    export MOCK_GH_STATE="OPEN"
    local wt_dir
    wt_dir=$(_make_teardown_job "dd-gate" "succeeded" '.pr_url = "https://github.com/x/y/pull/21"')

    _td_execute "dd-gate"

    [ -d "$wt_dir" ]
    [ "$STATUS_OUT" = "deferred" ]
    [ "$REASON_OUT" = "pr_open" ]
}

@test "docker unreachable: a worktree removal error keeps the failed/worktree_error park" {
    # work_dir == repo_path is refused by the worktree step (status 2).
    local repo_dir="$MOTHER_ROOT/repo-dd-wterr"
    _make_teardown_repo "$repo_dir"
    make_job "dd-wterr" "failed" \
        ".repo_path = \"$repo_dir\" | .branch = \"feature/dd-wterr\" | .work_dir = \"$repo_dir\" | .isolation = \"worktree\" | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

    _td_execute "dd-wterr"

    [ -d "$repo_dir/.git" ]
    [ "$STATUS_OUT" = "failed" ]
    [ "$REASON_OUT" = "worktree_error" ]
    [ -f "$(_pending dd-wterr)" ]
}

# ===========================================================================
# A2. Worktree step skipped + docker unreachable
# ===========================================================================

@test "docker unreachable + main-dir job: parked as docker_unreachable with docker_pending, worktree_removed false" {
    local repo_dir="$MOTHER_ROOT/repo-dd-main"
    _make_teardown_repo "$repo_dir"
    make_job "dd-main" "failed" \
        ".repo_path = \"$repo_dir\" | .branch = \"main\" | .isolation = \"main-dir\" | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

    _td_execute "dd-main"

    [ -d "$repo_dir/.git" ]
    [ "$STATUS_OUT" = "deferred" ]
    [ "$REASON_OUT" = "docker_unreachable" ]
    [ "$(jq -r '.docker_pending' "$(_pending dd-main)")" = "true" ]
    [ "$(jq -r '.worktree_removed // false' "$(_pending dd-main)")" = "false" ]
    [ "$(_event_count dd-main teardown_completed)" = "0" ]
}

@test "docker unreachable + worktree already gone: parked as docker_unreachable with docker_pending, worktree_removed false" {
    local wt_dir
    wt_dir=$(_make_teardown_job "dd-absent" "failed")
    # The directory vanished out from under Mother (and git forgets it).
    git -C "$MOTHER_ROOT/repo-dd-absent" worktree remove --force "$wt_dir"

    _td_execute "dd-absent"

    [ "$STATUS_OUT" = "deferred" ]
    [ "$REASON_OUT" = "docker_unreachable" ]
    [ "$(jq -r '.docker_pending' "$(_pending dd-absent)")" = "true" ]
    [ "$(jq -r '.worktree_removed // false' "$(_pending dd-absent)")" = "false" ]
}

# ===========================================================================
# A3. Draining a docker_pending record runs ONLY the docker half
# ===========================================================================

# Park a job (succeeded + merged PR) in the docker_pending state, then change
# the world so any re-evaluation of the gate / race / worktree would be visible.
_park_docker_pending() {
    local id="$1"
    export MOCK_GH_STATE="MERGED"
    _make_teardown_job "$id" "succeeded" '.pr_url = "https://github.com/x/y/pull/31"' >/dev/null
    _td_execute "$id"
    [ "$REASON_OUT" = "docker_unreachable_worktree_done" ]
    [ "$(jq -r '.docker_pending' "$(_pending "$id")")" = "true" ]
}

@test "drain with docker back: runs the compose/label teardown, emits teardown_completed, clears the record" {
    _park_docker_pending "dd-drain-ok"
    export MOCK_DOCKER_INFO_EXIT=0
    : > "$MOTHER_ROOT/mock-docker-args"

    run mother teardowns --drain
    [ "$status" -eq 0 ]

    [ ! -f "$(_pending dd-drain-ok)" ]
    run grep -F "mother-dd-drain-ok" "$MOTHER_ROOT/mock-docker-args"
    [ "$status" -eq 0 ]
    [[ "$output" == *"down"* ]]

    local ev
    ev=$(_events_of_kind "dd-drain-ok" "teardown_completed" | tail -n1)
    [ -n "$ev" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.worktree_removed')" = "true" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.compose_project')" = "mother-dd-drain-ok" ]
    printf '%s' "$ev" | jq -e '.detail | has("containers") and has("volumes") and has("networks")' >/dev/null
    [ "$(_event_count dd-drain-ok teardown_completed)" = "1" ]
}

@test "drain with docker back: the live job record ends up torn_down" {
    _park_docker_pending "dd-drain-rec"
    export MOCK_DOCKER_INFO_EXIT=0

    run mother teardowns --drain
    [ "$status" -eq 0 ]

    [ "$(jq -r '.teardown_status' "$JOBS_DIR/dd-drain-rec.json")" = "torn_down" ]
}

@test "drain of a docker_pending record never re-runs the gate: no gh call even though the PR now reads open" {
    _park_docker_pending "dd-drain-nogate"
    export MOTHER_ROOT
    export MOCK_GH_STATE="OPEN"
    : > "$MOTHER_ROOT/mock-gh-calls"
    export MOCK_DOCKER_INFO_EXIT=0

    run mother teardowns --drain
    [ "$status" -eq 0 ]

    # Gate would have said pr_open and re-parked; instead docker finished.
    [ ! -f "$(_pending dd-drain-nogate)" ]
    [ ! -s "$MOTHER_ROOT/mock-gh-calls" ]
}

@test "drain of a docker_pending record never re-runs the race check: a live job on the same branch does not block it" {
    _park_docker_pending "dd-drain-norace"
    make_job "dd-drain-racer" "running" \
        ".repo_path = \"$MOTHER_ROOT/repo-dd-drain-norace\" | .branch = \"feature/dd-drain-norace\""
    export MOCK_DOCKER_INFO_EXIT=0

    run mother teardowns --drain
    [ "$status" -eq 0 ]

    [ ! -f "$(_pending dd-drain-norace)" ]
    [ "$(_event_count dd-drain-norace teardown_completed)" = "1" ]
}

@test "drain of a docker_pending record never touches a recreated worktree directory" {
    _park_docker_pending "dd-drain-nowt"
    # Something (a follow-up job on the same branch) recreated the directory.
    mkdir -p "$MOTHER_ROOT/wt-dd-drain-nowt"
    echo "follow-up work" > "$MOTHER_ROOT/wt-dd-drain-nowt/keep.txt"
    export MOCK_DOCKER_INFO_EXIT=0

    run mother teardowns --drain
    [ "$status" -eq 0 ]

    [ -f "$MOTHER_ROOT/wt-dd-drain-nowt/keep.txt" ]
    [ ! -f "$(_pending dd-drain-nowt)" ]
}

@test "drain with docker still down: stays parked and emits no further teardown_deferred events" {
    _park_docker_pending "dd-drain-down"
    [ "$(_event_count dd-drain-down teardown_deferred)" = "1" ]

    run mother teardowns --drain
    [ "$status" -eq 0 ]
    run mother teardowns --drain
    [ "$status" -eq 0 ]
    run mother teardowns --drain
    [ "$status" -eq 0 ]

    [ -f "$(_pending dd-drain-down)" ]
    [ "$(jq -r '.docker_pending' "$(_pending dd-drain-down)")" = "true" ]
    [ "$(_event_count dd-drain-down teardown_deferred)" = "1" ]
    [ "$(_event_count dd-drain-down teardown_completed)" = "0" ]
}

@test "drain with docker still down: stall counters keep counting" {
    _park_docker_pending "dd-drain-stalls"
    local before after
    before=$(jq -r '.stall_deferrals' "$(_pending dd-drain-stalls)")

    run mother teardowns --drain
    [ "$status" -eq 0 ]
    run mother teardowns --drain
    [ "$status" -eq 0 ]

    after=$(jq -r '.stall_deferrals' "$(_pending dd-drain-stalls)")
    [ "$after" -eq $((before + 2)) ]
}

@test "the hourly bulk archive sweep drains a docker_pending record once docker is back" {
    _park_docker_pending "dd-bulk"
    export MOCK_DOCKER_INFO_EXIT=0

    run mother archive
    [ "$status" -eq 0 ]

    [ ! -f "$(_pending dd-bulk)" ]
    run grep -rl '"kind":"teardown_completed"' "$MOTHER_ROOT/events" "$MOTHER_ROOT/archive" 2>/dev/null
    [ "$status" -eq 0 ]
}

@test "--dry-run teardown with docker unreachable removes nothing and writes no pending record" {
    local wt_dir
    wt_dir=$(_make_teardown_job "dd-dry" "failed")

    _td_execute "dd-dry" 1

    [ -d "$wt_dir" ]
    [ ! -f "$(_pending dd-dry)" ]
    [ "$(_event_count dd-dry teardown_deferred)" = "0" ]
}

# ===========================================================================
# A4. Operator visibility
# ===========================================================================

@test "mother teardowns lists a docker_pending record as 'docker pending' with 'worktree removed'" {
    _park_docker_pending "dd-list"

    run mother teardowns
    [ "$status" -eq 0 ]
    local line
    line=$(printf '%s\n' "$output" | grep -F "dd-list")
    [ -n "$line" ]
    [[ "$line" == *"docker pending"* ]]
    [[ "$line" == *"worktree removed"* ]]
}

@test "needs-attention: a stalled docker_pending record says the worktree is already gone and Docker is what is missing" {
    _park_docker_pending "dd-attn"
    # Cross the stall cap directly in the record.
    local tmp; tmp=$(mktemp)
    jq '.stall_deferrals = 999 | .deferrals = 999' "$(_pending dd-attn)" > "$tmp" && mv "$tmp" "$(_pending dd-attn)"

    run mother status --format json
    [ "$status" -eq 0 ]

    local item
    item=$(printf '%s' "$output" | jq -c '[.needs_attention[] | select(.kind == "teardown_stalled" and .job_id == "dd-attn")] | .[0] // empty')
    [ -n "$item" ]
    [ "$(printf '%s' "$item" | jq -r '.detail.docker_pending')" = "true" ]
    [ "$(printf '%s' "$item" | jq -r '.detail.worktree_removed')" = "true" ]
    local hint; hint=$(printf '%s' "$item" | jq -r '.hint')
    [[ "$hint" == *"worktree already removed"* ]]
    [[ "$hint" == *"Docker"* ]]
}
