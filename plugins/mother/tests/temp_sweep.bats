#!/usr/bin/env bats
# temp_sweep.bats — behavioral contract for the orphaned-temp-file sweep.
#
# `_prune_orphan_temps` / `cmd_prune_temps` / `mother prune-temps` do NOT
# exist yet in plugins/mother/bin/mother, and `mother-runner --prune-temps-tick`
# does not exist yet either. Every test in this file is expected to FAIL
# (red) until Cody implements the feature. Do not weaken an assertion to
# make it pass against current behavior — that defeats the point of
# red/green.
#
# Contract under test:
#   - `mother prune-temps [--dry-run]` sweeps (each -maxdepth 1): $MOTHER_ROOT,
#     $JOBS_DIR, $EVENTS_DIR, $DRAFTS_DIR, $CURSORS_DIR, $RUNNER_DIR,
#     $TEARDOWN_DIR.
#   - It removes regular FILES (never directories) matching `*.tmp.*` or
#     `*.bak.*` whose mtime is older than MOTHER_TEMP_ORPHAN_MINUTES minutes
#     (default 60). A freshly-written temp file (still mid-write by some
#     other process) must never be touched — that's the whole safety
#     rationale for the age gate.
#   - MOTHER_RETENTION_SWEEP_ENABLED=0 (default 1) disables the sweep
#     entirely.
#   - `mother archive --older-than N` (bulk form, no positional id) runs the
#     sweep as part of its pass. `mother archive <id>` (single-id form) does
#     NOT.
#   - `mother-runner` runs the sweep once at daemon startup; a test-only
#     entry point `mother-runner --prune-temps-tick` runs just that step
#     and exits, logging a line containing `prune-temps:`.

load 'test_helper'

# Mock `gh`/`docker` so `mother archive` end-to-end calls in this file never
# depend on real tooling being present. Mirrors teardown.bats's mocks; kept
# minimal since this file only cares whether the *sweep* ran, not teardown
# disposition logic (already covered by teardown.bats).
_install_mock_gh() {
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-gh-calls"
if [ "${MOCK_GH_EXIT:-0}" != "0" ]; then
    exit "${MOCK_GH_EXIT}"
fi
case "$*" in
    *"pr view"*state*) printf '%s\n' "${MOCK_GH_STATE:-OPEN}" ;;
    *) echo "" ;;
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

# Backdate a file (or directory) far enough in the past that any sane
# MOTHER_TEMP_ORPHAN_MINUTES threshold considers it orphaned.
_backdate() {
    touch -t 202001010000 "$1"
}

setup() {
    setup_mother_env
    _install_mock_gh
    _install_mock_docker
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# 1. Basic removal in $MOTHER_ROOT
# ---------------------------------------------------------------------------

@test "an old rate-limits.json.tmp.* file in MOTHER_ROOT is removed by mother prune-temps" {
    local f="$MOTHER_ROOT/rate-limits.json.tmp.999"
    touch "$f"
    _backdate "$f"

    run mother prune-temps
    [ "$status" -eq 0 ]
    [ ! -e "$f" ]
    [[ "$output" == *"removed"* ]]
}

# ---------------------------------------------------------------------------
# 2. Both .tmp. and .bak. shapes removed in $JOBS_DIR
# ---------------------------------------------------------------------------

@test "old .tmp. and .bak. files in JOBS_DIR are both removed by mother prune-temps" {
    local f1="$JOBS_DIR/x.json.tmp.999"
    local f2="$JOBS_DIR/x.json.bak.1"
    touch "$f1" "$f2"
    _backdate "$f1"
    _backdate "$f2"

    run mother prune-temps
    [ "$status" -eq 0 ]
    [ ! -e "$f1" ]
    [ ! -e "$f2" ]
}

# ---------------------------------------------------------------------------
# 3. In-flight-write safety — THE most important case in this file
# ---------------------------------------------------------------------------

@test "a freshly created tmp file survives a default-settings prune-temps run" {
    # Deliberately NOT setting MOTHER_TEMP_ORPHAN_MINUTES=0 here: this proves
    # the age gate protects a file that some other process may still be
    # mid-write on. If this test ever passes because the sweep deletes
    # aggressively, that is a correctness regression, not progress.
    local f="$MOTHER_ROOT/live-write.json.tmp.42"
    touch "$f"

    run mother prune-temps
    [ "$status" -eq 0 ]
    [ -e "$f" ]
}

# ---------------------------------------------------------------------------
# 4. --dry-run never removes, but still reports
# ---------------------------------------------------------------------------

@test "mother prune-temps --dry-run removes nothing but reports a would-remove count" {
    local f="$MOTHER_ROOT/dryrun.json.tmp.1"
    touch "$f"
    _backdate "$f"

    run mother prune-temps --dry-run
    [ "$status" -eq 0 ]
    [ -e "$f" ]
    [[ "$output" == *"would remove"* ]]
}

# ---------------------------------------------------------------------------
# 5. Kill switch
# ---------------------------------------------------------------------------

@test "MOTHER_RETENTION_SWEEP_ENABLED=0 disables the sweep entirely" {
    local f="$MOTHER_ROOT/disabled.json.tmp.1"
    touch "$f"
    _backdate "$f"

    MOTHER_RETENTION_SWEEP_ENABLED=0 run mother prune-temps
    [ "$status" -eq 0 ]
    [ -e "$f" ]
    [[ "$output" == *"disabled"* ]]
}

# ---------------------------------------------------------------------------
# 6. Lockdirs are a live concurrency primitive — never touched
# ---------------------------------------------------------------------------

@test "a lockdir survives the sweep even after backdating its mtime old" {
    local d="$JOBS_DIR/some-target.json.lockdir"
    mkdir "$d"
    _backdate "$d"

    run mother prune-temps
    [ "$status" -eq 0 ]
    [ -d "$d" ]
}

# ---------------------------------------------------------------------------
# 7. A directory that merely LOOKS like a *.tmp.* name is still a directory
# ---------------------------------------------------------------------------

@test "a directory named like a tmp file (not a regular file) survives the sweep" {
    local d="$JOBS_DIR/a.json.tmp.d"
    mkdir "$d"
    _backdate "$d"

    run mother prune-temps
    [ "$status" -eq 0 ]
    [ -d "$d" ]
}

# ---------------------------------------------------------------------------
# 8. Live job records are never collateral damage
# ---------------------------------------------------------------------------

@test "a live job file in JOBS_DIR is untouched by a sweep that also removes an old temp file" {
    make_job "live-job-untouched" "ready"
    local f="$JOBS_DIR/orphan.json.tmp.7"
    touch "$f"
    _backdate "$f"

    run mother prune-temps
    [ "$status" -eq 0 ]
    [ -f "$JOBS_DIR/live-job-untouched.json" ]
    [ ! -e "$f" ]
}

# ---------------------------------------------------------------------------
# 9. Bulk `mother archive --older-than N` runs the sweep
# ---------------------------------------------------------------------------

@test "mother archive --older-than N (bulk form) performs the orphan-temp sweep" {
    local f="$MOTHER_ROOT/bulk-archive.json.tmp.1"
    touch "$f"
    _backdate "$f"

    run mother archive --older-than 30
    [ "$status" -eq 0 ]
    [ ! -e "$f" ]
}

# ---------------------------------------------------------------------------
# 10. Single-id `mother archive <id>` does NOT run the sweep
# ---------------------------------------------------------------------------

@test "mother archive <id> (single-id form) does NOT perform the orphan-temp sweep" {
    # A real terminal job with no PR URL, so the teardown gate proceeds
    # immediately without needing a real repo_path on disk (same shape as
    # teardown.bats's "no PR URL on a failed job tears down immediately").
    make_job "single-id-no-sweep" "failed" \
        ".pr_url = null | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""
    local f="$MOTHER_ROOT/single-id.json.tmp.1"
    touch "$f"
    _backdate "$f"

    run mother archive single-id-no-sweep
    [ "$status" -eq 0 ]
    [ -e "$f" ]
}

# ---------------------------------------------------------------------------
# 11. mother-runner startup tick
# ---------------------------------------------------------------------------

@test "mother-runner --prune-temps-tick performs the sweep and logs a prune-temps: line" {
    local f="$MOTHER_ROOT/runner-tick.json.tmp.1"
    touch "$f"
    _backdate "$f"

    run mother-runner --prune-temps-tick
    [ "$status" -eq 0 ]
    [ ! -e "$f" ]
    [[ "$output" == *"prune-temps:"* ]]
}
