#!/usr/bin/env bats
# progress_flags.bats — HC-11 "progress flags, statusline/switcher surfaces".
#
# Contract under test (CLAUDE.md "Progress indicator", "Typed attention reasons"):
#
#   mother-usage progress-tick raises/clears observer-owned flags in
#   $MOTHER_ROOT/progress/<id>.json `.flags[]` = [{reason, since, detail}]
#     progress_stalled  pct has not increased for longer than max(600s, stage p90 active
#                       duration [repo calibration, else fleet]); detail {stage, stuck_s}
#     burn_ahead        max_cost_usd set, cost_frac >= 0.5 and cost_frac >= 2 * pct/100;
#                       detail {cost_frac, progress_frac}
#   Raise emits `attention_raised {reason}`, clear emits `attention_cleared {reason}`,
#   each once per transition. Flags never touch job JSON.
#
#   Surfaces: `mother status <id>`, `mother list` (marker ⚠stalled / ⚠burn, "(acked)"),
#   `--format json` attention_reasons always; the needs_attention list (job_attention
#   items) only when MOTHER_PROGRESS_FLAGS_ATTENTION=1.
#   Statusline: sidecar "${MOTHER_STATUSLINE_CACHE}.progress" and `≈` in mother_segment.
#   Switcher: running/awaiting rows carry the pct.
#
# Time is driven by `--now`; T0 is the fixed "now" (see progress.bats).

load 'test_helper'

T0=1792238400   # 2026-10-17T12:00:00Z

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    unset MOTHER_PROGRESS_ENABLED MOTHER_PROGRESS_NOW MOTHER_PROGRESS_INTERVAL \
          MOTHER_PROGRESS_CALIBRATE_INTERVAL MOTHER_PROGRESS_FLAGS_ATTENTION
    JOB_REPO="Carefeed/big-repo"
    PROG_DIR="$MOTHER_ROOT/progress"
    CAL="$RUNNER_DIR/progress-calibration.json"
    SL_CACHE="$MOTHER_ROOT/sl-cache"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers (same shapes as progress.bats)
# ---------------------------------------------------------------------------

iso_at() {
    local e=$((T0 + $1))
    date -u -r "$e" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "@$e" +%Y-%m-%dT%H:%M:%S.000Z
}

ev() {
    local id="$1" off="$2" kind="$3" d="${4:-}"
    [ -n "$d" ] || d='{}'
    jq -nc --arg ts "$(iso_at "$off")" --arg kind "$kind" --argjson d "$d" \
        '{ts: $ts, kind: $kind, detail: $d}' >> "$EVENTS_DIR/$id.jsonl"
}

mkjob() {
    local id="$1" state="$2" extra="${3:-.}"
    make_job "$id" "$state" \
        ".repo = \"$JOB_REPO\" | .created_at = \"2026-10-17T11:00:00.000Z\" | $extra"
}

jobset() {
    local f="$JOBS_DIR/$1.json"
    jq -c "$2" "$f" > "$f.edit" && mv "$f.edit" "$f"
}

# A running job with 600 active build seconds at T0.
build_job() {
    local id="$1" extra="${2:-.}"
    mkjob "$id" running "$extra"
    ev "$id" -700 queued '{"title":"t"}'
    ev "$id" -660 ready
    ev "$id" -600 running
    ev "$id" -600 worker_spawned '{"session_id":"s1"}'
}

tick_ok() {
    run mother-usage progress-tick --root "$MOTHER_ROOT" --now "$(iso_at "$1")"
    if [ "$status" -ne 0 ]; then
        echo "progress-tick failed (status $status): $output" >&2
        return 1
    fi
}

pj() { jq -r "$2" "$PROG_DIR/$1.json"; }

count_kind() {
    [ -f "$EVENTS_DIR/$1.jsonl" ] || { echo 0; return; }
    jq -s --arg k "$2" '[.[] | select(.kind == $k)] | length' "$EVENTS_DIR/$1.jsonl"
}

# Count of attention_raised / attention_cleared events for one reason.
count_att() {  # <id> <raised|cleared> <reason>
    [ -f "$EVENTS_DIR/$1.jsonl" ] || { echo 0; return; }
    jq -s --arg k "attention_$2" --arg r "$3" \
        '[.[] | select(.kind == $k and .detail.reason == $r)] | length' "$EVENTS_DIR/$1.jsonl"
}

flag_count() {  # <id> <reason> -> number of such flags in the progress file
    jq --arg r "$2" '[(.flags // [])[] | select(.reason == $r)] | length' "$PROG_DIR/$1.json"
}

scope_json() {
    local n="$1" bs="$2" bm="$3" p10="$4" p90="$5" sn="${6:-50}"
    jq -nc --argjson n "$n" --argjson bs "$bs" --argjson bm "$bm" \
        --argjson p10 "$p10" --argjson p90 "$p90" --argjson sn "$sn" '
        ((1 - $bs) / 0.28) as $k
        | def st(m; share): {n: $n, median_s: m, p90_s: (m * 2), share: share};
        {n: $n,
         stages: {build: st($bm; $bs), rework: st(600; 0.17 * $k), gates: st(120; 0.03 * $k),
                  review: st(300; 0.06 * $k), present: st(60; 0.02 * $k)},
         remaining_ratio: {
            start: (["build", "rework", "gates", "review", "present"]
                    | map({key: ., value: {n: $sn, p10: $p10, p50: (($p10 + $p90) / 2), p90: $p90}})
                    | from_entries),
            half: {n: 50, p10: 0.4, p50: 1.0, p90: 1.7}}}'
}

# Calibration whose build stage has median 1200s and the given p90_s.
# Usage: cal_p90 <p90_s> [fleet-only]
cal_p90() {
    local fleet repo
    fleet=$(scope_json 300 0.72 1200 0.8 3.0 | jq -c --argjson p "$1" '.stages.build.p90_s = $p')
    repo=$(scope_json 339 0.72 1200 0.5 2.0 | jq -c --argjson p "$1" '.stages.build.p90_s = $p')
    mkdir -p "$RUNNER_DIR"
    if [ "${2:-}" = fleet-only ]; then
        jq -n --argjson f "$fleet" '{fitted_at:"2026-10-16T00:00:00.000Z", min_repo_n:20, fleet:$f, repos:{}}' > "$CAL"
    else
        jq -n --argjson f "$fleet" --argjson r "$repo" \
            '{fitted_at:"2026-10-16T00:00:00.000Z", min_repo_n:20, fleet:$f, repos:{"Carefeed/big-repo":$r}}' > "$CAL"
    fi
}

# A build job whose pct reaches its 65 plateau (90% of the stage median, active
# 1080s) at the tick at offset 480 and then never moves. Ticks before: 0, 300.
#   active at offset t = 600 + t.  Plateau first visible at tick 480.
plateau_job() {
    build_job "$1" "${2:-.}"
    tick_ok 0
    tick_ok 300
    tick_ok 480
}

# Move a plateaued job on: gates start, which raises pct.
advance_job() {  # <id> <offset-of-gates_started>
    ev "$1" "$2" final_result_observed
    ev "$1" "$2" gates_started '{"attempt":1,"max_attempts":3,"head_sha":"abc1234","mode":"enforce","posture":"normal","gates":["lint"]}'
}

jobs_sum() { (cd "$JOBS_DIR" && cksum ./*.json); }

# =============================================================================
# (a) progress_stalled
# =============================================================================

@test "stalled: no flag until pct has been flat for more than the 10 minute floor, then one flag with stage and stuck_s" {
    cal_p90 300                      # p90 below the floor -> 600s threshold applies
    plateau_job s1
    [ "$(pj s1 .pct)" = "65" ]
    [ "$(flag_count s1 progress_stalled)" = "0" ]
    tick_ok 980                      # flat for ~500s
    [ "$(flag_count s1 progress_stalled)" = "0" ]
    [ "$(count_att s1 raised progress_stalled)" = "0" ]
    tick_ok 1180                     # flat for ~700s
    [ "$(flag_count s1 progress_stalled)" = "1" ]
    [ "$(pj s1 '.flags[] | select(.reason == "progress_stalled") | .detail.stage')" = "build" ]
    stuck=$(pj s1 '.flags[] | select(.reason == "progress_stalled") | .detail.stuck_s')
    awk -v s="$stuck" 'BEGIN { exit !(s > 600 && s < 900) }'
    [ -n "$(pj s1 '.flags[] | select(.reason == "progress_stalled") | .since')" ]
    [ "$(pj s1 '.flags[] | select(.reason == "progress_stalled") | .since')" != "null" ]
    [ "$(count_att s1 raised progress_stalled)" = "1" ]
}

@test "stalled: the threshold is the repo's stage p90 when that is above the floor" {
    cal_p90 1800
    plateau_job s2
    tick_ok 1180                     # ~700s flat: over the floor, under p90
    [ "$(flag_count s2 progress_stalled)" = "0" ]
    tick_ok 2180                     # ~1700s flat
    [ "$(flag_count s2 progress_stalled)" = "0" ]
    tick_ok 2400                     # ~1900s flat
    [ "$(flag_count s2 progress_stalled)" = "1" ]
}

@test "stalled: a job in a repo without calibration of its own uses the fleet stage p90" {
    cal_p90 1800 fleet-only
    plateau_job s3
    tick_ok 1180
    [ "$(flag_count s3 progress_stalled)" = "0" ]
    tick_ok 2400
    [ "$(flag_count s3 progress_stalled)" = "1" ]
}

@test "stalled: repeated ticks while stalled raise once; a later pct increase clears it once" {
    cal_p90 300
    plateau_job s4
    tick_ok 1180
    tick_ok 1200
    tick_ok 1220
    [ "$(count_att s4 raised progress_stalled)" = "1" ]
    [ "$(flag_count s4 progress_stalled)" = "1" ]
    [ "$(count_att s4 cleared progress_stalled)" = "0" ]

    advance_job s4 1300
    tick_ok 1310
    [ "$(pj s4 .pct)" -gt 65 ]
    [ "$(flag_count s4 progress_stalled)" = "0" ]
    [ "$(count_att s4 cleared progress_stalled)" = "1" ]
    tick_ok 1330
    tick_ok 1350
    [ "$(count_att s4 cleared progress_stalled)" = "1" ]
    [ "$(count_att s4 raised progress_stalled)" = "1" ]
}

# =============================================================================
# (b) paused time never stalls
# =============================================================================

@test "an awaiting job never raises progress_stalled however long it waits" {
    cal_p90 300
    plateau_job w1
    ev w1 500 awaiting_input '{"question":"q?","paused_reason":"gate_hold"}'
    jobset w1 '.state = "awaiting" | .paused_reason = "gate_hold"'
    tick_ok 520
    tick_ok 20000
    tick_ok 40000
    [ "$(flag_count w1 progress_stalled)" = "0" ]
    [ "$(count_att w1 raised progress_stalled)" = "0" ]
}

# =============================================================================
# (c) burn_ahead
# =============================================================================

# Running job with exactly 500 active build seconds (pct 30 under default calibration).
burn_job() {  # <id> <live_cost> [max_cost]
    mkjob "$1" running ".max_cost_usd = ${3:-10} | .live_cost_usd = $2"
    ev "$1" -600 queued
    ev "$1" -500 worker_spawned
}

@test "burn_ahead: 80% of the cap spent at 30% progress raises a flag with cost_frac and progress_frac" {
    burn_job b1 8
    tick_ok 0
    [ "$(pj b1 .pct)" = "30" ]
    [ "$(flag_count b1 burn_ahead)" = "1" ]
    cf=$(pj b1 '.flags[] | select(.reason == "burn_ahead") | .detail.cost_frac')
    pf=$(pj b1 '.flags[] | select(.reason == "burn_ahead") | .detail.progress_frac')
    awk -v c="$cf" 'BEGIN { exit !(c > 0.79 && c < 0.81) }'
    awk -v p="$pf" 'BEGIN { exit !(p > 0.29 && p < 0.31) }'
    [ "$(count_att b1 raised burn_ahead)" = "1" ]
    tick_ok 10
    [ "$(count_att b1 raised burn_ahead)" = "1" ]
}

@test "burn_ahead: below 50% of the cap, or spend not at least twice the progress, raises nothing" {
    burn_job b2 4                    # cost_frac 0.4 < 0.5
    burn_job b3 5.5                  # cost_frac 0.55 >= 0.5 but < 2 * 0.30
    mkjob b4 running ".live_cost_usd = 8"   # no cap at all
    ev b4 -500 worker_spawned
    tick_ok 0
    for id in b2 b3 b4; do
        [ "$(flag_count $id burn_ahead)" = "0" ]
        [ "$(count_att $id raised burn_ahead)" = "0" ]
    done
}

@test "burn_ahead: clears and reports it when progress catches up with spend" {
    burn_job b5 8
    tick_ok 0
    [ "$(flag_count b5 burn_ahead)" = "1" ]
    jobset b5 '.live_cost_usd = 3'
    tick_ok 30
    [ "$(flag_count b5 burn_ahead)" = "0" ]
    [ "$(count_att b5 cleared burn_ahead)" = "1" ]
}

# =============================================================================
# (d) surfaces and MOTHER_PROGRESS_FLAGS_ATTENTION
# =============================================================================

mk_stalled() {   # a stalled job named <id>
    cal_p90 300
    plateau_job "$1"
    tick_ok 1180
    [ "$(flag_count "$1" progress_stalled)" = "1" ]
}

_job_attention_items() {  # needs_attention job_attention items from status json
    mother status --format json | jq -c '[.needs_attention[] | select(.kind == "job_attention")]'
}

@test "flags default off: shown in status <id>, list marker and attention_reasons, but not in needs_attention" {
    mk_stalled d1
    mkjob d2 running ".max_cost_usd = 10 | .live_cost_usd = 8"   # 500 active seconds at the tick below
    ev d2 600 queued
    ev d2 681 worker_spawned
    tick_ok 1181
    run mother status d1
    [ "$status" -eq 0 ]
    [[ "$output" == *stall* ]]
    run mother status d2
    [[ "$output" == *burn* ]]

    run mother list
    [[ "$(echo "$output" | grep -E '^d1 ')" == *"⚠stalled"* ]]
    [[ "$(echo "$output" | grep -E '^d2 ')" == *"⚠burn"* ]]

    [ "$(mother list --format json | jq -r '.[] | select(.id=="d1") | .attention_reasons[0].reason')" = "progress_stalled" ]
    [ "$(mother status d2 --format json | jq -r '.job.attention_reasons[0].reason')" = "burn_ahead" ]
    [ "$(_job_attention_items)" = "[]" ]
}

@test "MOTHER_PROGRESS_FLAGS_ATTENTION=1: flags are job_attention items; ack hides them until they clear and return" {
    mk_stalled e1
    export MOTHER_PROGRESS_FLAGS_ATTENTION=1
    items=$(_job_attention_items)
    [ "$(echo "$items" | jq 'length')" = "1" ]
    [ "$(echo "$items" | jq -r '.[0].reason')" = "progress_stalled" ]
    [ "$(echo "$items" | jq -r '.[0].job_id')" = "e1" ]
    [ "$(echo "$items" | jq -r '.[0].detail.acked')" = "false" ]

    run mother ack e1 progress_stalled
    [ "$status" -eq 0 ]
    [ "$(_job_attention_items | jq -r '.[0].detail.acked')" = "true" ]
    [[ "$(mother list | grep -E '^e1 ')" == *"(acked)"* ]]
    [ "$(mother status e1 --format json | jq -r '.job.attention_reasons[0].acked')" = "true" ]

    # the condition clears and comes back: a new `since` lapses the ack
    jq '.flags[0].since = "2026-10-17T13:30:00.000Z"' "$PROG_DIR/e1.json" > "$PROG_DIR/e1.json.edit" \
        && mv "$PROG_DIR/e1.json.edit" "$PROG_DIR/e1.json"
    [ "$(_job_attention_items | jq -r '.[0].detail.acked')" = "false" ]
}

@test "ack of a progress flag works through the CLI and is audited" {
    mk_stalled e2
    run mother ack e2 progress_stalled
    [ "$status" -eq 0 ]
    [ "$(count_kind e2 attention_acked)" = "1" ]
}

@test "job-owned reasons stay in needs_attention even with MOTHER_PROGRESS_FLAGS_ATTENTION off" {
    mk_stalled f1
    jobset f1 '.attention = [{reason: "gates_incomplete", since: "2026-10-17T12:10:00.000Z"}]'
    items=$(_job_attention_items)
    [ "$(echo "$items" | jq -c '[.[].reason]')" = '["gates_incomplete"]' ]
    [ "$(mother status f1 --format json | jq -c '[.job.attention_reasons[].reason] | sort')" = '["gates_incomplete","progress_stalled"]' ]
}

# =============================================================================
# (e) observer only
# =============================================================================

@test "raising and clearing flags never changes job files and appends only attention_* / progress_* events" {
    cal_p90 300
    plateau_job o1
    tick_ok 980
    before_sum=$(jobs_sum)
    before_lines=$(wc -l < "$EVENTS_DIR/o1.jsonl")
    tick_ok 1180                     # raise
    advance_job o1 1300
    before_lines=$(wc -l < "$EVENTS_DIR/o1.jsonl")   # test-made events excluded
    tick_ok 1310                     # clear
    [ "$(jobs_sum)" = "$before_sum" ]
    [ "$(count_att o1 raised progress_stalled)" = "1" ]
    [ "$(count_att o1 cleared progress_stalled)" = "1" ]
    new_kinds=$(tail -n +$((before_lines + 1)) "$EVENTS_DIR/o1.jsonl" | jq -r .kind | sort -u)
    for k in $new_kinds; do
        case "$k" in attention_*|progress_*) ;; *) echo "unexpected event $k" >&2; return 1 ;; esac
    done
    [ "$(jq 'has("flags") or has("progress") or has("attention")' "$JOBS_DIR/o1.json")" = "false" ]
}

# =============================================================================
# (f) statusline
# =============================================================================

_seg() {
    bash -c "export MOTHER_ROOT='$MOTHER_ROOT' MOTHER_STATUSLINE_TTL=99999 MOTHER_STATUSLINE_CACHE='$SL_CACHE'
             source '$_PLUGIN_DIR/statusline/segment.sh'
             $1" 2>/dev/null
}

# Hand-written progress file: <id> <pct> <hi_s> <eta label>
mkprog() {
    mkdir -p "$PROG_DIR"
    jq -nc --argjson pct "$2" --argjson hi "$3" --arg el "$4" \
        '{v:1, pct:$pct, label:("≈\($pct)% · ETA \($el)"), stage:"build",
          eta:{lo_s:($hi - 300), hi_s:$hi, label:$el}}' > "$PROG_DIR/$1.json"
}

@test "statusline: cache keeps exactly six colon-separated fields" {
    mkjob sa running
    mkprog sa 60 1500 "~25m"
    _seg "mother_statusline_refresh '$SL_CACHE'"
    [ "$(tr -d '\n' < "$SL_CACHE" | awk -F: '{print NF}')" = "6" ]
    [ "$(wc -l < "$SL_CACHE" | tr -d ' ')" = "1" ]
}

@test "statusline: sidecar names the running job with the soonest ETA and its label" {
    mkjob sa running; mkprog sa 60 1500 "~25m"
    mkjob sb running; mkprog sb 30 3000 "~50m"
    mkjob sc awaiting; mkprog sc 80 100 "~2m"       # not running: never chosen
    mkjob sd running                                  # no progress file
    _seg "mother_statusline_refresh '$SL_CACHE'"
    [ -f "$SL_CACHE.progress" ]
    side=$(cat "$SL_CACHE.progress")
    [[ "$side" == "sa"$'\t'* ]]
    label="${side#*$'\t'}"
    [[ "$label" == *"60%"* ]]
    [[ "$label" == *"~25m"* ]]
    [[ "$label" == *"≈"* ]]
}

@test "statusline: sidecar is empty when no running job has an ETA" {
    mkjob sa awaiting; mkprog sa 60 1500 "~25m"
    mkjob sb running
    _seg "mother_statusline_refresh '$SL_CACHE'"
    [ ! -s "$SL_CACHE.progress" ]
}

@test "statusline: MOTHER_PROGRESS_ENABLED=0 writes no sidecar" {
    mkjob sa running; mkprog sa 60 1500 "~25m"
    MOTHER_PROGRESS_ENABLED=0 _seg "mother_statusline_refresh '$SL_CACHE'"
    [ ! -e "$SL_CACHE.progress" ]
    [ "$(tr -d '\n' < "$SL_CACHE" | awk -F: '{print NF}')" = "6" ]
}

@test "statusline: the segment shows the sidecar label after the running count" {
    printf '%s\n' "2:0:0:0:0:0" > "$SL_CACHE"
    printf 'sa\t%s\n' "≈60% ~25m" > "$SL_CACHE.progress"
    out=$(_seg "mother_segment")
    plain=$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')
    [[ "$plain" == *"▶2"* ]]
    [[ "$plain" == *"≈60% ~25m"* ]]
}

@test "statusline: the label in the segment is cut to 24 characters" {
    printf '%s\n' "1:0:0:0:0:0" > "$SL_CACHE"
    printf 'sa\t%s\n' "60%-abcdefghijklmnopqrstuvwxyz0123456789" > "$SL_CACHE.progress"
    out=$(_seg "mother_segment")
    plain=$(printf '%s' "$out" | sed $'s/\x1b\\[[0-9;]*m//g')
    [[ "$plain" == *"60%-abcdefghijklmnopqrst"* ]]        # first 24 chars
    [[ "$plain" != *"60%-abcdefghijklmnopqrstu"* ]]       # not the 25th
}

@test "statusline: no sidecar, no ≈ in the segment" {
    printf '%s\n' "1:0:0:0:0:0" > "$SL_CACHE"
    out=$(_seg "mother_segment")
    [[ "$out" != *"≈"* ]]
    [[ "$out" == *"▶1"* ]]
}

# =============================================================================
# (g) switcher rows
# =============================================================================

@test "switcher rows: running and awaiting jobs show their pct, other states stay blank" {
    command -v fzf >/dev/null || skip "mother-switcher needs fzf"
    mkjob r1 running;  mkprog r1 60 1500 "~25m"
    mkjob a1 awaiting; mkprog a1 45 1500 "~25m"
    mkjob s1 succeeded; mkprog s1 100 0 "~0m"
    mkjob q1 queued
    run mother-switcher --emit-rows
    [ "$status" -eq 0 ]
    [[ "$(echo "$output" | grep -E '^r1'$'\t')" == *"60%"* ]]
    [[ "$(echo "$output" | grep -E '^a1'$'\t')" == *"45%"* ]]
    [[ "$(echo "$output" | grep -E '^s1'$'\t')" != *"%"* ]]
    [[ "$(echo "$output" | grep -E '^q1'$'\t')" != *"%"* ]]
}
