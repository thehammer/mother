#!/usr/bin/env bats
# safe_rm.bats — the live-state deletion guard.
#
# Contract under test:
#   * safe_rm_tree <path> behaves like `rm -rf <dir>` EXCEPT it refuses
#     (non-zero, stderr starting `safe_rm_tree: refusing`, nothing deleted) for
#     an empty path, `/`, $HOME (with or without trailing slash), an ancestor of
#     $HOME, or any directory that is or contains a `.mother-live` marker file
#     (directly, or up to 3 levels deeper). A nonexistent path is a successful
#     no-op.
#   * mother_ensure_live_marker creates $MOTHER_ROOT/.mother-live once, unless
#     MOTHER_TEST_ROOT=1, and never rewrites an existing marker. Sourcing
#     state.sh (every `mother <cmd>`) triggers it.
#   * teardown_mother_env deletes through safe_rm_tree, so a MOTHER_ROOT that
#     carries a marker survives the test teardown.
#   * Every real deletion site (gc, teardown residue / job tmp, runner stale
#     lock cleanup) refuses a directory carrying a marker and still removes a
#     normal directory.
#
# Every test points HOME at a throwaway dir. Deletion-refusal tests for `/` and
# HOME ancestors additionally shadow `rm` with a no-op shim so a broken guard
# cannot damage the machine running the suite.

load 'test_helper'

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    # gc seams: nothing there unless a test creates it.
    export MOTHER_GC_DERIVED_DATA_DIR="$MOTHER_ROOT/Library/Developer/Xcode/DerivedData"
    export MOTHER_GC_CODE_DIR="$MOTHER_ROOT/Code"
    export MOTHER_GO_BIN=""
    mkdir -p "$MOTHER_GC_CODE_DIR"
}

teardown() {
    # A test may have planted a marker in MOTHER_ROOT itself.
    rm -f "$MOTHER_ROOT/.mother-live" 2>/dev/null || true
    chmod -R u+rwx "$MOTHER_ROOT" 2>/dev/null || true
    teardown_mother_env
}

# Run safe_rm_tree in a fresh bash; sets status/output (stderr merged).
_srt() {
    run bash -c "source '$_LIB_DIR/safe-rm.sh'; safe_rm_tree \"\$1\"" _ "$1"
}

# Same, but isolates stderr only (stdout dropped).
_srt_stderr() {
    run bash -c "source '$_LIB_DIR/safe-rm.sh'; safe_rm_tree \"\$1\" 2>&1 >/dev/null" _ "$1"
}

# Put a no-op `rm` first on PATH (safety net for the dangerous-path tests).
_shim_rm() {
    mkdir -p "$MOTHER_ROOT/rm-shim"
    printf '#!/bin/sh\nexit 0\n' > "$MOTHER_ROOT/rm-shim/rm"
    chmod +x "$MOTHER_ROOT/rm-shim/rm"
    export PATH="$MOTHER_ROOT/rm-shim:$PATH"
}

_job_tmp_dir() { echo "$MOTHER_ROOT/tmp/$1"; }

# ===========================================================================
# safe_rm_tree
# ===========================================================================

@test "safe_rm_tree removes an ordinary directory tree" {
    mkdir -p "$MOTHER_ROOT/victim/a/b"
    echo x > "$MOTHER_ROOT/victim/a/b/f"

    _srt "$MOTHER_ROOT/victim"

    [ "$status" -eq 0 ]
    [ ! -e "$MOTHER_ROOT/victim" ]
}

@test "safe_rm_tree on a nonexistent path succeeds and does nothing" {
    _srt "$MOTHER_ROOT/does-not-exist"
    [ "$status" -eq 0 ]
}

@test "safe_rm_tree refuses an empty path, with a 'safe_rm_tree: refusing' message on stderr" {
    mkdir -p "$MOTHER_ROOT/bystander"
    run bash -c "source '$_LIB_DIR/safe-rm.sh'; safe_rm_tree ''"
    [ "$status" -ne 0 ]
    [[ "$output" == "safe_rm_tree: refusing"* ]]
    [ -d "$MOTHER_ROOT/bystander" ]
}

@test "safe_rm_tree refuses / " {
    _shim_rm
    _srt_stderr "/"
    [[ "$output" == "safe_rm_tree: refusing"* ]]
    run bash -c "source '$_LIB_DIR/safe-rm.sh'; safe_rm_tree /"
    [ "$status" -ne 0 ]
    [ -d /usr ]
}

@test "safe_rm_tree refuses \$HOME and \$HOME/ and leaves its contents alone" {
    echo precious > "$HOME/keep"

    _srt "$HOME"
    [ "$status" -ne 0 ]
    [[ "$output" == *"safe_rm_tree: refusing"* ]]
    [ -f "$HOME/keep" ]

    _srt "$HOME/"
    [ "$status" -ne 0 ]
    [[ "$output" == *"safe_rm_tree: refusing"* ]]
    [ -f "$HOME/keep" ]
}

@test "safe_rm_tree refuses an ancestor of \$HOME" {
    _shim_rm
    export HOME="$MOTHER_ROOT/ancestor/inner/home"
    mkdir -p "$HOME"
    echo precious > "$HOME/keep"

    _srt "$MOTHER_ROOT/ancestor"
    [ "$status" -ne 0 ]
    [[ "$output" == *"safe_rm_tree: refusing"* ]]
    [ -f "$HOME/keep" ]

    _srt "$MOTHER_ROOT/ancestor/inner"
    [ "$status" -ne 0 ]
    [ -f "$HOME/keep" ]
}

@test "safe_rm_tree refuses a directory that directly contains a .mother-live marker" {
    mkdir -p "$MOTHER_ROOT/live-tree/jobs"
    echo x > "$MOTHER_ROOT/live-tree/jobs/j.json"
    echo "live" > "$MOTHER_ROOT/live-tree/.mother-live"

    _srt "$MOTHER_ROOT/live-tree"

    [ "$status" -ne 0 ]
    [[ "$output" == *"safe_rm_tree: refusing"* ]]
    [ -f "$MOTHER_ROOT/live-tree/.mother-live" ]
    [ -f "$MOTHER_ROOT/live-tree/jobs/j.json" ]
}

@test "safe_rm_tree reports its refusal on stderr, not stdout" {
    mkdir -p "$MOTHER_ROOT/live-tree"
    echo "live" > "$MOTHER_ROOT/live-tree/.mother-live"

    run bash -c "source '$_LIB_DIR/safe-rm.sh'; safe_rm_tree '$MOTHER_ROOT/live-tree' 2>/dev/null"
    [ "$status" -ne 0 ]
    [ -z "$output" ]

    _srt_stderr "$MOTHER_ROOT/live-tree"
    [[ "$output" == "safe_rm_tree: refusing"* ]]
}

@test "safe_rm_tree refuses a directory whose marker is one level deeper" {
    mkdir -p "$MOTHER_ROOT/wrapper/.mother"
    echo "live" > "$MOTHER_ROOT/wrapper/.mother/.mother-live"

    _srt "$MOTHER_ROOT/wrapper"

    [ "$status" -ne 0 ]
    [ -f "$MOTHER_ROOT/wrapper/.mother/.mother-live" ]
}

@test "safe_rm_tree refuses a directory whose marker is three levels deeper" {
    mkdir -p "$MOTHER_ROOT/wrapper/a/b/c"
    echo "live" > "$MOTHER_ROOT/wrapper/a/b/c/.mother-live"

    _srt "$MOTHER_ROOT/wrapper"

    [ "$status" -ne 0 ]
    [ -f "$MOTHER_ROOT/wrapper/a/b/c/.mother-live" ]
}

@test "safe_rm_tree still removes a tree that merely has similarly named files" {
    mkdir -p "$MOTHER_ROOT/victim"
    echo x > "$MOTHER_ROOT/victim/mother-live"
    echo x > "$MOTHER_ROOT/victim/.mother-live.bak"

    _srt "$MOTHER_ROOT/victim"

    [ "$status" -eq 0 ]
    [ ! -e "$MOTHER_ROOT/victim" ]
}

# ===========================================================================
# mother_ensure_live_marker
# ===========================================================================

@test "a mother command creates the .mother-live marker when MOTHER_TEST_ROOT is unset" {
    unset MOTHER_TEST_ROOT
    [ ! -e "$MOTHER_ROOT/.mother-live" ]

    run mother list
    [ "$status" -eq 0 ]

    [ -s "$MOTHER_ROOT/.mother-live" ]
}

@test "a mother command does not create a marker when MOTHER_TEST_ROOT=1" {
    export MOTHER_TEST_ROOT=1

    run mother list
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_ROOT/.mother-live" ]
}

@test "mother_ensure_live_marker is idempotent: an existing marker is not rewritten" {
    unset MOTHER_TEST_ROOT
    run mother list
    [ -f "$MOTHER_ROOT/.mother-live" ]
    echo "operator edit" > "$MOTHER_ROOT/.mother-live"

    run mother list
    [ "$status" -eq 0 ]

    [ "$(cat "$MOTHER_ROOT/.mother-live")" = "operator edit" ]
}

@test "mother_ensure_live_marker writes a human-readable marker with a created timestamp" {
    unset MOTHER_TEST_ROOT
    run bash -c "source '$_LIB_DIR/safe-rm.sh'; mother_ensure_live_marker"
    [ "$status" -eq 0 ]
    [ -s "$MOTHER_ROOT/.mother-live" ]
    grep -qiE 'created' "$MOTHER_ROOT/.mother-live"
    grep -qE '20[0-9]{2}' "$MOTHER_ROOT/.mother-live"
}

@test "mother_ensure_live_marker is a no-op under MOTHER_TEST_ROOT=1" {
    export MOTHER_TEST_ROOT=1
    run bash -c "source '$_LIB_DIR/safe-rm.sh'; mother_ensure_live_marker"
    [ "$status" -eq 0 ]
    [ ! -e "$MOTHER_ROOT/.mother-live" ]
}

# ===========================================================================
# teardown_mother_env goes through the guard
# ===========================================================================

@test "teardown_mother_env leaves a MOTHER_ROOT that carries a .mother-live marker" {
    echo live > "$MOTHER_ROOT/.mother-live"
    local mine="$MOTHER_ROOT"

    teardown_mother_env

    [ -f "$mine/.mother-live" ]
    # bats `teardown` removes the marker and the tree afterwards.
}

@test "teardown_mother_env still removes an unmarked MOTHER_ROOT" {
    local mine="$MOTHER_ROOT"
    teardown_mother_env
    [ ! -d "$mine" ]
}

# ===========================================================================
# Deletion sites: gc
# ===========================================================================

_derived_dead() {
    local d="$MOTHER_GC_DERIVED_DATA_DIR/$1"
    mkdir -p "$d/Build"
    echo blob > "$d/Build/blob"
    cat > "$d/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>$MOTHER_ROOT/Projects/Gone-$1.xcodeproj</string>
</dict>
</plist>
EOF
}

@test "gc job temp: a dead job's tmp dir carrying .mother-live is refused; an unmarked one is removed" {
    mkdir -p "$(_job_tmp_dir marked)/cache" "$(_job_tmp_dir plain)/cache"
    echo x > "$(_job_tmp_dir marked)/cache/blob"
    echo x > "$(_job_tmp_dir plain)/cache/blob"
    echo live > "$(_job_tmp_dir marked)/.mother-live"

    run mother gc
    [ "$status" -eq 0 ]

    [ -d "$(_job_tmp_dir marked)" ]
    [ -f "$(_job_tmp_dir marked)/.mother-live" ]
    [ ! -e "$(_job_tmp_dir plain)" ]
}

@test "gc DerivedData: an orphaned folder carrying .mother-live is refused; an unmarked one is removed" {
    _derived_dead "Marked-aaa"
    _derived_dead "Plain-bbb"
    echo live > "$MOTHER_GC_DERIVED_DATA_DIR/Marked-aaa/.mother-live"

    run mother gc
    [ "$status" -eq 0 ]

    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/Marked-aaa" ]
    [ -f "$MOTHER_GC_DERIVED_DATA_DIR/Marked-aaa/.mother-live" ]
    [ ! -e "$MOTHER_GC_DERIVED_DATA_DIR/Plain-bbb" ]
}

# ===========================================================================
# Deletion sites: teardown
# ===========================================================================

_teardown_libs() {
    printf "source '%s/state.sh'; source '%s/worktree.sh'; [ -r '%s/prdetect.sh' ] && source '%s/prdetect.sh'; source '%s/teardown.sh';" \
        "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR"
}

@test "teardown residue removal refuses a directory carrying .mother-live and never fails the caller" {
    local dir="$MOTHER_ROOT/residue-marked"
    mkdir -p "$dir/node_modules/pkg"
    echo x > "$dir/node_modules/pkg/index.js"
    echo live > "$dir/.mother-live"

    run bash -c "$(_teardown_libs) _teardown_remove_residue '$dir' '$MOTHER_ROOT/some-repo'"
    [ "$status" -eq 0 ]

    [ -d "$dir" ]
    [ -f "$dir/.mother-live" ]
    [ -f "$dir/node_modules/pkg/index.js" ]
}

@test "teardown residue removal still removes an unmarked directory" {
    local dir="$MOTHER_ROOT/residue-plain"
    mkdir -p "$dir/node_modules/pkg"
    echo x > "$dir/node_modules/pkg/index.js"

    run bash -c "$(_teardown_libs) _teardown_remove_residue '$dir' '$MOTHER_ROOT/some-repo'"
    [ "$status" -eq 0 ]

    [ ! -e "$dir" ]
}

@test "teardown job-tmp removal refuses a tmp dir carrying .mother-live; an unmarked one is removed" {
    mkdir -p "$(_job_tmp_dir tj-marked)/x" "$(_job_tmp_dir tj-plain)/x"
    echo live > "$(_job_tmp_dir tj-marked)/.mother-live"
    echo x > "$(_job_tmp_dir tj-plain)/x/f"

    run bash -c "$(_teardown_libs) _teardown_remove_job_tmp '{\"id\":\"tj-marked\"}' 0; _teardown_remove_job_tmp '{\"id\":\"tj-plain\"}' 0"
    [ "$status" -eq 0 ]

    [ -f "$(_job_tmp_dir tj-marked)/.mother-live" ]
    [ ! -e "$(_job_tmp_dir tj-plain)" ]
}

# ===========================================================================
# Deletion sites: runner stale-lock cleanup
# ===========================================================================

@test "runner startup lock cleanup removes a populated stale lockdir that has no marker" {
    mkdir -p "$RUNNER_DIR/adherence-review.lockdir"
    echo stale > "$RUNNER_DIR/adherence-review.lockdir/owner"

    run mother-runner --recover-stale-locks-tick
    [ "$status" -eq 0 ]

    [ ! -e "$RUNNER_DIR/adherence-review.lockdir" ]
}

@test "runner startup lock cleanup refuses a lockdir carrying .mother-live (adherence-review)" {
    mkdir -p "$RUNNER_DIR/adherence-review.lockdir"
    echo live > "$RUNNER_DIR/adherence-review.lockdir/.mother-live"

    run mother-runner --recover-stale-locks-tick
    [ "$status" -eq 0 ]

    [ -d "$RUNNER_DIR/adherence-review.lockdir" ]
    [ -f "$RUNNER_DIR/adherence-review.lockdir/.mother-live" ]
}

@test "runner startup lock cleanup refuses a lockdir carrying .mother-live (pipeline-driver)" {
    mkdir -p "$RUNNER_DIR/pipeline-driver.lockdir"
    echo live > "$RUNNER_DIR/pipeline-driver.lockdir/.mother-live"

    run mother-runner --recover-stale-locks-tick
    [ "$status" -eq 0 ]

    [ -d "$RUNNER_DIR/pipeline-driver.lockdir" ]
    [ -f "$RUNNER_DIR/pipeline-driver.lockdir/.mother-live" ]
}
