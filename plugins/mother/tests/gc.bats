#!/usr/bin/env bats
# gc.bats — `mother gc [--dry-run]`, the machine-hygiene sweep.
#
# Reclaims disk that nothing else cleans, without ever guessing:
#   1. Xcode DerivedData folders whose workspace (info.plist WorkspacePath) is gone.
#   2. The Go build cache when it is over MOTHER_GOCACHE_MAX_GB and no job is running.
#   3. Rust target/ dirs under ~/Code: REPORTED only, never removed.
#   4. Job-scoped TMPDIRs ($MOTHER_ROOT/tmp/<job-id>) of jobs that no longer exist.
#   5. teardown-residue records whose directory is gone.
# It rides along with the hourly archive sweep (MOTHER_GC_ENABLED=0 opts out).
# Always exits 0: a failing step never fails the sweep.
#
# Every test points HOME and every gc test seam at throwaway dirs: this suite
# must never touch the operator's real DerivedData, Go cache or ~/Code.

load 'test_helper'

REPO_ROOT_DIR="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd -P)"

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none

    # Default every seam to "nothing there" so a test only exercises its own step.
    export MOTHER_GC_DERIVED_DATA_DIR="$MOTHER_ROOT/Library/Developer/Xcode/DerivedData"
    export MOTHER_GC_CODE_DIR="$MOTHER_ROOT/Code"
    export MOTHER_GO_BIN=""
    unset MOTHER_GOCACHE_MAX_GB MOTHER_GC_TARGET_REPORT_GB MOTHER_GC_ENABLED
    mkdir -p "$MOTHER_GC_CODE_DIR"
}

teardown() {
    chmod -R u+rwx "$MOTHER_ROOT" 2>/dev/null || true
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# A DerivedData project folder with an XML info.plist naming <workspace>.
# Usage: _derived <name> <workspace_path>
_derived() {
    local name="$1" ws="$2" dir="$MOTHER_GC_DERIVED_DATA_DIR/$1"
    mkdir -p "$dir/Build/Products"
    head -c 4000 /dev/zero > "$dir/Build/Products/app.bin"
    cat > "$dir/info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>LastAccessedDate</key>
	<date>2026-01-01T00:00:00Z</date>
	<key>WorkspacePath</key>
	<string>$ws</string>
</dict>
</plist>
EOF
}

# Convert a DerivedData folder's info.plist to the binary format Xcode also writes.
_to_binary_plist() { plutil -convert binary1 "$MOTHER_GC_DERIVED_DATA_DIR/$1/info.plist"; }

# A stub `go`: `env GOCACHE` prints the fixture cache dir, `clean -cache`
# records the call and empties the dir. Usage: _stub_go [exit_code_for_everything]
_stub_go() {
    GOCACHE_DIR="$MOTHER_ROOT/gocache"
    mkdir -p "$GOCACHE_DIR"
    echo "cached build output" > "$GOCACHE_DIR/entry"
    cat > "$MOTHER_ROOT/stub-go" <<EOF
#!/usr/bin/env bash
if [ -n "\${STUB_GO_FAIL:-}" ]; then
    echo "asdf: No version is set for command go" >&2
    exit 126
fi
case "\$1 \${2:-}" in
    "env GOCACHE") echo "$GOCACHE_DIR" ;;
    "clean -cache")
        echo "clean -cache" >> "$MOTHER_ROOT/go-calls"
        rm -rf "$GOCACHE_DIR"/*
        ;;
    *) exit 0 ;;
esac
EOF
    chmod +x "$MOTHER_ROOT/stub-go"
    export MOTHER_GO_BIN="$MOTHER_ROOT/stub-go"
}

_go_clean_calls() {
    if [ -f "$MOTHER_ROOT/go-calls" ]; then wc -l < "$MOTHER_ROOT/go-calls" | tr -d ' '; else echo 0; fi
}

_require_non_root() {
    if [ "$(id -u)" = "0" ]; then skip "running as root: chmod 000 has no effect"; fi
}

SIZE_RE='[0-9]+(\.[0-9]+)? ?(B|KB|MB|GB|K|M|G)'

# ===========================================================================
# 1. Xcode DerivedData
# ===========================================================================

@test "gc DerivedData: only the folder whose workspace is gone is listed (dry-run) and nothing is removed" {
    mkdir -p "$MOTHER_ROOT/Projects/Live.xcodeproj"
    _derived "Live-abc" "$MOTHER_ROOT/Projects/Live.xcodeproj"
    _derived "Dead-def" "$MOTHER_ROOT/Projects/Gone.xcodeproj"
    mkdir -p "$MOTHER_GC_DERIVED_DATA_DIR/ModuleCache.noindex/x" "$MOTHER_GC_DERIVED_DATA_DIR/NoPlist-xyz/y"

    run mother gc --dry-run
    [ "$status" -eq 0 ]

    local dead_line
    dead_line=$(printf '%s\n' "$output" | grep -F "DerivedData/Dead-def")
    [ -n "$dead_line" ]
    [[ "$dead_line" == "[dry-run] would remove"* ]]
    [[ "$dead_line" =~ $SIZE_RE ]]
    # None of the keepers is offered for removal.
    run bash -c "printf '%s\n' \"\$1\" | grep -F 'would remove' | grep -E 'Live-abc|ModuleCache|NoPlist-xyz'" _ "$output"
    [ "$status" -ne 0 ]

    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/Dead-def" ]
}

@test "gc DerivedData: without --dry-run only the missing-workspace folder is deleted" {
    mkdir -p "$MOTHER_ROOT/Projects/Live.xcodeproj"
    _derived "Live-abc" "$MOTHER_ROOT/Projects/Live.xcodeproj"
    _derived "Dead-def" "$MOTHER_ROOT/Projects/Gone.xcodeproj"
    mkdir -p "$MOTHER_GC_DERIVED_DATA_DIR/ModuleCache.noindex/x" "$MOTHER_GC_DERIVED_DATA_DIR/NoPlist-xyz/y"

    run mother gc
    [ "$status" -eq 0 ]
    [[ "$output" != *"[dry-run]"* ]]
    [[ "$output" == *"DerivedData/Dead-def"* ]]

    [ ! -e "$MOTHER_GC_DERIVED_DATA_DIR/Dead-def" ]
    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/Live-abc" ]
    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/ModuleCache.noindex/x" ]
    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/NoPlist-xyz/y" ]
}

@test "gc DerivedData: binary-format info.plist files are understood too" {
    mkdir -p "$MOTHER_ROOT/Projects/Live.xcodeproj"
    _derived "Live-bin" "$MOTHER_ROOT/Projects/Live.xcodeproj"
    _derived "Dead-bin" "$MOTHER_ROOT/Projects/Gone.xcodeproj"
    _to_binary_plist "Live-bin"
    _to_binary_plist "Dead-bin"

    run mother gc
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_GC_DERIVED_DATA_DIR/Dead-bin" ]
    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/Live-bin" ]
}

@test "gc DerivedData: an info.plist without a WorkspacePath is never treated as orphaned" {
    mkdir -p "$MOTHER_GC_DERIVED_DATA_DIR/Odd-1"
    cat > "$MOTHER_GC_DERIVED_DATA_DIR/Odd-1/info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0"><dict><key>Other</key><string>x</string></dict></plist>
EOF
    mkdir -p "$MOTHER_GC_DERIVED_DATA_DIR/Odd-2"
    echo "not a plist at all" > "$MOTHER_GC_DERIVED_DATA_DIR/Odd-2/info.plist"

    run mother gc
    [ "$status" -eq 0 ]

    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/Odd-1" ]
    [ -d "$MOTHER_GC_DERIVED_DATA_DIR/Odd-2" ]
}

@test "gc DerivedData: a missing DerivedData directory is not an error" {
    run mother gc
    [ "$status" -eq 0 ]
}

# ===========================================================================
# 2. Go build cache
# ===========================================================================

@test "gc Go cache: over the cap with no job running runs go clean -cache" {
    _stub_go
    export MOTHER_GOCACHE_MAX_GB=0

    run mother gc
    [ "$status" -eq 0 ]

    [ "$(_go_clean_calls)" = "1" ]
    [ ! -e "$GOCACHE_DIR/entry" ]
}

@test "gc Go cache: --dry-run says it would run go clean -cache and does not" {
    _stub_go
    export MOTHER_GOCACHE_MAX_GB=0

    run mother gc --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" == *"would run go clean -cache"* ]]

    [ "$(_go_clean_calls)" = "0" ]
    [ -f "$GOCACHE_DIR/entry" ]
}

@test "gc Go cache: under the cap it is left alone and the output says so" {
    _stub_go
    export MOTHER_GOCACHE_MAX_GB=1

    run mother gc
    [ "$status" -eq 0 ]
    [[ "$output" == *"under"*"cap"* ]]

    [ "$(_go_clean_calls)" = "0" ]
    [ -f "$GOCACHE_DIR/entry" ]
}

@test "gc Go cache: an empty cache is not over a cap of 0" {
    _stub_go
    rm -f "$GOCACHE_DIR/entry"
    export MOTHER_GOCACHE_MAX_GB=0

    run mother gc
    [ "$status" -eq 0 ]

    [ "$(_go_clean_calls)" = "0" ]
}

@test "gc Go cache: MOTHER_GOCACHE_MAX_GB defaults to a cap a tiny cache is far under" {
    _stub_go

    run mother gc
    [ "$status" -eq 0 ]

    [ "$(_go_clean_calls)" = "0" ]
    [ -f "$GOCACHE_DIR/entry" ]
}

@test "gc Go cache: an empty MOTHER_GO_BIN means go is unavailable, and gc still exits 0" {
    export MOTHER_GO_BIN=""

    run mother gc
    [ "$status" -eq 0 ]
    [[ "$output" == *"go not available"* ]]
}

@test "gc Go cache: a MOTHER_GO_BIN that is not executable means go is unavailable" {
    echo "not executable" > "$MOTHER_ROOT/not-go"
    export MOTHER_GO_BIN="$MOTHER_ROOT/not-go"

    run mother gc
    [ "$status" -eq 0 ]
    [[ "$output" == *"go not available"* ]]
}

@test "gc Go cache: a running job blocks the clean and the output says why" {
    _stub_go
    export MOTHER_GOCACHE_MAX_GB=0
    make_job "gc-busy" "running"

    run mother gc
    [ "$status" -eq 0 ]
    [[ "$output" == *"job(s) running"* ]]

    [ "$(_go_clean_calls)" = "0" ]
    [ -f "$GOCACHE_DIR/entry" ]
}

@test "gc Go cache: a job that is merely ready or finished does not block the clean" {
    _stub_go
    export MOTHER_GOCACHE_MAX_GB=0
    make_job "gc-ready" "ready"
    make_job "gc-done" "succeeded"

    run mother gc
    [ "$status" -eq 0 ]

    [ "$(_go_clean_calls)" = "1" ]
}

@test "gc Go cache: a go that errors (asdf shim with no version set) is skipped with a reason, exit 0" {
    _stub_go
    export STUB_GO_FAIL=1
    export MOTHER_GOCACHE_MAX_GB=0

    run mother gc
    [ "$status" -eq 0 ]
    printf '%s\n' "$output" | grep -Ei 'go.*(skip|not available|unavailable|failed)'

    [ "$(_go_clean_calls)" = "0" ]
}

# ===========================================================================
# 3. Rust target/ directories: report, never remove
# ===========================================================================

@test "gc Rust targets: a target/ beside a Cargo.toml is reported as informational and left untouched" {
    mkdir -p "$MOTHER_GC_CODE_DIR/proj/target/debug"
    echo "[package]" > "$MOTHER_GC_CODE_DIR/proj/Cargo.toml"
    echo "binary" > "$MOTHER_GC_CODE_DIR/proj/target/debug/app"
    export MOTHER_GC_TARGET_REPORT_GB=0

    run mother gc
    [ "$status" -eq 0 ]
    local line
    line=$(printf '%s\n' "$output" | grep -F "proj/target")
    [ -n "$line" ]
    printf '%s\n' "$line" | grep -Eiq 'not touched|info'

    [ -f "$MOTHER_GC_CODE_DIR/proj/target/debug/app" ]
}

@test "gc Rust targets: they are never removed, dry-run or not" {
    mkdir -p "$MOTHER_GC_CODE_DIR/proj/target/debug"
    echo "[package]" > "$MOTHER_GC_CODE_DIR/proj/Cargo.toml"
    echo "binary" > "$MOTHER_GC_CODE_DIR/proj/target/debug/app"
    export MOTHER_GC_TARGET_REPORT_GB=0

    run mother gc --dry-run
    [ "$status" -eq 0 ]
    [[ "$output" != *"would remove"*"proj/target"* ]]
    run mother gc
    [ "$status" -eq 0 ]

    [ -f "$MOTHER_GC_CODE_DIR/proj/target/debug/app" ]
    [ -f "$MOTHER_GC_CODE_DIR/proj/Cargo.toml" ]
}

@test "gc Rust targets: a target/ with no sibling Cargo.toml is not reported" {
    mkdir -p "$MOTHER_GC_CODE_DIR/other/target"
    echo "x" > "$MOTHER_GC_CODE_DIR/other/target/file"
    export MOTHER_GC_TARGET_REPORT_GB=0

    run mother gc
    [ "$status" -eq 0 ]
    [[ "$output" != *"other/target"* ]]
    [ -f "$MOTHER_GC_CODE_DIR/other/target/file" ]
}

@test "gc Rust targets: a small target/ is below the default report threshold" {
    mkdir -p "$MOTHER_GC_CODE_DIR/proj/target"
    echo "[package]" > "$MOTHER_GC_CODE_DIR/proj/Cargo.toml"
    echo "x" > "$MOTHER_GC_CODE_DIR/proj/target/file"

    run mother gc
    [ "$status" -eq 0 ]
    [[ "$output" != *"proj/target"* ]]
}

# ===========================================================================
# 4. Job-scoped temp directories
# ===========================================================================

_job_tmp() {
    mkdir -p "$MOTHER_ROOT/tmp/$1/cache"
    head -c 3000 /dev/zero > "$MOTHER_ROOT/tmp/$1/cache/blob"
}

@test "gc job temp: dirs of jobs with no record left are removed; dirs of live records are kept" {
    _job_tmp "gone-job"
    _job_tmp "kept-job"
    make_job "kept-job" "succeeded"

    run mother gc
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_ROOT/tmp/gone-job" ]
    [ -d "$MOTHER_ROOT/tmp/kept-job/cache" ]
}

@test "gc job temp: the dir of an archived job (record moved out of jobs/) is removed" {
    _job_tmp "archived-job"
    mkdir -p "$ARCHIVE_DIR/2026-09"
    make_job "archived-job" "succeeded"
    mv "$JOBS_DIR/archived-job.json" "$ARCHIVE_DIR/2026-09/archived-job.json"

    run mother gc
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_ROOT/tmp/archived-job" ]
}

@test "gc job temp: --dry-run lists the removable dirs with sizes and removes nothing" {
    _job_tmp "gone-job"
    _job_tmp "kept-job"
    make_job "kept-job" "running"

    run mother gc --dry-run
    [ "$status" -eq 0 ]
    local line
    line=$(printf '%s\n' "$output" | grep -F "gone-job")
    [ -n "$line" ]
    [[ "$line" == "[dry-run] would remove"* ]]
    [[ "$line" =~ $SIZE_RE ]]
    [[ "$output" != *"kept-job"*"would remove"* ]]

    [ -d "$MOTHER_ROOT/tmp/gone-job/cache" ]
    [ -d "$MOTHER_ROOT/tmp/kept-job/cache" ]
}

@test "gc job temp: nothing outside \$MOTHER_ROOT/tmp is ever touched" {
    _job_tmp "gone-job"
    mkdir -p "$MOTHER_ROOT/fake-private-tmp/gone-job"
    echo "not ours" > "$MOTHER_ROOT/fake-private-tmp/sibling.txt"
    echo "not ours" > "$MOTHER_ROOT/fake-private-tmp/gone-job/file"
    echo "root file" > "$MOTHER_ROOT/some-top-level-file"

    run mother gc
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_ROOT/tmp/gone-job" ]
    [ -f "$MOTHER_ROOT/fake-private-tmp/sibling.txt" ]
    [ -f "$MOTHER_ROOT/fake-private-tmp/gone-job/file" ]
    [ -f "$MOTHER_ROOT/some-top-level-file" ]
    [ -d "$MOTHER_ROOT/jobs" ]
}

# ===========================================================================
# 5. Resolved teardown-residue records
# ===========================================================================

_residue_record() {
    local id="$1" path="$2"
    mkdir -p "$MOTHER_ROOT/teardown-residue"
    jq -nc --arg id "$id" --arg p "$path" \
        '{id: $id, repo: "r", branch: "b", path: $p, sub: "node_modules", since: "2026-09-01T00:00:00Z", command: "x"}' \
        > "$MOTHER_ROOT/teardown-residue/$id.json"
}

@test "gc residue records: a record whose directory is gone is pruned, a still-present one is kept" {
    mkdir -p "$MOTHER_ROOT/still-here"
    _residue_record "res-present" "$MOTHER_ROOT/still-here"
    _residue_record "res-gone" "$MOTHER_ROOT/already-removed"

    run mother gc
    [ "$status" -eq 0 ]

    [ -f "$MOTHER_ROOT/teardown-residue/res-present.json" ]
    [ ! -e "$MOTHER_ROOT/teardown-residue/res-gone.json" ]
    [ -d "$MOTHER_ROOT/still-here" ]
}

@test "gc residue records: --dry-run prunes nothing" {
    _residue_record "res-gone" "$MOTHER_ROOT/already-removed"

    run mother gc --dry-run
    [ "$status" -eq 0 ]

    [ -f "$MOTHER_ROOT/teardown-residue/res-gone.json" ]
}

# ===========================================================================
# General: always exits 0, steps are independent
# ===========================================================================

@test "gc with nothing to do exits 0" {
    run mother gc
    [ "$status" -eq 0 ]
    run mother gc --dry-run
    [ "$status" -eq 0 ]
}

@test "gc: an unreadable DerivedData directory does not stop the other steps or fail the sweep" {
    _require_non_root
    mkdir -p "$MOTHER_GC_DERIVED_DATA_DIR"
    chmod 000 "$MOTHER_GC_DERIVED_DATA_DIR"
    _job_tmp "gone-job"

    run mother gc
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_ROOT/tmp/gone-job" ]
}

# ===========================================================================
# 6. Hourly ride-along with the archive sweep
# ===========================================================================

_install_fake_mother_recording() {
    _FAKE_BIN="$MOTHER_ROOT/fake-bin"
    mkdir -p "$_FAKE_BIN"
    cat > "$_FAKE_BIN/mother" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$MOTHER_ROOT/mother-calls"
exit 0
EOF
    chmod +x "$_FAKE_BIN/mother"
    export MOTHER_BIN_DIR="$_FAKE_BIN"
}

@test "the hourly archive sweep also runs mother gc, after mother archive" {
    _install_fake_mother_recording
    export MOTHER_ARCHIVE_INTERVAL=0
    export MOTHER_ARCHIVE_TIMEOUT=20

    run mother-runner --archive-tick
    [ "$status" -eq 0 ]

    [ -f "$MOTHER_ROOT/mother-calls" ]
    local archive_line gc_line
    archive_line=$(grep -n '^archive' "$MOTHER_ROOT/mother-calls" | head -1 | cut -d: -f1)
    gc_line=$(grep -n '^gc' "$MOTHER_ROOT/mother-calls" | head -1 | cut -d: -f1)
    [ -n "$archive_line" ]
    [ -n "$gc_line" ]
    [ "$archive_line" -lt "$gc_line" ]
}

@test "MOTHER_GC_ENABLED=0 skips gc but the archive sweep still runs" {
    _install_fake_mother_recording
    export MOTHER_ARCHIVE_INTERVAL=0
    export MOTHER_ARCHIVE_TIMEOUT=20
    export MOTHER_GC_ENABLED=0

    run mother-runner --archive-tick
    [ "$status" -eq 0 ]

    grep -q '^archive' "$MOTHER_ROOT/mother-calls"
    run grep -q '^gc' "$MOTHER_ROOT/mother-calls"
    [ "$status" -ne 0 ]
}

@test "when the archive interval gate is not due, neither archive nor gc runs" {
    _install_fake_mother_recording
    echo "$(date +%s)" > "$RUNNER_DIR/last-archive.ts"
    export MOTHER_ARCHIVE_INTERVAL=3600

    run mother-runner --archive-tick
    [ "$status" -eq 0 ]

    [ ! -e "$MOTHER_ROOT/mother-calls" ]
}

# ===========================================================================
# 7. Documentation
# ===========================================================================

@test "mother help documents gc and its two knobs" {
    run mother help
    [ "$status" -eq 0 ]
    [[ "$output" == *"mother gc"* ]]
    [[ "$output" == *"MOTHER_MIN_FREE_GB"* ]]
    [[ "$output" == *"MOTHER_GOCACHE_MAX_GB"* ]]
}

@test "README documents mother gc, MOTHER_MIN_FREE_GB and MOTHER_GOCACHE_MAX_GB" {
    local readme="$REPO_ROOT_DIR/README.md"
    [ -f "$readme" ]
    grep -Fq "mother gc" "$readme"
    grep -Fq "MOTHER_MIN_FREE_GB" "$readme"
    grep -Fq "MOTHER_GOCACHE_MAX_GB" "$readme"
}

@test "CHANGELOG has an entry for mother gc" {
    local changelog="$REPO_ROOT_DIR/CHANGELOG.md"
    [ -f "$changelog" ]
    grep -Fq "mother gc" "$changelog"
}
