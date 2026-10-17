#!/usr/bin/env bats
# backup.bats — `mother backup now|list|restore` and the runner's backup tick.
#
# Contract under test:
#   * `mother backup now` writes $MOTHER_BACKUP_DIR/mother-state-<UTC stamp>.tar.gz
#     atomically, prints its path, contains the restorable state (jobs, events,
#     archive, ...; logs only with MOTHER_BACKUP_LOGS=1), refuses a backup dir
#     inside MOTHER_ROOT, and then prunes by retention (decided from the
#     timestamp in the filename, never mtime; foreign files are never touched).
#   * `mother-runner --backup-tick` takes a backup only when the interval gate
#     (runner/last-backup.ts) allows it; MOTHER_BACKUP_ENABLED=0 disables it.
#   * `mother backup list` lists newest first with size and jobs=N.
#   * `mother backup restore` refuses while the daemon runs, refuses without
#     --yes off a tty, refuses a corrupt archive, and otherwise moves the
#     current state aside (never deletes it) before extracting.
#
# Every test points the backup dir at a throwaway location outside MOTHER_ROOT.

load 'test_helper'

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_BACKUP_DIR="$BATS_TEST_TMPDIR/backups"
    unset MOTHER_BACKUP_INTERVAL MOTHER_BACKUP_KEEP_HOURS MOTHER_BACKUP_KEEP_DAYS \
          MOTHER_BACKUP_ENABLED MOTHER_BACKUP_LOGS MOTHER_BACKUP_NOW_EPOCH
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# One bounded runner tick. Until --backup-tick exists mother-runner would start
# its daemon loop, so the call is capped at 20s (perl alarm) to keep RED runs
# from hanging the suite.
_tick() {
    perl -e 'alarm 20; exec @ARGV' mother-runner --backup-tick
}

_backup_files() {
    ls "$MOTHER_BACKUP_DIR"/mother-state-*.tar.gz 2>/dev/null || true
}

_backup_count() {
    _backup_files | grep -c . || true
}

# Entry names in a tarball, normalised (leading ./ stripped).
_tar_names() {
    tar -tzf "$1" | sed 's|^\./||'
}

# Run `mother backup now`; sets BK (path printed on stdout) and BK_RC.
_backup_now() {
    BK_RC=0
    BK=$(mother backup now 2>"$BATS_TEST_TMPDIR/bk.err") || BK_RC=$?
    BK=$(printf '%s\n' "$BK" | tail -n1)
}

# Build a fixture tarball by hand: _fake_tar <name> <stage-dir> [./]
_fake_backup_with_jobs() {
    local name="$1" njobs="$2" stage i
    stage=$(mktemp -d "$BATS_TEST_TMPDIR/stage.XXXXXX")
    mkdir -p "$stage/jobs" "$stage/archive"
    for i in $(seq 1 "$njobs"); do echo '{}' > "$stage/jobs/j$i.json"; done
    echo '{}' > "$stage/archive/old.json"   # archive entries must not count as jobs
    mkdir -p "$MOTHER_BACKUP_DIR"
    if [ "${3:-}" = "dotslash" ]; then
        tar -czf "$MOTHER_BACKUP_DIR/$name" -C "$stage" .
    else
        tar -czf "$MOTHER_BACKUP_DIR/$name" -C "$stage" jobs archive
    fi
    rm -rf "$stage"
}

# Epoch for an ISO UTC stamp, portable across BSD/GNU date.
_epoch() {
    date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s
}

_fake_stamp() {   # create an empty-ish backup file with the given stamp
    mkdir -p "$MOTHER_BACKUP_DIR"
    echo x > "$MOTHER_BACKUP_DIR/mother-state-$1.tar.gz"
}

# ===========================================================================
# backup now
# ===========================================================================

@test "backup now writes a timestamped tarball, prints its path, and leaves no temp file behind" {
    make_job "bk-job" ready
    echo '{"x":1}' > "$ARCHIVE_DIR/arch-job.json"

    _backup_now

    [ "$BK_RC" -eq 0 ]
    [[ "$BK" == "$MOTHER_BACKUP_DIR"/mother-state-*.tar.gz ]]
    [[ "$(basename "$BK")" =~ ^mother-state-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]
    [ -s "$BK" ]
    [ "$(ls "$MOTHER_BACKUP_DIR" | grep -c 'tmp' || true)" -eq 0 ]
    [ "$(ls "$MOTHER_BACKUP_DIR" | wc -l | tr -d ' ')" -eq 1 ]

    local names; names=$(_tar_names "$BK")
    grep -qx 'jobs/bk-job.json' <<<"$names"
    grep -qx 'archive/arch-job.json' <<<"$names"
}

@test "backup now stamps the file with the current UTC time" {
    local before after stamp
    before=$(date -u +%Y%m%dT%H%M%S)
    _backup_now
    after=$(date -u +%Y%m%dT%H%M%S)
    [ "$BK_RC" -eq 0 ]
    stamp=$(basename "$BK" | sed -E 's/^mother-state-([0-9]{8}T[0-9]{6})Z\.tar\.gz$/\1/')
    [[ "$stamp" > "$before" || "$stamp" == "$before" ]]
    [[ "$stamp" < "$after" || "$stamp" == "$after" ]]
}

@test "backup now excludes logs by default" {
    make_job "bk-job" ready
    echo "log line" > "$LOGS_DIR/bk-job.log"

    _backup_now

    [ "$BK_RC" -eq 0 ]
    ! _tar_names "$BK" | grep -q '^logs/'
}

@test "backup now includes logs when MOTHER_BACKUP_LOGS=1" {
    make_job "bk-job" ready
    echo "log line" > "$LOGS_DIR/bk-job.log"
    export MOTHER_BACKUP_LOGS=1

    _backup_now

    [ "$BK_RC" -eq 0 ]
    _tar_names "$BK" | grep -qx 'logs/bk-job.log'
}

@test "backup now includes events, drafts, cursors, metrics, attention, rate-limits and config.env when present" {
    echo '{}' > "$EVENTS_DIR/e.jsonl"
    echo d > "$DRAFTS_DIR/draft.md"
    echo c > "$CURSORS_DIR/cur.json"
    mkdir -p "$MOTHER_ROOT/metrics"; echo '{}' > "$MOTHER_ROOT/metrics/runs.jsonl"
    echo '[]' > "$MOTHER_ROOT/attention.json"
    echo '{}' > "$MOTHER_ROOT/rate-limits.json"
    echo 'MOTHER_CONCURRENCY=2' > "$MOTHER_ROOT/config.env"

    _backup_now
    [ "$BK_RC" -eq 0 ]

    local names; names=$(_tar_names "$BK")
    grep -qx 'events/e.jsonl' <<<"$names"
    grep -qx 'drafts/draft.md' <<<"$names"
    grep -qx 'cursors/cur.json' <<<"$names"
    grep -qx 'metrics/runs.jsonl' <<<"$names"
    grep -qx 'attention.json' <<<"$names"
    grep -qx 'rate-limits.json' <<<"$names"
    grep -qx 'config.env' <<<"$names"
}

@test "backup now succeeds when optional files (config.env, metrics, attention.json) do not exist" {
    make_job "bk-job" ready
    rm -f "$MOTHER_ROOT/config.env" "$MOTHER_ROOT/attention.json" "$MOTHER_ROOT/rate-limits.json"
    rm -rf "$MOTHER_ROOT/metrics"

    _backup_now

    [ "$BK_RC" -eq 0 ]
    _tar_names "$BK" | grep -qx 'jobs/bk-job.json'
}

@test "backup now creates a missing backup directory" {
    export MOTHER_BACKUP_DIR="$BATS_TEST_TMPDIR/deep/er/backups"
    [ ! -e "$MOTHER_BACKUP_DIR" ]

    _backup_now

    [ "$BK_RC" -eq 0 ]
    [ -s "$BK" ]
}

@test "backup now refuses a backup directory inside MOTHER_ROOT and writes nothing" {
    export MOTHER_BACKUP_DIR="$MOTHER_ROOT/backups-inside"

    run mother backup now

    [ "$status" -ne 0 ]
    [[ "$output" == *"inside"* ]]
    [ "$(_backup_count)" -eq 0 ]
}

# ===========================================================================
# retention
# ===========================================================================

# Fixed clock: 2026-06-15T12:00:00Z. Fake stamps, offsets from that clock:
#   20260615T100000Z  2h    keep (within KEEP_HOURS)
#   20260615T020000Z  10h   keep
#   20260614T130000Z  23h   keep
#   20260613T200000Z  40h   newest of its day  -> keep
#   20260613T080000Z  52h   same day, older    -> delete
#   20260605T120000Z  10d   only one that day  -> keep
#   20260605T060000Z  10d   same day, older    -> delete
#   20260501T120000Z  45d   beyond KEEP_DAYS   -> delete
_seed_retention_fixtures() {
    _fake_stamp 20260615T100000Z
    _fake_stamp 20260615T020000Z
    _fake_stamp 20260614T130000Z
    _fake_stamp 20260613T200000Z
    _fake_stamp 20260613T080000Z
    _fake_stamp 20260605T120000Z
    _fake_stamp 20260605T060000Z
    _fake_stamp 20260501T120000Z
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)
}

_exists()  { [ -e "$MOTHER_BACKUP_DIR/mother-state-$1.tar.gz" ]; }

@test "retention keeps everything newer than KEEP_HOURS, one per day after that, and drops what is older than KEEP_DAYS" {
    _seed_retention_fixtures

    _backup_now
    [ "$BK_RC" -eq 0 ]

    _exists 20260615T100000Z
    _exists 20260615T020000Z
    _exists 20260614T130000Z
    _exists 20260613T200000Z
    ! _exists 20260613T080000Z
    _exists 20260605T120000Z
    ! _exists 20260605T060000Z
    ! _exists 20260501T120000Z
    # The fresh backup written by this very run is never pruned.
    [ -s "$BK" ]
}

@test "retention is driven by the timestamp in the filename, not by file mtime" {
    _seed_retention_fixtures
    # A 2h-old backup with an ancient mtime must survive; a 45d-old one with a
    # fresh mtime must still go.
    touch -t 200101010000 "$MOTHER_BACKUP_DIR/mother-state-20260615T100000Z.tar.gz"
    touch "$MOTHER_BACKUP_DIR/mother-state-20260501T120000Z.tar.gz"

    _backup_now
    [ "$BK_RC" -eq 0 ]

    _exists 20260615T100000Z
    ! _exists 20260501T120000Z
}

@test "retention never deletes files that are not mother-state-*.tar.gz backups" {
    _seed_retention_fixtures
    echo keep > "$MOTHER_BACKUP_DIR/README.txt"
    echo keep > "$MOTHER_BACKUP_DIR/other-20200101T000000Z.tar.gz"
    echo keep > "$MOTHER_BACKUP_DIR/mother-state-20200101T000000Z.tar.gz.bak"
    mkdir "$MOTHER_BACKUP_DIR/mother-state-dir"

    _backup_now
    [ "$BK_RC" -eq 0 ]

    [ -f "$MOTHER_BACKUP_DIR/README.txt" ]
    [ -f "$MOTHER_BACKUP_DIR/other-20200101T000000Z.tar.gz" ]
    [ -f "$MOTHER_BACKUP_DIR/mother-state-20200101T000000Z.tar.gz.bak" ]
    [ -d "$MOTHER_BACKUP_DIR/mother-state-dir" ]
}

@test "retention honours MOTHER_BACKUP_KEEP_DAYS" {
    _seed_retention_fixtures
    export MOTHER_BACKUP_KEEP_DAYS=5

    _backup_now
    [ "$BK_RC" -eq 0 ]

    _exists 20260613T200000Z          # 2d old, newest of its day
    ! _exists 20260613T080000Z
    ! _exists 20260605T120000Z        # 10d old: past the 5-day window
    ! _exists 20260605T060000Z
    ! _exists 20260501T120000Z
}

@test "retention honours MOTHER_BACKUP_KEEP_HOURS" {
    _seed_retention_fixtures
    export MOTHER_BACKUP_KEEP_HOURS=1

    _backup_now
    [ "$BK_RC" -eq 0 ]

    # With a 1h window the 2h-old backup is no longer kept "for being recent",
    # but it is the newest of 2026-06-15 so it still survives as the day's
    # representative; the older same-day one is dropped.
    _exists 20260615T100000Z
    ! _exists 20260615T020000Z
}

# ===========================================================================
# runner backup tick (interval gate)
# ===========================================================================

@test "first backup tick takes a backup and records the time in last-backup.ts" {
    make_job "tick-job" ready
    export MOTHER_BACKUP_INTERVAL=900
    local before; before=$(date +%s)

    run _tick
    [ "$status" -eq 0 ]

    [ "$(_backup_count)" -eq 1 ]
    [ -f "$RUNNER_DIR/last-backup.ts" ]
    local ts; ts=$(tr -d '[:space:]' < "$RUNNER_DIR/last-backup.ts")
    [[ "$ts" =~ ^[0-9]+$ ]]
    [ "$ts" -ge $((before - 2)) ]
    [ "$ts" -le $(( $(date +%s) + 2 )) ]
}

@test "a second backup tick inside the interval does not take another backup" {
    export MOTHER_BACKUP_INTERVAL=3600

    run _tick
    [ "$status" -eq 0 ]
    [ "$(_backup_count)" -eq 1 ]
    local marker_before; marker_before=$(cat "$RUNNER_DIR/last-backup.ts")

    run _tick
    [ "$status" -eq 0 ]

    [ "$(_backup_count)" -eq 1 ]
    [ "$(cat "$RUNNER_DIR/last-backup.ts")" = "$marker_before" ]
}

@test "a backup tick fires again once the marker is older than the interval" {
    export MOTHER_BACKUP_INTERVAL=900
    echo "$(( $(date +%s) - 7200 ))" > "$RUNNER_DIR/last-backup.ts"
    local before; before=$(date +%s)

    run _tick
    [ "$status" -eq 0 ]

    [ "$(_backup_count)" -eq 1 ]
    [ "$(tr -d '[:space:]' < "$RUNNER_DIR/last-backup.ts")" -ge $((before - 2)) ]
}

@test "a backup tick does nothing when the marker is fresher than the interval" {
    export MOTHER_BACKUP_INTERVAL=900
    echo "$(( $(date +%s) - 60 ))" > "$RUNNER_DIR/last-backup.ts"

    run _tick
    [ "$status" -eq 0 ]

    [ "$(_backup_count)" -eq 0 ]
}

@test "MOTHER_BACKUP_ENABLED=0 disables the tick: no backup and no marker" {
    export MOTHER_BACKUP_ENABLED=0
    export MOTHER_BACKUP_INTERVAL=0

    run _tick
    [ "$status" -eq 0 ]

    [ "$(_backup_count)" -eq 0 ]
    [ ! -e "$RUNNER_DIR/last-backup.ts" ]
}

@test "a backup tick with the backup dir inside MOTHER_ROOT produces no backup file" {
    export MOTHER_BACKUP_DIR="$MOTHER_ROOT/backups-inside"
    export MOTHER_BACKUP_INTERVAL=0

    run _tick

    [ -z "$(find "$MOTHER_ROOT" -name 'mother-state-*' 2>/dev/null)" ]
}

# ===========================================================================
# backup list
# ===========================================================================

@test "backup list shows newest first with a size and the job count of each backup" {
    _fake_backup_with_jobs mother-state-20260101T000000Z.tar.gz 2
    _fake_backup_with_jobs mother-state-20260102T000000Z.tar.gz 3 dotslash

    run mother backup list
    [ "$status" -eq 0 ]

    local lines; lines=$(grep -c 'mother-state-' <<<"$output")
    [ "$lines" -eq 2 ]
    local first second
    first=$(grep 'mother-state-' <<<"$output" | sed -n 1p)
    second=$(grep 'mother-state-' <<<"$output" | sed -n 2p)
    [[ "$first" == *"mother-state-20260102T000000Z.tar.gz"* ]]
    [[ "$first" == *"jobs=3"* ]]
    [[ "$second" == *"mother-state-20260101T000000Z.tar.gz"* ]]
    [[ "$second" == *"jobs=2"* ]]
    # human-readable size on each line
    [[ "$first" =~ [0-9]+(\.[0-9]+)?[[:space:]]?(B|K|KB|KiB|M|MB|MiB|G|GB) ]]
    [[ "$second" =~ [0-9]+(\.[0-9]+)?[[:space:]]?(B|K|KB|KiB|M|MB|MiB|G|GB) ]]
}

@test "backup list on an empty backup directory says there are no backups and exits 0" {
    mkdir -p "$MOTHER_BACKUP_DIR"

    run mother backup list

    [ "$status" -eq 0 ]
    [[ "$output" =~ [Nn]o[[:space:]]+backups ]]
}

@test "backup list on a missing backup directory says there are no backups and exits 0" {
    [ ! -e "$MOTHER_BACKUP_DIR" ]

    run mother backup list

    [ "$status" -eq 0 ]
    [[ "$output" =~ [Nn]o[[:space:]]+backups ]]
}

@test "backup list reports a backup taken by backup now with its real job count" {
    make_job "a" ready
    make_job "b" ready
    _backup_now
    [ "$BK_RC" -eq 0 ]

    run mother backup list
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(basename "$BK")"* ]]
    [[ "$output" == *"jobs=2"* ]]
}

# ===========================================================================
# backup restore
# ===========================================================================

_pre_restore_dirs() {
    find "$MOTHER_ROOT" -maxdepth 1 -name '.pre-restore-*' 2>/dev/null
}

@test "restore refuses while the runner pid file names a live process" {
    make_job "orig" ready
    _backup_now
    [ "$BK_RC" -eq 0 ]
    rm -f "$JOBS_DIR/orig.json"
    echo $$ > "$RUNNER_DIR/runner.pid"

    run mother backup restore "$BK" --yes </dev/null

    [ "$status" -ne 0 ]
    [[ "$output" == *"mother daemon stop"* ]]
    [ ! -e "$JOBS_DIR/orig.json" ]
    [ -z "$(_pre_restore_dirs)" ]
}

@test "restore without --yes and without a tty refuses and changes nothing" {
    make_job "orig" ready
    _backup_now
    [ "$BK_RC" -eq 0 ]
    rm -f "$JOBS_DIR/orig.json"
    make_job "later" ready

    run mother backup restore "$BK" </dev/null

    [ "$status" -ne 0 ]
    [ -f "$JOBS_DIR/later.json" ]
    [ ! -e "$JOBS_DIR/orig.json" ]
    [ -z "$(_pre_restore_dirs)" ]
}

@test "restore --yes brings the backed-up state back and keeps the replaced state under .pre-restore-*" {
    make_job "orig" ready
    echo '{"kind":"old"}' > "$ARCHIVE_DIR/arch.json"
    _backup_now
    [ "$BK_RC" -eq 0 ]
    local orig_title; orig_title=$(jq -r '.title' "$JOBS_DIR/orig.json")

    # Diverge: lose the original job, gain a different one.
    rm -f "$JOBS_DIR/orig.json"
    make_job "later" ready
    echo '{"kind":"new"}' > "$ARCHIVE_DIR/arch.json"

    run mother backup restore "$BK" --yes </dev/null
    [ "$status" -eq 0 ]
    [ -n "$output" ]

    # Original state is back; the post-backup job is gone from the live tree.
    [ -f "$JOBS_DIR/orig.json" ]
    [ "$(jq -r '.title' "$JOBS_DIR/orig.json")" = "$orig_title" ]
    [ "$(jq -r '.id' "$JOBS_DIR/orig.json")" = "orig" ]
    [ ! -e "$JOBS_DIR/later.json" ]
    [ "$(jq -r '.kind' "$ARCHIVE_DIR/arch.json")" = "old" ]

    # ...but nothing was destroyed: the diverged state sits in .pre-restore-*.
    local pre; pre=$(_pre_restore_dirs | head -n1)
    [ -n "$pre" ]
    [ -f "$pre/jobs/later.json" ]
    [ "$(jq -r '.kind' "$pre/archive/arch.json")" = "new" ]
}

@test "restore resolves a bare filename inside the backup directory" {
    make_job "orig" ready
    _backup_now
    [ "$BK_RC" -eq 0 ]
    rm -f "$JOBS_DIR/orig.json"

    run mother backup restore "$(basename "$BK")" --yes </dev/null

    [ "$status" -eq 0 ]
    [ -f "$JOBS_DIR/orig.json" ]
}

@test "restore refuses a corrupt, non-tarball file without moving anything aside" {
    make_job "keepme" ready
    mkdir -p "$MOTHER_BACKUP_DIR"
    echo "this is not a tarball" > "$MOTHER_BACKUP_DIR/mother-state-20200101T000000Z.tar.gz"

    run mother backup restore "$MOTHER_BACKUP_DIR/mother-state-20200101T000000Z.tar.gz" --yes </dev/null

    [ "$status" -ne 0 ]
    [ -f "$JOBS_DIR/keepme.json" ]
    [ -z "$(_pre_restore_dirs)" ]
}

@test "restore of a nonexistent backup name fails and changes nothing" {
    make_job "keepme" ready
    mkdir -p "$MOTHER_BACKUP_DIR"

    run mother backup restore "mother-state-19990101T000000Z.tar.gz" --yes </dev/null

    [ "$status" -ne 0 ]
    [ -f "$JOBS_DIR/keepme.json" ]
    [ -z "$(_pre_restore_dirs)" ]
}

# ===========================================================================
# help
# ===========================================================================

@test "mother help documents the backup subcommands" {
    run mother help
    [ "$status" -eq 0 ]
    [[ "$output" == *"backup now"* ]]
    [[ "$output" == *"backup list"* ]]
    [[ "$output" == *"backup restore"* ]]
}
