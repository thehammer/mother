#!/usr/bin/env bats
# cargo_targets.bats — `mother gc` reclaims idle Rust target/ dirs of job worktrees.
#
# Contract under test (lib/gc.sh, bin/mother, bin/mother-runner):
#   * Candidates are the distinct work_dirs of Mother job records whose
#     isolation is "worktree" and whose work_dir is not the repo_path. The
#     directory <work_dir>/target is deleted (rm -rf) only when ALL hold:
#       - <work_dir>/Cargo.toml exists
#       - target is a real directory (not a symlink) that contains CACHEDIR.TAG
#       - no job referencing that work_dir is live: queued|ready|running|awaiting,
#         activity pipeline_review, adherence_pending == true, or an unreadable /
#         unknown state (fail closed). succeeded|failed|cancelled are idle.
#       - nothing under target (maxdepth 3) changed within
#         MOTHER_CARGO_TARGET_IDLE_MINUTES (default 10; non-numeric -> 10)
#       - MOTHER_CARGO_TARGET_PURGE != 0 and the job's repo is not listed in
#         MOTHER_CARGO_TARGET_PURGE_EXCLUDE (space or comma separated)
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

# A fake Rust worktree: Cargo.toml, src/, and a cargo-style target/ (CACHEDIR.TAG
# plus three 1 MB blobs under debug/deps), all back-dated.
# Usage: _fake_worktree <name>
_fake_worktree() {
    local dir; dir=$(_wt "$1")
    mkdir -p "$dir/src" "$dir/target/debug/deps"
    echo '[package]' > "$dir/Cargo.toml"
    echo 'fn main() {}' > "$dir/src/main.rs"
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
    _fake_worktree linked
    local dest="$MOTHER_ROOT/elsewhere/real-target"
    mkdir -p "$MOTHER_ROOT/elsewhere"
    mv "$(_wt linked)/target" "$dest"
    ln -s "$dest" "$(_wt linked)/target"
    _wt_job "ct-linked" "succeeded" linked

    run mother gc
    [ "$status" -eq 0 ]

    [ -L "$(_wt linked)/target" ]
    [ -f "$dest/CACHEDIR.TAG" ]
    [ -f "$dest/debug/deps/blob1" ]
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
