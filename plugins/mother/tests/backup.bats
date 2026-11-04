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
#   * `mother backup list` lists newest first with size and jobs=N, then the
#     archive backups (kind=archive), then a one-line summary.
#   * `mother backup restore` refuses while the daemon runs, refuses without
#     --yes off a tty, refuses a corrupt archive, and otherwise moves the
#     current state aside (never deletes it) before extracting.
#
# Churn control (this change): the append-only archive/ lives in its own
# mother-archive-<ts>.tar.gz (not in the state tarball), and `backup now --auto`
# (what the runner calls) skips the state tarball when nothing meaningful
# changed since the last one and that one is younger than MOTHER_BACKUP_MAX_AGE.
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
          MOTHER_BACKUP_ENABLED MOTHER_BACKUP_LOGS MOTHER_BACKUP_NOW_EPOCH \
          MOTHER_BACKUP_MAX_AGE MOTHER_BACKUP_WARN_GB MOTHER_BACKUP_ARCHIVE_INTERVAL
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

_archive_files() {
    ls "$MOTHER_BACKUP_DIR"/mother-archive-*.tar.gz 2>/dev/null || true
}

_archive_count() {
    _archive_files | grep -c . || true
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

# Run `mother backup now --auto`; sets AUTO_OUT (stdout only) and AUTO_RC.
_auto() {
    AUTO_RC=0
    AUTO_OUT=$(mother backup now --auto 2>"$BATS_TEST_TMPDIR/auto.err") || AUTO_RC=$?
}

# Real tarball holding one file: _fake_tarball <backup-file-name> <relpath> <content>
_fake_tarball() {
    local name="$1" rel="$2" content="$3" stage
    stage=$(mktemp -d "$BATS_TEST_TMPDIR/stage.XXXXXX")
    mkdir -p "$stage/$(dirname "$rel")"
    printf '%s' "$content" > "$stage/$rel"
    mkdir -p "$MOTHER_BACKUP_DIR"
    tar -czf "$MOTHER_BACKUP_DIR/$name" -C "$stage" "${rel%%/*}"
    rm -rf "$stage"
}

# UTC stamp for "<seconds> ago", portable across BSD/GNU date.
_stamp_ago() {
    local e=$(( $(date +%s) - $1 ))
    date -u -r "$e" +%Y%m%dT%H%M%SZ 2>/dev/null || date -u -d "@$e" +%Y%m%dT%H%M%SZ
}

# Pretend the existing backups were taken <seconds> ago by renaming them (age is
# read from the filename). _age_backups <seconds> [state|archive|both]. Assumes
# at most one backup of each kind exists.
_age_backups() {
    local stamp f kind which="${2:-both}"
    stamp=$(_stamp_ago "$1")
    for f in "$MOTHER_BACKUP_DIR"/mother-state-*.tar.gz "$MOTHER_BACKUP_DIR"/mother-archive-*.tar.gz; do
        [ -e "$f" ] || continue
        kind=$(basename "$f"); kind=${kind#mother-}; kind=${kind%%-*}
        [ "$which" = both ] || [ "$which" = "$kind" ] || continue
        mv "$f" "$MOTHER_BACKUP_DIR/mother-$kind-$stamp.tar.gz"
    done
}

# Fingerprint of the recorded state signature, to prove it was left untouched.
_sig_sum() { cksum < "$RUNNER_DIR/last-backup.sig"; }

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
    # One state tarball + one archive tarball, nothing else.
    [ "$(ls "$MOTHER_BACKUP_DIR" | wc -l | tr -d ' ')" -eq 2 ]
    [ "$(_archive_count)" -eq 1 ]

    # The state tarball no longer carries archive/; that lives in its own file.
    local names; names=$(_tar_names "$BK")
    grep -qx 'jobs/bk-job.json' <<<"$names"
    ! grep -q '^archive' <<<"$names"

    local arch; arch=$(_archive_files)
    [[ "$(basename "$arch")" =~ ^mother-archive-[0-9]{8}T[0-9]{6}Z\.tar\.gz$ ]]
    local anames; anames=$(_tar_names "$arch")
    grep -qx 'archive/arch-job.json' <<<"$anames"
    # ...and the archive tarball holds nothing but archive/.
    ! grep -qv '^archive\(/\|$\)' <<<"$anames"
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

_fake_archive_stamp() {   # create an empty-ish archive backup with the given stamp
    mkdir -p "$MOTHER_BACKUP_DIR"
    echo x > "$MOTHER_BACKUP_DIR/mother-archive-$1.tar.gz"
}
_a_exists() { [ -e "$MOTHER_BACKUP_DIR/mother-archive-$1.tar.gz" ]; }

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

# ===========================================================================
# backup now: state + archive layout
# ===========================================================================

@test "backup now prints the archive tarball path first and the state tarball path last" {
    make_job "bk-job" ready
    echo '{"x":1}' > "$ARCHIVE_DIR/arch-job.json"

    local out; out=$(mother backup now 2>/dev/null)

    [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 2 ]
    [[ "$(printf '%s\n' "$out" | sed -n 1p)" == "$MOTHER_BACKUP_DIR"/mother-archive-*.tar.gz ]]
    [[ "$(printf '%s\n' "$out" | sed -n 2p)" == "$MOTHER_BACKUP_DIR"/mother-state-*.tar.gz ]]
    [ -s "$(printf '%s\n' "$out" | sed -n 1p)" ]
    [ -s "$(printf '%s\n' "$out" | sed -n 2p)" ]
}

@test "backup now records the state signature so later --auto runs can compare" {
    make_job "bk-job" ready
    _backup_now
    [ "$BK_RC" -eq 0 ]
    [ -s "$RUNNER_DIR/last-backup.sig" ]
}

@test "backup now writes no new archive tarball while archive/ is unchanged, but always writes state" {
    echo '{"x":1}' > "$ARCHIVE_DIR/arch-job.json"
    _backup_now
    [ "$BK_RC" -eq 0 ]
    _age_backups 10800            # pretend the first pair was taken 3h ago
    local first_archive; first_archive=$(_archive_files)

    _backup_now
    [ "$BK_RC" -eq 0 ]

    [ "$(_backup_count)" -eq 2 ]
    [ "$(_archive_count)" -eq 1 ]
    [ "$(_archive_files)" = "$first_archive" ]
    # With no archive tarball written, the state path is the only stdout line.
    [[ "$BK" == "$MOTHER_BACKUP_DIR"/mother-state-*.tar.gz ]]
}

@test "backup now writes a new archive tarball when archive/ changed, even right after the last one" {
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    _backup_now
    _age_backups 10800
    echo '{"n":2}' > "$ARCHIVE_DIR/two.json"

    _backup_now
    [ "$BK_RC" -eq 0 ]

    [ "$(_archive_count)" -eq 2 ]
    local newest; newest=$(_archive_files | sort | tail -n1)
    _tar_names "$newest" | grep -qx 'archive/two.json'
}

@test "backup now writes an archive tarball again when the last one is gone or the signature is missing" {
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    _backup_now
    _age_backups 10800

    # signature missing => write
    rm -f "$RUNNER_DIR/last-backup-archive.sig"
    _backup_now
    [ "$(_archive_count)" -eq 2 ]

    # archive tarballs deleted (sig still says "unchanged") => write
    rm -f "$MOTHER_BACKUP_DIR"/mother-archive-*.tar.gz
    _backup_now
    [ "$(_archive_count)" -eq 1 ]
}

@test "backup now with no archive/ directory still succeeds and writes only a state tarball" {
    make_job "bk-job" ready
    rmdir "$ARCHIVE_DIR"

    _backup_now

    [ "$BK_RC" -eq 0 ]
    [ "$(_backup_count)" -eq 1 ]
    [ "$(_archive_count)" -eq 0 ]
}

# ===========================================================================
# backup now --auto: skip when nothing changed
# ===========================================================================

@test "--auto with no prior backup writes a state tarball, an archive tarball and the signature" {
    make_job "bk-job" ready
    echo '{"x":1}' > "$ARCHIVE_DIR/arch-job.json"

    _auto

    [ "$AUTO_RC" -eq 0 ]
    [ "$(_backup_count)" -eq 1 ]
    [ "$(_archive_count)" -eq 1 ]
    [ -s "$RUNNER_DIR/last-backup.sig" ]
    [[ "$(printf '%s\n' "$AUTO_OUT" | tail -n1)" == "$MOTHER_BACKUP_DIR"/mother-state-*.tar.gz ]]
}

@test "--auto on an unchanged tree skips: one stdout line, exit 0, no new file, signature untouched" {
    make_job "bk-job" ready
    echo '{"x":1}' > "$ARCHIVE_DIR/arch-job.json"
    _backup_now
    local before_sum; before_sum=$(_sig_sum)
    local before_files; before_files=$(ls "$MOTHER_BACKUP_DIR")

    _auto

    [ "$AUTO_RC" -eq 0 ]
    [ "$AUTO_OUT" = "unchanged, skipped" ]
    [ "$(ls "$MOTHER_BACKUP_DIR")" = "$before_files" ]
    [ "$(_sig_sum)" = "$before_sum" ]
}

@test "--auto taken twice in a row only writes the first time" {
    make_job "bk-job" ready

    _auto
    [ "$(_backup_count)" -eq 1 ]
    _auto

    [ "$AUTO_RC" -eq 0 ]
    [ "$AUTO_OUT" = "unchanged, skipped" ]
    [ "$(_backup_count)" -eq 1 ]
}

@test "--auto writes a state tarball after a job file is added or edited" {
    make_job "bk-job" ready
    _auto
    [ "$(_backup_count)" -eq 1 ]

    make_job "second-job" ready
    _auto
    [ "$(_backup_count)" -eq 2 ]

    echo '{"id":"bk-job","padding":"changes the size"}' > "$JOBS_DIR/bk-job.json"
    _auto
    [ "$(_backup_count)" -eq 3 ]
}

@test "--auto writes a state tarball after events, drafts, metrics or config.env change" {
    make_job "bk-job" ready
    echo '{}' > "$EVENTS_DIR/e.jsonl"
    echo d > "$DRAFTS_DIR/draft.md"
    mkdir -p "$MOTHER_ROOT/metrics"; echo '{}' > "$MOTHER_ROOT/metrics/runs.jsonl"
    echo 'MOTHER_CONCURRENCY=2' > "$MOTHER_ROOT/config.env"
    _auto
    [ "$(_backup_count)" -eq 1 ]

    echo '{"more":1}' >> "$EVENTS_DIR/e.jsonl"
    _auto; [ "$(_backup_count)" -eq 2 ]

    echo 'more' >> "$DRAFTS_DIR/draft.md"
    _auto; [ "$(_backup_count)" -eq 3 ]

    echo '{"more":1}' >> "$MOTHER_ROOT/metrics/runs.jsonl"
    _auto; [ "$(_backup_count)" -eq 4 ]

    echo 'MOTHER_CONCURRENCY=3' >> "$MOTHER_ROOT/config.env"
    _auto; [ "$(_backup_count)" -eq 5 ]
}

@test "--auto ignores cursor churn: rewriting cursors with new mtimes and the same size is not a change" {
    make_job "bk-job" ready
    echo 'aaaa' > "$CURSORS_DIR/c1.json"
    echo 'bbbb' > "$CURSORS_DIR/c2.json"
    _auto
    [ "$(_backup_count)" -eq 1 ]

    # Same file count, same total size, different mtimes and content.
    echo 'cccc' > "$CURSORS_DIR/c1.json"
    echo 'dddd' > "$CURSORS_DIR/c2.json"
    touch -t 202001010000 "$CURSORS_DIR/c1.json"
    touch -t 202101010000 "$CURSORS_DIR/c2.json"
    _auto

    [ "$AUTO_OUT" = "unchanged, skipped" ]
    [ "$(_backup_count)" -eq 1 ]
}

@test "--auto treats a new cursor file as a change" {
    make_job "bk-job" ready
    echo 'aaaa' > "$CURSORS_DIR/c1.json"
    _auto
    [ "$(_backup_count)" -eq 1 ]

    echo 'bbbb' > "$CURSORS_DIR/c2.json"
    _auto

    [ "$(_backup_count)" -eq 2 ]
}

@test "--auto ignores attention.json and rate-limits.json, which the daemon rewrites constantly" {
    make_job "bk-job" ready
    echo '[]' > "$MOTHER_ROOT/attention.json"
    echo '{}' > "$MOTHER_ROOT/rate-limits.json"
    _auto
    [ "$(_backup_count)" -eq 1 ]

    echo '[{"kind":"low_disk","reason":"a much longer attention payload"}]' > "$MOTHER_ROOT/attention.json"
    echo '{"five_hour":{"used_pct":42}}' > "$MOTHER_ROOT/rate-limits.json"
    _auto

    [ "$AUTO_OUT" = "unchanged, skipped" ]
    [ "$(_backup_count)" -eq 1 ]
}

@test "backups still contain attention.json and rate-limits.json even though they are not fingerprinted" {
    echo '[]' > "$MOTHER_ROOT/attention.json"
    echo '{}' > "$MOTHER_ROOT/rate-limits.json"

    _auto

    _tar_names "$(_backup_files)" | grep -qx 'attention.json'
    _tar_names "$(_backup_files)" | grep -qx 'rate-limits.json'
}

@test "--auto does not write a state tarball for an archive-only change" {
    make_job "bk-job" ready
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    _auto
    _age_backups 10800
    echo '{"n":2}' > "$ARCHIVE_DIR/two.json"

    MOTHER_BACKUP_ARCHIVE_INTERVAL=0 _auto

    [ "$(_backup_count)" -eq 1 ]
    # ...but with the archive interval satisfied the archive itself is backed up.
    [ "$(_archive_count)" -eq 2 ]
    _tar_names "$(_archive_files | sort | tail -n1)" | grep -qx 'archive/two.json'
}

@test "--auto holds off a changed archive until MOTHER_BACKUP_ARCHIVE_INTERVAL has passed since the last archive tarball" {
    make_job "bk-job" ready
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    _auto
    _age_backups 10800            # archive tarball is 3h old; default interval is 24h
    local before; before=$(_archive_files)
    echo '{"n":2}' > "$ARCHIVE_DIR/two.json"

    _auto

    [ "$(_archive_files)" = "$before" ]

    # Once the last archive tarball is older than the interval, it is written.
    _age_backups 172800 archive   # 2 days
    _auto

    local newest; newest=$(_archive_files | sort | tail -n1)
    _tar_names "$newest" | grep -qx 'archive/two.json'
}

@test "--auto writes anyway when the newest state tarball is older than the default 6h max age" {
    make_job "bk-job" ready
    _backup_now
    _age_backups 25200            # 7h ago

    _auto

    [ "$AUTO_RC" -eq 0 ]
    [ "$AUTO_OUT" != "unchanged, skipped" ]
    [ "$(_backup_count)" -eq 2 ]
}

@test "--auto still skips when the newest state tarball is younger than the default 6h max age" {
    make_job "bk-job" ready
    _backup_now
    _age_backups 18000            # 5h ago

    _auto

    [ "$AUTO_OUT" = "unchanged, skipped" ]
    [ "$(_backup_count)" -eq 1 ]
}

@test "MOTHER_BACKUP_MAX_AGE sets how stale an unchanged backup may get before --auto rewrites it" {
    make_job "bk-job" ready
    _backup_now
    _age_backups 600              # 10 min ago
    export MOTHER_BACKUP_MAX_AGE=300

    _auto

    [ "$(_backup_count)" -eq 2 ]
}

@test "MOTHER_BACKUP_MAX_AGE=0 means --auto never skips" {
    make_job "bk-job" ready
    _backup_now
    export MOTHER_BACKUP_MAX_AGE=0

    _auto

    [ "$AUTO_RC" -eq 0 ]
    [ "$AUTO_OUT" != "unchanged, skipped" ]
    [ "$(_backup_count)" -eq 2 ]
}

@test "--auto honours MOTHER_BACKUP_NOW_EPOCH when judging the age of the newest backup" {
    make_job "bk-job" ready
    _backup_now
    export MOTHER_BACKUP_NOW_EPOCH=$(( $(date +%s) + 7 * 3600 ))

    _auto

    [ "$(_backup_count)" -eq 2 ]
}

@test "--auto writes when no state tarball is left in the dir, even though the signature matches" {
    make_job "bk-job" ready
    _backup_now
    rm -f "$MOTHER_BACKUP_DIR"/mother-state-*.tar.gz

    _auto

    [ "$(_backup_count)" -eq 1 ]
}

@test "--auto writes when the signature file is missing" {
    make_job "bk-job" ready
    _backup_now
    rm -f "$RUNNER_DIR/last-backup.sig"

    _auto

    [ "$(_backup_count)" -eq 2 ]
    [ -s "$RUNNER_DIR/last-backup.sig" ]
}

@test "--auto still refuses a backup directory inside MOTHER_ROOT" {
    export MOTHER_BACKUP_DIR="$MOTHER_ROOT/backups-inside"

    run mother backup now --auto

    [ "$status" -ne 0 ]
    [[ "$output" == *"inside"* ]]
    [ -z "$(find "$MOTHER_ROOT" -name 'mother-*.tar.gz' 2>/dev/null)" ]
}

# ===========================================================================
# retention: new defaults, newest is never pruned, archive backups
# ===========================================================================

@test "retention defaults to 12 hours of everything: older same-day backups collapse to the day's newest" {
    # Clock 2026-06-15T12:00Z. Both candidates are 13h-16h old (past 12h, inside
    # the old 24h default) and fall on the same UTC day.
    _fake_stamp 20260614T230000Z
    _fake_stamp 20260614T200000Z
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)

    _backup_now
    [ "$BK_RC" -eq 0 ]

    _exists 20260614T230000Z
    ! _exists 20260614T200000Z
}

@test "retention defaults to 14 days of daily backups" {
    _fake_stamp 20260603T120000Z   # 12d: kept
    _fake_stamp 20260525T120000Z   # 21d: gone (was kept under the old 30d default)
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)

    _backup_now
    [ "$BK_RC" -eq 0 ]

    _exists 20260603T120000Z
    ! _exists 20260525T120000Z
}

@test "KEEP_HOURS=0 KEEP_DAYS=0 still leaves the newest state and archive backups" {
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    _fake_stamp 20260615T100000Z
    _fake_stamp 20260615T090000Z
    _fake_archive_stamp 20260615T080000Z
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)
    export MOTHER_BACKUP_KEEP_HOURS=0 MOTHER_BACKUP_KEEP_DAYS=0

    _backup_now
    [ "$BK_RC" -eq 0 ]

    # The fresh pair written by this run is the newest of each kind and survives.
    [ -s "$BK" ]
    [ "$(_backup_count)" -eq 1 ]
    [ "$(_archive_count)" -eq 1 ]
    ! _exists 20260615T100000Z
    ! _a_exists 20260615T080000Z
}

@test "an ancient newest state and archive backup survive pruning on an unchanged --auto run" {
    make_job "bk-job" ready
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    _backup_now
    local f
    for f in state archive; do
        mv "$MOTHER_BACKUP_DIR"/mother-$f-*.tar.gz "$MOTHER_BACKUP_DIR/mother-$f-20200101T000000Z.tar.gz"
    done
    _fake_stamp 20190101T000000Z
    _fake_archive_stamp 20190101T000000Z
    export MOTHER_BACKUP_MAX_AGE=999999999999   # never "too old to skip"

    _auto

    [ "$AUTO_OUT" = "unchanged, skipped" ]
    _exists 20200101T000000Z
    _a_exists 20200101T000000Z
    ! _exists 20190101T000000Z
    ! _a_exists 20190101T000000Z
}

@test "prune also runs when --auto skips: old backups are removed" {
    make_job "bk-job" ready
    _backup_now
    _age_backups 10800
    _fake_stamp 20200101T000000Z
    _fake_stamp 20200102T000000Z
    _fake_archive_stamp 20200101T000000Z

    _auto

    [ "$AUTO_OUT" = "unchanged, skipped" ]
    ! _exists 20200101T000000Z
    ! _exists 20200102T000000Z
    ! _a_exists 20200101T000000Z
    [ "$(_backup_count)" -eq 1 ]
    [ "$(_archive_count)" -eq 1 ]
}

@test "archive retention keeps the newest archive plus, for each kept state backup, the newest archive at or before it" {
    # Clock 2026-06-15T12:00Z. Kept states: 06-15 10:00, 06-14 13:00, 06-13 20:00.
    _fake_stamp 20260615T100000Z
    _fake_stamp 20260614T130000Z
    _fake_stamp 20260613T200000Z
    _fake_archive_stamp 20260615T090000Z   # newest <= state 06-15 10:00  -> keep
    _fake_archive_stamp 20260614T120000Z   # newest <= state 06-14 13:00  -> keep
    _fake_archive_stamp 20260614T060000Z   # shadowed by the one above    -> prune
    _fake_archive_stamp 20260613T100000Z   # newest <= state 06-13 20:00  -> keep
    _fake_archive_stamp 20260612T100000Z   # shadowed                     -> prune
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)

    _backup_now
    [ "$BK_RC" -eq 0 ]

    _a_exists 20260615T090000Z
    _a_exists 20260614T120000Z
    _a_exists 20260613T100000Z
    ! _a_exists 20260614T060000Z
    ! _a_exists 20260612T100000Z
    # the archive written by this run (newest overall) is kept too
    [ "$(_archive_count)" -eq 4 ]
}

@test "archive retention falls back to the oldest newer archive when none is old enough for a kept state backup" {
    _fake_stamp 20260610T120000Z           # kept (only backup of its day, 5d old)
    _fake_archive_stamp 20260611T000000Z   # oldest archive newer than that state -> keep
    _fake_archive_stamp 20260613T000000Z   # not needed by anything               -> prune
    echo '{"n":1}' > "$ARCHIVE_DIR/one.json"
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)

    _backup_now
    [ "$BK_RC" -eq 0 ]

    _exists 20260610T120000Z
    _a_exists 20260611T000000Z
    ! _a_exists 20260613T000000Z
}

@test "retention never touches names that merely look like archive backups" {
    _seed_retention_fixtures
    echo keep > "$MOTHER_BACKUP_DIR/mother-archive-20200101T000000Z.tar.gz.bak"
    echo keep > "$MOTHER_BACKUP_DIR/mother-archive-20200101T000000Z.tgz"
    echo keep > "$MOTHER_BACKUP_DIR/other-archive-20200101T000000Z.tar.gz"
    mkdir "$MOTHER_BACKUP_DIR/mother-archive-dir"

    _backup_now
    [ "$BK_RC" -eq 0 ]

    [ -f "$MOTHER_BACKUP_DIR/mother-archive-20200101T000000Z.tar.gz.bak" ]
    [ -f "$MOTHER_BACKUP_DIR/mother-archive-20200101T000000Z.tgz" ]
    [ -f "$MOTHER_BACKUP_DIR/other-archive-20200101T000000Z.tar.gz" ]
    [ -d "$MOTHER_BACKUP_DIR/mother-archive-dir" ]
}

# ===========================================================================
# runner tick: defaults and the skip path
# ===========================================================================

@test "the runner's default backup interval is an hour: a 30 minute old marker does not fire" {
    echo "$(( $(date +%s) - 1800 ))" > "$RUNNER_DIR/last-backup.ts"

    run _tick

    [ "$status" -eq 0 ]
    [ "$(_backup_count)" -eq 0 ]
}

@test "the runner's default backup interval is an hour: a marker older than that fires" {
    echo "$(( $(date +%s) - 4000 ))" > "$RUNNER_DIR/last-backup.ts"

    run _tick

    [ "$status" -eq 0 ]
    [ "$(_backup_count)" -eq 1 ]
}

@test "a runner tick on an unchanged tree writes nothing and logs 'backup: unchanged, skipped'" {
    make_job "tick-job" ready
    export MOTHER_BACKUP_INTERVAL=0

    run _tick
    [ "$status" -eq 0 ]
    [ "$(_backup_count)" -eq 1 ]
    [[ "$output" != *"unchanged, skipped"* ]]
    local before; before=$(ls "$MOTHER_BACKUP_DIR")

    run _tick

    [ "$status" -eq 0 ]
    [[ "$output" == *"backup: unchanged, skipped"* ]]
    [ "$(ls "$MOTHER_BACKUP_DIR")" = "$before" ]
}

@test "a runner tick after a job changed writes a fresh state tarball" {
    make_job "tick-job" ready
    export MOTHER_BACKUP_INTERVAL=0
    run _tick
    [ "$(_backup_count)" -eq 1 ]

    make_job "another-job" ready
    run _tick

    [ "$status" -eq 0 ]
    [ "$(_backup_count)" -eq 2 ]
    [[ "$output" != *"unchanged, skipped"* ]]
}

# ===========================================================================
# restore with the split layout
# ===========================================================================

@test "restoring a legacy backup (archive/ inside the state tarball) restores as before and ignores archive tarballs" {
    make_job "live" ready
    echo '{"v":"live"}' > "$ARCHIVE_DIR/cur.json"
    _fake_backup_with_jobs mother-state-20260102T000000Z.tar.gz 2
    _fake_tarball mother-archive-20260101T000000Z.tar.gz archive/other.json '{"v":"other"}'

    run mother backup restore "$MOTHER_BACKUP_DIR/mother-state-20260102T000000Z.tar.gz" --yes </dev/null

    [ "$status" -eq 0 ]
    [ -f "$ARCHIVE_DIR/old.json" ]            # from the legacy tarball
    [ ! -e "$ARCHIVE_DIR/other.json" ]        # NOT combined with the archive tarball
    [ ! -e "$ARCHIVE_DIR/cur.json" ]
    [[ "$output" != *"mother-archive-"* ]]
    [ -f "$JOBS_DIR/j1.json" ]
}

@test "restoring a state tarball without archive/ also restores the newest archive backup at or before it" {
    make_job "live" ready
    echo '{"v":"current"}' > "$ARCHIVE_DIR/cur.json"
    _fake_tarball mother-state-20260102T000000Z.tar.gz jobs/restored.json '{"id":"restored"}'
    _fake_tarball mother-archive-20251201T000000Z.tar.gz archive/a1.json '{"v":"oldest"}'
    _fake_tarball mother-archive-20260101T000000Z.tar.gz archive/a1.json '{"v":"match"}'
    _fake_tarball mother-archive-20260103T000000Z.tar.gz archive/a1.json '{"v":"newer"}'

    run mother backup restore "$MOTHER_BACKUP_DIR/mother-state-20260102T000000Z.tar.gz" --yes </dev/null

    [ "$status" -eq 0 ]
    [ -f "$JOBS_DIR/restored.json" ]
    [ ! -e "$JOBS_DIR/live.json" ]
    [ "$(jq -r .v "$ARCHIVE_DIR/a1.json")" = "match" ]
    [ ! -e "$ARCHIVE_DIR/cur.json" ]
    [[ "$output" == *"mother-archive-20260101T000000Z"* ]]
    # The replaced archive/ is kept aside with the rest of the previous state.
    local pre; pre=$(_pre_restore_dirs | head -n1)
    [ -n "$pre" ]
    [ -f "$pre/archive/cur.json" ]
    [ -f "$pre/jobs/live.json" ]
}

@test "restore uses the oldest newer archive backup when none is as old as the state backup" {
    _fake_tarball mother-state-20260102T000000Z.tar.gz jobs/restored.json '{"id":"restored"}'
    _fake_tarball mother-archive-20260110T000000Z.tar.gz archive/a1.json '{"v":"later"}'
    _fake_tarball mother-archive-20260105T000000Z.tar.gz archive/a1.json '{"v":"closest"}'

    run mother backup restore "$MOTHER_BACKUP_DIR/mother-state-20260102T000000Z.tar.gz" --yes </dev/null

    [ "$status" -eq 0 ]
    [ "$(jq -r .v "$ARCHIVE_DIR/a1.json")" = "closest" ]
    [[ "$output" == *"mother-archive-20260105T000000Z"* ]]
}

@test "restore with no archive backup at all restores state only, keeps the current archive/ in place and says so" {
    make_job "live" ready
    echo '{"v":"current"}' > "$ARCHIVE_DIR/cur.json"
    _fake_tarball mother-state-20260102T000000Z.tar.gz jobs/restored.json '{"id":"restored"}'

    run mother backup restore "$MOTHER_BACKUP_DIR/mother-state-20260102T000000Z.tar.gz" --yes </dev/null

    [ "$status" -eq 0 ]
    [ -f "$JOBS_DIR/restored.json" ]
    [ -f "$ARCHIVE_DIR/cur.json" ]
    [[ "$output" == *"no archive backup"* ]]
    local pre; pre=$(_pre_restore_dirs | head -n1)
    [ -n "$pre" ]
    [ ! -e "$pre/archive" ]
}

@test "restoring an archive tarball directly restores only archive/" {
    make_job "live" ready
    echo '{"v":"current"}' > "$ARCHIVE_DIR/cur.json"
    _fake_tarball mother-archive-20260101T000000Z.tar.gz archive/a1.json '{"v":"restored"}'

    run mother backup restore "$MOTHER_BACKUP_DIR/mother-archive-20260101T000000Z.tar.gz" --yes </dev/null

    [ "$status" -eq 0 ]
    [ "$(jq -r .v "$ARCHIVE_DIR/a1.json")" = "restored" ]
    [ ! -e "$ARCHIVE_DIR/cur.json" ]
    [ -f "$JOBS_DIR/live.json" ]              # state untouched
    local pre; pre=$(_pre_restore_dirs | head -n1)
    [ -f "$pre/archive/cur.json" ]
    [ ! -e "$pre/jobs" ]
}

@test "round trip: backup now then restore by name brings back both jobs and archived jobs" {
    make_job "orig" ready
    echo '{"kind":"old"}' > "$ARCHIVE_DIR/arch.json"
    _backup_now
    [ "$BK_RC" -eq 0 ]

    rm -f "$JOBS_DIR/orig.json"
    make_job "later" ready
    echo '{"kind":"new"}' > "$ARCHIVE_DIR/arch.json"
    echo '{"kind":"extra"}' > "$ARCHIVE_DIR/extra.json"

    run mother backup restore "$(basename "$BK")" --yes </dev/null

    [ "$status" -eq 0 ]
    [ "$(jq -r .id "$JOBS_DIR/orig.json")" = "orig" ]
    [ ! -e "$JOBS_DIR/later.json" ]
    [ "$(jq -r .kind "$ARCHIVE_DIR/arch.json")" = "old" ]
    [ ! -e "$ARCHIVE_DIR/extra.json" ]
    [[ "$output" == *"mother-archive-"* ]]
    local pre; pre=$(_pre_restore_dirs | head -n1)
    [ "$(jq -r .kind "$pre/archive/arch.json")" = "new" ]
    [ -f "$pre/jobs/later.json" ]
}

@test "restore refuses when the matching archive tarball is corrupt and leaves the current state untouched" {
    make_job "live" ready
    echo '{"v":"current"}' > "$ARCHIVE_DIR/cur.json"
    _fake_tarball mother-state-20260102T000000Z.tar.gz jobs/restored.json '{"id":"restored"}'
    echo "this is not a tarball" > "$MOTHER_BACKUP_DIR/mother-archive-20260101T000000Z.tar.gz"

    run mother backup restore "$MOTHER_BACKUP_DIR/mother-state-20260102T000000Z.tar.gz" --yes </dev/null

    [ "$status" -ne 0 ]
    [ -f "$JOBS_DIR/live.json" ]
    [ ! -e "$JOBS_DIR/restored.json" ]
    [ -f "$ARCHIVE_DIR/cur.json" ]
    [ -z "$(_pre_restore_dirs)" ]
}

# ===========================================================================
# backup list and the size summary
# ===========================================================================

# Fixed clock for the summary tests: 2026-06-15T12:00:00Z.
#   state   20260615T110000Z  1 MiB   (1h ago)
#   archive 20260615T100000Z  1 MiB   (2h ago)
#   state   20260612T120000Z  3 MiB   (3d ago)  -> total 5 MiB, 2 MiB in last 24h
_seed_summary_fixtures() {
    mkdir -p "$MOTHER_BACKUP_DIR"
    head -c 1048576 /dev/zero > "$MOTHER_BACKUP_DIR/mother-state-20260615T110000Z.tar.gz"
    head -c 1048576 /dev/zero > "$MOTHER_BACKUP_DIR/mother-archive-20260615T100000Z.tar.gz"
    head -c 3145728 /dev/zero > "$MOTHER_BACKUP_DIR/mother-state-20260612T120000Z.tar.gz"
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)
}

@test "backup list shows state backups first, then archive backups marked kind=archive, then a summary" {
    _fake_backup_with_jobs mother-state-20260101T000000Z.tar.gz 2
    _fake_backup_with_jobs mother-state-20260102T000000Z.tar.gz 3
    _fake_tarball mother-archive-20260101T000000Z.tar.gz archive/a.json '{}'
    _fake_tarball mother-archive-20260103T000000Z.tar.gz archive/b.json '{}'

    run mother backup list

    [ "$status" -eq 0 ]
    local last_state first_archive a_new a_old
    last_state=$(grep -n 'mother-state-' <<<"$output" | tail -n1 | cut -d: -f1)
    first_archive=$(grep -n 'mother-archive-' <<<"$output" | head -n1 | cut -d: -f1)
    [ "$last_state" -lt "$first_archive" ]
    [ "$(grep -c 'mother-archive-' <<<"$output")" -eq 2 ]
    a_new=$(grep -n 'mother-archive-20260103' <<<"$output" | cut -d: -f1)
    a_old=$(grep -n 'mother-archive-20260101' <<<"$output" | cut -d: -f1)
    [ "$a_new" -lt "$a_old" ]
    local line
    while IFS= read -r line; do
        [[ "$line" == *"kind=archive"* ]]
        [[ "$line" != *"jobs="* ]]
        [[ "$line" =~ [0-9]+(\.[0-9]+)?[[:space:]]?(B|K|KB|KiB|M|MB|MiB|G|GB) ]]
    done < <(grep 'mother-archive-' <<<"$output")
    grep -q 'jobs=3' <<<"$(grep 'mother-state-20260102' <<<"$output")"
    # summary line at the end
    [[ "$(tail -n1 <<<"$output")" == backups:*"4 files"* ]]
}

@test "backup list --summary prints only the summary: count, total, newest age and bytes written in the last 24h" {
    _seed_summary_fixtures

    run mother backup list --summary

    [ "$status" -eq 0 ]
    [[ "$output" != *"mother-state-"* ]]
    [[ "$output" != *"mother-archive-"* ]]
    [[ "$output" == backups:* ]]
    [[ "$output" == *"3 files"* ]]
    [[ "$output" =~ 5(\.0)?[[:space:]]?MB[[:space:]]total ]]
    [[ "$output" == *"newest"*"ago"* ]]
    [[ "$output" =~ 2(\.0)?[[:space:]]?MB[[:space:]]written[[:space:]]in[[:space:]]the[[:space:]]last[[:space:]]24h ]]
    [[ "$output" != *"warn:"* ]]
}

@test "backup list --summary on an empty directory says there are no backups" {
    mkdir -p "$MOTHER_BACKUP_DIR"

    run mother backup list --summary

    [ "$status" -eq 0 ]
    [[ "$output" =~ [Nn]o[[:space:]]+backups ]]
}

@test "backup list --summary warns, naming the knobs to turn, when the total exceeds MOTHER_BACKUP_WARN_GB" {
    mkdir -p "$MOTHER_BACKUP_DIR"
    # 2 GiB, sparse (no disk is actually used).
    dd if=/dev/null of="$MOTHER_BACKUP_DIR/mother-state-20260615T110000Z.tar.gz" bs=1 count=0 seek=2147483648 2>/dev/null
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)
    export MOTHER_BACKUP_WARN_GB=1

    run mother backup list --summary

    [ "$status" -eq 0 ]
    local warn; warn=$(grep '^warn:' <<<"$output")
    [ -n "$warn" ]
    [[ "$warn" == *"MOTHER_BACKUP_KEEP_HOURS"* ]]
    [[ "$warn" == *"MOTHER_BACKUP_INTERVAL"* ]]
    [[ "$warn" == *"MOTHER_BACKUP_KEEP_DAYS"* ]]
}

@test "backup list --summary does not warn while the total is under the threshold (default 5 GB)" {
    _seed_summary_fixtures

    run mother backup list --summary
    [ "$status" -eq 0 ]
    [[ "$output" != *"warn:"* ]]

    export MOTHER_BACKUP_WARN_GB=1
    run mother backup list --summary
    [ "$status" -eq 0 ]
    [[ "$output" != *"warn:"* ]]
}

@test "MOTHER_BACKUP_WARN_GB=0 warns for any non-empty total" {
    _seed_summary_fixtures
    export MOTHER_BACKUP_WARN_GB=0

    run mother backup list --summary

    [ "$status" -eq 0 ]
    [[ "$output" == *"warn:"* ]]
}

@test "backup list ends with the same summary line, warn included" {
    _seed_summary_fixtures
    export MOTHER_BACKUP_WARN_GB=0

    run mother backup list

    [ "$status" -eq 0 ]
    [[ "$output" == *"backups: 3 files"* ]]
    [[ "$output" == *"warn:"* ]]
}

@test "mother doctor's backups section includes the summary" {
    _seed_summary_fixtures

    # Exit status is deliberately not asserted: doctor fails without tmux/claude.
    run bash "$MOTHER_PLUGIN_DIR/scripts/doctor.sh"

    [[ "$output" == *"backups: 3 files"* ]]
    [[ "$output" =~ 5(\.0)?[[:space:]]?MB[[:space:]]total ]]
    [[ "$output" == *"last 24h"* ]]
    [[ "$output" != *"warn:"* ]]
}

@test "mother doctor's backups section carries the warning when the backups are too big" {
    _seed_summary_fixtures
    export MOTHER_BACKUP_WARN_GB=0

    run bash "$MOTHER_PLUGIN_DIR/scripts/doctor.sh"

    [[ "$output" == *"backups: 3 files"* ]]
    [[ "$output" == *"warn:"*"MOTHER_BACKUP_KEEP_HOURS"* ]]
}

# ===========================================================================
# help: new knobs and defaults
# ===========================================================================

@test "mother help documents backup now --auto, MAX_AGE, WARN_GB and the new defaults" {
    run mother help
    [ "$status" -eq 0 ]
    [[ "$output" == *"backup now --auto"* ]]
    [[ "$output" == *"MOTHER_BACKUP_MAX_AGE"* ]]
    [[ "$output" == *"MOTHER_BACKUP_WARN_GB"* ]]
    grep -E 'MOTHER_BACKUP_INTERVAL.*\(default: 3600\)' <<<"$output"
    grep -E 'MOTHER_BACKUP_KEEP_HOURS.*\(default: 12\)' <<<"$output"
    grep -E 'MOTHER_BACKUP_KEEP_DAYS.*\(default: 14\)' <<<"$output"
}

# ===========================================================================
# PR #107 review fix-ups
# ===========================================================================

@test "restore prints a note (not an error) when the paired archive backup is over 1h older than the state backup" {
    _fake_tarball mother-state-20260615T110000Z.tar.gz jobs/a.json '{}'
    _fake_tarball mother-archive-20260615T090000Z.tar.gz archive/o.json '{}'

    run mother backup restore mother-state-20260615T110000Z.tar.gz --yes </dev/null

    [ "$status" -eq 0 ]
    [[ "$output" == *"note:"*"20260615T090000Z"*"20260615T110000Z"*"not in this restore"* ]]
}

@test "restore prints no archive-gap note when the archive backup is within 1h of the state backup" {
    _fake_tarball mother-state-20260615T110000Z.tar.gz jobs/a.json '{}'
    _fake_tarball mother-archive-20260615T103000Z.tar.gz archive/o.json '{}'

    run mother backup restore mother-state-20260615T110000Z.tar.gz --yes </dev/null

    [ "$status" -eq 0 ]
    [[ "$output" != *"not in this restore"* ]]
}

@test "backup list --summary shows the age of the newest archive backup" {
    _seed_summary_fixtures

    run mother backup list --summary

    [[ "$output" =~ newest[[:space:]]archive[[:space:]]backup[[:space:]]2h[[:space:]]ago ]]
}

@test "backup list --summary reports bytes written from the write log even after prune removed the files" {
    mkdir -p "$MOTHER_BACKUP_DIR"
    head -c 1048576 /dev/zero > "$MOTHER_BACKUP_DIR/mother-state-20260615T110000Z.tar.gz"
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)
    local i
    for i in $(seq 1 24); do
        echo "$((MOTHER_BACKUP_NOW_EPOCH - i * 3500)) state 1048576 mother-state-x$i.tar.gz"
    done > "$MOTHER_ROOT/backups-written.log"

    run mother backup list --summary

    [[ "$output" =~ 24(\.0)?[[:space:]]?MB[[:space:]]written[[:space:]]in[[:space:]]the[[:space:]]last[[:space:]]24h ]]
    [[ "$output" != *"estimated"* ]]
}

@test "backup list --summary falls back to the on-disk figure, labelled estimated, when there is no write log" {
    _seed_summary_fixtures

    run mother backup list --summary

    [[ "$output" =~ 2(\.0)?[[:space:]]?MB[[:space:]]written[[:space:]]in[[:space:]]the[[:space:]]last[[:space:]]24h.*estimated ]]
}

@test "backup now appends to the write log and trims entries older than 7 days" {
    mkdir -p "$MOTHER_ROOT/jobs"; echo '{}' > "$MOTHER_ROOT/jobs/a.json"
    echo "$(( $(date +%s) - 8 * 86400 )) state 100 mother-state-old.tar.gz" > "$MOTHER_ROOT/backups-written.log"

    _backup_now
    [ "$BK_RC" -eq 0 ]

    run cat "$MOTHER_ROOT/backups-written.log"
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" -eq 1 ]
    [[ "$output" == *" state "*"$(basename "$BK")" ]]
    [[ "$output" != *"mother-state-old"* ]]
}

@test "MOTHER_BACKUP_WARN_GB='.' is invalid and falls back to the default 5 GB" {
    _seed_summary_fixtures
    export MOTHER_BACKUP_WARN_GB=.

    run mother backup list --summary

    [[ "$output" != *"warn:"* ]]
}

@test "prune removes stale orphaned hidden temp files, and only those" {
    mkdir -p "$MOTHER_BACKUP_DIR"
    _fake_stamp 20260615T110000Z
    export MOTHER_BACKUP_NOW_EPOCH
    MOTHER_BACKUP_NOW_EPOCH=$(_epoch 2026-06-15T12:00:00Z)
    local d="$MOTHER_BACKUP_DIR"
    echo x > "$d/.mother-state-20260615T100000Z.tmp.999999"      # stale, dead pid
    echo x > "$d/.mother-archive-20260615T100000Z.tmp.999998"    # stale, dead pid
    echo x > "$d/.mother-state-20260615T100000Z.tmp.$$"          # stale, live pid
    echo x > "$d/.mother-state-20260615T110000Z.tmp.999997"      # recent, dead pid
    echo x > "$d/.mother-other.tmp.999996"                       # wrong pattern
    echo x > "$d/.mother-state-20260615T100000Z.tmp.999995.bak"  # wrong pattern
    touch -t 202001010000 "$d/.mother-state-20260615T100000Z.tmp.999999" \
        "$d/.mother-archive-20260615T100000Z.tmp.999998" "$d/.mother-state-20260615T100000Z.tmp.$$" \
        "$d/.mother-other.tmp.999996" "$d/.mother-state-20260615T100000Z.tmp.999995.bak"

    mother backup now >/dev/null 2>&1 || true

    [ ! -e "$d/.mother-state-20260615T100000Z.tmp.999999" ]
    [ ! -e "$d/.mother-archive-20260615T100000Z.tmp.999998" ]
    [ -e "$d/.mother-state-20260615T100000Z.tmp.$$" ]
    [ -e "$d/.mother-state-20260615T110000Z.tmp.999997" ]
    [ -e "$d/.mother-other.tmp.999996" ]
    [ -e "$d/.mother-state-20260615T100000Z.tmp.999995.bak" ]
}
