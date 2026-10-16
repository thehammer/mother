#!/usr/bin/env bats
# cargo_targets.bats — `mother gc` reclaims idle Rust target/ dirs of job worktrees.
#
# Contract under test (lib/gc.sh, bin/mother, bin/mother-runner):
#   * Candidates are the distinct work_dirs of Mother job records whose
#     isolation is "worktree" and whose work_dir is not the repo_path. The
#     directory <work_dir>/target is deleted (rm -rf) only when ALL hold:
#       - <work_dir>/Cargo.toml exists
#       - <work_dir>/.git is a regular FILE (a linked worktree) whose first line is
#         `gitdir: <path>` with <path> an existing directory named
#         .../worktrees/<name>: a main checkout (.git directory), a symlinked
#         .git, no .git, or an empty/garbage/submodule-style/dangling pointer
#         is never touched
#       - target is a real directory (not a symlink) that contains CACHEDIR.TAG,
#         and its physical path is <physical work_dir>/target
#       - no job referencing that work_dir is live: queued|ready|running|awaiting,
#         activity pipeline_review, adherence_pending == true, or an unreadable /
#         unknown state (fail closed). succeeded|failed|cancelled are idle.
#         Any unreadable job record in $JOBS_DIR keeps every target.
#       - no unplaced job could land there: a non-terminal worktree-isolation job
#         with no work_dir yet counts against the worktree its path derives to
#         (<dirname repo_path>/<basename repo_path>-<branch, / -> ->, as
#         worktree_path_for_repo, the helper mother-run-job uses: cd repo_path,
#         then worktree_get_path); when that path cannot be derived (empty branch
#         or repo_path, repo_path missing / not a git repo / not its own
#         `git rev-parse --show-toplevel`, e.g. a symlink or subdirectory) it
#         blocks every worktree of the same repo name, and never another repo. Terminal and main-dir jobs without a work_dir never block.
#       - nothing anywhere under target (the WHOLE tree, not a fixed depth)
#         changed within MOTHER_CARGO_TARGET_IDLE_MINUTES (default 10;
#         non-numeric -> 10; 0 disables the check)
#       - MOTHER_CARGO_TARGET_PURGE is not a disabled value and the job's repo is
#         not listed in MOTHER_CARGO_TARGET_PURGE_EXCLUDE (space or comma
#         separated). PURGE: unset/empty or 1|true|yes|on (any case) purge;
#         0|false|no|off (any case) report only; anything else is treated as
#         disabled AND the output says the value is "unrecognised".
#       - immediately before the rm the job records are re-read and the in-use and
#         activity checks repeated, and the dir's mtime must be unchanged
#   * Only target/ goes: Cargo.toml and src/ stay. A failed rm never fails gc.
#   * The same pass writes $RUNNER_DIR/cargo-targets.json (also on --dry-run).
#   * `mother status` shows a "Rust build dirs:" line from that cache, and
#     `mother status --format json` always carries `rust_build_dirs`.
#
# Every fixture lives under $MOTHER_ROOT; HOME and every gc seam are redirected
# so this suite can never touch the operator's real ~/Code or caches.

load 'test_helper'

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none

    export MOTHER_GC_DERIVED_DATA_DIR="$MOTHER_ROOT/Library/Developer/Xcode/DerivedData"
    export MOTHER_GC_CODE_DIR="$MOTHER_ROOT/Code"
    export MOTHER_GO_BIN=""
    unset MOTHER_GOCACHE_MAX_GB MOTHER_GC_TARGET_REPORT_GB MOTHER_GC_ENABLED \
          MOTHER_CARGO_TARGET_PURGE MOTHER_CARGO_TARGET_IDLE_MINUTES \
          MOTHER_CARGO_TARGET_PURGE_EXCLUDE
    mkdir -p "$MOTHER_GC_CODE_DIR" "$MOTHER_ROOT/wt"
}

teardown() {
    chmod -R u+rwx "$MOTHER_ROOT" 2>/dev/null || true
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

SIZE_RE='[0-9]+(\.[0-9]+)? ?(B|KB|MB|GB|K|M|G)'

_wt() { echo "$MOTHER_ROOT/wt/$1"; }

# Push every mtime under <dir> far enough into the past to count as idle.
_backdate() { find "$1" -exec touch -t 202601010000 {} +; }

# A fake Rust worktree: Cargo.toml, src/, a .git file, and a cargo-style target/ (CACHEDIR.TAG
# plus three 1 MB blobs under debug/deps), all back-dated.
# Usage: _fake_worktree <name>
_fake_worktree() {
    local dir; dir=$(_wt "$1")
    mkdir -p "$dir/src" "$dir/target/debug/deps"
    echo '[package]' > "$dir/Cargo.toml"
    echo 'fn main() {}' > "$dir/src/main.rs"
    local gname="${1//\//_}"   # the pointer target is <something>/worktrees/<flat name>
    mkdir -p "$MOTHER_ROOT/fake-main/.git/worktrees/$gname"
    echo "gitdir: $MOTHER_ROOT/fake-main/.git/worktrees/$gname" > "$dir/.git"   # linked worktree: .git is a FILE
    echo 'Signature: 8a477f597d28d172789f06886806bc55' > "$dir/target/CACHEDIR.TAG"
    local i
    for i in 1 2 3; do
        head -c 1048576 /dev/zero > "$dir/target/debug/deps/blob$i"
    done
    _backdate "$dir/target"
}

# A job record pointing at a worktree.
# Usage: _wt_job <id> <state> <worktree-name> [extra jq filter]
_wt_job() {
    local id="$1" state="$2" name="$3" extra="${4:-.}" dir
    dir=$(_wt "$name")
    make_job "$id" "$state" ".work_dir = \"$dir\" | $extra"
}

_assert_target_kept() {
    [ -d "$(_wt "$1")/target" ] || { echo "target of $1 was removed" >&2; return 1; }
    [ -f "$(_wt "$1")/target/debug/deps/blob1" ] || { echo "contents of $1 target gone" >&2; return 1; }
}

_assert_target_removed() {
    [ ! -e "$(_wt "$1")/target" ] || { echo "target of $1 still exists" >&2; return 1; }
}

# Cargo.toml and src/ must survive any reclaim.
_assert_sources_intact() {
    [ -f "$(_wt "$1")/Cargo.toml" ] || return 1
    [ -f "$(_wt "$1")/src/main.rs" ] || return 1
}

_assert_output_has() {
    printf '%s\n' "$output" | grep -Fq -- "$1" || { echo "output lacks: $1" >&2; echo "$output" >&2; return 1; }
}

_assert_output_lacks() {
    if printf '%s\n' "$output" | grep -Fq -- "$1"; then
        echo "output unexpectedly contains: $1" >&2; echo "$output" >&2; return 1
    fi
}

_require_non_root() {
    if [ "$(id -u)" = "0" ]; then skip "running as root: chmod has no effect"; fi
}

_cache() { echo "$RUNNER_DIR/cargo-targets.json"; }

# ===========================================================================
# Reclaim: the happy path
# ===========================================================================

@test "an idle job worktree's target/ is removed, sources stay, and the output names repo, path and size" {
    _fake_worktree idle
    _wt_job "ct-idle" "succeeded" idle

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed idle
    _assert_sources_intact idle
    local line
    line=$(printf '%s\n' "$output" | grep -F "removed testrepo worktree target" | grep -F "wt/idle/target")
    [ -n "$line" ]
    [[ "$line" =~ $SIZE_RE ]]
    [[ "$line" == *"ct-idle"* ]]
    _assert_output_has "cargo targets: reclaimed 1 dir(s)"
}

@test "--dry-run lists the idle target/ as would-remove and deletes nothing" {
    _fake_worktree idle
    _wt_job "ct-dry" "succeeded" idle

    run mother gc --dry-run
    [ "$status" -eq 0 ]

    local line
    line=$(printf '%s\n' "$output" | grep -F "[dry-run] would remove testrepo worktree target" | grep -F "wt/idle/target")
    [ -n "$line" ]
    [[ "$line" =~ $SIZE_RE ]]
    _assert_target_kept idle
    _assert_sources_intact idle
}

@test "failed and cancelled jobs count as idle: their worktree target/ is removed" {
    _fake_worktree wfail
    _fake_worktree wcancel
    _wt_job "ct-failed" "failed" wfail
    _wt_job "ct-cancelled" "cancelled" wcancel

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed wfail
    _assert_target_removed wcancel
    _assert_sources_intact wfail
    _assert_sources_intact wcancel
    _assert_output_has "cargo targets: reclaimed 2 dir(s)"
}

@test "a worktree shared by several finished jobs is reclaimed once and the line names every job" {
    _fake_worktree shared
    _wt_job "ct-shared-a" "succeeded" shared
    _wt_job "ct-shared-b" "failed" shared

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed shared
    local line
    line=$(printf '%s\n' "$output" | grep -F "removed testrepo worktree target" | grep -F "wt/shared/target")
    [ -n "$line" ]
    [[ "$line" == *"ct-shared-a"* ]]
    [[ "$line" == *"ct-shared-b"* ]]
    _assert_output_has "cargo targets: reclaimed 1 dir(s)"
}

# ===========================================================================
# In-use guard: any live user of the worktree keeps its target/
# ===========================================================================

_assert_kept_for_state() {
    local state="$1" extra="${2:-.}"
    _fake_worktree busy
    _wt_job "ct-busy" "$state" busy "$extra"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept busy
    _assert_sources_intact busy
    _assert_output_lacks "removed testrepo worktree target"
    _assert_output_has "cargo targets: nothing idle"
}

@test "a running job keeps its worktree target/" {
    _assert_kept_for_state running
}

@test "a ready job keeps its worktree target/" {
    _assert_kept_for_state ready
}

@test "a queued job keeps its worktree target/" {
    _assert_kept_for_state queued
}

@test "an awaiting job keeps its worktree target/" {
    _assert_kept_for_state awaiting
}

@test "a succeeded pipeline job still in pipeline_review keeps its worktree target/" {
    _assert_kept_for_state succeeded '.activity = "pipeline_review"'
}

@test "a succeeded job awaiting adherence review keeps its worktree target/" {
    _assert_kept_for_state succeeded '.adherence_pending = true'
}

@test "a job with an unknown state keeps its worktree target/ (fail closed)" {
    _assert_kept_for_state mystery-state
}

@test "a job record with no readable state keeps the worktree target/ (fail closed)" {
    _fake_worktree busy
    _wt_job "ct-good" "succeeded" busy
    _wt_job "ct-nostate" "succeeded" busy 'del(.state)'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept busy
}

@test "one running job among several sharing a worktree keeps the target/ (the others being finished)" {
    _fake_worktree shared
    _wt_job "ct-share-done" "succeeded" shared
    _wt_job "ct-share-live" "running" shared

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept shared
    _assert_output_lacks "removed testrepo worktree target"
}

@test "an in-use worktree does not block reclaiming an idle one" {
    _fake_worktree busy
    _fake_worktree idle
    _wt_job "ct-live" "running" busy
    _wt_job "ct-done" "succeeded" idle

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept busy
    _assert_target_removed idle
}

# ===========================================================================
# Activity guard
# ===========================================================================

@test "a target/ with a file modified in the last 10 minutes is kept by default" {
    _fake_worktree fresh
    _wt_job "ct-fresh" "succeeded" fresh
    touch "$(_wt fresh)/target/debug/deps/blob1"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept fresh
    _assert_output_lacks "removed testrepo worktree target"
}

@test "MOTHER_CARGO_TARGET_IDLE_MINUTES=0 removes even a freshly touched target/" {
    _fake_worktree fresh
    _wt_job "ct-fresh0" "succeeded" fresh
    touch "$(_wt fresh)/target/debug/deps/blob1"
    export MOTHER_CARGO_TARGET_IDLE_MINUTES=0

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed fresh
    _assert_sources_intact fresh
}

@test "a non-numeric MOTHER_CARGO_TARGET_IDLE_MINUTES falls back to the 10 minute default" {
    _fake_worktree fresh
    _fake_worktree stale
    _wt_job "ct-fresh-nan" "succeeded" fresh
    _wt_job "ct-stale-nan" "succeeded" stale
    touch "$(_wt fresh)/target/debug/deps/blob1"
    export MOTHER_CARGO_TARGET_IDLE_MINUTES=soon

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept fresh
    _assert_target_removed stale
}

# ===========================================================================
# Safety checks on what a target/ is
# ===========================================================================

@test "a worktree without Cargo.toml is untouched and the output says nothing about it" {
    _fake_worktree nonrust
    rm -f "$(_wt nonrust)/Cargo.toml"
    _wt_job "ct-nonrust" "succeeded" nonrust

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept nonrust
    _assert_output_lacks "wt/nonrust"
}

@test "a target/ without CACHEDIR.TAG is untouched" {
    _fake_worktree untagged
    rm -f "$(_wt untagged)/target/CACHEDIR.TAG"
    _wt_job "ct-untagged" "succeeded" untagged

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept untagged
    _assert_sources_intact untagged
}

@test "a target that is a symlink is untouched and its destination is intact" {
    # Note: the symlink guard on target/ is an equivalent mutant (a symlink's
    # physical path can never equal <canon work_dir>/target); the guard is
    # defence in depth, so this test pins the outcome, not a unique guard.
    _fake_worktree linked
    local dest="$MOTHER_ROOT/elsewhere/real-target"
    mkdir -p "$MOTHER_ROOT/elsewhere"
    mv "$(_wt linked)/target" "$dest"
    ln -s "$dest" "$(_wt linked)/target"
    # A fresh symlink would be kept by the 10 minute activity guard alone; age
    # the link itself and its destination so only the symlink guard is left.
    _backdate "$dest"
    touch -h -t 202601010000 "$(_wt linked)/target"
    _wt_job "ct-linked" "succeeded" linked

    run mother gc
    [ "$status" -eq 0 ]

    [ -L "$(_wt linked)/target" ]
    [ -f "$dest/CACHEDIR.TAG" ]
    [ -f "$dest/debug/deps/blob1" ]
    _assert_output_lacks "removed "
}

@test "a main-dir job (work_dir is the repo itself) never has its target/ removed" {
    _fake_worktree maindir
    local dir; dir=$(_wt maindir)
    make_job "ct-maindir" "succeeded" \
        ".isolation = \"main-dir\" | .work_dir = \"$dir\" | .repo_path = \"$dir\""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept maindir
}

@test "a worktree-isolation job whose work_dir equals its repo_path is never removed" {
    _fake_worktree samepath
    local dir; dir=$(_wt samepath)
    make_job "ct-samepath" "succeeded" ".work_dir = \"$dir\" | .repo_path = \"$dir\""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept samepath
}

@test "a target/ that no job record points at is never removed" {
    _fake_worktree orphan

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept orphan
}

# ===========================================================================
# Settings
# ===========================================================================

@test "MOTHER_CARGO_TARGET_PURGE=0 reports only: nothing is deleted" {
    _fake_worktree idle
    _wt_job "ct-nopurge" "succeeded" idle
    export MOTHER_CARGO_TARGET_PURGE=0

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
    _assert_sources_intact idle
    _assert_output_lacks "removed testrepo worktree target"
}

@test "MOTHER_CARGO_TARGET_PURGE_EXCLUDE keeps the target/ of a listed repo" {
    _fake_worktree idle
    _wt_job "ct-excl" "succeeded" idle '.repo = "keep-me"'
    export MOTHER_CARGO_TARGET_PURGE_EXCLUDE="keep-me"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
}

@test "MOTHER_CARGO_TARGET_PURGE_EXCLUDE accepts a comma separated list" {
    _fake_worktree idle
    _wt_job "ct-excl-comma" "succeeded" idle '.repo = "keep-me"'
    export MOTHER_CARGO_TARGET_PURGE_EXCLUDE="other-repo,keep-me"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
}

@test "MOTHER_CARGO_TARGET_PURGE_EXCLUDE accepts a space separated list" {
    _fake_worktree idle
    _wt_job "ct-excl-space" "succeeded" idle '.repo = "keep-me"'
    export MOTHER_CARGO_TARGET_PURGE_EXCLUDE="other-repo keep-me"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
}

@test "excluding one repo does not protect the target/ of a different repo" {
    _fake_worktree idle
    _wt_job "ct-excl-other" "succeeded" idle '.repo = "some-other-repo"'
    export MOTHER_CARGO_TARGET_PURGE_EXCLUDE="keep-me"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed idle
}

# ===========================================================================
# Failure handling
# ===========================================================================

@test "a target/ that cannot be fully removed does not fail gc, and other worktrees are still reclaimed" {
    _require_non_root
    _fake_worktree locked
    _fake_worktree fine
    mkdir -p "$(_wt locked)/target/debug/stuck"
    echo x > "$(_wt locked)/target/debug/stuck/file"
    _backdate "$(_wt locked)/target"
    chmod 555 "$(_wt locked)/target/debug/stuck"
    _wt_job "ct-locked" "succeeded" locked
    _wt_job "ct-fine" "succeeded" fine

    run mother gc
    [ "$status" -eq 0 ]

    [ -f "$(_wt locked)/target/debug/stuck/file" ]
    _assert_target_removed fine
    _assert_sources_intact locked
}

# ===========================================================================
# Inventory cache: $RUNNER_DIR/cargo-targets.json
# ===========================================================================

@test "cache: one in-use dir and one reclaimed dir are accounted separately" {
    _fake_worktree busy
    _fake_worktree idle
    _wt_job "ct-c-live" "running" busy
    _wt_job "ct-c-done" "succeeded" idle

    run mother gc
    [ "$status" -eq 0 ]

    local f; f=$(_cache)
    [ -f "$f" ]
    jq -e . "$f" >/dev/null
    [ -n "$(jq -r '.checked_at // empty' "$f")" ]
    # Only the surviving target/ is inventoried.
    [ "$(jq -r '.dirs' "$f")" = "1" ]
    [ "$(jq -r '.entries | length' "$f")" = "1" ]
    [ "$(jq -r '.entries[0].repo' "$f")" = "testrepo" ]
    [ "$(jq -r '.entries[0].in_use' "$f")" = "true" ]
    [[ "$(jq -r '.entries[0].path' "$f")" == */wt/busy/target ]]
    # 3 x 1 MB of blobs in each dir.
    [ "$(jq -r '.in_use_kb' "$f")" -ge 3000 ]
    [ "$(jq -r '.reclaimed_kb' "$f")" -ge 3000 ]
    [ "$(jq -r '.idle_kb' "$f")" = "0" ]
    [ "$(jq -r '.total_kb' "$f")" = "$(jq -r '.in_use_kb' "$f")" ]
    [ "$(jq -r '.entries[0].kb' "$f")" = "$(jq -r '.in_use_kb' "$f")" ]
}

@test "cache: when every dir was reclaimed it says dirs 0 and lists nothing" {
    _fake_worktree idle
    _wt_job "ct-c-none" "succeeded" idle

    run mother gc
    [ "$status" -eq 0 ]

    local f; f=$(_cache)
    [ -f "$f" ]
    [ "$(jq -r '.dirs' "$f")" = "0" ]
    [ "$(jq -r '.entries | length' "$f")" = "0" ]
    [ "$(jq -r '.total_kb' "$f")" = "0" ]
    [ "$(jq -r '.reclaimed_kb' "$f")" -ge 3000 ]
}

@test "cache: with no job worktrees at all it is still written, with dirs 0" {
    run mother gc
    [ "$status" -eq 0 ]

    local f; f=$(_cache)
    [ -f "$f" ]
    [ "$(jq -r '.dirs' "$f")" = "0" ]
    [ "$(jq -r '.reclaimed_kb' "$f")" = "0" ]
}

@test "cache: --dry-run writes it too, counting the would-be-reclaimed dir as idle and reclaiming nothing" {
    _fake_worktree idle
    _wt_job "ct-c-dry" "succeeded" idle

    run mother gc --dry-run
    [ "$status" -eq 0 ]

    local f; f=$(_cache)
    [ -f "$f" ]
    [ "$(jq -r '.dirs' "$f")" = "1" ]
    [ "$(jq -r '.entries[0].in_use' "$f")" = "false" ]
    [ "$(jq -r '.reclaimed_kb' "$f")" = "0" ]
    [ "$(jq -r '.idle_kb' "$f")" -ge 3000 ]
    [ "$(jq -r '.in_use_kb' "$f")" = "0" ]
    _assert_target_kept idle
}

# ===========================================================================
# `mother status` surfaces the cache
# ===========================================================================

_seed_cache() {
    jq -n '{checked_at: "2026-10-16T15:00:00Z", dirs: 3,
            total_kb: 23907533, in_use_kb: 10276045, idle_kb: 13631488, reclaimed_kb: 0,
            entries: [
              {path: "/x/a/target", repo: "r1", kb: 10276045, in_use: true},
              {path: "/x/b/target", repo: "r2", kb: 6815744, in_use: false},
              {path: "/x/c/target", repo: "r3", kb: 6815744, in_use: false}]}' > "$(_cache)"
}

@test "mother status prints the Rust build dirs line right after Concurrency when the cache has dirs" {
    _seed_cache

    run mother status
    [ "$status" -eq 0 ]

    local line
    line=$(printf '%s\n' "$output" | grep -F "Rust build dirs:")
    [ -n "$line" ]
    [[ "$line" == "Rust build dirs: 3 worktree target/ dirs, 22.8 GB (9.8 GB in use, 13.0 GB idle; reclaimed by mother gc)"* ]]
    [[ "$line" == *"as of "* ]]
    local conc_n rust_n
    conc_n=$(printf '%s\n' "$output" | grep -n '^Concurrency:' | head -1 | cut -d: -f1)
    rust_n=$(printf '%s\n' "$output" | grep -n '^Rust build dirs:' | head -1 | cut -d: -f1)
    [ -n "$conc_n" ]
    [ "$rust_n" -eq $((conc_n + 1)) ]
}

@test "mother status prints no Rust build dirs line when there is no cache file" {
    run mother status
    [ "$status" -eq 0 ]
    _assert_output_lacks "Rust build dirs"
}

@test "mother status prints no Rust build dirs line when the cache says dirs 0" {
    jq -n '{checked_at: "2026-10-16T15:00:00Z", dirs: 0, total_kb: 0, in_use_kb: 0,
            idle_kb: 0, reclaimed_kb: 5000000, entries: []}' > "$(_cache)"

    run mother status
    [ "$status" -eq 0 ]
    _assert_output_lacks "Rust build dirs"
}

@test "mother status --format json carries the cache object as rust_build_dirs" {
    _seed_cache

    run mother status --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.rust_build_dirs.dirs')" = "3" ]
    [ "$(printf '%s' "$output" | jq -r '.rust_build_dirs.in_use_kb')" = "10276045" ]
    # Existing keys are unharmed.
    printf '%s' "$output" | jq -e 'has("counts") and has("needs_attention") and has("concurrency")' >/dev/null
}

@test "mother status --format json has rust_build_dirs: null when there is no cache file" {
    run mother status --format json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e 'has("rust_build_dirs") and .rust_build_dirs == null' >/dev/null
}

# ===========================================================================
# Review fix-ups
#
# `mother gc` deletes directories, so every guard below must fail closed, and
# each test is written so that it fails if the guard it names is removed.
# ===========================================================================

# A job that already has a worktree. The worktree's <main> checkout and branch
# determine the path a later, not-yet-placed job of the same repo/branch gets:
#   <dirname repo_path>/<basename repo_path>-<branch with / -> ->   (worktree_get_path)
# Usage: _placed_job <id> <state> <worktree-name> <main-name> <branch> [repo] [extra jq]
_placed_job() {
    local id="$1" state="$2" name="$3" main="$4" branch="$5" repo="${6:-testrepo}" extra="${7:-.}"
    make_job "$id" "$state" \
        ".work_dir = \"$(_wt "$name")\" | .repo_path = \"$(_wt "$main")\" | .branch = \"$branch\" | .repo = \"$repo\" | $extra"
}

# A real git repo at $MOTHER_ROOT/wt/<name> (idempotent). The runner derives an unplaced
# job's worktree from the real repo, so unplaced-job fixtures must point at one.
_real_repo() {
    local d; d=$(_wt "$1")
    [ -d "$d/.git" ] || git init -q "$d"
}

# A job that has NOT been given a work_dir yet (queued, or dispatched but the
# worker has not recorded one). Its eventual worktree is <main>-<branch>.
# Usage: _unplaced_job <id> <state> <main-name> <branch> [repo] [extra jq]
_unplaced_job() {
    local id="$1" state="$2" main="$3" branch="$4" repo="${5:-testrepo}" extra="${6:-.}"
    _real_repo "$main"
    make_job "$id" "$state" \
        "del(.work_dir) | .repo_path = \"$(_wt "$main")\" | .branch = \"$branch\" | .repo = \"$repo\" | $extra"
}

# --- jobs that have no work_dir yet ----------------------------------------

@test "a queued job with no work_dir that will land on this worktree keeps its target/" {
    _fake_worktree main-fix
    _placed_job "ct-u1-done" succeeded main-fix main fix
    _unplaced_job "ct-u1-next" queued main fix

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept main-fix
    _assert_sources_intact main-fix
    _assert_output_lacks "removed testrepo worktree target"
    _assert_output_has "job still active or awaiting review"
}

@test "a running job with no work_dir that will land on this worktree keeps its target/" {
    _fake_worktree main-fix
    _placed_job "ct-u2-done" succeeded main-fix main fix
    _unplaced_job "ct-u2-next" running main fix

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept main-fix
    _assert_output_lacks "removed testrepo worktree target"
}

@test "a ready job with no work_dir that will land on this worktree keeps its target/" {
    _fake_worktree main-fix
    _placed_job "ct-u2-done" succeeded main-fix main fix
    _unplaced_job "ct-u2-next" ready main fix

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept main-fix
    _assert_output_lacks "removed testrepo worktree target"
}

@test "an awaiting job with no work_dir that will land on this worktree keeps its target/" {
    _fake_worktree main-fix
    _placed_job "ct-u2-done" succeeded main-fix main fix
    _unplaced_job "ct-u2-next" awaiting main fix

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept main-fix
}

@test "a slash in an unplaced job's branch maps to the dashed worktree name (feat/x -> main-feat-x)" {
    _fake_worktree main-feat-x
    _placed_job "ct-u3-done" succeeded main-feat-x main feat/x
    _unplaced_job "ct-u3-next" queued main feat/x

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept main-feat-x
    _assert_output_lacks "removed testrepo worktree target"
}

@test "an unplaced job on a different branch of the same repo does not block this worktree" {
    _fake_worktree main-fix
    _placed_job "ct-u3b-done" succeeded main-fix main fix
    _unplaced_job "ct-u3b-next" queued main other-branch

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed main-fix
    _assert_sources_intact main-fix
}

@test "an unplaced job in another repo does not block an unrelated worktree" {
    _fake_worktree main-fix
    _placed_job "ct-u4-done" succeeded main-fix main fix testrepo
    _unplaced_job "ct-u4-next" queued other feature-z otherrepo

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed main-fix
    _assert_sources_intact main-fix
    _assert_output_has "cargo targets: reclaimed 1 dir(s)"
}

@test "an unplaced job whose branch is empty blocks every worktree of the same repo but no other repo" {
    _fake_worktree same-a
    _fake_worktree same-b
    _fake_worktree elsewhere
    _placed_job "ct-u5-a" succeeded same-a main a testrepo
    _placed_job "ct-u5-b" succeeded same-b main b testrepo
    _placed_job "ct-u5-x" succeeded elsewhere other x otherrepo
    _unplaced_job "ct-u5-next" queued main "" testrepo

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept same-a
    _assert_target_kept same-b
    _assert_target_removed elsewhere
}

@test "an unplaced job whose repo_path is empty blocks every worktree of the same repo but no other repo" {
    _fake_worktree same-a
    _fake_worktree elsewhere
    _placed_job "ct-u5b-a" succeeded same-a main a testrepo
    _placed_job "ct-u5b-x" succeeded elsewhere other x otherrepo
    make_job "ct-u5b-next" queued 'del(.work_dir) | .repo_path = "" | .branch = "fix" | .repo = "testrepo"'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept same-a
    _assert_target_removed elsewhere
}

@test "once the queued job is placed on the worktree and finishes, the target/ is reclaimable" {
    _fake_worktree main-fix
    _placed_job "ct-u6-done" succeeded main-fix main fix
    _unplaced_job "ct-u6-next" queued main fix

    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_kept main-fix

    # The same job is now dispatched into the worktree and finishes.
    _placed_job "ct-u6-next" succeeded main-fix main fix

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed main-fix
    _assert_sources_intact main-fix
}

@test "finished jobs with no work_dir never block, even when their worktree path cannot be derived" {
    _fake_worktree main-fix
    _placed_job "ct-u7-done" succeeded main-fix main fix
    _unplaced_job "ct-u7-ok" succeeded main fix
    _unplaced_job "ct-u7-failed" failed main fix
    _unplaced_job "ct-u7-cancelled" cancelled main fix
    _unplaced_job "ct-u7-nobranch" cancelled main ""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed main-fix
}

@test "a succeeded job with no work_dir that still awaits adherence review keeps the worktree" {
    _fake_worktree main-fix
    _placed_job "ct-u7b-done" succeeded main-fix main fix
    _unplaced_job "ct-u7b-adh" succeeded main fix testrepo '.adherence_pending = true'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept main-fix
}

@test "a queued main-dir job with no work_dir does not block a worktree" {
    _fake_worktree main-fix
    _placed_job "ct-u8-done" succeeded main-fix main fix
    _unplaced_job "ct-u8-main" queued main fix testrepo '.isolation = "main-dir"'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed main-fix
}

# --- the second look immediately before deletion ---------------------------
#
# A job can be enqueued or dispatched between gc's first check and the rm.
# These tests inject that change at a deterministic point: the first activity
# probe (`find ... -mmin`) of the pass, which runs after the first in-use check
# and before the delete. The shim fires once and then behaves like real find.

_install_find_hook() {
    export FIND_REAL; FIND_REAL=$(command -v find)
    export FIND_HOOK_MARK="$MOTHER_ROOT/find-hook-fired"
    export FIND_HOOK_CMD="$1"
    cat > "$_MOCK_BIN/find" <<'SHIM'
#!/usr/bin/env bash
case " $* " in *" -mmin "*) ;; *) exec "$FIND_REAL" "$@" ;; esac
[ ! -e "$FIND_HOOK_MARK" ] || exec "$FIND_REAL" "$@"
: > "$FIND_HOOK_MARK"
out=$("$FIND_REAL" "$@" 2>/dev/null); rc=$?
eval "$FIND_HOOK_CMD"
[ -z "$out" ] || printf '%s\n' "$out"
exit $rc
SHIM
    chmod +x "$_MOCK_BIN/find"
}

_assert_find_hook_fired() {
    [ -e "$FIND_HOOK_MARK" ] || {
        echo "race hook never fired: gc no longer probes activity with find -mmin; update _install_find_hook's injection point" >&2
        return 1
    }
}

@test "a job queued for this worktree after the first check but before the delete keeps the target/" {
    _fake_worktree main-fix
    _placed_job "ct-r1-done" succeeded main-fix main fix
    _unplaced_job "ct-r1-late" queued main fix
    mv "$JOBS_DIR/ct-r1-late.json" "$MOTHER_ROOT/late-job.json"
    _install_find_hook 'mv "$MOTHER_ROOT/late-job.json" "$JOBS_DIR/ct-r1-late.json"'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_find_hook_fired
    _assert_target_kept main-fix
    _assert_output_lacks "removed testrepo worktree target"
}

@test "a job started on this worktree after the first check but before the delete keeps the target/" {
    _fake_worktree main-fix
    _placed_job "ct-r2-done" succeeded main-fix main fix
    _placed_job "ct-r2-late" running main-fix main fix
    mv "$JOBS_DIR/ct-r2-late.json" "$MOTHER_ROOT/late-job.json"
    _install_find_hook 'mv "$MOTHER_ROOT/late-job.json" "$JOBS_DIR/ct-r2-late.json"'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_find_hook_fired
    _assert_target_kept main-fix
}

@test "a target/ whose directory changes between the first check and the delete is kept" {
    _fake_worktree main-fix
    _placed_job "ct-r3-done" succeeded main-fix main fix
    # Still old enough to count as idle, but different from what gc first saw.
    _install_find_hook 'touch -t 202602020000 "$1"'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_find_hook_fired
    _assert_target_kept main-fix
    _assert_output_lacks "removed testrepo worktree target"
}

# --- unreadable job records -------------------------------------------------

@test "a malformed job record anywhere in the queue keeps every target/ (fail closed)" {
    _fake_worktree idle
    _wt_job "ct-bad-ok" succeeded idle
    echo '{this is not json' > "$JOBS_DIR/ct-bad-garbage.json"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
    _assert_output_lacks "removed testrepo worktree target"
}

@test "a job record that is not a JSON object keeps every target/ (fail closed)" {
    _fake_worktree idle
    _wt_job "ct-bad-ok" succeeded idle
    echo '["not","a","job"]' > "$JOBS_DIR/ct-bad-array.json"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
}

@test "an empty (zero-byte) job record keeps every target/ (fail closed)" {
    _fake_worktree idle
    _wt_job "ct-bad-ok" succeeded idle
    : > "$JOBS_DIR/ct-bad-empty.json"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
}

@test "a job record whose fields have the wrong type keeps every target/ (fail closed)" {
    _fake_worktree idle
    _wt_job "ct-bad-ok" succeeded idle
    make_job "ct-bad-types" succeeded '.work_dir = 42'

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept idle
}

@test "removing the malformed job record lets the idle target/ be reclaimed again" {
    _fake_worktree idle
    _wt_job "ct-bad-ok" succeeded idle
    echo '{this is not json' > "$JOBS_DIR/ct-bad-garbage.json"

    run mother gc
    _assert_target_kept idle

    rm -f "$JOBS_DIR/ct-bad-garbage.json"
    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_removed idle
}

# --- hardening: what counts as a removable target/ -------------------------

@test "a main checkout (.git is a directory) recorded as a job worktree is never touched" {
    _fake_worktree maincheckout
    local dir; dir=$(_wt maincheckout)
    rm -f "$dir/.git"
    mkdir -p "$dir/.git/objects"
    _backdate "$dir"
    make_job "ct-h1" succeeded \
        ".work_dir = \"$dir\" | .repo_path = \"$MOTHER_ROOT/somewhere-else\" | .isolation = \"worktree\""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept maincheckout
    _assert_sources_intact maincheckout
    _assert_output_lacks "removed "
    _assert_output_lacks "would remove"
}

@test "a directory with no .git at all recorded as a job worktree is never touched" {
    _fake_worktree nogit
    rm -f "$(_wt nogit)/.git"
    _backdate "$(_wt nogit)"
    _wt_job "ct-h1b" succeeded nogit

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept nogit
    _assert_output_lacks "removed "
}

@test "a .git that is a symlink recorded as a job worktree is never touched" {
    _fake_worktree gitlink
    local dir; dir=$(_wt gitlink)
    mv "$dir/.git" "$MOTHER_ROOT/real-dot-git-file"
    ln -s "$MOTHER_ROOT/real-dot-git-file" "$dir/.git"
    _backdate "$dir"
    touch -h -t 202601010000 "$dir/.git"
    _wt_job "ct-h1c" succeeded gitlink

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept gitlink
    _assert_output_lacks "removed "
}

@test "a back-dated target/ symlink is kept on the symlink alone and its destination is intact" {
    _fake_worktree backlinked
    local dest="$MOTHER_ROOT/elsewhere/real-target"
    mkdir -p "$MOTHER_ROOT/elsewhere"
    mv "$(_wt backlinked)/target" "$dest"
    ln -s "$dest" "$(_wt backlinked)/target"
    _backdate "$dest"
    touch -h -t 202601010000 "$(_wt backlinked)/target"
    _wt_job "ct-h2" succeeded backlinked

    run mother gc
    [ "$status" -eq 0 ]

    [ -L "$(_wt backlinked)/target" ]
    [ -f "$dest/CACHEDIR.TAG" ]
    [ -f "$dest/debug/deps/blob1" ]
    _assert_output_lacks "removed "
}

@test "a work_dir whose .. segment crosses a symlink to a different directory than it names is kept" {
    # wt/link -> wt/real/sub, so the kernel resolves wt/link/../b to wt/real/b,
    # while a purely textual reading gives wt/b. The job's path is not a
    # trustworthy name for the directory that would be deleted.
    _fake_worktree real/b
    mkdir -p "$MOTHER_ROOT/wt/real/sub" "$MOTHER_ROOT/wt/b"
    ln -s "$MOTHER_ROOT/wt/real/sub" "$MOTHER_ROOT/wt/link"
    _backdate "$MOTHER_ROOT/wt/real"
    make_job "ct-h3" succeeded ".work_dir = \"$MOTHER_ROOT/wt/link/../b\""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept real/b
    _assert_sources_intact real/b
    _assert_output_lacks "removed "
}

@test "a work_dir reached through a symlinked parent directory is still reclaimed" {
    _fake_worktree realparent/wtx
    ln -s "$MOTHER_ROOT/wt/realparent" "$MOTHER_ROOT/wt/alias"
    make_job "ct-h4" succeeded ".work_dir = \"$MOTHER_ROOT/wt/alias/wtx\""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed realparent/wtx
    _assert_sources_intact realparent/wtx
    _assert_output_has "cargo targets: reclaimed 1 dir(s)"
}

@test "a work_dir with a plain .. segment that resolves consistently is still reclaimed" {
    _fake_worktree b
    mkdir -p "$MOTHER_ROOT/wt/x"
    make_job "ct-h4b" succeeded ".work_dir = \"$MOTHER_ROOT/wt/x/../b\""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed b
    _assert_sources_intact b
}

@test "a live job recorded through a different path to the same worktree still keeps its target/" {
    _fake_worktree realparent/wtx
    ln -s "$MOTHER_ROOT/wt/realparent" "$MOTHER_ROOT/wt/alias"
    make_job "ct-h4c-done" succeeded ".work_dir = \"$MOTHER_ROOT/wt/alias/wtx\""
    make_job "ct-h4c-live" running ".work_dir = \"$MOTHER_ROOT/wt/realparent/wtx\""

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept realparent/wtx
    _assert_output_lacks "removed testrepo worktree target"
}

# --- activity guard covers the whole tree ----------------------------------

@test "a file modified recently six levels deep keeps the target/; once it is old the target/ goes" {
    _fake_worktree deep
    local d; d="$(_wt deep)/target/a/b/c/d/e/f"
    mkdir -p "$d"
    echo x > "$d/file"
    _backdate "$(_wt deep)/target"
    touch "$d/file"
    _wt_job "ct-act-deep" succeeded deep

    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_kept deep
    _assert_output_lacks "removed testrepo worktree target"

    _backdate "$(_wt deep)/target"

    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_removed deep
    _assert_sources_intact deep
}

# --- MOTHER_CARGO_TARGET_PURGE parsing -------------------------------------

# Fresh fixture, one gc pass. Usage: _purge_case <value|UNSET> <removed|kept>
_purge_case() {
    local value="$1" expect="$2"
    rm -rf "$MOTHER_ROOT/wt" "$JOBS_DIR"
    mkdir -p "$MOTHER_ROOT/wt" "$JOBS_DIR"
    _fake_worktree p
    _wt_job "ct-purge" succeeded p
    if [ "$value" = "UNSET" ]; then unset MOTHER_CARGO_TARGET_PURGE; else export MOTHER_CARGO_TARGET_PURGE="$value"; fi

    run mother gc
    [ "$status" -eq 0 ] || { echo "PURGE='$value': gc exited $status" >&2; return 1; }
    if [ "$expect" = "removed" ]; then
        [ ! -e "$(_wt p)/target" ] || { echo "PURGE='$value': target should have been removed" >&2; return 1; }
    else
        [ -f "$(_wt p)/target/debug/deps/blob1" ] || { echo "PURGE='$value': target should have been kept" >&2; return 1; }
        _assert_output_lacks "removed testrepo worktree target" || return 1
    fi
    _assert_sources_intact p
}

@test "MOTHER_CARGO_TARGET_PURGE accepts 0 false no off in any case as disabled: nothing is deleted" {
    local v
    for v in 0 false no off FALSE Off NO; do
        _purge_case "$v" kept || return 1
        # Recognised values are not complained about.
        _assert_output_lacks "unrecognised" || return 1
    done
}

@test "MOTHER_CARGO_TARGET_PURGE accepts 1 true yes on in any case as enabled: the target/ is removed" {
    local v
    for v in 1 true yes on TRUE Yes ON; do
        _purge_case "$v" removed || return 1
        _assert_output_lacks "unrecognised" || return 1
    done
}

@test "MOTHER_CARGO_TARGET_PURGE unset or empty still purges" {
    _purge_case UNSET removed || return 1
    _purge_case "" removed || return 1
}

@test "an unrecognised MOTHER_CARGO_TARGET_PURGE deletes nothing and says so" {
    local v line
    for v in maybe 2 enable 00; do
        _purge_case "$v" kept || return 1
        line=$(printf '%s\n' "$output" | grep -F "MOTHER_CARGO_TARGET_PURGE" | grep -F "unrecognised")
        [ -n "$line" ] || { echo "PURGE='$v': no unrecognised-value warning in output" >&2; echo "$output" >&2; return 1; }
    done
}

@test "an unrecognised MOTHER_CARGO_TARGET_PURGE also deletes nothing on --dry-run and never says would-remove" {
    _fake_worktree p
    _wt_job "ct-purge-dry" succeeded p
    export MOTHER_CARGO_TARGET_PURGE=maybe

    run mother gc --dry-run
    [ "$status" -eq 0 ]

    _assert_target_kept p
    _assert_output_lacks "would remove testrepo worktree target"
    _assert_output_has "unrecognised"
}

# --- scale and awkward paths ------------------------------------------------

@test "thirty idle worktrees are all reclaimed in one pass, and a live one among them is untouched" {
    local i
    for i in $(seq 1 30); do
        _fake_worktree "many-$i"
        _wt_job "ct-many-$i" succeeded "many-$i"
    done
    _fake_worktree many-live
    _wt_job "ct-many-live" running many-live

    run mother gc
    [ "$status" -eq 0 ]

    for i in $(seq 1 30); do
        _assert_target_removed "many-$i" || return 1
        _assert_sources_intact "many-$i" || return 1
    done
    _assert_target_kept many-live
    _assert_output_has "cargo targets: reclaimed 30 dir(s)"
}

@test "a work_dir containing a space is reclaimed when idle and kept when live" {
    _fake_worktree "idle tree"
    _fake_worktree "busy tree"
    _wt_job "ct-sp-idle" succeeded "idle tree"
    _wt_job "ct-sp-busy" running "busy tree"

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed "idle tree"
    _assert_sources_intact "idle tree"
    _assert_target_kept "busy tree"
    _assert_output_has "wt/idle tree/target"
}

# ===========================================================================
# Unplaced jobs: the derived worktree must be the one the runner would create
# ===========================================================================

# Give a real repo one commit so `git worktree add` works.
_commit_in() {
    git -C "$1" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
}

# The path bin/mother-run-job would give <repo_path>/<branch>, computed the same way.
_runner_path() {
    ( source "$MOTHER_LIB_DIR/worktree.sh" && worktree_path_for_repo "$1" "$2" )
}

# An unplaced job whose repo_path is given verbatim (no fixture repo is created).
# Usage: _unplaced_at <id> <state> <repo_path> <branch> [repo]
_unplaced_at() {
    make_job "$1" "$2" "del(.work_dir) | .repo_path = \"$3\" | .branch = \"$4\" | .repo = \"${5:-testrepo}\""
}

@test "a queued job whose repo_path is a symlink to the repo keeps the worktree it will land on" {
    _real_repo real
    ln -s "$(_wt real)" "$(_wt link)"
    _fake_worktree real-feat-x
    _wt_job "ct-sym-done" succeeded real-feat-x
    _unplaced_at "ct-sym-next" queued "$(_wt link)" feat/x

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept real-feat-x
    _assert_sources_intact real-feat-x
    _assert_output_lacks "removed "
}

@test "a queued job whose repo_path is a subdirectory of the repo keeps the worktree it will land on" {
    _real_repo real
    mkdir -p "$(_wt real)/sub"
    _fake_worktree real-feat-x
    _wt_job "ct-sub-done" succeeded real-feat-x
    _unplaced_at "ct-sub-next" queued "$(_wt real)/sub" feat/x

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept real-feat-x
    _assert_output_lacks "removed "
}

@test "a queued job whose repo_path is a linked worktree of the repo keeps the worktree it will land on" {
    _real_repo real
    _commit_in "$(_wt real)"
    git -C "$(_wt real)" worktree add -q -b side "$(_wt real-side)"
    _fake_worktree real-feat-x
    _wt_job "ct-lw-done" succeeded real-feat-x
    _unplaced_at "ct-lw-next" queued "$(_wt real-side)" feat/x

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept real-feat-x
    _assert_output_lacks "removed "
}

@test "an unplaced job on a different branch of a real git repo does not block an idle worktree" {
    _real_repo real
    _fake_worktree real-fix
    _wt_job "ct-diff-done" succeeded real-fix
    _unplaced_at "ct-diff-next" queued "$(_wt real)" other-branch

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_removed real-fix
    _assert_sources_intact real-fix
}

@test "an unplaced job whose repo_path does not exist keeps every worktree of the same repo" {
    _fake_worktree same-a
    _wt_job "ct-nx-done" succeeded same-a
    _unplaced_at "ct-nx-next" queued "$MOTHER_ROOT/wt/does-not-exist" fix

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept same-a
    _assert_output_lacks "removed "
}

@test "an unplaced job whose repo_path is not a git repo keeps every worktree of the same repo" {
    mkdir -p "$(_wt plain-dir)"
    _fake_worktree same-a
    _wt_job "ct-ng-done" succeeded same-a
    _unplaced_at "ct-ng-next" queued "$(_wt plain-dir)" fix

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept same-a
}

@test "an underivable unplaced job's block does not extend to a worktree of a different repo" {
    _fake_worktree same-a
    _fake_worktree elsewhere
    _wt_job "ct-nxr-a" succeeded same-a
    _wt_job "ct-nxr-x" succeeded elsewhere '.repo = "otherrepo"'
    _unplaced_at "ct-nxr-next" queued "$MOTHER_ROOT/wt/does-not-exist" fix testrepo

    run mother gc
    [ "$status" -eq 0 ]

    _assert_target_kept same-a
    _assert_target_removed elsewhere
}

@test "gc and the runner agree on which worktree an unplaced job will land on (plain, symlinked, linked-worktree repo_path)" {
    _real_repo real
    _commit_in "$(_wt real)"
    ln -s "$(_wt real)" "$(_wt link)"
    git -C "$(_wt real)" worktree add -q -b side "$(_wt real-side)"

    local rp out name
    for rp in "$(_wt real)" "$(_wt link)" "$(_wt real-side)"; do
        out=$(_runner_path "$rp" feat/x)
        [ -n "$out" ]
        name=$(basename "$out")
        rm -rf "$JOBS_DIR"/*.json "$(_wt "$name")"
        _fake_worktree "$name"
        _fake_worktree decoy
        _wt_job "ct-drift-done" succeeded "$name"
        _wt_job "ct-drift-decoy" succeeded decoy
        _unplaced_at "ct-drift-next" queued "$rp" feat/x

        run mother gc
        [ "$status" -eq 0 ]
        # The worktree the runner would create must never be reclaimed from under it.
        _assert_target_kept "$name" || { echo "repo_path=$rp runner path=$out" >&2; return 1; }
        # For the plain repo the derivation is exact: an unrelated worktree is not blocked.
        if [ "$rp" = "$(_wt real)" ]; then _assert_target_removed decoy; fi
        rm -rf "$(_wt decoy)"
    done
}

@test "mother-run-job derives a job's worktree path with the shared worktree_path_for_repo helper" {
    grep -q 'worktree_path_for_repo "\$repo_path" "\$branch"' "$BATS_TEST_DIRNAME/../bin/mother-run-job"
}

# ===========================================================================
# <work_dir>/.git must be a genuine linked-worktree pointer
# ===========================================================================

# Replace an idle worktree's .git file content, then gc.
# Usage: _git_shape <name> <content>
_git_shape() {
    _fake_worktree "$1"
    printf '%s' "$2" > "$(_wt "$1")/.git"
    _wt_job "ct-gs-$1" succeeded "$1"
}

@test "a worktree whose .git file is empty keeps its target/" {
    _git_shape gs-empty ""
    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_kept gs-empty
}

@test "a worktree whose .git file is garbage keeps its target/" {
    _git_shape gs-garbage "this is not a gitdir pointer"
    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_kept gs-garbage
}

@test "a submodule-style .git pointer (existing .git/modules dir) keeps its target/" {
    mkdir -p "$MOTHER_ROOT/wt/.git/modules/x"
    _git_shape gs-sub "gitdir: ../.git/modules/x"
    run mother gc
    [ "$status" -eq 0 ]
    [ -d "$MOTHER_ROOT/wt/.git/modules/x" ]
    _assert_target_kept gs-sub
}

@test "a worktree .git pointer to a missing directory keeps its target/" {
    _git_shape gs-missing "gitdir: $MOTHER_ROOT/fake-main/.git/worktrees/never-created"
    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_kept gs-missing
}

@test "a genuine absolute linked-worktree pointer is reclaimed" {
    mkdir -p "$MOTHER_ROOT/fake-main/.git/worktrees/gs-real"
    _git_shape gs-real "gitdir: $MOTHER_ROOT/fake-main/.git/worktrees/gs-real"
    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_removed gs-real
    _assert_sources_intact gs-real
}

@test "a relative linked-worktree pointer to an existing worktrees/<name> dir is reclaimed" {
    mkdir -p "$MOTHER_ROOT/wt/gs-rel-meta/worktrees/gs-rel"
    _git_shape gs-rel "gitdir: ../gs-rel-meta/worktrees/gs-rel"
    run mother gc
    [ "$status" -eq 0 ]
    _assert_target_removed gs-rel
    _assert_sources_intact gs-rel
}
