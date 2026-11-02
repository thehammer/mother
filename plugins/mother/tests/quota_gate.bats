#!/usr/bin/env bats
# quota_gate.bats — the quota gate: Bishop-first usage feed, the three-state
# on/off/off-until-reset switch, `mother quota`, and the stale-feed attention item.
#
# Contract under test:
#   Feed      MOTHER_BISHOP_POSTURE_FILE (five_hour/seven_day .used_pct or .used_percentage,
#             .resets_at, top-level stale_input) is read first; MOTHER_RATE_LIMIT_CACHE
#             (used_percentage) is the fallback when Bishop is missing, unparseable or
#             stale_input:true. A source whose mtime is older than
#             MOTHER_QUOTA_FEED_MAX_AGE_S (1800) is not used. No fresh source => source
#             "none", stale true, and the gate lets work through.
#   Windows   an expired resets_at counts as 0%. Caps default to 90 per window
#             (MOTHER_QUOTA_CAP_5H_PCT / MOTHER_QUOTA_CAP_7D_PCT); at-or-over blocks.
#   Switch    $MOTHER_ROOT/quota-gate.json {state, changed_at, changed_by, until};
#             missing/corrupt => on. off passes at 100%. off_until_reset passes before
#             `until`, then flips to on (audit line, changed_by auto:reset).
#   CLI       mother quota status [--json] | on | off | off-until-reset [--source S]
#             --source is `cli` (default) or `broker:<token>` ([A-Za-z0-9._-]{1,64}); anything else
#             is rejected. on/off/off-until-reset are refused (and logged to
#             quota-gate-refusals.jsonl) when MOTHER_JOB_ID is set, even empty, or when any ancestor
#             process is a `mother-run-job`. off-until-reset needs a known window reset within
#             7 days + 1h and is otherwise refused with `no_reset_known`.
#   Attention quota_feed_stale is raised by mother_attention_write while the feed is stale,
#             cleared when fresh, acknowledged with `mother ack quota quota_feed_stale`.
#
# Every test points MOTHER_BISHOP_POSTURE_FILE under its temp MOTHER_ROOT, so the
# operator's real ~/.claude/budget-posture.json is never read.

load 'test_helper'

FIXTURE="$BATS_TEST_DIRNAME/fixtures/quota_block.json"

# Fixed future instants, one in US daylight time and one in standard time.
EPOCH_CDT=1814464800   # 2027-07-01 18:00:00 UTC = 1:00 PM CDT
EPOCH_CST=1827684000   # 2027-12-01 18:00:00 UTC = 12:00 PM CST

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME" "$MOTHER_ROOT/bishop"
    export MOTHER_BISHOP_POSTURE_FILE="$MOTHER_ROOT/bishop/budget-posture.json"
    export MOTHER_RATE_LIMIT_CACHE="$MOTHER_ROOT/rate-limits.json"
    unset MOTHER_JOB_ID MOTHER_QUOTA_FEED_MAX_AGE_S MOTHER_QUOTA_CAP_5H_PCT MOTHER_QUOTA_CAP_7D_PCT
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_PROGRESS_FLAGS_ATTENTION=1
    GATE_FILE="$MOTHER_ROOT/quota-gate.json"
    AUDIT_FILE="$MOTHER_ROOT/quota-gate-audit.jsonl"
}

teardown() {
    # Kill only the sleepers this test started, by exact pid.
    local p
    for p in ${_BG_PIDS:-}; do kill "$p" 2>/dev/null || true; done
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_now() { date +%s; }

# Run a shell snippet with the state libs sourced. Usage: _lib '<snippet>'
_lib() {
    bash -c "set -u; source '$_LIB_DIR/state.sh'; source '$_LIB_DIR/attention.sh'; $*"
}

# Write a Bishop-shaped file. Usage: _bishop <5h pct> <7d pct> [5h resets_at] [7d resets_at]
_bishop() {
    local r5="${3:-$(( $(_now) + 3600 ))}" r7="${4:-$(( $(_now) + 86400 ))}"
    jq -nc --argjson p5 "$1" --argjson p7 "$2" --argjson r5 "$r5" --argjson r7 "$r7" '
        {posture: "Cruise", stale_input: false,
         five_hour: {used_pct: $p5, resets_at: $r5},
         seven_day: {used_pct: $p7, resets_at: $r7}}' > "$MOTHER_BISHOP_POSTURE_FILE"
}

# Write a statusline-cache-shaped file. Usage: _cache <5h pct> <7d pct> [5h resets_at] [7d resets_at]
_cache() {
    local r5="${3:-$(( $(_now) + 3600 ))}" r7="${4:-$(( $(_now) + 86400 ))}"
    jq -nc --argjson p5 "$1" --argjson p7 "$2" --argjson r5 "$r5" --argjson r7 "$r7" '
        {five_hour: {used_percentage: $p5, resets_at: $r5},
         seven_day: {used_percentage: $p7, resets_at: $r7}}' > "$MOTHER_RATE_LIMIT_CACHE"
}

# Make <file>'s mtime <seconds> old.
_age() {
    /usr/bin/perl -e 'my $t = time - $ARGV[1]; utime($t, $t, $ARGV[0]) or die "utime: $!"' "$1" "$2"
}

# `mother quota status --json` (stdout only: the CLI logs to stderr).
_qjson() { mother quota status --json 2>/dev/null; }
_qf() { _qjson | jq -r "$1"; }

_audit_lines() { [ -f "$AUDIT_FILE" ] && grep -c . "$AUDIT_FILE" || echo 0; }

# Write a switch file by hand. Usage: _gate_file <state> [until]
_gate_file() {
    if [ -n "${2:-}" ]; then
        jq -nc --arg s "$1" --argjson u "$2" \
            '{state: $s, changed_at: "2026-11-02T00:00:00.000Z", changed_by: "cli", until: $u}' > "$GATE_FILE"
    else
        jq -nc --arg s "$1" \
            '{state: $s, changed_at: "2026-11-02T00:00:00.000Z", changed_by: "cli"}' > "$GATE_FILE"
    fi
}

# Start a long sleep and register it as <job id>'s live supervisor in the runner's children dir
# (exactly what _track_child writes). Sets LIVE_SUP_PID. Call directly, never through `run`/$().
_live_supervisor() {
    sleep 300 >/dev/null 2>&1 3>&- &
    LIVE_SUP_PID=$!
    _BG_PIDS="${_BG_PIDS:-} $LIVE_SUP_PID"
    mkdir -p "$RUNNER_DIR/children"
    jq -nc --argjson pid "$LIVE_SUP_PID" --arg j "$1" \
        '{pid: $pid, job_id: $j, started_at: "2026-11-02T00:00:00Z"}' > "$RUNNER_DIR/children/$LIVE_SUP_PID.json"
}

# A mother-run-job stand-in that only logs its argv; counts supervisors the runner starts.
_fake_run_job() {
    FAKE_BIN="$MOTHER_ROOT/fake-bin"; mkdir -p "$FAKE_BIN"
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/run-job-calls"\nexit 0\n' "$MOTHER_ROOT" > "$FAKE_BIN/mother-run-job"
    chmod +x "$FAKE_BIN/mother-run-job"
    export MOTHER_POSTURE_ENABLED=0 MOTHER_CONCURRENCY=3
}

# Fail fast (instead of letting mother-runner start a real daemon loop) when a test entry point is missing.
_need_hook() {
    grep -q -e "^    $1)" "$_BIN_DIR/mother-runner" || { echo "mother-runner has no $1 test entry point yet" >&2; return 1; }
}

# Run a command the way production does, without MOTHER_TEST_ROOT. Sourcing state.sh then drops a
# .mother-live marker into the temp MOTHER_ROOT (which would make teardown refuse to delete it), so
# remove that one file afterwards.
_run_live_mode() {
    run env -u MOTHER_TEST_ROOT "$@"
    rm -f "$MOTHER_ROOT/.mother-live"
}

_gate_items() {
    jq -c '[.[] | select(.kind == "quota_gate_off")]' "$MOTHER_ROOT/attention.json"
}

_stale_items() {
    jq -c '[.[] | select(.kind == "quota_feed_stale")]' "$MOTHER_ROOT/attention.json"
}

# ---------------------------------------------------------------------------
# Feed: Bishop first, statusline cache as fallback
# ---------------------------------------------------------------------------

@test "feed: a fresh Bishop file is the source and its per-window usage and reset times are reported" {
    local r5=$(( $(_now) + 3600 )) r7=$(( $(_now) + 86400 ))
    _bishop 23 40 "$r5" "$r7"

    [ "$(_qf .source)" = "bishop" ]
    [ "$(_qf .stale)" = "false" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "23" ]
    [ "$(_qf .windows.seven_day.used_pct)" = "40" ]
    [ "$(_qf .windows.five_hour.resets_at)" = "$r5" ]
    [ "$(_qf .windows.seven_day.resets_at)" = "$r7" ]
}

@test "feed: Bishop's used_percentage spelling is accepted as well as used_pct" {
    jq -nc --argjson r "$(( $(_now) + 3600 ))" \
        '{five_hour: {used_percentage: 61, resets_at: $r}, seven_day: {used_percentage: 12, resets_at: $r}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"

    [ "$(_qf .source)" = "bishop" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "61" ]
    [ "$(_qf .windows.seven_day.used_pct)" = "12" ]
}

@test "feed: Bishop wins over a fresh statusline cache" {
    _bishop 10 20
    _cache 80 85

    [ "$(_qf .source)" = "bishop" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "10" ]
    [ "$(_qf .windows.seven_day.used_pct)" = "20" ]
}

@test "feed: a missing Bishop file falls back to the statusline cache" {
    _cache 33 44

    [ "$(_qf .source)" = "cache" ]
    [ "$(_qf .stale)" = "false" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "33" ]
    [ "$(_qf .windows.seven_day.used_pct)" = "44" ]
}

@test "feed: an unparseable Bishop file falls back to the statusline cache" {
    printf '{ this is not json' > "$MOTHER_BISHOP_POSTURE_FILE"
    _cache 33 44

    [ "$(_qf .source)" = "cache" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "33" ]
}

@test "feed: Bishop with stale_input:true is not used; the cache is" {
    _bishop 95 95
    jq '.stale_input = true' "$MOTHER_BISHOP_POSTURE_FILE" > "$MOTHER_BISHOP_POSTURE_FILE.new"
    mv "$MOTHER_BISHOP_POSTURE_FILE.new" "$MOTHER_BISHOP_POSTURE_FILE"
    _cache 5 6

    [ "$(_qf .source)" = "cache" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "5" ]
}

@test "feed: Bishop with stale_input:true and no cache means no feed" {
    _bishop 95 95
    jq '.stale_input = true' "$MOTHER_BISHOP_POSTURE_FILE" > "$MOTHER_BISHOP_POSTURE_FILE.new"
    mv "$MOTHER_BISHOP_POSTURE_FILE.new" "$MOTHER_BISHOP_POSTURE_FILE"

    [ "$(_qf .source)" = "none" ]
    [ "$(_qf .stale)" = "true" ]
}

@test "feed: a Bishop file older than 30 minutes is not used; a fresh cache is" {
    _bishop 95 95
    _age "$MOTHER_BISHOP_POSTURE_FILE" 2000
    _cache 7 8

    [ "$(_qf .source)" = "cache" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "7" ]
}

@test "feed: a file just inside the 1800s window is still used" {
    _bishop 15 16
    _age "$MOTHER_BISHOP_POSTURE_FILE" 1700

    [ "$(_qf .source)" = "bishop" ]
    [ "$(_qf .stale)" = "false" ]
}

@test "feed: MOTHER_QUOTA_FEED_MAX_AGE_S tunes how old a feed may be" {
    _bishop 15 16
    _age "$MOTHER_BISHOP_POSTURE_FILE" 120

    [ "$(_qf .source)" = "bishop" ]
    export MOTHER_QUOTA_FEED_MAX_AGE_S=60
    [ "$(_qf .source)" = "none" ]
    export MOTHER_QUOTA_FEED_MAX_AGE_S=300
    [ "$(_qf .source)" = "bishop" ]
}

@test "feed: with no source at all the feed is none, stale, has no age and the gate lets work through" {
    [ "$(_qf .source)" = "none" ]
    [ "$(_qf .stale)" = "true" ]
    [ "$(_qf .feed_age_s)" = "null" ]

    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "feed: stale sources never block, even when their last reading was 100%" {
    _bishop 100 100
    _cache 100 100
    _age "$MOTHER_BISHOP_POSTURE_FILE" 5000
    _age "$MOTHER_RATE_LIMIT_CACHE" 5000

    [ "$(_qf .source)" = "none" ]
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "feed: feed_age_s reports the age of the feed file" {
    _bishop 1 1
    _age "$MOTHER_BISHOP_POSTURE_FILE" 300

    local age; age=$(_qf .feed_age_s)
    [ "$age" -ge 299 ]
    [ "$age" -le 330 ]
}

@test "feed: a window whose resets_at has passed counts as 0% used" {
    _bishop 100 10 "$(( $(_now) - 100 ))" "$(( $(_now) + 3600 ))"

    [ "$(_qf .windows.five_hour.used_pct)" = "0" ]
    [ "$(_qf .windows.seven_day.used_pct)" = "10" ]
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "feed: an expired seven-day window does not block either" {
    _bishop 10 100 "$(( $(_now) + 3600 ))" "$(( $(_now) - 5 ))"
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "feed: the same expiry rule applies to the statusline cache" {
    _cache 100 100 "$(( $(_now) - 100 ))" "$(( $(_now) - 100 ))"

    [ "$(_qf .source)" = "cache" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "0" ]
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "feed: fractional percentages are read as whole percentages by the gate" {
    _bishop 23.7 89.9
    run _lib '_quota_pct_for_window five_hour'
    [ "$output" = "23" ]
    run _lib '_quota_pct_for_window seven_day'
    [ "$output" = "89" ]
}

# ---------------------------------------------------------------------------
# Caps
# ---------------------------------------------------------------------------

@test "caps: below 90% on both windows dispatch is allowed" {
    _bishop 89 89
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "caps: exactly 90% on the five-hour window blocks" {
    _bishop 90 10
    run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "caps: exactly 90% on the seven-day window blocks" {
    _bishop 10 90
    run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "caps: a cache-sourced reading over the cap blocks too" {
    _cache 95 10
    run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "caps: MOTHER_QUOTA_CAP_5H_PCT and MOTHER_QUOTA_CAP_7D_PCT move each cap independently" {
    _bishop 60 60
    run _lib _quota_check
    [ "$status" -eq 0 ]

    MOTHER_QUOTA_CAP_5H_PCT=50 run _lib _quota_check
    [ "$status" -eq 1 ]

    MOTHER_QUOTA_CAP_7D_PCT=50 run _lib _quota_check
    [ "$status" -eq 1 ]

    MOTHER_QUOTA_CAP_5H_PCT=70 MOTHER_QUOTA_CAP_7D_PCT=70 run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "caps: cap_pct in the status reflects the configured caps" {
    _bishop 1 1
    [ "$(_qf .windows.five_hour.cap_pct)" = "90" ]
    [ "$(_qf .windows.seven_day.cap_pct)" = "90" ]

    export MOTHER_QUOTA_CAP_5H_PCT=75 MOTHER_QUOTA_CAP_7D_PCT=60
    [ "$(_qf .windows.five_hour.cap_pct)" = "75" ]
    [ "$(_qf .windows.seven_day.cap_pct)" = "60" ]
}

# ---------------------------------------------------------------------------
# Switch semantics (lib/state.sh)
# ---------------------------------------------------------------------------

@test "switch: with no switch file the gate is on and blocks at 100%" {
    _bishop 100 100
    [ ! -e "$GATE_FILE" ]
    [ "$(_qf .gate)" = "on" ]
    run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "switch: a corrupt switch file means on" {
    _bishop 100 100
    printf 'garbage{{' > "$GATE_FILE"
    [ "$(_qf .gate)" = "on" ]
    run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "switch: a switch file with an unknown state means on" {
    _bishop 100 100
    _gate_file sometimes
    [ "$(_qf .gate)" = "on" ]
    run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "switch: an empty switch file means on" {
    _bishop 100 100
    : > "$GATE_FILE"
    [ "$(_qf .gate)" = "on" ]
}

@test "switch: off lets dispatch through at 100% on both windows" {
    _bishop 100 100
    _gate_file off
    [ "$(_qf .gate)" = "off" ]
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "switch: off_until_reset lets dispatch through before its reset time" {
    _bishop 100 100
    _gate_file off_until_reset "$(( $(_now) + 600 ))"
    run _lib _quota_check
    [ "$status" -eq 0 ]
    [ "$(_qf .gate)" = "off_until_reset" ]
}

@test "switch: off_until_reset flips back to on once its reset time has passed, and the gate blocks again" {
    _bishop 100 100
    _gate_file off_until_reset "$(( $(_now) - 5 ))"

    run _lib _quota_check
    [ "$status" -eq 1 ]
    [ "$(_qf .gate)" = "on" ]
    [ "$(_qf .until)" = "null" ]
    [ "$(jq -r .state "$GATE_FILE")" = "on" ]
}

@test "switch: the automatic flip is audited as auto:reset" {
    _bishop 10 10
    _gate_file off_until_reset "$(( $(_now) - 5 ))"

    run _lib _quota_check
    [ "$status" -eq 0 ]    # under the cap: passes, but the switch still flips
    [ "$(_audit_lines)" = "1" ]
    [ "$(jq -r .changed_by "$AUDIT_FILE")" = "auto:reset" ]
    [ "$(jq -r .from "$AUDIT_FILE")" = "off_until_reset" ]
    [ "$(jq -r .to "$AUDIT_FILE")" = "on" ]
    [ "$(jq -r .changed_by "$GATE_FILE")" = "auto:reset" ]
}

# ---------------------------------------------------------------------------
# CLI: mother quota on | off | off-until-reset
# ---------------------------------------------------------------------------

@test "cli: off then on round-trips through status --json" {
    _bishop 100 100

    run mother quota off
    [ "$status" -eq 0 ]
    [ "$(_qf .gate)" = "off" ]
    [ "$(_qf .until)" = "null" ]
    [ "$(_qf .changed_by)" = "cli" ]
    [ "$(_qf .changed_at)" != "null" ]
    run _lib _quota_check
    [ "$status" -eq 0 ]

    run mother quota on
    [ "$status" -eq 0 ]
    [ "$(_qf .gate)" = "on" ]
    run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "cli: off-until-reset stores the earliest future window reset as the until time" {
    local r5=$(( $(_now) + 3600 )) r7=$(( $(_now) + 3 * 86400 ))
    _bishop 100 100 "$r5" "$r7"

    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [ "$(_qf .gate)" = "off_until_reset" ]
    [ "$(_qf .until)" = "$r5" ]
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "cli: off-until-reset skips an already-expired window and uses the next reset" {
    local r7=$(( $(_now) + 2 * 86400 ))
    _bishop 100 100 "$(( $(_now) - 60 ))" "$r7"

    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [ "$(_qf .until)" = "$r7" ]
}

@test "cli: off-until-reset with no feed at all is refused as no_reset_known and changes nothing" {
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ ! -e "$GATE_FILE" ]
    [ "$(_audit_lines)" = "0" ]
}

@test "cli: off-until-reset with every window already expired is refused as no_reset_known" {
    _bishop 100 100 "$(( $(_now) - 60 ))" "$(( $(_now) - 30 ))"
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ ! -e "$GATE_FILE" ]
    [ "$(_audit_lines)" = "0" ]
}

@test "cli: off-until-reset on a stale feed is refused as no_reset_known even if its resets lie in the future" {
    _bishop 100 100
    _age "$MOTHER_BISHOP_POSTURE_FILE" 5000
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ ! -e "$GATE_FILE" ]
}

@test "cli: a refused off-until-reset leaves an existing switch file and audit trail byte-for-byte unchanged" {
    _gate_file off
    cp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    cmp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    [ "$(_audit_lines)" = "0" ]
}

@test "until clamp: a reset 30 days out is never stored; the call is refused as no_reset_known" {
    _bishop 100 100 "$(( $(_now) + 30 * 86400 ))" "$(( $(_now) + 31 * 86400 ))"
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ ! -e "$GATE_FILE" ]
    [ "$(_audit_lines)" = "0" ]
}

@test "until clamp: the cap is now + 7 days + 1 hour: just inside is stored, just outside is refused" {
    local inside=$(( $(_now) + 608400 - 60 ))
    _bishop 10 10 "$(( $(_now) - 5 ))" "$inside"
    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [ "$(_qf .until)" = "$inside" ]
    mother quota on >/dev/null 2>&1

    _bishop 10 10 "$(( $(_now) - 5 ))" "$(( $(_now) + 608400 + 300 ))"
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ "$(_qf .gate)" = "on" ]
}

@test "until clamp: a too-distant reset is skipped, not chosen: the nearest VALID reset wins" {
    local r7=$(( $(_now) + 3 * 86400 ))
    _bishop 10 10 "$(( $(_now) + 30 * 86400 ))" "$r7"
    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [ "$(_qf .until)" = "$r7" ]
}

@test "until clamp: among valid resets the nearer one is stored" {
    local r5=$(( $(_now) + 3600 ))
    _bishop 10 10 "$r5" "$(( $(_now) + 30 * 86400 ))"
    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [ "$(_qf .until)" = "$r5" ]
}

@test "until clamp: a non-numeric resets_at makes the feed unusable, so no reset is known" {
    jq -nc '{five_hour:{used_pct:10,resets_at:"tomorrow"},seven_day:{used_pct:10,resets_at:"soon"}}' > "$MOTHER_BISHOP_POSTURE_FILE"
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ ! -e "$GATE_FILE" ]
}

@test "until clamp: without MOTHER_TEST_ROOT the switch ignores MOTHER_BISHOP_POSTURE_FILE and MOTHER_RATE_LIMIT_CACHE" {
    # A forged Bishop file with a reset one hour out, at a non-default path.
    _bishop 10 10 "$(( $(_now) + 3600 ))" "$(( $(_now) + 7200 ))"
    _run_live_mode mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ ! -e "$GATE_FILE" ]

    # Same for a forged statusline cache at a non-default path.
    rm -f "$MOTHER_BISHOP_POSTURE_FILE"
    export MOTHER_RATE_LIMIT_CACHE="$MOTHER_ROOT/forged-cache.json"
    _cache 10 10 "$(( $(_now) + 3600 ))" "$(( $(_now) + 7200 ))"
    _run_live_mode mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    [ ! -e "$GATE_FILE" ]

    # Under test the same files are honoured.
    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [ "$(_qf .gate)" = "off_until_reset" ]
}

@test "cli: off-until-reset when already off_until_reset with a still-future until and no feed is a no-op success" {
    _gate_file off_until_reset "$(( $(_now) + 600 ))"
    cp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [[ "$output" != *no_reset_known* ]]
    cmp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    [ "$(_audit_lines)" = "0" ]
}

@test "cli: the audit trail records who changed the switch, from what and to what" {
    _bishop 50 50
    mother quota off 2>/dev/null
    mother quota on --source broker:nostromo 2>/dev/null

    [ "$(_audit_lines)" = "2" ]
    [ "$(sed -n 1p "$AUDIT_FILE" | jq -r '[.changed_by, .from, .to] | join(",")')" = "cli,on,off" ]
    [ "$(sed -n 2p "$AUDIT_FILE" | jq -r '[.changed_by, .from, .to] | join(",")')" = "broker:nostromo,off,on" ]
}

@test "cli: --source is recorded as changed_by" {
    run mother quota off --source broker:ui
    [ "$status" -eq 0 ]
    [ "$(_qf .changed_by)" = "broker:ui" ]
}

@test "cli: --source accepts cli and broker:<token> with a [A-Za-z0-9._-]{1,64} token" {
    local long; long=$(printf 'a%.0s' $(seq 1 64))
    run mother quota off --source cli
    [ "$status" -eq 0 ]
    [ "$(_qf .changed_by)" = "cli" ]
    run mother quota on --source "broker:Ab.c_d-9"
    [ "$status" -eq 0 ]
    [ "$(_qf .changed_by)" = "broker:Ab.c_d-9" ]
    run mother quota off --source "broker:$long"
    [ "$status" -eq 0 ]
    [ "$(_qf .changed_by)" = "broker:$long" ]
}

@test "cli: --source values other than cli or broker:<token> are rejected and change nothing" {
    local long; long=$(printf 'a%.0s' $(seq 1 65))
    local bad
    for bad in "auto:reset" "auto:x" "foo" "broker:" "broker:a b" "broker:a/b" "broker:$long" "CLI" ""; do
        run mother quota off --source "$bad"
        [ "$status" -ne 0 ]
        [ ! -e "$GATE_FILE" ]
        [ "$(_audit_lines)" = "0" ]
    done
}

@test "cli: setting the state it is already in changes nothing and writes no audit line" {
    _bishop 50 50
    mother quota off 2>/dev/null
    local at; at=$(_qf .changed_at)
    [ "$(_audit_lines)" = "1" ]
    sleep 1

    run mother quota off --source broker:other
    [ "$status" -eq 0 ]
    [ "$(_audit_lines)" = "1" ]
    [ "$(_qf .changed_at)" = "$at" ]
    [ "$(_qf .changed_by)" = "cli" ]
}

@test "cli: turning on when it is already on (no switch file) is a no-op" {
    run mother quota on
    [ "$status" -eq 0 ]
    [ "$(_audit_lines)" = "0" ]
    [ "$(_qf .gate)" = "on" ]
}

@test "cli: off-until-reset twice for the same reset is a no-op the second time" {
    _bishop 50 50 "$(( $(_now) + 3600 ))" "$(( $(_now) + 86400 ))"
    mother quota off-until-reset 2>/dev/null
    mother quota off-until-reset 2>/dev/null
    [ "$(_audit_lines)" = "1" ]
}

@test "cli: switching from off to off-until-reset is a real change and is audited" {
    _bishop 50 50
    mother quota off 2>/dev/null
    mother quota off-until-reset 2>/dev/null
    [ "$(_audit_lines)" = "2" ]
    [ "$(_qf .gate)" = "off_until_reset" ]
}

@test "cli: a worker (MOTHER_JOB_ID set) is refused for every state change and the switch is untouched" {
    local s
    for s in on off off-until-reset; do
        MOTHER_JOB_ID=some-job run mother quota "$s"
        [ "$status" -ne 0 ]
        [[ "$output" == *refused* ]]
    done
    [ ! -e "$GATE_FILE" ]
    [ "$(_audit_lines)" = "0" ]
}

@test "cli: MOTHER_JOB_ID set to the empty string is still refused (set is enough), logged, and changes nothing" {
    local s
    for s in on off off-until-reset; do
        MOTHER_JOB_ID= run mother quota "$s"
        [ "$status" -ne 0 ]
        [[ "$output" == *refused* ]]
    done
    [ ! -e "$GATE_FILE" ]
    [ "$(_audit_lines)" = "0" ]
    local log="$MOTHER_ROOT/quota-gate-refusals.jsonl"
    [ "$(grep -c . "$log")" = "3" ]
    [ "$(jq -s 'all(.[]; has("ts") and has("requested") and has("reason") and has("source"))' "$log")" = "true" ]
    [ "$(jq -s 'all(.[]; (.reason | length) > 0 and (.requested | length) > 0)' "$log")" = "true" ]
    [ "$(jq -rs '.[0].source' "$log")" = "cli" ]
}

@test "cli: a refusal for a worker with an id is logged to the refusals file too" {
    MOTHER_JOB_ID=some-job run mother quota off --source broker:ui
    [ "$status" -ne 0 ]
    [ "$(grep -c . "$MOTHER_ROOT/quota-gate-refusals.jsonl")" = "1" ]
    [ "$(jq -r .source "$MOTHER_ROOT/quota-gate-refusals.jsonl")" = "broker:ui" ]
    [ ! -e "$GATE_FILE" ]
    [ "$(_audit_lines)" = "0" ]
}

@test "cli: a process whose ancestor is a mother-run-job is refused even with MOTHER_JOB_ID unset" {
    local fake="$MOTHER_ROOT/fake-sup"; mkdir -p "$fake"
    printf '#!/usr/bin/env bash\nenv -u MOTHER_JOB_ID mother quota off\n' > "$fake/mother-run-job"
    chmod +x "$fake/mother-run-job"
    unset MOTHER_JOB_ID
    run "$fake/mother-run-job"
    [ "$status" -ne 0 ]
    [[ "$output" == *refused* ]]
    [ ! -e "$GATE_FILE" ]
    [ "$(_audit_lines)" = "0" ]
    [ "$(grep -c . "$MOTHER_ROOT/quota-gate-refusals.jsonl")" = "1" ]
}

@test "cli: an unknown subcommand is an error" {
    run mother quota sometimes
    [ "$status" -ne 0 ]
    [ ! -e "$GATE_FILE" ]
}

@test "cli: --source with no value is an error" {
    run mother quota off --source
    [ "$status" -ne 0 ]
    [ ! -e "$GATE_FILE" ]
}

@test "cli: bare 'mother quota' shows status" {
    _bishop 12 34
    run mother quota
    [ "$status" -eq 0 ]
    [[ "$output" == *"bishop"* ]]
}

@test "cli: the switch persists across separate invocations (a daemon restart keeps it)" {
    _bishop 100 100
    mother quota off 2>/dev/null
    run bash -c "set -u; source '$_LIB_DIR/state.sh'; _quota_check"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# status --json shape
# ---------------------------------------------------------------------------

@test "status --json has exactly the documented keys of the golden fixture block" {
    _bishop 23 100
    local want got
    want=$(jq -c '.quota_block | [keys, (.windows | keys), (.windows.five_hour | keys), (.windows.seven_day | keys)]' "$FIXTURE")
    got=$(_qjson | jq -c '[keys, (.windows | keys), (.windows.five_hour | keys), (.windows.seven_day | keys)]')
    [ "$got" = "$want" ]
}

@test "status --json value types match the fixture: gate string, until null, numbers, source enum" {
    _bishop 23 40
    run bash -c "mother quota status --json 2>/dev/null | jq -e '
        (.gate | IN(\"on\",\"off\",\"off_until_reset\"))
        and (.until == null)
        and (.changed_at == null) and (.changed_by == null)
        and (.source | IN(\"bishop\",\"cache\",\"none\"))
        and (.feed_age_s | type == \"number\")
        and (.stale | type == \"boolean\")
        and (.windows.five_hour.used_pct | type == \"number\")
        and (.windows.five_hour.cap_pct | type == \"number\")
        and (.windows.five_hour.resets_at | type == \"number\")
        and (.windows.seven_day.used_pct | type == \"number\")
    '"
    [ "$status" -eq 0 ]
}

@test "status --json with no feed: source none, stale true, windows at 0% with null reset times" {
    [ "$(_qf .source)" = "none" ]
    [ "$(_qf .stale)" = "true" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "0" ]
    [ "$(_qf .windows.five_hour.resets_at)" = "null" ]
    [ "$(_qf .windows.seven_day.resets_at)" = "null" ]
}

@test "status --json while off_until_reset carries the until epoch" {
    _bishop 50 50
    local u=$(( $(_now) + 900 ))
    _gate_file off_until_reset "$u"
    [ "$(_qf .gate)" = "off_until_reset" ]
    [ "$(_qf .until)" = "$u" ]
}

@test "status --json is a single line of valid JSON on stdout" {
    _bishop 1 2
    run bash -c "mother quota status --json 2>/dev/null"
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e . >/dev/null
    [ "$(printf '%s\n' "$output" | grep -c .)" = "1" ]
}

# ---------------------------------------------------------------------------
# status text: Central time first, UTC in parentheses
# ---------------------------------------------------------------------------

@test "status text shows reset times in Central time (CDT) followed by UTC in parentheses" {
    _bishop 40 50 "$EPOCH_CDT" "$EPOCH_CST"
    # A non-Central session timezone must not leak into the output.
    TZ=Asia/Tokyo run mother quota status
    [ "$status" -eq 0 ]
    echo "$output" | grep -E '(1:00 PM|13:00) CDT \(2027-07-01 18:00 UTC\)'
}

@test "status text uses CST in winter" {
    _bishop 40 50 "$EPOCH_CDT" "$EPOCH_CST"
    TZ=Asia/Tokyo run mother quota status
    [ "$status" -eq 0 ]
    echo "$output" | grep -E '(12:00 PM|12:00) CST \(2027-12-01 18:00 UTC\)'
}

@test "status text shows the off-until time in Central then UTC while off_until_reset" {
    _bishop 40 50 "$EPOCH_CST" "$EPOCH_CST"
    _gate_file off_until_reset "$EPOCH_CDT"
    TZ=Asia/Tokyo run mother quota status
    [ "$status" -eq 0 ]
    echo "$output" | grep -i "off until" | grep -E '(1:00 PM|13:00) CDT \(2027-07-01 18:00 UTC\)'
}

@test "status text names the gate state, the source and each window's usage" {
    _bishop 23 40
    run mother quota status
    [ "$status" -eq 0 ]
    [[ "$output" == *"bishop"* ]]
    [[ "$output" == *"23"* ]]
    [[ "$output" == *"40"* ]]
    [[ "$output" == *"90"* ]]
}

@test "status text with no feed says the source is none" {
    run mother quota status
    [ "$status" -eq 0 ]
    [[ "$output" == *"none"* ]]
}

# ---------------------------------------------------------------------------
# quota_feed_stale attention item
# ---------------------------------------------------------------------------

@test "attention: no fresh feed raises quota_feed_stale when the attention list is written" {
    run _lib mother_attention_write
    [ "$status" -eq 0 ]

    [ "$(_stale_items | jq length)" = "1" ]
    local item; item=$(_stale_items | jq -c '.[0]')
    [ "$(echo "$item" | jq -r .reason)" = "quota_feed_stale" ]
    [ "$(echo "$item" | jq -r .detail.acked)" = "false" ]
    [ -n "$(echo "$item" | jq -r .since)" ]
    [ "$(echo "$item" | jq -r .since)" != "null" ]
    [ -n "$(echo "$item" | jq -r .hint)" ]
    [ -f "$MOTHER_ROOT/quota-feed-stale.json" ]
}

@test "attention: the item carries the standard attention-item fields" {
    _lib mother_attention_write
    [ "$(_stale_items | jq 'all(.[]; has("kind") and has("job_id") and has("repo") and has("branch") and has("reason") and has("since") and has("detail") and has("hint"))')" = "true" ]
}

@test "attention: a fresh Bishop feed raises nothing" {
    _bishop 10 10
    _lib mother_attention_write
    [ "$(_stale_items | jq length)" = "0" ]
    [ ! -e "$MOTHER_ROOT/quota-feed-stale.json" ]
}

@test "attention: a fresh statusline cache is enough to keep it quiet" {
    _cache 10 10
    _lib mother_attention_write
    [ "$(_stale_items | jq length)" = "0" ]
}

@test "attention: an over-old feed raises it" {
    _bishop 10 10
    _age "$MOTHER_BISHOP_POSTURE_FILE" 4000
    _lib mother_attention_write
    [ "$(_stale_items | jq length)" = "1" ]
}

@test "attention: the item clears as soon as the feed is fresh again" {
    _lib mother_attention_write
    [ "$(_stale_items | jq length)" = "1" ]

    _bishop 10 10
    _lib mother_attention_write
    [ "$(_stale_items | jq length)" = "0" ]
    [ ! -e "$MOTHER_ROOT/quota-feed-stale.json" ]
}

@test "attention: since stays put while the feed stays stale" {
    _lib mother_attention_write
    local s1; s1=$(_stale_items | jq -r '.[0].since')
    sleep 1
    _lib mother_attention_write
    local s2; s2=$(_stale_items | jq -r '.[0].since')
    [ "$s1" = "$s2" ]
}

@test "attention: the stale item shows in mother status after the list is written" {
    _lib mother_attention_write
    run mother status --format json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '[.needs_attention[] | select(.kind == "quota_feed_stale")] | length')" = "1" ]
}

@test "attention: a stale feed still lets the gate pass (never a silent block)" {
    _lib mother_attention_write
    run _lib _quota_check
    [ "$status" -eq 0 ]
}

@test "ack: 'mother ack quota quota_feed_stale' acknowledges the item and it stops counting" {
    _lib mother_attention_write
    local since; since=$(_stale_items | jq -r '.[0].since')

    run mother ack quota quota_feed_stale
    [ "$status" -eq 0 ]

    [ "$(jq -r '.quota_feed_stale.since' "$MOTHER_ROOT/acks/_quota.json")" = "$since" ]
    [ "$(_stale_items | jq -r '.[0].detail.acked')" = "true" ]
    # An acked item is still listed but does not count.
    [ "$(jq '[.[] | select(.detail.acked != true)] | length' "$MOTHER_ROOT/attention.json")" = "0" ]
    run mother status
    [[ "$output" == *"needs attention (0)"* ]]
    [[ "$output" == *"(acked)"* ]]
}

@test "ack: an acknowledgement lapses when the feed recovers and goes stale again" {
    _lib mother_attention_write
    mother ack quota quota_feed_stale >/dev/null 2>&1

    _bishop 10 10
    _lib mother_attention_write
    [ "$(_stale_items | jq length)" = "0" ]

    sleep 1
    rm -f "$MOTHER_BISHOP_POSTURE_FILE"
    _lib mother_attention_write
    [ "$(_stale_items | jq length)" = "1" ]
    [ "$(_stale_items | jq -r '.[0].detail.acked')" = "false" ]
}

@test "ack: acknowledging while the feed is fresh fails" {
    _bishop 10 10
    _lib mother_attention_write
    run mother ack quota quota_feed_stale
    [ "$status" -ne 0 ]
    [ ! -e "$MOTHER_ROOT/acks/_quota.json" ]
}

@test "ack: a worker (MOTHER_JOB_ID set) cannot acknowledge the quota item" {
    _lib mother_attention_write
    MOTHER_JOB_ID=some-job run mother ack quota quota_feed_stale
    [ "$status" -ne 0 ]
    [ ! -e "$MOTHER_ROOT/acks/_quota.json" ]
}

# ---------------------------------------------------------------------------
# Golden fixture: the wire contract Nostromo decodes
# ---------------------------------------------------------------------------

@test "fixture: the quota block, snapshot and command envelopes are present and well-formed" {
    run jq -e '
        (.quota_block.gate | IN("on","off","off_until_reset"))
        and (.quota_block.windows.five_hour | has("used_pct") and has("cap_pct") and has("resets_at"))
        and (.quota_block.windows.seven_day | has("used_pct") and has("cap_pct") and has("resets_at"))
        and (.snapshot_envelope.t == "snapshot" and .snapshot_envelope.dir == "event")
        and (.snapshot_envelope.data | has("sub") and has("jobs") and has("quota"))
        and (.command_envelopes.request | .t == "quota-gate" and .dir == "cmd" and (.data.state | IN("on","off","off_until_reset")))
        and (.command_envelopes.ok_ack | .t == "quota-gate" and .dir == "ack" and .data.ok == true and has("id"))
        and (.command_envelopes.ok_ack.id == .command_envelopes.request.id)
        and (.command_envelopes.rejected_ack | .data.ok == false and .data.error.code == "malformed")
        and (.command_envelopes.rejected_ack.id == .command_envelopes.rejected_request.id)
        and (.command_envelopes.rejected_request.data.state | IN("on","off","off_until_reset") | not)
    ' "$FIXTURE"
    [ "$status" -eq 0 ]
}

@test "fixture: every key of the fixture's quota block is produced by mother quota status --json" {
    _bishop 23 40
    mother quota off-until-reset --source broker:nostromo >/dev/null 2>&1
    local missing
    missing=$(jq -n --slurpfile f "$FIXTURE" --argjson live "$(_qjson)" '
        ($f[0].quota_block | [path(.. | select(type != "object"))] | map(map(tostring) | join("."))) as $want
        | ($live | [path(.. | select(type != "object"))] | map(map(tostring) | join("."))) as $have
        | $want - $have | length')
    [ "$missing" = "0" ]
}

# ---------------------------------------------------------------------------
# PR #106 review fix-ups
# ---------------------------------------------------------------------------

_park_job() {   # <id> <window reason> <resume-at epoch>
    make_job "$1" awaiting ".paused_reason = \"$2\" | .auto_resume_at = $3"
}
_job_state() { jq -r .state "$JOBS_DIR/$1.json"; }

@test "parked: 'mother quota off' releases a quota-parked job on the next tick, before auto_resume_at" {
    _bishop 10 100
    _park_job parked-1 quota_7d "$(( $(_now) + 259200 ))"
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state parked-1)" = "awaiting" ]     # gate on: stays parked
    mother quota off >/dev/null 2>&1
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state parked-1)" = "ready" ]
    [ "$(jq -r .paused_reason "$JOBS_DIR/parked-1.json")" = "null" ]
}

@test "parked: off_until_reset in force releases parked jobs too" {
    _bishop 10 100
    _park_job parked-2 quota_5h "$(( $(_now) + 9000 ))"
    mother quota off-until-reset >/dev/null 2>&1
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state parked-2)" = "ready" ]
}

@test "parked: the gate being open never releases an awaiting job parked for a non-quota reason" {
    _bishop 10 100
    make_job other-1 awaiting '.paused_reason = "gate_hold" | .auto_resume_at = 1'
    make_job other-2 awaiting '.paused_reason = null'
    mother quota off >/dev/null 2>&1
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state other-1)" = "awaiting" ]
    [ "$(_job_state other-2)" = "awaiting" ]
}

@test "runner tick: at 100% weekly with the gate on a ready job waits; 'mother quota off' lets the next tick start it" {
    _bishop 10 100
    local fake="$MOTHER_ROOT/fake-bin"; mkdir -p "$fake"
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/run-job-calls"\nexit 0\n' "$MOTHER_ROOT" > "$fake/mother-run-job"
    chmod +x "$fake/mother-run-job"
    export MOTHER_POSTURE_ENABLED=0 MOTHER_CONCURRENCY=2
    make_job gated-1 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_BIN_DIR="$fake" mother-runner --dispatch-tick >/dev/null 2>&1 || true
    [ "$(_job_state gated-1)" = "ready" ]
    [ ! -s "$MOTHER_ROOT/run-job-calls" ]
    mother quota off >/dev/null 2>&1
    MOTHER_BIN_DIR="$fake" mother-runner --dispatch-tick >/dev/null 2>&1 || true
    local i=0; while [ ! -s "$MOTHER_ROOT/run-job-calls" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    [ -s "$MOTHER_ROOT/run-job-calls" ]
    [ "$(_job_state gated-1)" != "ready" ]
}

@test "feed: a string used_pct makes the Bishop file unusable; the cache is used instead" {
    jq -nc '{five_hour:{used_pct:"100",resets_at:9999999999},seven_day:{used_pct:10,resets_at:9999999999}}' > "$MOTHER_BISHOP_POSTURE_FILE"
    _cache 20 30
    [ "$(_qf .source)" = "cache" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "20" ]
}

@test "feed: a null seven_day window makes Bishop unusable and with no cache the source is none, never bishop at 0%" {
    jq -nc '{five_hour:{used_pct:10,resets_at:9999999999},seven_day:null}' > "$MOTHER_BISHOP_POSTURE_FILE"
    [ "$(_qf .source)" = "none" ]
    [ "$(_qf .stale)" = "true" ]
}

@test "feed: a missing window makes Bishop unusable (falls to the cache)" {
    jq -nc '{five_hour:{used_pct:99,resets_at:9999999999}}' > "$MOTHER_BISHOP_POSTURE_FILE"
    _cache 5 6
    [ "$(_qf .source)" = "cache" ]
}

@test "feed: a null used_pct is unusable, not 0%" {
    jq -nc '{five_hour:{used_pct:null,resets_at:9999999999},seven_day:{used_pct:10,resets_at:9999999999}}' > "$MOTHER_BISHOP_POSTURE_FILE"
    [ "$(_qf .source)" = "none" ]
}

@test "epochs: a float until in the past flips off_until_reset to on" {
    _bishop 100 100
    _gate_file off_until_reset "$(( $(_now) - 100 )).5"
    run _lib _quota_check
    [ "$status" -eq 1 ]
    [ "$(_qf .gate)" = "on" ]
    [ "$(jq -r .state "$GATE_FILE")" = "on" ]
}

@test "epochs: a float resets_at is truncated in the status and the stored until" {
    local r=$(( $(_now) + 3600 ))
    _bishop 10 10 "$r.75" "$(( r + 1000 )).25"
    mother quota off-until-reset >/dev/null 2>&1
    [ "$(jq -r .until "$GATE_FILE")" = "$r" ]
    [ "$(_qf .windows.five_hour.resets_at)" = "$r" ]
}

@test "cas: two concurrent evaluators of an expired off_until_reset write exactly one audit line (interleaving forced)" {
    _bishop 10 10
    _gate_file off_until_reset "$(( $(_now) - 5 ))"
    # Widen the read-to-write window: whoever has read the expired state sleeps 1s before it writes.
    # Without the switch's lock both evaluators read "expired" and both write + audit.
    local stub='eval "_orig$(declare -f _atomic_write)"; _atomic_write() { sleep 1; _orig_atomic_write "$@"; }; _quota_gate_open'
    ( _lib "$stub" ) & local a=$!
    ( _lib "$stub" ) & local b=$!
    wait "$a" || true; wait "$b" || true
    [ "$(_audit_lines)" = "1" ]
    [ "$(jq -r .state "$GATE_FILE")" = "on" ]
    [ "$(jq -r .changed_by "$GATE_FILE")" = "auto:reset" ]
}

@test "cas: an expired auto flip never overwrites an explicit 'off' that landed first" {
    _bishop 100 100
    _gate_file off_until_reset "$(( $(_now) - 5 ))"
    # The evaluator has read the expired state; an operator then says off.
    run _lib 'cur=$(_quota_gate_read); mother quota off >/dev/null 2>&1; _quota_gate_set on auto:reset off_until_reset >/dev/null'
    [ "$(jq -r .state "$GATE_FILE")" = "off" ]
    [ "$(jq -r .changed_by "$GATE_FILE")" = "cli" ]
}

@test "re-issue: off-until-reset with a stale stored until takes the new earliest future reset" {
    local r=$(( $(_now) + 3600 ))
    _bishop 10 10 "$r" "$(( r + 5000 ))"
    _gate_file off_until_reset "$(( $(_now) - 50 ))"
    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    [[ "$output" != *already* ]]
    [ "$(jq -r .until "$GATE_FILE")" = "$r" ]
}

@test "re-issue: off-until-reset with a stale until and no known future reset is refused and leaves the stale file alone" {
    _bishop 10 10 1 1
    _gate_file off_until_reset "$(( $(_now) - 50 ))"
    cp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    run mother quota off-until-reset
    [ "$status" -ne 0 ]
    [[ "$output" == *no_reset_known* ]]
    cmp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    [ "$(_audit_lines)" = "0" ]
}

@test "re-issue: off-until-reset refreshes a still-future until to the earlier new reset" {
    local r=$(( $(_now) + 3600 ))
    _bishop 10 10 "$r" "$(( r + 5000 ))"
    _gate_file off_until_reset "$(( r + 5000 ))"
    run mother quota off-until-reset
    [ "$(jq -r .until "$GATE_FILE")" = "$r" ]
}

@test "cap: MOTHER_QUOTA_CAP_5H_PCT=90% is read as 90, not a crash" {
    _bishop 95 10
    MOTHER_QUOTA_CAP_5H_PCT='90%' run mother quota status --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r .windows.five_hour.cap_pct)" = "90" ]
    [ "$(echo "$output" | jq -r .cap_invalid)" = "false" ]
    MOTHER_QUOTA_CAP_5H_PCT='90%' run _lib _quota_check
    [ "$status" -eq 1 ]
}

@test "cap: a non-numeric cap falls back to 90 and is flagged cap_invalid" {
    _bishop 95 10
    MOTHER_QUOTA_CAP_7D_PCT='lots' run mother quota status --json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq -r .windows.seven_day.cap_pct)" = "90" ]
    [ "$(echo "$output" | jq -r .cap_invalid)" = "true" ]
    MOTHER_QUOTA_CAP_5H_PCT='lots' run _lib _quota_check
    [ "$status" -eq 1 ]   # 95 >= default 90
}

@test "ack: a job id other than 'quota' is not the quota special case" {
    _lib mother_attention_write    # no feed -> stale marker exists
    run mother ack some-job quota_feed_stale
    [ "$status" -ne 0 ]
    [ ! -e "$MOTHER_ROOT/acks/_quota.json" ]
}

@test "fixture: _doc says feed_age_s is null without a usable feed file, and the block has cap_invalid" {
    run jq -e '(._doc | test("no usable feed file")) and (.quota_block.cap_invalid == false) and (._doc | test("cap_invalid"))' "$FIXTURE"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Double supervisor: a parked or pausing job must never get a second supervisor
# while the first one is still alive (children/<pid>.json naming the job, pid alive)
# ---------------------------------------------------------------------------

@test "parked: a quota-parked job whose supervisor is still alive stays awaiting when the gate opens, and is released once it is gone" {
    _bishop 10 100
    _park_job parked-live quota_7d "$(( $(_now) + 259200 ))"
    _live_supervisor parked-live
    local sup=$LIVE_SUP_PID

    mother quota off >/dev/null 2>&1
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state parked-live)" = "awaiting" ]
    [ "$(jq -r .paused_reason "$JOBS_DIR/parked-live.json")" = "quota_7d" ]
    ! grep -q auto_resumed "$EVENTS_DIR/parked-live.jsonl" 2>/dev/null

    # Control: the same job is released as soon as that supervisor has exited.
    kill "$sup"; wait "$sup" 2>/dev/null || true
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state parked-live)" = "ready" ]
}

@test "parked: a live supervisor entry for a DIFFERENT job does not hold a parked job back" {
    _bishop 10 100
    _park_job parked-free quota_5h "$(( $(_now) + 9000 ))"
    _live_supervisor some-other-job
    mother quota off >/dev/null 2>&1
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state parked-free)" = "ready" ]
}

@test "pause in flight: when the gate opens before the worker stops, the next tick clears the pause request and no second supervisor starts" {
    _bishop 10 100
    _fake_run_job
    make_job pausing-1 running ".repo_path = \"$MOTHER_ROOT\" | .pause_requested = true | .paused_reason = \"quota_7d\" | .auto_resume_at = $(( $(_now) + 86400 ))"
    _live_supervisor pausing-1

    # Gate still on: the request stands.
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(jq -r '.pause_requested // false' "$JOBS_DIR/pausing-1.json")" = "true" ]

    mother quota off >/dev/null 2>&1
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick >/dev/null 2>&1 || true

    [ "$(jq -r '.pause_requested // false' "$JOBS_DIR/pausing-1.json")" = "false" ]
    [ "$(jq -r .paused_reason "$JOBS_DIR/pausing-1.json")" = "null" ]
    [ "$(jq -r .auto_resume_at "$JOBS_DIR/pausing-1.json")" = "null" ]
    [ "$(_job_state pausing-1)" = "running" ]
    [ ! -s "$MOTHER_ROOT/run-job-calls" ]
    [ "$(find "$RUNNER_DIR/children" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
}

@test "pause in flight: an open gate only clears QUOTA pause requests, never another reason's" {
    _bishop 10 10
    make_job pausing-2 running '.pause_requested = true | .paused_reason = "something_else" | .auto_resume_at = 1'
    mother quota off >/dev/null 2>&1
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(jq -r '.pause_requested // false' "$JOBS_DIR/pausing-2.json")" = "true" ]
    [ "$(jq -r .paused_reason "$JOBS_DIR/pausing-2.json")" = "something_else" ]
}

@test "pause pass: with the gate open the pause pass pauses nothing, with it on it pauses the running job" {
    _need_hook --pause-tick
    _bishop 10 100
    make_job pausing-3 running
    _live_supervisor pausing-3

    mother quota off >/dev/null 2>&1
    mother-runner --pause-tick >/dev/null 2>&1 || true
    [ "$(jq -r '.pause_requested // false' "$JOBS_DIR/pausing-3.json")" = "false" ]

    # Control: same job, gate on again -> the pass does request the pause (the hook works).
    mother quota on >/dev/null 2>&1
    mother-runner --pause-tick >/dev/null 2>&1 || true
    [ "$(jq -r '.pause_requested // false' "$JOBS_DIR/pausing-3.json")" = "true" ]
    [ "$(jq -r .paused_reason "$JOBS_DIR/pausing-3.json")" = "quota_7d" ]
}

@test "dispatch: a ready job whose supervisor is still alive is not spawned again and the pass terminates" {
    _bishop 10 10
    _fake_run_job
    make_job dup-1 ready ".repo_path = \"$MOTHER_ROOT\""
    _live_supervisor dup-1

    # perl alarm: a pass that keeps re-picking the refused job would spin forever.
    run env MOTHER_BIN_DIR="$FAKE_BIN" perl -e 'alarm 30; exec @ARGV' mother-runner --dispatch-tick
    [ "$status" -ne 142 ]
    [ ! -s "$MOTHER_ROOT/run-job-calls" ]
    [ "$(_job_state dup-1)" = "ready" ]
    [ "$(jq -r '.spawned_by // "none"' "$JOBS_DIR/dup-1.json")" = "none" ]
    [ "$(find "$RUNNER_DIR/children" -name '*.json' | wc -l | tr -d ' ')" = "1" ]
}

@test "dispatch: once the old supervisor is gone the same ready job is started exactly once" {
    _bishop 10 10
    _fake_run_job
    make_job dup-2 ready ".repo_path = \"$MOTHER_ROOT\""
    _live_supervisor dup-2
    local sup=$LIVE_SUP_PID
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick >/dev/null 2>&1 || true
    [ ! -s "$MOTHER_ROOT/run-job-calls" ]

    kill "$sup"; wait "$sup" 2>/dev/null || true
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick >/dev/null 2>&1 || true
    local i=0; while [ ! -s "$MOTHER_ROOT/run-job-calls" ] && [ "$i" -lt 50 ]; do sleep 0.1; i=$((i+1)); done
    [ "$(grep -c . "$MOTHER_ROOT/run-job-calls")" = "1" ]
}

# ---------------------------------------------------------------------------
# quota_gate_off attention item
# ---------------------------------------------------------------------------

@test "attention: the gate switched off raises quota_gate_off with the switch's changed_at as since" {
    _bishop 10 10
    mother quota off >/dev/null 2>&1
    run _lib mother_attention_write
    [ "$status" -eq 0 ]

    [ "$(_gate_items | jq length)" = "1" ]
    local item; item=$(_gate_items | jq -c '.[0]')
    [ "$(echo "$item" | jq -r .reason)" = "quota_gate_off" ]
    [ "$(echo "$item" | jq -r .since)" = "$(_qf .changed_at)" ]
    [ "$(echo "$item" | jq -r .detail.acked)" = "false" ]
    [ "$(echo "$item" | jq -r .detail.since)" = "$(_qf .changed_at)" ]
    [ "$(echo "$item" | jq -r .detail.state)" = "off" ]
    [ "$(_gate_items | jq 'all(.[]; has("kind") and has("job_id") and has("repo") and has("branch") and has("reason") and has("since") and has("detail") and has("hint"))')" = "true" ]
    [ -n "$(echo "$item" | jq -r .hint)" ]
}

@test "attention: off_until_reset raises quota_gate_off too, naming the state" {
    _bishop 10 10
    mother quota off-until-reset >/dev/null 2>&1
    _lib mother_attention_write
    [ "$(_gate_items | jq length)" = "1" ]
    [ "$(_gate_items | jq -r '.[0].detail.state')" = "off_until_reset" ]
}

@test "attention: the gate on raises no quota_gate_off, and switching it back on clears the item" {
    _bishop 10 10
    _lib mother_attention_write
    [ "$(_gate_items | jq length)" = "0" ]

    mother quota off >/dev/null 2>&1
    _lib mother_attention_write
    [ "$(_gate_items | jq length)" = "1" ]

    mother quota on >/dev/null 2>&1
    _lib mother_attention_write
    [ "$(_gate_items | jq length)" = "0" ]
}

@test "attention: an off_until_reset whose until has already passed is not raised (the gate is effectively on)" {
    _bishop 10 10
    _gate_file off_until_reset "$(( $(_now) - 30 ))"
    _lib mother_attention_write
    [ "$(_gate_items | jq length)" = "0" ]
}

@test "attention: the item shows in mother status needs_attention" {
    _bishop 10 10
    mother quota off >/dev/null 2>&1
    _lib mother_attention_write
    run mother status --format json
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | jq '[.needs_attention[] | select(.kind == "quota_gate_off")] | length')" = "1" ]
}

@test "ack: 'mother ack quota quota_gate_off' acknowledges it, keyed to the switch's changed_at, and it stops counting" {
    _bishop 10 10
    mother quota off >/dev/null 2>&1
    _lib mother_attention_write
    local since; since=$(_gate_items | jq -r '.[0].since')

    run mother ack quota quota_gate_off
    [ "$status" -eq 0 ]
    [ "$(jq -r '.quota_gate_off.since' "$MOTHER_ROOT/acks/_quota.json")" = "$since" ]
    [ "$(_gate_items | jq -r '.[0].detail.acked')" = "true" ]
    [ "$(jq '[.[] | select(.detail.acked != true)] | length' "$MOTHER_ROOT/attention.json")" = "0" ]
}

@test "ack: acknowledging quota_gate_off lapses when the switch changes state (off -> off_until_reset)" {
    _bishop 10 10
    mother quota off >/dev/null 2>&1
    _lib mother_attention_write
    mother ack quota quota_gate_off >/dev/null 2>&1
    [ "$(_gate_items | jq -r '.[0].detail.acked')" = "true" ]

    sleep 1
    mother quota off-until-reset >/dev/null 2>&1
    _lib mother_attention_write
    [ "$(_gate_items | jq length)" = "1" ]
    [ "$(_gate_items | jq -r '.[0].detail.state')" = "off_until_reset" ]
    [ "$(_gate_items | jq -r '.[0].detail.acked')" = "false" ]
}

@test "ack: acknowledging quota_gate_off while the gate is on fails as not raised" {
    _bishop 10 10
    _lib mother_attention_write
    run mother ack quota quota_gate_off
    [ "$status" -ne 0 ]
    [[ "$output" == *"not raised"* ]]
    [ ! -e "$MOTHER_ROOT/acks/_quota.json" ]
}

@test "ack: a worker cannot acknowledge quota_gate_off" {
    _bishop 10 10
    mother quota off >/dev/null 2>&1
    _lib mother_attention_write
    MOTHER_JOB_ID=some-job run mother ack quota quota_gate_off
    [ "$status" -ne 0 ]
    [ ! -e "$MOTHER_ROOT/acks/_quota.json" ]
}

# ---------------------------------------------------------------------------
# Stale quota-gate lock
# ---------------------------------------------------------------------------

_dead_pid() { bash -c 'echo $$'; }

@test "lock: a lockdir left by a dead owner is taken over and 'mother quota off' succeeds quickly" {
    local lockdir="$GATE_FILE.lockdir"
    mkdir "$lockdir"; _dead_pid > "$lockdir/owner"
    local t0; t0=$(_now)
    run mother quota off
    [ "$status" -eq 0 ]
    [ $(( $(_now) - t0 )) -lt 5 ]
    [ "$(_qf .gate)" = "off" ]
    [ ! -d "$lockdir" ]
}

@test "lock: a dead owner's lockdir does not block turning the gate back on either" {
    mother quota off >/dev/null 2>&1
    local lockdir="$GATE_FILE.lockdir"
    mkdir "$lockdir"; _dead_pid > "$lockdir/owner"
    local t0; t0=$(_now)
    run mother quota on
    [ "$status" -eq 0 ]
    [ $(( $(_now) - t0 )) -lt 5 ]
    [ "$(_qf .gate)" = "on" ]
}

@test "lock: a lockdir with no owner file and an mtime older than 30s is taken over" {
    local lockdir="$GATE_FILE.lockdir"
    mkdir "$lockdir"; _age "$lockdir" 120
    local t0; t0=$(_now)
    run mother quota off
    [ "$status" -eq 0 ]
    [ $(( $(_now) - t0 )) -lt 5 ]
    [ "$(_qf .gate)" = "off" ]
}

@test "lock: a fresh lock held by a live owner is not taken over; the daemon path fails closed fast, writes nothing and does not hang" {
    _bishop 10 10
    _gate_file off_until_reset "$(( $(_now) - 5 ))"
    cp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    local lockdir="$GATE_FILE.lockdir"
    sleep 300 >/dev/null 2>&1 3>&- &
    local owner=$!; _BG_PIDS="${_BG_PIDS:-} $owner"
    mkdir "$lockdir"; echo "$owner" > "$lockdir/owner"

    local t0; t0=$(_now)
    run _lib _quota_gate_open
    [ "$status" -eq 1 ]
    [ $(( $(_now) - t0 )) -lt 4 ]
    cmp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    [ "$(_audit_lines)" = "0" ]
    [ -d "$lockdir" ]
    [ "$(cat "$lockdir/owner")" = "$owner" ]
}

@test "lock: a fresh lockdir that has no owner file yet is not taken over either" {
    _bishop 10 10
    _gate_file off_until_reset "$(( $(_now) - 5 ))"
    cp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    mkdir "$GATE_FILE.lockdir"

    local t0; t0=$(_now)
    run _lib _quota_gate_open
    [ "$status" -eq 1 ]
    [ $(( $(_now) - t0 )) -lt 4 ]
    cmp "$GATE_FILE" "$MOTHER_ROOT/gate.before"
    [ "$(_audit_lines)" = "0" ]
    [ -d "$GATE_FILE.lockdir" ]
}

# ---------------------------------------------------------------------------
# Release reasons and future-dated feeds
# ---------------------------------------------------------------------------

@test "parked: a job released because the gate was switched off is told so, and the event reason is gate_off" {
    _bishop 10 100
    _park_job rel-gate quota_7d "$(( $(_now) + 259200 ))"
    mother quota off >/dev/null 2>&1
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state rel-gate)" = "ready" ]

    local ans; ans=$(jq -r .pending_answer "$JOBS_DIR/rel-gate.json")
    [[ "$ans" == *"switched off"* ]]
    [[ "$ans" != *"window has reset"* ]]
    [ "$(jq -rs '[.[] | select(.kind == "auto_resumed")] | last | .detail.reason' "$EVENTS_DIR/rel-gate.jsonl")" = "gate_off" ]
}

@test "parked: a job released because its window reset keeps the window-reset text, and the event reason is window_reset" {
    _bishop 10 10
    _park_job rel-clock quota_5h "$(( $(_now) - 10 ))"
    mother-runner --auto-resume-tick >/dev/null 2>&1 || true
    [ "$(_job_state rel-clock)" = "ready" ]

    local ans; ans=$(jq -r .pending_answer "$JOBS_DIR/rel-clock.json")
    [[ "$ans" == *"Quota window has reset"* ]]
    [[ "$ans" != *"switched off"* ]]
    [ "$(jq -rs '[.[] | select(.kind == "auto_resumed")] | last | .detail.reason' "$EVENTS_DIR/rel-clock.jsonl")" = "window_reset" ]
}

@test "feed: a Bishop file whose mtime is in the future is unusable; the cache is used instead" {
    _bishop 95 95
    _age "$MOTHER_BISHOP_POSTURE_FILE" -3600
    _cache 5 6
    [ "$(_qf .source)" = "cache" ]
    [ "$(_qf .windows.five_hour.used_pct)" = "5" ]
}

@test "feed: future-dated Bishop and cache files with nothing else mean no feed: source none, stale true, and the gate lets work through" {
    _bishop 100 100
    _cache 100 100
    _age "$MOTHER_BISHOP_POSTURE_FILE" -3600
    _age "$MOTHER_RATE_LIMIT_CACHE" -3600
    [ "$(_qf .source)" = "none" ]
    [ "$(_qf .stale)" = "true" ]
    run _lib _quota_check
    [ "$status" -eq 0 ]
}
