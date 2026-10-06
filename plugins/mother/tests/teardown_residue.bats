#!/usr/bin/env bats
# teardown_residue.bats — directories a removed worktree leaves behind.
#
# `git worktree remove` only knows about tracked files and its own admin
# entry. Ignored / generated output (node_modules, target/, containers writing
# root-owned files) can leave a plain, non-git directory at the job's recorded
# work_dir, long after git has forgotten the worktree. That residue used to be
# classified `already_absent` and ignored forever, eating disk.
#
# Contract under test:
#   * A directory Mother recorded as a job's work_dir that still exists, has no
#     `.git` entry and is no longer a registered worktree is removed (rm -rf);
#     the worktree step reports success.
#   * A directory WITH a `.git` entry that is not a registered worktree (a
#     standalone clone) is never deleted — it is skipped as already_absent.
#   * Residue that cannot be removed (root-owned/unreadable files) never fails
#     the sweep. A `teardown_residue` event {path, sub, command}, a durable
#     record $MOTHER_ROOT/teardown-residue/<id>.json and a `teardown_residue`
#     needs-attention item are produced instead. The suggested command is text
#     only: Mother never runs sudo (or docker run) itself.
#   * --dry-run never removes residue.

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

# Real repo + real worktree + job record (terminal, finished now). Echoes the
# worktree path. Usage: _make_teardown_job <id> <state> [extra-jq-filter]
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

# Job whose git worktree is already gone from git's registry but whose
# recorded work_dir still holds ignored/generated residue (no .git).
# The job's PR is merged (so the unrecovered-work probe is not involved).
# Usage: _make_residue_job <id>   (echoes the residue dir)
_make_residue_job() {
    local id="$1" wt_dir
    wt_dir=$(_make_teardown_job "$id" "succeeded" '.pr_url = "https://github.com/x/y/pull/41"')
    git -C "$MOTHER_ROOT/repo-$id" worktree remove --force "$wt_dir"
    git -C "$MOTHER_ROOT/repo-$id" worktree prune
    mkdir -p "$wt_dir/target/debug" "$wt_dir/node_modules/pkg"
    echo "artifact" > "$wt_dir/target/debug/app"
    echo "module" > "$wt_dir/node_modules/pkg/index.js"
    echo "junk" > "$wt_dir/leftover.log"
    echo "$wt_dir"
}

# Make a residue dir impossible for a non-root rm -rf to remove: an unreadable
# node_modules/ with a file inside. Everything else in the dir stays removable.
_lock_node_modules() {
    local dir="$1"
    rm -rf "$dir/target" "$dir/leftover.log"
    chmod 000 "$dir/node_modules"
}

_facts_for() {
    jq -c '{id, repo, repo_path, branch, work_dir, isolation, pr_url, state,
            no_pr: (.no_pr // false), events_path: ""}' "$JOBS_DIR/$1.json"
}

_source_teardown_libs() {
    printf "source '%s/state.sh'; source '%s/worktree.sh'; [ -r '%s/prdetect.sh' ] && source '%s/prdetect.sh'; source '%s/teardown.sh';" \
        "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR"
}

# Call _teardown_worktree directly; publishes RC / SKIP_OUT.
# Usage: _tw_call <id> [dry_run]
_tw_call() {
    local id="$1" dry="${2:-0}" facts out="$MOTHER_ROOT/tw.out"
    facts=$(_facts_for "$id")
    bash -c "$(_source_teardown_libs) TEARDOWN_WORKTREE_SKIP_REASON=''; _teardown_worktree '$facts' $dry; rc=\$?; echo \"RESULT RC=\$rc SKIP=\$TEARDOWN_WORKTREE_SKIP_REASON\"" \
        > "$out" 2>&1 || true
    RC=$(sed -n 's/^RESULT RC=\([0-9]*\) .*/\1/p' "$out" | tail -n1)
    SKIP_OUT=$(sed -n 's/^RESULT .* SKIP=\(.*\)$/\1/p' "$out" | tail -n1)
}

# Call _teardown_execute directly; publishes RC / STATUS_OUT / REASON_OUT.
_td_execute() {
    local id="$1" dry="${2:-0}" facts out="$MOTHER_ROOT/exec.out"
    facts=$(_facts_for "$id")
    bash -c "$(_source_teardown_libs) _teardown_execute '$facts' $dry; rc=\$?; echo \"RESULT RC=\$rc STATUS=\$TEARDOWN_LAST_STATUS REASON=\$TEARDOWN_LAST_REASON\"" \
        > "$out" 2>&1 || true
    RC=$(sed -n 's/^RESULT RC=\([0-9]*\) .*/\1/p' "$out" | tail -n1)
    STATUS_OUT=$(sed -n 's/^RESULT .* STATUS=\([a-z_]*\) REASON=.*/\1/p' "$out" | tail -n1)
    REASON_OUT=$(sed -n 's/^RESULT .* REASON=\(.*\)$/\1/p' "$out" | tail -n1)
}

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
    # Tripwire: Mother must never run sudo.
    cat > "$_MOCK_BIN/sudo" <<'SUDO'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-sudo-calls"
exit 1
SUDO
    chmod +x "$_MOCK_BIN/gh" "$_MOCK_BIN/docker" "$_MOCK_BIN/sudo"
}

_require_non_root() {
    if [ "$(id -u)" = "0" ]; then
        skip "running as root: chmod 000 cannot make rm -rf fail"
    fi
}

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_DOCKER_PROBE_TIMEOUT=1
    export MOCK_GH_STATE="MERGED"
    _install_mocks
}

teardown() {
    # Locked fixture dirs would make the final rm -rf fail and leak.
    chmod -R u+rwx "$MOTHER_ROOT" 2>/dev/null || true
    teardown_mother_env
}

# ===========================================================================
# B1. Residue with no .git that git no longer knows about is removed
# ===========================================================================

@test "_teardown_worktree: an unregistered directory with no .git at the recorded work_dir is removed" {
    local dir
    dir=$(_make_residue_job "rs-unit")
    [ -d "$dir/node_modules/pkg" ]
    [ ! -e "$dir/.git" ]

    _tw_call "rs-unit"

    [ "$RC" -eq 0 ]
    [ ! -e "$dir" ]
}

@test "_teardown_worktree: a real worktree full of ignored build output (node_modules, target) is fully removed" {
    local wt_dir
    wt_dir=$(_make_teardown_job "rs-ignored" "succeeded" '.pr_url = "https://github.com/x/y/pull/42"')
    printf 'node_modules/\ntarget/\n' >> "$MOTHER_ROOT/repo-rs-ignored/.git/info/exclude"
    mkdir -p "$wt_dir/node_modules/a/b" "$wt_dir/target/debug"
    echo x > "$wt_dir/node_modules/a/b/c.js"
    echo x > "$wt_dir/target/debug/app"

    _tw_call "rs-ignored"

    [ "$RC" -eq 0 ]
    [ ! -e "$wt_dir" ]
    run git -C "$MOTHER_ROOT/repo-rs-ignored" worktree list --porcelain
    [[ "$output" != *"wt-rs-ignored"* ]]
}

@test "_teardown_worktree: a directory that still has a .git entry but is not a registered worktree is never deleted" {
    local dir
    dir=$(_make_residue_job "rs-clone")
    # Turn the leftover dir into a standalone clone (an operator's own checkout).
    rm -rf "$dir"
    git clone -q "$MOTHER_ROOT/repo-rs-clone.origin.git" "$dir"
    echo "my work" > "$dir/mine.txt"

    _tw_call "rs-clone"

    [ "$RC" -eq 1 ]
    [ "$SKIP_OUT" = "already_absent" ]
    [ -d "$dir/.git" ]
    [ -f "$dir/mine.txt" ]
}

@test "_teardown_worktree: --dry-run reports but does not remove residue" {
    local dir
    dir=$(_make_residue_job "rs-dry-unit")

    _tw_call "rs-dry-unit" 1

    [ -d "$dir/node_modules/pkg" ]
    [ -f "$dir/leftover.log" ]
}

# ===========================================================================
# B1 (end to end). The sweep clears residue
# ===========================================================================

@test "mother archive: residue left at a merged job's work_dir is removed and the job reads torn_down" {
    local dir
    dir=$(_make_residue_job "rs-e2e")

    run mother archive "rs-e2e"
    [ "$status" -eq 0 ]

    [ ! -e "$dir" ]
    [ ! -f "$TEARDOWN_DIR/rs-e2e.json" ]
    [ ! -e "$MOTHER_ROOT/teardown-residue/rs-e2e.json" ]
}

@test "mother archive --dry-run never removes residue and records nothing" {
    local dir
    dir=$(_make_residue_job "rs-e2e-dry")

    run mother archive "rs-e2e-dry" --dry-run
    [ "$status" -eq 0 ]

    [ -f "$dir/node_modules/pkg/index.js" ]
    [ -f "$dir/leftover.log" ]
    [ ! -e "$MOTHER_ROOT/teardown-residue/rs-e2e-dry.json" ]
    [ "$(_event_count rs-e2e-dry teardown_residue)" = "0" ]
}

# ===========================================================================
# B2. Unremovable residue never fails the sweep; it is surfaced instead
# ===========================================================================

@test "unremovable residue: _teardown_execute still completes as torn_down (rc 0)" {
    _require_non_root
    local dir
    dir=$(_make_residue_job "rs-lock-exec")
    _lock_node_modules "$dir"

    _td_execute "rs-lock-exec"

    [ "$RC" -eq 0 ]
    [ "$STATUS_OUT" = "torn_down" ]
    # The unreadable part is still there; the removable part is gone.
    [ -d "$dir/node_modules" ]
}

@test "unremovable residue: mother archive <id> exits 0" {
    _require_non_root
    local dir
    dir=$(_make_residue_job "rs-lock-archive")
    _lock_node_modules "$dir"

    run mother archive "rs-lock-archive"
    [ "$status" -eq 0 ]
}

@test "unremovable residue: a teardown_residue event names the path, the first remaining entry and a suggested command" {
    _require_non_root
    local dir
    dir=$(_make_residue_job "rs-lock-event")
    _lock_node_modules "$dir"

    _td_execute "rs-lock-event"

    local ev
    ev=$(_events_of_kind "rs-lock-event" "teardown_residue" | tail -n1)
    [ -n "$ev" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.path')" = "$dir" ]
    [ "$(printf '%s' "$ev" | jq -r '.detail.sub')" = "node_modules" ]
    local cmd; cmd=$(printf '%s' "$ev" | jq -r '.detail.command')
    [ -n "$cmd" ]
    [[ "$cmd" == *"$dir"* ]]
}

@test "unremovable residue: a durable record is written under teardown-residue/<id>.json" {
    _require_non_root
    local dir
    dir=$(_make_residue_job "rs-lock-record")
    _lock_node_modules "$dir"

    _td_execute "rs-lock-record"

    local rec="$MOTHER_ROOT/teardown-residue/rs-lock-record.json"
    [ -f "$rec" ]
    jq -e 'has("id") and has("repo") and has("branch") and has("path") and has("sub") and has("since") and has("command")' "$rec" >/dev/null
    [ "$(jq -r '.id' "$rec")" = "rs-lock-record" ]
    [ "$(jq -r '.branch' "$rec")" = "feature/rs-lock-record" ]
    [ "$(jq -r '.path' "$rec")" = "$dir" ]
    [ "$(jq -r '.sub' "$rec")" = "node_modules" ]
    [ -n "$(jq -r '.since' "$rec")" ]
}

@test "unremovable residue: needs-attention lists it with a docker-run command and a sudo fallback, and it disappears once the dir is gone" {
    _require_non_root
    local dir
    dir=$(_make_residue_job "rs-lock-attn")
    _lock_node_modules "$dir"
    _td_execute "rs-lock-attn"

    run mother status --format json
    [ "$status" -eq 0 ]
    local item
    item=$(printf '%s' "$output" | jq -c '[.needs_attention[] | select(.kind == "teardown_residue" and .job_id == "rs-lock-attn")] | .[0] // empty')
    [ -n "$item" ]
    local hint; hint=$(printf '%s' "$item" | jq -r '.hint')
    [[ "$hint" == *"docker run --rm -v $dir:/x alpine rm -rf /x/node_modules"* ]]
    [[ "$hint" == *"sudo"* ]]

    # The operator cleans it up by hand.
    chmod -R u+rwx "$dir"
    rm -rf "$dir"

    run mother status --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq '[.needs_attention[] | select(.kind == "teardown_residue" and .job_id == "rs-lock-attn")] | length')" = "0" ]
}

@test "unremovable residue: Mother never runs sudo or docker run itself" {
    _require_non_root
    local dir
    dir=$(_make_residue_job "rs-lock-nosudo")
    _lock_node_modules "$dir"

    run mother archive "rs-lock-nosudo"
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_ROOT/mock-sudo-calls" ]
    run grep -E '^run( |$)' "$MOTHER_ROOT/mock-docker-args"
    [ "$status" -ne 0 ]
}

@test "unremovable residue: --dry-run neither removes anything nor records residue" {
    _require_non_root
    local dir
    dir=$(_make_residue_job "rs-lock-dry")
    echo "keep" > "$dir/leftover2.log"
    chmod 000 "$dir/node_modules"

    run mother archive "rs-lock-dry" --dry-run
    [ "$status" -eq 0 ]

    [ -f "$dir/leftover2.log" ]
    [ -f "$dir/leftover.log" ]
    [ ! -e "$MOTHER_ROOT/teardown-residue/rs-lock-dry.json" ]
    [ "$(_event_count rs-lock-dry teardown_residue)" = "0" ]
}
