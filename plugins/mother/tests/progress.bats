#!/usr/bin/env bats
# progress.bats — HC-09 "progress indicator core".
#
# Contract under test (docs/design.md "Headless crew contract", `.progress`):
#
#   mother-usage calibrate      --root R              -> $R/runner/progress-calibration.json
#   mother-usage progress-tick  --root R [--now ISO]  -> $R/progress/<id>.json  (+ progress_* events)
#   mother-runner --progress-tick                      one runner-side pass (interval gate, calibrate-when-stale)
#   mother list / mother status                        render the label / merge `.progress` (observer only)
#
# Progress is an OBSERVER-ONLY estimate: it is never written into job JSON, it
# is switched off wholesale by MOTHER_PROGRESS_ENABLED=0, and a tick appends
# nothing but `progress_updated` / `progress_half` events.
#
# Test time control: every tick passes `--now <ISO-ms-Z>`; all time math uses
# it. T0 below is the fixed "now" most tests build their event timelines
# around, via `ev <id> <offset-seconds> <kind> [detail]`.
#
# Exact-number tests hand-write the calibration file (write_cal) so the
# expected pct / ETA are derivable from the spec by hand:
#   pct = 5 * round(raw / 5),   raw (percent) = 100 * [ sum(share of stages earlier in the order
#         build < rework < gates < review < present) + share(current) * min(stage_active / stage_median, 0.9) ]
# Without calibration: shares build .72 rework .17 gates .03 review .06 present .02,
# medians build 1200s rework 600 gates 120 review 300 present 60.
#
# fixtures/progress/make_archive.sh builds the synthetic finished-job history
# (and its hand-derived expectations) used by the calibrate tests.

load 'test_helper'

FIX="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/progress"
T0=1792238400   # 2026-10-17T12:00:00Z

GATES_STARTED='{"attempt":1,"max_attempts":3,"head_sha":"abc1234","mode":"enforce","posture":"normal","gates":["lint","unit","static"]}'
G_ALL_PASS='.gates = {status:"running",attempt:1,max_attempts:3,results:[{name:"lint",result:"passed",blocking:true},{name:"unit",result:"passed",blocking:true},{name:"static",result:"passed",blocking:true}],not_run:[]}'

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    unset MOTHER_PROGRESS_ENABLED MOTHER_PROGRESS_NOW MOTHER_PROGRESS_INTERVAL \
          MOTHER_PROGRESS_CALIBRATE_INTERVAL
    JOB_REPO="Carefeed/big-repo"
    PROG_DIR="$MOTHER_ROOT/progress"
    CAL="$RUNNER_DIR/progress-calibration.json"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# ISO-8601 ms-Z timestamp T0 + <offset seconds>.
iso_at() {
    local e=$((T0 + $1))
    date -u -r "$e" +%Y-%m-%dT%H:%M:%S.000Z 2>/dev/null \
        || date -u -d "@$e" +%Y-%m-%dT%H:%M:%S.000Z
}

# Append one event line {ts,kind,detail} to events/<id>.jsonl.
# Usage: ev <id> <offset-seconds> <kind> [detail-json]
ev() {
    local id="$1" off="$2" kind="$3" d="${4:-}"
    [ -n "$d" ] || d='{}'
    jq -nc --arg ts "$(iso_at "$off")" --arg kind "$kind" --argjson d "$d" \
        '{ts: $ts, kind: $kind, detail: $d}' >> "$EVENTS_DIR/$id.jsonl"
}

# Write a job file. Usage: mkjob <id> <state> [extra-jq-filter]
mkjob() {
    local id="$1" state="$2" extra="${3:-.}"
    make_job "$id" "$state" \
        ".repo = \"$JOB_REPO\" | .created_at = \"2026-10-17T11:00:00.000Z\" | $extra"
}

# Edit a job file in place (test-side edit; never done inside a tick).
jobset() {
    local f="$JOBS_DIR/$1.json"
    jq -c "$2" "$f" > "$f.edit" && mv "$f.edit" "$f"
}

# A running job whose worker has been building for 600 active seconds at T0
# (queue wait before it is deliberately longer and must not count).
# Usage: build_job <id> [extra-jq-filter]
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

# jq over a job's progress file.   Usage: pj <id> <jq-filter>
pj() { jq -r "$2" "$PROG_DIR/$1.json"; }

count_kind() {
    [ -f "$EVENTS_DIR/$1.jsonl" ] || { echo 0; return; }
    jq -s --arg k "$2" '[.[] | select(.kind == $k)] | length' "$EVENTS_DIR/$1.jsonl"
}

# |a - b| <= tol.   Usage: close <a> <b> [tol]
close() {
    [ "$1" != "null" ] && [ -n "$1" ] || return 1
    awk -v a="$1" -v b="$2" -v t="${3:-0.5}" 'BEGIN { d = a - b; if (d < 0) d = -d; exit !(d <= t) }'
}

# A complete calibration scope.
# Usage: scope_json <n> <build_share> <build_median_s> <start_p10> <start_p90> [start_n=50]
#   The other four shares are scaled so shares sum to 1. remaining_ratio.start is
#   given for every stage with the same p10/p90; remaining_ratio.half is
#   {n:50, p10:0.4, p50:1.0, p90:1.7}.
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

# Hand-write the calibration file.
# Usage: write_cal <fleet-scope-json> [<repo-name> <repo-scope-json>]
write_cal() {
    mkdir -p "$RUNNER_DIR"
    jq -n --argjson fleet "$1" --arg repo "${2:-}" --argjson rs "${3:-null}" '
        {fitted_at: "2026-10-16T00:00:00.000Z", min_repo_n: 20, fleet: $fleet,
         repos: (if $repo == "" then {} else {($repo): $rs} end)}' > "$CAL"
}

# The standard hand-written calibration used by exact-number tests:
#   Carefeed/big-repo : n=339, build share .80, build median 1200s, start ratios p10 .5 / p90 2.0
#   fleet             : n=300, build share .72, build median 1200s, start ratios p10 .8 / p90 3.0
write_std_cal() {
    write_cal "$(scope_json 300 0.72 1200 0.8 3.0)" \
              "Carefeed/big-repo" "$(scope_json 339 0.80 1200 0.5 2.0)"
}

# Calibration with a single band driven by <p10>/<p90> (start ratios of every
# stage, n=50) for the job's repo, and the label the tick then renders.
# Usage: eta_label_for <p10> <p90>   (job built with E = 600 active seconds)
eta_label_for() {
    # (runs inside $(...), so the sequence number lives in a file, not a variable)
    local n; n=$(cat "$MOTHER_ROOT/eta-seq" 2>/dev/null || echo 0)
    n=$((n + 1)); echo "$n" > "$MOTHER_ROOT/eta-seq"
    local id="eta$n"
    # earlier cases' jobs are irrelevant; keep each tick small
    rm -f "$JOBS_DIR"/eta*.json "$PROG_DIR"/eta*.json
    write_cal "$(scope_json 300 0.72 1200 "$1" "$2")" \
              "Carefeed/big-repo" "$(scope_json 300 0.72 1200 "$1" "$2")"
    build_job "$id"
    tick_ok 0
    pj "$id" '.eta.label'
}

# Run the runner's progress entry point with a hard wall-clock bound so a
# runner that does not know the flag (and would start its daemon loop) cannot
# hang the suite.
run_runner_tick() {
    run perl -e 'alarm 5; exec @ARGV' mother-runner --progress-tick
}

jobs_sum() { (cd "$JOBS_DIR" && cksum ./*.json); }

# =============================================================================
# (a) calibrate
# =============================================================================

@test "calibrate: writes a repo entry only for repos with at least 20 finished jobs, and a fleet entry" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$CAL" ]
    jq -e . "$CAL" >/dev/null
    [ "$(jq -r '.repos | keys | join(",")' "$CAL")" = "Carefeed/big-repo" ]
    [ "$(jq '.min_repo_n' "$CAL")" = "20" ]
    [ "$(jq '.fleet.n' "$CAL")" = "30" ]
    [ "$(jq '.repos["Carefeed/big-repo"].n' "$CAL")" = "25" ]
    jq -e '.fitted_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z$")' "$CAL" >/dev/null
}

@test "calibrate: cancelled jobs and jobs that never ran a worker are not counted" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    # The fixture really contains both (otherwise this test would be vacuous).
    [ "$(jq -r .state "$MOTHER_ROOT"/archive/*/big-cancelled.json)" = "cancelled" ]
    [ "$(jq -r .state "$MOTHER_ROOT"/archive/*/big-noworker.json)" = "failed" ]
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    # 25 counted big-repo jobs, not 27.
    [ "$(jq '.repos["Carefeed/big-repo"].n' "$CAL")" = "25" ]
    [ "$(jq '.fleet.n' "$CAL")" = "30" ]
}

@test "calibrate: stage shares sum to 1 and equal each stage's share of all active time" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    EXP="$MOTHER_ROOT/fixture-expected.json"
    for scope in fleet repo; do
        if [ "$scope" = repo ]; then
            cal_path='.repos["Carefeed/big-repo"]'; exp_key='Carefeed/big-repo'
        else
            cal_path='.fleet'; exp_key='fleet'
        fi
        sum=$(jq "[$cal_path.stages[].share] | add" "$CAL")
        close "$sum" 1 0.001
        for st in build rework gates review present; do
            got=$(jq "$cal_path.stages.$st.share" "$CAL")
            want=$(jq --arg k "$exp_key" ".[\$k].stages.$st.share" "$EXP")
            close "$got" "$want" 0.005
        done
    done
}

@test "calibrate: per-repo stage counts, medians and p90s reflect the fixture durations" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    EXP="$MOTHER_ROOT/fixture-expected.json"
    key='Carefeed/big-repo'
    for st in build rework gates review present; do
        [ "$(jq ".repos[\"$key\"].stages.$st.n" "$CAL")" = "$(jq ".[\"$key\"].stages.$st.n" "$EXP")" ]
        # odd n in every stage, so the median is an actual observation
        close "$(jq ".repos[\"$key\"].stages.$st.median_s" "$CAL")" \
              "$(jq ".[\"$key\"].stages.$st.median_s" "$EXP")" 1
        p90=$(jq ".repos[\"$key\"].stages.$st.p90_s" "$CAL")
        med=$(jq ".repos[\"$key\"].stages.$st.median_s" "$CAL")
        mx=$(jq ".[\"$key\"].stages.$st.max_s" "$EXP")
        awk -v p="$p90" -v m="$med" -v x="$mx" 'BEGIN { exit !(p >= m && p <= x + 1) }'
    done
    # spot-check the headline numbers from the generator's construction
    close "$(jq '.repos["Carefeed/big-repo"].stages.build.median_s' "$CAL")" 960 1
    [ "$(jq '.repos["Carefeed/big-repo"].stages.rework.n' "$CAL")" = "9" ]
}

@test "calibrate: fleet scope covers both repos (n, share, and bounded medians)" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    EXP="$MOTHER_ROOT/fixture-expected.json"
    for st in build gates review present; do
        [ "$(jq ".fleet.stages.$st.n" "$CAL")" = "$(jq ".fleet.stages.$st.n" "$EXP")" ]
        med=$(jq ".fleet.stages.$st.median_s" "$CAL")
        awk -v m="$med" -v lo="$(jq ".fleet.stages.$st.min_s" "$EXP")" -v hi="$(jq ".fleet.stages.$st.max_s" "$EXP")" \
            'BEGIN { exit !(m >= lo && m <= hi) }'
    done
}

@test "calibrate: remaining_ratio at stage start and at the half mark is sane" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    EXP="$MOTHER_ROOT/fixture-expected.json"
    key='Carefeed/big-repo'
    # (total - elapsed) / elapsed at the first start of each stage (build starts at
    # elapsed 0, so it has no start ratio).
    for st in rework gates review present; do
        [ "$(jq ".repos[\"$key\"].remaining_ratio.start.$st.n" "$CAL")" = "$(jq ".[\"$key\"].start_p50.$st.n" "$EXP")" ]
        close "$(jq ".repos[\"$key\"].remaining_ratio.start.$st.p50" "$CAL")" \
              "$(jq ".[\"$key\"].start_p50.$st.p50" "$EXP")" 0.01
        jq -e --arg k "$key" --arg st "$st" \
            '.repos[$k].remaining_ratio.start[$st] | (.p10 <= .p50 and .p50 <= .p90 and .p10 >= 0)' "$CAL" >/dev/null
    done
    jq -e '.fleet.remaining_ratio.half | (.n > 0 and .p10 >= 0 and .p10 <= .p50 and .p50 <= .p90)' "$CAL" >/dev/null
    jq -e '.repos["Carefeed/big-repo"].remaining_ratio.half | (.n > 0 and .p10 <= .p50 and .p50 <= .p90)' "$CAL" >/dev/null
}

@test "calibrate: finished jobs still in jobs/ count; running jobs do not" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    JOB_REPO="Carefeed/small-repo"
    mkjob live-done succeeded ".finished_at = \"$(iso_at -2290)\""
    ev live-done -3000 queued
    ev live-done -2990 ready
    ev live-done -2900 worker_spawned
    ev live-done -2300 final_result_observed
    ev live-done -2290 succeeded
    mkjob live-run running
    ev live-run -700 queued
    ev live-run -600 worker_spawned
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ "$(jq '.fleet.n' "$CAL")" = "31" ]
    [ "$(jq '.repos["Carefeed/big-repo"].n' "$CAL")" = "25" ]
    [ "$(jq '.repos | has("Carefeed/small-repo")' "$CAL")" = "false" ]
}

@test "calibrate: with no history exits 0 and writes a fleet entry with n=0" {
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ -f "$CAL" ]
    [ "$(jq '.fleet.n' "$CAL")" = "0" ]
    [ "$(jq '.repos | length' "$CAL")" = "0" ]
}

@test "calibrate: output is valid JSON, leaves no temp files behind, and can be re-run" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    first=$(jq -S . "$CAL")
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    jq -e . "$CAL" >/dev/null
    # same history -> same fit (fitted_at aside)
    [ "$(jq -S 'del(.fitted_at)' "$CAL")" = "$(printf '%s' "$first" | jq -S 'del(.fitted_at)')" ]
    [ -z "$(find "$RUNNER_DIR" -name '*.tmp*' -o -name '*.bak*')" ]
}

# =============================================================================
# (b)-(d) the figure and the ETA, driven by hand-written calibration
# =============================================================================

@test "tick: build job 10 min into a 20 min per-repo median shows a multiple-of-5 figure with a repo-basis ETA" {
    write_std_cal
    build_job r1
    tick_ok 0
    [ -f "$PROG_DIR/r1.json" ]
    jq -e . "$PROG_DIR/r1.json" >/dev/null
    # 0.80 share * (600 / 1200) = 40%
    [ "$(pj r1 .pct)" = "40" ]
    [ $(( $(pj r1 .pct) % 5 )) -eq 0 ]
    [ "$(pj r1 .v)" = "1" ]
    [ "$(pj r1 .stage)" = "build" ]
    jq -e '.label | test("^≈[0-9]+% .*ETA ~")' "$PROG_DIR/r1.json" >/dev/null
    [ "$(pj r1 .label)" = "≈40% · ETA ~5–20m" ]
    [ "$(pj r1 .eta.basis)" = "repo" ]
    [ "$(pj r1 .eta.n)" = "339" ]
    close "$(pj r1 .eta.lo_s)" 300 1
    close "$(pj r1 .eta.hi_s)" 1200 1
    [ "$(pj r1 .eta.label)" = "~5–20m" ]
    [ "$(pj r1 .paused)" = "false" ]
    [ "$(pj r1 .flags)" = "[]" ]
    [ "$(pj r1 .updated_at)" = "$(iso_at 0)" ]
}

@test "tick: signals carry stage share and fraction, active seconds, unavailable checklist, null gates, cost" {
    write_std_cal
    build_job r1
    tick_ok 0
    [ "$(pj r1 .signals.stage)" = "build" ]
    close "$(pj r1 .signals.stage_share)" 0.80 0.001
    close "$(pj r1 .signals.stage_frac)" 0.5 0.001
    [ "$(pj r1 .signals.elapsed_active_s)" = "600" ]
    [ "$(pj r1 .signals.checklist.status)" = "unavailable" ]
    [ "$(pj r1 .signals.gates)" = "null" ]
    [ "$(pj r1 .signals.cost.basis)" = "none" ]
    [ "$(pj r1 '.moved_back | type')" = "null" ]
    [ "$(jq 'has("moved_back")' "$PROG_DIR/r1.json")" = "false" ]
}

@test "tick: a job in a repo without a repo entry uses the fleet scope for shares, medians and ETA" {
    write_std_cal
    JOB_REPO="Carefeed/small-repo"
    build_job s1
    tick_ok 0
    # fleet: 0.72 * 0.5 = 36% -> 35
    [ "$(pj s1 .pct)" = "35" ]
    [ "$(pj s1 .eta.basis)" = "fleet" ]
    [ "$(pj s1 .eta.n)" = "300" ]
    # band 600 * [0.8, 3.0] = [480, 1800] s -> 5-minute steps
    [ "$(pj s1 .label)" = "≈35% · ETA ~10–30m" ]
}

@test "tick: a fleet with fewer than 20 finished jobs and no repo entry gives no ETA band" {
    write_cal "$(scope_json 12 0.72 1200 0.8 3.0)"
    build_job s1
    tick_ok 0
    [ "$(pj s1 .eta.basis)" = "none" ]
    [ "$(pj s1 .eta.lo_s)" = "null" ]
    [ "$(pj s1 .eta.hi_s)" = "null" ]
    [ "$(pj s1 .eta.label)" = "?" ]
    [ "$(pj s1 .label)" = "≈35% · ETA ?" ]
}

@test "tick: with no calibration file the figure uses default shares and medians and the ETA is unknown" {
    [ ! -e "$CAL" ]
    build_job d1
    tick_ok 0
    [ "$(pj d1 .pct)" = "35" ]
    [ "$(pj d1 .label)" = "≈35% · ETA ?" ]
    [ "$(pj d1 .eta.basis)" = "none" ]
    [ "$(pj d1 .eta.lo_s)" = "null" ]
    [ "$(pj d1 .eta.hi_s)" = "null" ]
    [ "$(pj d1 .eta.label)" = "?" ]
    close "$(pj d1 .signals.stage_share)" 0.72 0.001
    [ "$(pj d1 .signals.elapsed_active_s)" = "600" ]
}

@test "tick: a calibration fitted from an empty history behaves like no calibration" {
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    build_job d1
    tick_ok 0
    [ "$(pj d1 .pct)" = "35" ]
    [ "$(pj d1 .label)" = "≈35% · ETA ?" ]
    [ "$(pj d1 .eta.basis)" = "none" ]
}

@test "tick: within-stage progress is capped at 90% of the stage, so a very long build stalls at 65" {
    # 100 hours into build: 0.72 * 0.9 = 64.8% -> 65, never beyond
    mkjob d1 running
    ev d1 -360700 queued
    ev d1 -360600 worker_spawned
    tick_ok 0
    [ "$(pj d1 .pct)" = "65" ]
    [ "$(pj d1 .stage)" = "build" ]
    [ "$(pj d1 .signals.elapsed_active_s)" = "360600" ]
}

@test "tick: eta falls back to the half-mark ratios when the stage-start sample has fewer than 5 jobs" {
    # start.build has n=3 (would give ~1-2m); half has p10 .4 / p90 1.7 -> [240, 1020]
    write_cal "$(scope_json 300 0.72 1200 0.1 0.2 3)" \
              "Carefeed/big-repo" "$(scope_json 300 0.72 1200 0.1 0.2 3)"
    build_job h1
    tick_ok 0
    [ "$(pj h1 .eta.basis)" = "repo" ]
    close "$(pj h1 .eta.lo_s)" 240 1
    close "$(pj h1 .eta.hi_s)" 1020 1
    [ "$(pj h1 .eta.label)" = "~5–15m" ]
}

@test "tick: eta uses the current stage's start ratios when that sample has at least 5 jobs" {
    write_cal "$(scope_json 300 0.72 1200 0.5 2.0 5)" \
              "Carefeed/big-repo" "$(scope_json 300 0.72 1200 0.5 2.0 5)"
    build_job h1
    tick_ok 0
    close "$(pj h1 .eta.lo_s)" 300 1
    close "$(pj h1 .eta.hi_s)" 1200 1
}

@test "tick: MOTHER_PROGRESS_NOW is honored when --now is not given" {
    build_job d1
    MOTHER_PROGRESS_NOW="$(iso_at 0)" run mother-usage progress-tick --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ "$(pj d1 .updated_at)" = "$(iso_at 0)" ]
    [ "$(pj d1 .signals.elapsed_active_s)" = "600" ]
}

# =============================================================================
# Stage derivation and the active clock
# =============================================================================

@test "stage gates: figure comes from gates passed/total, label shows the gate part" {
    build_job g1 ".activity = \"gating\" | .gates = {status:\"running\",attempt:1,max_attempts:3,results:[{name:\"lint\",result:\"passed\",blocking:true},{name:\"unit\",result:\"passed\",blocking:true}],not_run:[\"static\"]}"
    ev g1 -300 final_result_observed
    ev g1 -200 gates_started "$GATES_STARTED"
    tick_ok 0
    [ "$(pj g1 .stage)" = "gates" ]
    # build 300 (-600 .. -300) + gates 200 active seconds
    [ "$(pj g1 .signals.elapsed_active_s)" = "500" ]
    # .72 + .17 + .03 * (2/3) = 91% -> 90
    [ "$(pj g1 .pct)" = "90" ]
    close "$(pj g1 .signals.stage_frac)" 0.667 0.01
    close "$(pj g1 .signals.stage_share)" 0.03 0.001
    [ "$(pj g1 '.signals.gates | [.passed, .failed, .total, .attempt, .max_attempts] | join(",")')" = "2,0,3,1,3" ]
    [ "$(pj g1 .label)" = "≈90% · gates 2/3 · ETA ?" ]
}

@test "gates summary: skipped counts as passed, unavailable and non-blocking failures do not count as failed" {
    build_job g1 ".gates = {status:\"passed\",attempt:1,max_attempts:3,results:[{name:\"lint\",result:\"skipped\",blocking:true},{name:\"unit\",result:\"unavailable\",blocking:true},{name:\"static\",result:\"failed\",blocking:false},{name:\"e2e\",result:\"passed\",blocking:true}],not_run:[]}"
    tick_ok 0
    # skipped + passed = 2; no blocking failure; total = len(results) + len(not_run) with no gates_started event
    [ "$(pj g1 '.signals.gates | [.passed, .failed, .total] | join(",")')" = "2,0,4" ]
    [ "$(pj g1 .label)" = "≈35% · gates 2/4 · ETA ?" ]
}

@test "gates summary: total comes from the latest gates_started event's gate list when present" {
    build_job g1 ".gates = {status:\"running\",attempt:2,max_attempts:3,results:[{name:\"lint\",result:\"passed\",blocking:true}],not_run:[]}"
    ev g1 -400 final_result_observed
    ev g1 -390 gates_started '{"attempt":1,"max_attempts":3,"gates":["lint"]}'
    ev g1 -380 gates_completed '{"attempt":1,"status":"failed"}'
    ev g1 -200 gates_started "$GATES_STARTED"
    tick_ok 0
    [ "$(pj g1 .signals.gates.total)" = "3" ]
    [ "$(pj g1 .signals.gates.attempt)" = "2" ]
}

@test "a job with no .gates and no gate events has null gates and no gate part in the label" {
    build_job g1
    tick_ok 0
    [ "$(pj g1 .signals.gates)" = "null" ]
    [[ "$(pj g1 .label)" != *gates* ]]
}

@test "stage rework: after an adherence rework kick the resumed worker is rework" {
    mkjob w1 running
    ev w1 -1500 queued
    ev w1 -1400 worker_spawned
    ev w1 -800 final_result_observed
    ev w1 -790 adherence_review_spawned
    ev w1 -700 adherence_reviewed '{"verdict":"fail"}'
    ev w1 -700 adherence_rework_kicked
    ev w1 -300 worker_spawned
    tick_ok 0
    [ "$(pj w1 .stage)" = "rework" ]
    # build 600 + review 90 + rework 300
    [ "$(pj w1 .signals.elapsed_active_s)" = "990" ]
    # .72 + .17 * (300 / 600) = 80.5% -> 80
    [ "$(pj w1 .pct)" = "80" ]
    close "$(pj w1 .signals.stage_frac)" 0.5 0.001
    close "$(pj w1 .signals.stage_share)" 0.17 0.001
}

@test "stage review: an adherence review in flight is review" {
    mkjob v1 running
    ev v1 -1000 worker_spawned
    ev v1 -400 final_result_observed
    ev v1 -150 adherence_review_spawned
    tick_ok 0
    [ "$(pj v1 .stage)" = "review" ]
    [ "$(pj v1 .signals.elapsed_active_s)" = "750" ]
    # .72 + .17 + .03 + .06 * (150/300) = 95%
    [ "$(pj v1 .pct)" = "95" ]
}

@test "stage present: after pr_marked_ready the figure is capped at 95 however long it runs" {
    mkjob p1 running
    ev p1 -1000 worker_spawned
    ev p1 -400 final_result_observed
    ev p1 -300 pr_marked_ready '{"reason":"gates_passed"}'
    tick_ok 0
    [ "$(pj p1 .stage)" = "present" ]
    [ "$(pj p1 .signals.elapsed_active_s)" = "900" ]
    [ "$(pj p1 .pct)" = "95" ]
}

@test "non-terminal pct never exceeds 95 even after hours in the last stage" {
    mkjob p1 running
    ev p1 -40000 worker_spawned
    ev p1 -39000 final_result_observed
    ev p1 -36000 pr_marked_ready
    tick_ok 0
    [ "$(pj p1 .stage)" = "present" ]
    [ "$(pj p1 .pct)" -le 95 ]
    [ "$(pj p1 .pct)" = "95" ]
}

@test "active clock: review_spawned counts pending reviewers, so review stays active until the last one is reviewed" {
    mkjob rv running
    ev rv -1000 worker_spawned
    ev rv -700 final_result_observed
    ev rv -600 review_spawned '{"reviewer":"perri:correctness"}'
    ev rv -590 review_spawned '{"reviewer":"perri:tests"}'
    ev rv -500 reviewed '{"reviewer":"perri:correctness","finding_count":0,"decision":"pass"}'
    ev rv -400 reviewed '{"reviewer":"perri:tests","finding_count":0,"decision":"pass"}'
    ev rv -390 review_cycle_completed '{"cycle":1}'
    tick_ok 0
    # build 300 + review 200 (from the first spawn to the LAST reviewed)
    [ "$(pj rv .signals.elapsed_active_s)" = "500" ]
    [ "$(pj rv .stage)" = "review" ]
}

@test "active clock: a review wave cycle is active from review_cycle_started to review_cycle_completed" {
    mkjob rw running
    ev rw -700 worker_spawned
    ev rw -400 final_result_observed
    ev rw -300 review_cycle_started '{"cycle":1,"wave":true}'
    ev rw -100 review_cycle_completed '{"cycle":1,"decision":"pass"}'
    tick_ok 0
    [ "$(pj rw .signals.elapsed_active_s)" = "500" ]
    [ "$(pj rw .stage)" = "review" ]
}

@test "active clock: gate_fix_started opens rework time and the next gates_started closes the rework trigger" {
    mkjob gf running ".gates = {status:\"running\",attempt:2,max_attempts:3,results:[],not_run:[\"lint\",\"unit\",\"static\"]}"
    ev gf -1400 worker_spawned
    ev gf -800 final_result_observed
    ev gf -790 gates_started "$GATES_STARTED"
    ev gf -690 gates_completed '{"attempt":1,"status":"failed"}'
    ev gf -680 gate_fix_started '{"attempt":1,"red":["unit"]}'
    ev gf -490 final_result_observed
    ev gf -480 gates_started '{"attempt":2,"max_attempts":3,"gates":["lint","unit","static"]}'
    tick_ok 0
    # build 600 + gates 100 + rework 190 + gates (still open) 480
    [ "$(pj gf .signals.elapsed_active_s)" = "1370" ]
    [ "$(pj gf .stage)" = "gates" ]
    [ "$(pj gf .pct)" = "90" ]
}

@test "active clock: a continuation's queue wait is not active time" {
    mkjob c1 running
    ev c1 -1000 worker_spawned
    ev c1 -700 final_result_observed
    ev c1 -690 continuation_queued '{"continuation":1}'
    ev c1 -300 worker_spawned
    tick_ok 0
    [ "$(pj c1 .signals.elapsed_active_s)" = "600" ]
}

@test "active clock: a quota pause is excluded and the figure continues from the same active time" {
    mkjob q1 running
    ev q1 -1000 worker_spawned
    ev q1 -400 paused_for_quota '{"paused_reason":"quota_5h"}'
    ev q1 -100 auto_resumed
    ev q1 -90 worker_spawned
    tick_ok 0
    [ "$(pj q1 .signals.elapsed_active_s)" = "690" ]
}

# =============================================================================
# (e) paused (awaiting) jobs
# =============================================================================

@test "awaiting job: pct, eta and active seconds are frozen across ticks and the label says paused" {
    write_std_cal
    build_job a1
    tick_ok 0
    [ "$(pj a1 .pct)" = "40" ]
    # the worker keeps going for 5 more minutes (events say 900 active seconds, 60%), then asks a
    # question; the figure shown while paused is the one last published, not a recomputation
    jobset a1 '.state = "awaiting" | .paused_reason = "gate_hold" | .activity = "gate_hold"'
    ev a1 300 awaiting_input '{"question":"Which option?","paused_reason":"gate_hold"}'
    tick_ok 360
    pct1=$(pj a1 .pct); eta1=$(pj a1 .eta | jq -S -c .); el1=$(pj a1 .signals.elapsed_active_s)
    tick_ok $((3 * 3600))
    pct2=$(pj a1 .pct); eta2=$(pj a1 .eta | jq -S -c .); el2=$(pj a1 .signals.elapsed_active_s)
    [ "$pct1" = "40" ] && [ "$pct2" = "40" ]
    [ "$eta1" = "$eta2" ]
    [ "$el1" = "600" ] && [ "$el2" = "600" ]
    [ "$(pj a1 .paused)" = "true" ]
    [ "$(pj a1 .label)" = "≈40% · paused · gate_hold" ]
    [ "$(pj a1 .eta.label)" = "paused · gate_hold" ]
    [ "$(pj a1 .eta.basis)" = "repo" ]
}

@test "awaiting job: the paused reason is paused_reason, else activity, else 'awaiting'" {
    build_job pa '.state = "awaiting" | .paused_reason = "cost_cap" | .activity = "ignored_activity"'
    build_job pb '.state = "awaiting" | .activity = "adherence_blocked"'
    build_job pc '.state = "awaiting"'
    tick_ok 0
    [ "$(pj pa .eta.label)" = "paused · cost_cap" ]
    [ "$(pj pb .eta.label)" = "paused · adherence_blocked" ]
    [ "$(pj pc .eta.label)" = "paused · awaiting" ]
    [[ "$(pj pa .label)" == *"paused · cost_cap" ]]
    [ "$(pj pa .paused)" = "true" ]
}

@test "awaiting job with no previous file is computed from its events and still marked paused" {
    mkjob n1 awaiting '.paused_reason = "gate_hold"'
    ev n1 -600 worker_spawned
    ev n1 -300 awaiting_input '{"question":"?","paused_reason":"gate_hold"}'
    tick_ok 0
    [ "$(pj n1 .paused)" = "true" ]
    [ "$(pj n1 .signals.elapsed_active_s)" = "300" ]
    # defaults: 0.72 * (300 / 1200) = 18% -> 20
    [ "$(pj n1 .pct)" = "20" ]
    [ "$(pj n1 .label)" = "≈20% · paused · gate_hold" ]
}

@test "elapsed active time excludes a 3 hour pause: a paused-and-resumed job matches an uninterrupted one" {
    write_std_cal
    # X: 600 s, paused for 3 h, then 300 s more.  Y: 900 s straight through.
    mkjob px running
    ev px -700 queued
    ev px -600 worker_spawned
    ev px 0 awaiting_input '{"question":"?","paused_reason":"gate_hold"}'
    ev px 10800 resumed_from_input '{"answer":"go"}'
    ev px 10810 worker_spawned
    mkjob py running
    ev py 10100 queued
    ev py 10210 worker_spawned
    tick_ok 11110
    [ "$(pj px .signals.elapsed_active_s)" = "900" ]
    [ "$(pj py .signals.elapsed_active_s)" = "900" ]
    [ "$(pj px .pct)" = "$(pj py .pct)" ]
    [ "$(pj px .label)" = "$(pj py .label)" ]
    [ "$(pj px .paused)" = "false" ]
}

# =============================================================================
# (f) moved back
# =============================================================================

@test "gate failure between ticks lowers pct and records moved_back gate_failed with the old pct" {
    build_job gf "$G_ALL_PASS | .activity = \"gating\""
    ev gf -300 final_result_observed
    ev gf -100 gates_started "$GATES_STARTED"
    tick_ok 0
    # .72 + .17 + .03 * 0.9 = 91.7% -> 90
    [ "$(pj gf .pct)" = "90" ]
    [ "$(jq 'has("moved_back")' "$PROG_DIR/gf.json")" = "false" ]

    jobset gf '.gates.status = "failed" | .gates.results[1].result = "failed"'
    tick_ok 30
    # a failed gate during the gates stage is treated as rework: .72 -> 70
    [ "$(pj gf .stage)" = "rework" ]
    [ "$(pj gf .pct)" = "70" ]
    [ "$(pj gf .moved_back.reason)" = "gate_failed" ]
    [ "$(pj gf .moved_back.from_pct)" = "90" ]
    [ "$(pj gf .moved_back.at)" = "$(iso_at 30)" ]
    [ "$(pj gf '.signals.gates | [.passed, .failed, .total, .attempt, .max_attempts] | join(",")')" = "2,1,3,1,3" ]
    [ "$(pj gf .label)" = "≈70% · gates ✗ attempt 1/3 · ETA ?" ]
}

@test "a gate_fix_started trigger also records moved_back gate_failed" {
    build_job gf "$G_ALL_PASS | .activity = \"gating\""
    ev gf -300 final_result_observed
    ev gf -100 gates_started "$GATES_STARTED"
    tick_ok 0
    [ "$(pj gf .pct)" = "90" ]
    ev gf 10 gates_completed '{"attempt":1,"status":"failed"}'
    ev gf 30 gate_fix_started '{"attempt":1,"red":["unit"]}'
    tick_ok 30
    [ "$(pj gf .stage)" = "rework" ]
    [ "$(pj gf .pct)" -lt 90 ]
    [ $(( $(pj gf .pct) % 5 )) -eq 0 ]
    [ "$(pj gf .moved_back.reason)" = "gate_failed" ]
    [ "$(pj gf .moved_back.from_pct)" = "90" ]
}

@test "an adherence rework after review records moved_back adherence_rework" {
    mkjob ar running
    ev ar -1000 worker_spawned
    ev ar -400 final_result_observed
    ev ar -150 adherence_review_spawned
    tick_ok 0
    [ "$(pj ar .pct)" = "95" ]
    ev ar 10 adherence_reviewed '{"verdict":"fail"}'
    ev ar 10 adherence_rework_kicked
    ev ar 20 worker_spawned
    tick_ok 20
    [ "$(pj ar .stage)" = "rework" ]
    [ "$(pj ar .pct)" = "70" ]
    [ "$(pj ar .moved_back.reason)" = "adherence_rework" ]
    [ "$(pj ar .moved_back.from_pct)" = "95" ]
    [ "$(pj ar .moved_back.at)" = "$(iso_at 20)" ]
}

@test "a pipeline review cycle that continues records moved_back review_rework" {
    mkjob rr running
    ev rr -1000 worker_spawned
    ev rr -400 final_result_observed
    ev rr -150 review_cycle_started '{"cycle":1,"wave":true}'
    tick_ok 0
    [ "$(pj rr .pct)" = "95" ]
    ev rr 10 review_cycle_completed '{"cycle":1,"decision":"continue"}'
    ev rr 12 pipeline_cycle_continued '{"cycle":1}'
    ev rr 20 worker_spawned
    tick_ok 20
    [ "$(pj rr .stage)" = "rework" ]
    [ "$(pj rr .pct)" = "70" ]
    [ "$(pj rr .moved_back.reason)" = "review_rework" ]
    [ "$(pj rr .moved_back.from_pct)" = "95" ]
}

@test "moved_back is carried forward until pct reaches the old pct again, then dropped" {
    mkjob ar running
    ev ar -1000 worker_spawned
    ev ar -400 final_result_observed
    ev ar -150 adherence_review_spawned
    tick_ok 0
    ev ar 10 adherence_reviewed '{"verdict":"fail"}'
    ev ar 10 adherence_rework_kicked
    ev ar 20 worker_spawned
    tick_ok 20
    [ "$(pj ar .moved_back.from_pct)" = "95" ]
    # still working on the rework: moved_back is kept, with its original timestamp
    tick_ok 25
    [ "$(pj ar .pct)" -lt 95 ]
    [ "$(pj ar .moved_back.reason)" = "adherence_rework" ]
    [ "$(pj ar .moved_back.at)" = "$(iso_at 20)" ]
    [ "$(pj ar .moved_back.from_pct)" = "95" ]
    # rework finishes and the next review is well under way: pct is back at 95
    ev ar 30 final_result_observed
    ev ar 31 adherence_review_spawned
    tick_ok 181
    [ "$(pj ar .stage)" = "review" ]
    [ "$(pj ar .pct)" = "95" ]
    [ "$(jq 'has("moved_back")' "$PROG_DIR/ar.json")" = "false" ]
}

@test "a new drop replaces an older moved_back" {
    mkjob ar running "$G_ALL_PASS"
    ev ar -1000 worker_spawned
    ev ar -400 final_result_observed
    ev ar -150 adherence_review_spawned
    tick_ok 0
    [ "$(pj ar .pct)" = "95" ]
    # drop 1: adherence rework (95 -> 70)
    ev ar 10 adherence_reviewed '{"verdict":"fail"}'
    ev ar 10 adherence_rework_kicked
    ev ar 20 worker_spawned
    tick_ok 20
    [ "$(pj ar .moved_back.reason)" = "adherence_rework" ]
    # rework (60 s) finishes and gates start again, all green so far: back up to 90 (still below 95)
    ev ar 80 final_result_observed
    ev ar 81 gates_started "$GATES_STARTED"
    tick_ok 100
    [ "$(pj ar .stage)" = "gates" ]
    [ "$(pj ar .pct)" = "90" ]
    [ "$(pj ar .moved_back.reason)" = "adherence_rework" ]
    [ "$(pj ar .moved_back.from_pct)" = "95" ]
    # drop 2: a gate fails (90 -> rework)
    jobset ar '.gates.status = "failed" | .gates.results[1].result = "failed"'
    tick_ok 120
    [ "$(pj ar .pct)" -lt 90 ]
    [ "$(pj ar .moved_back.reason)" = "gate_failed" ]
    [ "$(pj ar .moved_back.from_pct)" = "90" ]
    [ "$(pj ar .moved_back.at)" = "$(iso_at 120)" ]
}

# =============================================================================
# (g) caps, terminal jobs, which jobs get a file
# =============================================================================

@test "a job that becomes succeeded is written once with pct 100, label ≈100%, a zero ETA and no moved_back" {
    build_job t1
    tick_ok 0
    [ "$(pj t1 .pct)" = "35" ]
    # simulate a stale moved_back so the terminal write has something to clear
    jq -c '. + {moved_back: {reason: "gate_failed", at: "2026-10-17T12:00:00.000Z", from_pct: 90}}' \
        "$PROG_DIR/t1.json" > "$PROG_DIR/t1.json.edit" && mv "$PROG_DIR/t1.json.edit" "$PROG_DIR/t1.json"
    ev t1 20 final_result_observed
    ev t1 30 succeeded
    jobset t1 ".state = \"succeeded\" | .finished_at = \"$(iso_at 30)\""
    tick_ok 60
    [ "$(pj t1 .pct)" = "100" ]
    [ "$(pj t1 .label)" = "≈100%" ]
    [ "$(pj t1 .paused)" = "false" ]
    [ "$(jq 'has("moved_back")' "$PROG_DIR/t1.json")" = "false" ]
    jq -e '.eta == {"lo_s":0,"hi_s":0,"label":"","basis":"none","n":null}' "$PROG_DIR/t1.json" >/dev/null
    # final: later ticks leave the 100% file alone
    before=$(cat "$PROG_DIR/t1.json")
    tick_ok 600
    [ "$(cat "$PROG_DIR/t1.json")" = "$before" ]
}

@test "the final write for a job with gates keeps the gate part of the label" {
    build_job t1 "$G_ALL_PASS"
    tick_ok 0
    ev t1 20 final_result_observed
    ev t1 30 succeeded
    jobset t1 '.state = "succeeded"'
    tick_ok 60
    [ "$(pj t1 .label)" = "≈100% · gates 3/3" ]
}

@test "failed and cancelled jobs that already have a progress file are finalized at 100" {
    for s in failed cancelled; do
        mkjob "x-$s" "$s"
        ev "x-$s" -600 worker_spawned
        ev "x-$s" -10 "$s"
    done
    mkdir -p "$PROG_DIR"
    for s in failed cancelled; do
        jq -nc '{v:1, pct:50, label:"≈50% · ETA ?", stage:"build",
                 moved_back:{reason:"gate_failed", at:"2026-10-17T11:00:00.000Z", from_pct:90}}' \
            > "$PROG_DIR/x-$s.json"
    done
    tick_ok 0
    for s in failed cancelled; do
        [ "$(pj "x-$s" .pct)" = "100" ]
        [ "$(pj "x-$s" .label)" = "≈100%" ]
        [ "$(jq 'has("moved_back")' "$PROG_DIR/x-$s.json")" = "false" ]
    done
}

@test "terminal jobs that never had a progress file, and archived jobs, get no file" {
    mkjob never-seen succeeded
    ev never-seen -600 worker_spawned
    ev never-seen -10 succeeded
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    tick_ok 0
    [ ! -e "$PROG_DIR/never-seen.json" ]
    [ -z "$(ls "$PROG_DIR"/big-*.json "$PROG_DIR"/small-*.json 2>/dev/null)" ]
}

@test "tick writes a file for running, awaiting and non-final succeeded jobs, and for no other jobs" {
    build_job j-run
    mkjob j-await awaiting; ev j-await -600 worker_spawned
    mkjob j-adh succeeded '.adherence_pending = true'
    ev j-adh -600 worker_spawned; ev j-adh -20 final_result_observed; ev j-adh -10 succeeded
    mkjob j-pipe succeeded '.activity = "pipeline_review"'
    ev j-pipe -600 worker_spawned; ev j-pipe -20 final_result_observed; ev j-pipe -10 succeeded
    mkjob j-ready ready
    mkjob j-queued queued
    mkjob j-done succeeded; ev j-done -600 worker_spawned; ev j-done -10 succeeded
    mkjob j-fail failed;    ev j-fail -600 worker_spawned;  ev j-fail -10 failed
    mkjob j-canc cancelled; ev j-canc -600 worker_spawned;  ev j-canc -10 cancelled
    tick_ok 0
    got=$(cd "$PROG_DIR" && ls -- *.json | sed 's/\.json$//' | sort | tr '\n' ' ')
    [ "$got" = "j-adh j-await j-pipe j-run " ]
}

@test "non-final succeeded jobs (adherence pending / pipeline_review) are treated as stage review, capped at 95" {
    mkjob j-adh succeeded '.adherence_pending = true'
    ev j-adh -600 worker_spawned; ev j-adh -20 final_result_observed; ev j-adh -10 succeeded
    mkjob j-pipe succeeded '.activity = "pipeline_review"'
    ev j-pipe -600 worker_spawned; ev j-pipe -20 final_result_observed; ev j-pipe -10 succeeded
    tick_ok 0
    for id in j-adh j-pipe; do
        [ "$(pj $id .stage)" = "review" ]
        # no review time yet: .72 + .17 + .03 = 92% -> 90
        [ "$(pj $id .pct)" = "90" ]
        [ "$(pj $id .pct)" -le 95 ]
        [ "$(pj $id .paused)" = "false" ]
    done
}

@test "progress files and sidecar data for jobs that no longer exist in jobs/ are removed" {
    build_job ghost
    build_job keeper
    tick_ok 0
    [ -f "$PROG_DIR/ghost.json" ]
    rm "$JOBS_DIR/ghost.json"
    # a stale file with no history at all
    jq -nc '{v:1, pct:50, label:"x", stage:"build"}' > "$PROG_DIR/orphan.json"
    tick_ok 30
    [ ! -e "$PROG_DIR/ghost.json" ]
    [ ! -e "$PROG_DIR/orphan.json" ]
    [ -f "$PROG_DIR/keeper.json" ]
    [ -z "$(find "$PROG_DIR" -name '*ghost*' -o -name '*orphan*')" ]
}

# =============================================================================
# Cost signal
# =============================================================================

@test "cost: a max_cost_usd cap is the denominator and spent is the larger of actual and live cost" {
    build_job c1 '.max_cost_usd = 10 | .actual_cost_usd = 1 | .live_cost_usd = 2.5'
    tick_ok 0
    [ "$(pj c1 .signals.cost.basis)" = "cap" ]
    close "$(pj c1 .signals.cost.usd)" 2.5 0.001
    close "$(pj c1 .signals.cost.of_usd)" 10 0.001
    close "$(pj c1 .signals.cost.fraction)" 0.25 0.001

    build_job c2 '.max_cost_usd = 10 | .actual_cost_usd = 4 | .live_cost_usd = 2.5'
    tick_ok 0
    close "$(pj c2 .signals.cost.usd)" 4 0.001
    close "$(pj c2 .signals.cost.fraction)" 0.4 0.001
}

@test "cost: without a cap the plan summary's 'expected spend' is the estimate" {
    build_job e1 '.actual_cost_usd = 2 | .plan_summary = "Add the export endpoint. Expected spend ≈ $8, mostly in review."'
    build_job e2 '.live_cost_usd = 3 | .plan_summary = "Small fix; EXPECTED SPEND ~ 12.50 overall."'
    tick_ok 0
    [ "$(pj e1 .signals.cost.basis)" = "estimate" ]
    close "$(pj e1 .signals.cost.of_usd)" 8 0.001
    close "$(pj e1 .signals.cost.usd)" 2 0.001
    close "$(pj e1 .signals.cost.fraction)" 0.25 0.001
    [ "$(pj e2 .signals.cost.basis)" = "estimate" ]
    close "$(pj e2 .signals.cost.of_usd)" 12.5 0.001
    close "$(pj e2 .signals.cost.fraction)" 0.24 0.001
}

@test "cost: a cap wins over a plan-summary estimate" {
    build_job c1 '.max_cost_usd = 20 | .actual_cost_usd = 5 | .plan_summary = "expected spend ≈ $8"'
    tick_ok 0
    [ "$(pj c1 .signals.cost.basis)" = "cap" ]
    close "$(pj c1 .signals.cost.of_usd)" 20 0.001
}

@test "cost: with neither cap nor estimate the basis is none and of_usd and fraction are null" {
    build_job n1 '.plan_summary = "No spend estimate here."'
    build_job n2
    tick_ok 0
    for id in n1 n2; do
        [ "$(pj $id .signals.cost.basis)" = "none" ]
        [ "$(pj $id .signals.cost.of_usd)" = "null" ]
        [ "$(pj $id .signals.cost.fraction)" = "null" ]
        close "$(pj $id .signals.cost.usd)" 0 0.0001
    done
}

# =============================================================================
# (h) progress_updated / progress_half events
# =============================================================================

@test "events: the first tick emits progress_updated with the whole progress object and the tick's timestamp" {
    build_job r1
    tick_ok 0
    [ "$(count_kind r1 progress_updated)" = "1" ]
    last=$(jq -c 'select(.kind == "progress_updated")' "$EVENTS_DIR/r1.jsonl" | tail -1)
    [ "$(printf '%s' "$last" | jq -r .ts)" = "$(iso_at 0)" ]
    [ "$(printf '%s' "$last" | jq -c 'keys')" = '["detail","kind","ts"]' ]
    [ "$(printf '%s' "$last" | jq -S -c .detail)" = "$(jq -S -c . "$PROG_DIR/r1.json")" ]
}

@test "events: ticks with no visible change append nothing, and a change within 60 s is held back until 60 s have passed" {
    build_job r1 "$G_ALL_PASS"
    # no gate events yet, so the job reads as stage build with a gates summary
    tick_ok 0
    [ "$(count_kind r1 progress_updated)" = "1" ]

    # 5 s later, nothing visible changed (35% either way)
    tick_ok 5
    [ "$(count_kind r1 progress_updated)" = "1" ]

    # the job reaches the gates stage: pct jumps, but only 30 s after the last event
    ev r1 6 final_result_observed
    ev r1 8 gates_started "$GATES_STARTED"
    tick_ok 30
    [ "$(pj r1 .stage)" = "gates" ]
    [ "$(pj r1 .pct)" = "90" ]
    [ "$(count_kind r1 progress_updated)" = "1" ]

    # still inside the 60 s window
    tick_ok 59
    [ "$(count_kind r1 progress_updated)" = "1" ]

    # 60 s after the last emitted event: the held-back change is emitted, exactly once.
    # (The previous FILE already shows this tuple; the comparison is against the last
    # EMITTED tuple.)
    tick_ok 60
    [ "$(count_kind r1 progress_updated)" = "2" ]
    last=$(jq -c 'select(.kind == "progress_updated")' "$EVENTS_DIR/r1.jsonl" | tail -1)
    [ "$(printf '%s' "$last" | jq -r .ts)" = "$(iso_at 60)" ]
    [ "$(printf '%s' "$last" | jq -S -c .detail)" = "$(jq -S -c . "$PROG_DIR/r1.json")" ]

    # and nothing more while nothing changes
    tick_ok 120
    tick_ok 400
    [ "$(count_kind r1 progress_updated)" = "2" ]
}

@test "events: a visible change after the 60 s window is emitted by the tick that sees it" {
    build_job r1
    tick_ok 0
    ev r1 70 final_result_observed
    ev r1 71 gates_started "$GATES_STARTED"
    tick_ok 100
    [ "$(count_kind r1 progress_updated)" = "2" ]
}

@test "events: progress_half is appended once, in the first tick with pct >= 50, with the eta band and active seconds" {
    write_std_cal
    # 1000 s into build: 0.80 * (1000/1200) = 66.7% -> 65
    mkjob h1 running
    ev h1 -1100 queued
    ev h1 -1000 worker_spawned
    tick_ok 0
    [ "$(pj h1 .pct)" -ge 50 ]
    [ "$(count_kind h1 progress_half)" = "1" ]
    half=$(jq -c 'select(.kind == "progress_half")' "$EVENTS_DIR/h1.jsonl" | head -1)
    [ "$(printf '%s' "$half" | jq -r .detail.eta_lo_s)" = "$(pj h1 .eta.lo_s)" ]
    [ "$(printf '%s' "$half" | jq -r .detail.eta_hi_s)" = "$(pj h1 .eta.hi_s)" ]
    [ "$(printf '%s' "$half" | jq -r .detail.elapsed_active_s)" = "$(pj h1 .signals.elapsed_active_s)" ]
    tick_ok 30
    tick_ok 200
    [ "$(count_kind h1 progress_half)" = "1" ]
}

@test "events: progress_half is emitted in the tick where pct first reaches 50, not before" {
    write_std_cal
    # 300 s into build: 0.80 * 0.25 = 20%
    mkjob h1 running
    ev h1 -400 queued
    ev h1 -300 worker_spawned
    tick_ok 0
    [ "$(pj h1 .pct)" -lt 50 ]
    [ "$(count_kind h1 progress_half)" = "0" ]
    # 1000 s in: 65%
    tick_ok 700
    [ "$(pj h1 .pct)" -ge 50 ]
    [ "$(count_kind h1 progress_half)" = "1" ]
}

@test "events: progress_half is consumed without an event when there is no ETA band" {
    # no calibration: pct passes 50 (65) but the ETA basis is none
    mkjob h1 running
    ev h1 -1800 worker_spawned
    tick_ok 0
    [ "$(pj h1 .pct)" = "65" ]
    [ "$(pj h1 .eta.basis)" = "none" ]
    [ "$(count_kind h1 progress_half)" = "0" ]
    # a band appears later; the half mark has already been consumed
    write_std_cal
    tick_ok 30
    [ "$(pj h1 .eta.basis)" = "repo" ]
    [ "$(count_kind h1 progress_half)" = "0" ]
}

@test "events: a job that is finalized by a tick does not emit progress_half" {
    write_std_cal
    mkjob h2 succeeded
    ev h2 -1000 worker_spawned
    ev h2 -10 succeeded
    mkdir -p "$PROG_DIR"
    jq -nc '{v:1, pct:45, label:"x", stage:"build"}' > "$PROG_DIR/h2.json"
    tick_ok 0
    [ "$(pj h2 .pct)" = "100" ]
    [ "$(count_kind h2 progress_half)" = "0" ]
}

# =============================================================================
# (i) kill switch
# =============================================================================

@test "MOTHER_PROGRESS_ENABLED=0: calibrate and progress-tick exit 0 and write nothing, not even events" {
    "$FIX/make_archive.sh" "$MOTHER_ROOT"
    build_job r1
    mkjob r2 awaiting; ev r2 -600 worker_spawned
    mkdir -p "$PROG_DIR"
    jq -nc '{v:1, pct:50, label:"x", stage:"build"}' > "$PROG_DIR/stale.json"
    sum_jobs=$(jobs_sum)
    sum_events=$(cd "$EVENTS_DIR" && cksum ./*.jsonl)
    rm -f "$CAL"
    export MOTHER_PROGRESS_ENABLED=0
    run mother-usage calibrate --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    run mother-usage progress-tick --root "$MOTHER_ROOT" --now "$(iso_at 0)"
    [ "$status" -eq 0 ]
    [ ! -e "$CAL" ]
    [ ! -e "$PROG_DIR/r1.json" ]
    [ ! -e "$PROG_DIR/r2.json" ]
    [ ! -e "$PROG_DIR/meta" ]
    [ -e "$PROG_DIR/stale.json" ]
    [ "$(jobs_sum)" = "$sum_jobs" ]
    [ "$(cd "$EVENTS_DIR" && cksum ./*.jsonl)" = "$sum_events" ]
}

@test "MOTHER_PROGRESS_ENABLED=0 from the start leaves no progress directory at all" {
    build_job r1
    export MOTHER_PROGRESS_ENABLED=0
    run mother-usage progress-tick --root "$MOTHER_ROOT" --now "$(iso_at 0)"
    [ "$status" -eq 0 ]
    [ ! -e "$PROG_DIR" ]
}

@test "MOTHER_PROGRESS_ENABLED=0: mother list and mother status output is exactly the pre-feature output, even with progress files present" {
    write_std_cal
    build_job r1 '.activity = "gating" | .max_cost_usd = 10'
    mkjob a1 awaiting '.paused_reason = "gate_hold" | .activity = "gate_hold"'
    ev a1 -600 worker_spawned
    ev a1 -10 awaiting_input '{"question":"?","paused_reason":"gate_hold"}'
    mkjob d1 succeeded
    # Pristine output: no progress directory exists.
    [ ! -e "$PROG_DIR" ]
    base_list=$(mother list)
    base_json=$(mother list --format json)
    base_status=$(mother status r1)
    base_status_json=$(mother status r1 --format json)
    base_a1=$(mother status a1)

    # Progress files exist (written directly, no events), switch on: the output differs.
    mkdir -p "$PROG_DIR"
    for id in r1 a1 d1; do
        jq -nc --arg id "$id" '{v:1, pct:45, label:"≈45% · ETA ~5–20m", stage:"build",
            signals:{stage:"build", stage_share:0.72, stage_frac:0.5, elapsed_active_s:600, gates:null,
                     checklist:{status:"unavailable"}, cost:{usd:0, of_usd:null, basis:"none", fraction:null}},
            eta:{lo_s:300, hi_s:1200, label:"~5–20m", basis:"repo", n:339},
            paused:false, flags:[], updated_at:"2026-10-17T12:00:00.000Z"}' > "$PROG_DIR/$id.json"
    done
    [ "$(mother list)" != "$base_list" ]
    [ "$(mother list --format json)" != "$base_json" ]
    [ "$(mother status r1)" != "$base_status" ]

    # Switch off: byte-for-byte the pristine output.
    export MOTHER_PROGRESS_ENABLED=0
    [ "$(mother list)" = "$base_list" ]
    [ "$(mother list --format json)" = "$base_json" ]
    [ "$(mother status r1)" = "$base_status" ]
    [ "$(mother status r1 --format json)" = "$base_status_json" ]
    [ "$(mother status a1)" = "$base_a1" ]
    [ "$(mother list --format json | jq 'map(has("progress")) | any')" = "false" ]
    [[ "$(mother status r1)" != *"=== progress ==="* ]]
}

# =============================================================================
# (j) observer only
# =============================================================================

@test "ticks never touch job files, never create files under jobs/, and append only progress_updated / progress_half" {
    write_std_cal
    build_job r1 "$G_ALL_PASS"
    mkjob a1 awaiting '.paused_reason = "gate_hold"'; ev a1 -600 worker_spawned
    mkjob d1 succeeded '.adherence_pending = true'
    ev d1 -600 worker_spawned; ev d1 -20 final_result_observed; ev d1 -10 succeeded
    mkjob q1 ready
    mkdir -p "$MOTHER_ROOT/orig-events"
    cp "$EVENTS_DIR"/*.jsonl "$MOTHER_ROOT/orig-events/"
    sum_jobs=$(jobs_sum)
    listing=$(ls -A "$JOBS_DIR")

    tick_ok 0
    ev r1 6 final_result_observed
    ev r1 8 gates_started "$GATES_STARTED"
    cp "$EVENTS_DIR/r1.jsonl" "$MOTHER_ROOT/orig-events/r1.jsonl"   # include the test's own late events
    tick_ok 100
    tick_ok 4000

    [ "$(jobs_sum)" = "$sum_jobs" ]
    [ "$(ls -A "$JOBS_DIR")" = "$listing" ]
    for f in "$MOTHER_ROOT"/orig-events/*.jsonl; do
        id=$(basename "$f" .jsonl)
        # every line that is not a progress event is exactly the original, in order
        [ "$(jq -c 'select(.kind | startswith("progress_") | not)' "$EVENTS_DIR/$id.jsonl")" \
          = "$(jq -c 'select(.kind | startswith("progress_") | not)' "$f")" ]
    done
    kinds=$(cat "$EVENTS_DIR"/*.jsonl | jq -r 'select(.kind | startswith("progress")) | .kind' | sort -u | tr '\n' ' ')
    [ "$kinds" = "progress_half progress_updated " ] || [ "$kinds" = "progress_updated " ]
    cat "$EVENTS_DIR"/*.jsonl | jq -s -e '[.[] | select(.kind | startswith("progress_")) | (keys == ["detail","kind","ts"])] | (length > 0 and all)' >/dev/null
    # no leftover mkdir locks
    [ -z "$(find "$EVENTS_DIR" -name '*.lockdir')" ]
}

@test "ticks leave no temporary files behind" {
    write_std_cal
    build_job r1
    tick_ok 0
    tick_ok 100
    [ -z "$(find "$PROG_DIR" -name '*.tmp*' -o -name '*.edit*' -o -name '*.bak*')" ]
}

# =============================================================================
# (k) ETA label rounding
# =============================================================================

@test "eta label: a band within 15 minutes is in minutes; one minute when both ends round alike, else a range" {
    [ "$(eta_label_for 1.19 1.21)" = "~12m" ]
    [ "$(eta_label_for 0.8 1.2)" = "~8–12m" ]
    # minimum one minute at the low end
    [ "$(eta_label_for 0.02 0.7)" = "~1–7m" ]
}

@test "eta label: bands over 15 minutes and up to an hour are rounded to 5-minute steps" {
    [ "$(eta_label_for 1.5 3.5)" = "~15–35m" ]
    [ "$(eta_label_for 2.45 2.55)" = "~25m" ]
    # minimum five minutes at the low end
    [ "$(eta_label_for 0.1 2.0)" = "~5–20m" ]
    [ "$(eta_label_for 0.6 1.7)" = "~5–15m" ]
}

@test "eta label: no band reaching past 15 minutes ever shows a single-minute value" {
    for pair in "0.1 2.0" "1.0 4.0" "0.3 2.2" "3.0 5.5"; do
        set -- $pair
        label=$(eta_label_for "$1" "$2")
        # ~25m  or  ~15–35m : every number is a multiple of 5
        [[ "$label" =~ ^~([0-9]+)(–([0-9]+))?m$ ]]
        [ $(( BASH_REMATCH[1] % 5 )) -eq 0 ]
        if [ -n "${BASH_REMATCH[3]}" ]; then [ $(( BASH_REMATCH[3] % 5 )) -eq 0 ]; fi
    done
}

@test "eta label: bands over an hour are in half-hour steps, without a trailing .0" {
    [ "$(eta_label_for 6.0 12.0)" = "~1–2h" ]
    [ "$(eta_label_for 8.8 9.2)" = "~1.5h" ]
    [ "$(eta_label_for 3.0 12.0)" = "~0.5–2h" ]
}

@test "eta label: the overall label is figure, optional gate part, then ETA with the band" {
    write_cal "$(scope_json 300 0.72 1200 1.5 3.5)" "Carefeed/big-repo" "$(scope_json 300 0.72 1200 1.5 3.5)"
    build_job g1 "$G_ALL_PASS"
    tick_ok 0
    [ "$(pj g1 .label)" = "≈35% · gates 3/3 · ETA ~15–35m" ]
    [ "$(pj g1 .eta.label)" = "~15–35m" ]
}

# =============================================================================
# (l) CLI display: mother list / mother status
# =============================================================================

# running run-1 (gating, with gates + cap), awaiting aw-1, finished done-1 (final
# file written), ready rdy-1 and queued q-1 (a file only for rdy-1, written by hand).
mk_display_fixture() {
    write_cal "$(scope_json 300 0.72 1200 0.8 3.0)" \
              "Carefeed/big-repo" "$(scope_json 339 0.72 1200 0.5 2.0)"
    mkjob run-1 running ".activity = \"gating\" | .max_cost_usd = 10 | .live_cost_usd = 2.5 | .gates = {status:\"running\",attempt:1,max_attempts:3,results:[{name:\"lint\",result:\"passed\",blocking:true},{name:\"unit\",result:\"passed\",blocking:true}],not_run:[\"static\"]}"
    ev run-1 -1000 queued
    ev run-1 -900 worker_spawned
    ev run-1 -300 final_result_observed
    ev run-1 -200 gates_started "$GATES_STARTED"
    mkjob aw-1 awaiting '.paused_reason = "gate_hold" | .activity = "gate_hold"'
    ev aw-1 -700 worker_spawned
    ev aw-1 -10 awaiting_input '{"question":"Which option?","paused_reason":"gate_hold"}'
    mkjob done-1 running
    ev done-1 -700 worker_spawned
    tick_ok 0
    ev done-1 20 final_result_observed
    ev done-1 30 succeeded
    jobset done-1 '.state = "succeeded"'
    tick_ok 60
    mkjob rdy-1 ready
    mkjob q-1 queued
    jq -nc '{v:1, pct:45, label:"≈45% · ETA ?", stage:"build"}' > "$PROG_DIR/rdy-1.json"
}

_row() { mother list | grep -E "^$1 "; }

@test "list text: the label is appended to the STATE cell of running and awaiting jobs, after existing markers" {
    mk_display_fixture
    run_label=$(pj run-1 .label)
    aw_label=$(pj aw-1 .label)
    [ -n "$run_label" ] && [ -n "$aw_label" ]
    [[ "$(_row run-1)" == *"running [gating] $run_label"* ]]
    # HC-08 renders a gate hold as the uppercase [GATES-HELD] marker (HC08-10).
    [[ "$(_row aw-1)" == *"awaiting [GATES-HELD] $aw_label"* ]]
    [[ "$aw_label" == *"paused · gate_hold" ]]
}

@test "list text: other states are unchanged even when a progress file exists" {
    mk_display_fixture
    [ -f "$PROG_DIR/done-1.json" ] && [ -f "$PROG_DIR/rdy-1.json" ]
    [[ "$(_row done-1)" != *"≈"* ]]
    [[ "$(_row rdy-1)" != *"≈"* ]]
    [[ "$(_row q-1)" != *"≈"* ]]
    [[ "$(_row done-1)" == *succeeded* ]]
}

@test "list json: jobs with a progress file carry .progress (the file's content), jobs without get no key" {
    mk_display_fixture
    json=$(mother list --format json)
    [ "$(printf '%s' "$json" | jq -S -c '.[] | select(.id == "run-1") | .progress')" = "$(jq -S -c . "$PROG_DIR/run-1.json")" ]
    [ "$(printf '%s' "$json" | jq -S -c '.[] | select(.id == "aw-1") | .progress')" = "$(jq -S -c . "$PROG_DIR/aw-1.json")" ]
    [ "$(printf '%s' "$json" | jq '.[] | select(.id == "done-1") | .progress.pct')" = "100" ]
    [ "$(printf '%s' "$json" | jq '.[] | select(.id == "q-1") | has("progress")')" = "false" ]
}

@test "status json: .job.progress is identical to the one in list json" {
    mk_display_fixture
    for id in run-1 aw-1 done-1; do
        from_list=$(mother list --format json | jq -S -c --arg id "$id" '.[] | select(.id == $id) | .progress')
        from_status=$(mother status "$id" --format json | jq -S -c '.job.progress')
        [ "$from_list" = "$from_status" ]
        [ "$from_list" = "$(jq -S -c . "$PROG_DIR/$id.json")" ]
    done
    [ "$(mother status q-1 --format json | jq '.job | has("progress")')" = "false" ]
}

@test "progress is never stored in the job file" {
    mk_display_fixture
    [ "$(jq 'has("progress")' "$JOBS_DIR/run-1.json")" = "false" ]
}

@test "status text: a progress section shows the figure, stage and share, gates, elapsed, cost vs cap, checklist and calibration" {
    mk_display_fixture
    section=$(mother status run-1 | awk '/^=== progress ===/{f=1; next} /^===/{f=0} f')
    [ -n "$section" ]
    echo "$section" | grep -qF "$(pj run-1 .label)"
    echo "$section" | grep -iE 'stage' | grep -qi 'gates'
    echo "$section" | grep -iE 'stage' | grep -qE '3%|0\.03'
    echo "$section" | grep -iE 'gates' | grep -qE '2/3'
    echo "$section" | grep -qi 'elapsed'
    echo "$section" | grep -iE 'cost' | grep -E '2\.5' | grep -qE '10'
    echo "$section" | grep -qF 'Checklist: unavailable'
    echo "$section" | grep -qF 'calibration: per-repo (n=339)'
    [ -z "$(echo "$section" | grep -iE 'paused|Moved back' || true)" ]
}

@test "status text: calibration line says fleet (n=...) or none when there is no per-repo band" {
    write_std_cal
    JOB_REPO="Carefeed/small-repo"
    build_job s1
    tick_ok 0
    section=$(mother status s1 | awk '/^=== progress ===/{f=1; next} /^===/{f=0} f')
    echo "$section" | grep -qF 'calibration: fleet (n=300)'

    rm -f "$CAL"
    tick_ok 30
    section=$(mother status s1 | awk '/^=== progress ===/{f=1; next} /^===/{f=0} f')
    echo "$section" | grep -qF 'calibration: none'
}

@test "status text: a paused job says paused and a moved-back job says Moved back: <reason>" {
    mk_display_fixture
    section=$(mother status aw-1 | awk '/^=== progress ===/{f=1; next} /^===/{f=0} f')
    echo "$section" | grep -qi 'paused'

    build_job mb "$G_ALL_PASS"
    ev mb -300 final_result_observed
    ev mb -100 gates_started "$GATES_STARTED"
    tick_ok 100
    jobset mb '.gates.status = "failed" | .gates.results[1].result = "failed"'
    tick_ok 130
    [ "$(pj mb .moved_back.reason)" = "gate_failed" ]
    section=$(mother status mb | awk '/^=== progress ===/{f=1; next} /^===/{f=0} f')
    echo "$section" | grep -qF 'Moved back: gate_failed'
}

@test "status text: no progress section for a job without a progress file" {
    mk_display_fixture
    [[ "$(mother status q-1)" != *"=== progress ==="* ]]
}

@test "jobs enqueued before the feature (minimal JSON, no stage events) still get a figure" {
    write_std_cal
    # Only the three state events; no worker_spawned, no gates, no crew fields.
    mkjob old-1 running
    ev old-1 -700 queued '{"title":"old"}'
    ev old-1 -660 ready
    ev old-1 -600 running
    # And one with no events file at all.
    mkjob old-2 running
    tick_ok 0
    for id in old-1 old-2; do
        [ -f "$PROG_DIR/$id.json" ]
        [ "$(pj $id .v)" = "1" ]
        jq -e '.pct | (type == "number" and . == floor and . >= 0 and . <= 95 and . % 5 == 0)' "$PROG_DIR/$id.json" >/dev/null
        jq -e '.label | test("^≈[0-9]+%")' "$PROG_DIR/$id.json" >/dev/null
        [ "$(pj $id .stage)" = "build" ]
        # nothing has run, so there is nothing to scale an ETA from
        [ "$(pj $id .eta.basis)" = "none" ]
        [[ "$(pj $id .label)" == *"ETA ?" ]]
        [ "$(pj $id .signals.elapsed_active_s)" = "0" ]
    done
    [[ "$(_row old-1)" == *"$(pj old-1 .label)"* ]]
    [ "$(mother list --format json | jq '.[] | select(.id == "old-2") | .progress.v')" = "1" ]
}

# =============================================================================
# mother-runner --progress-tick
# =============================================================================

@test "mother-runner --progress-tick runs one pass: progress for a running job, calibrating when no calibration exists" {
    export MOTHER_BROKER_ENABLED=0 MOTHER_PROGRESS_INTERVAL=0 MOTHER_PROGRESS_NOW="$(iso_at 0)"
    build_job r1
    [ ! -e "$CAL" ]
    run_runner_tick
    [ "$status" -eq 0 ]
    [ -f "$PROG_DIR/r1.json" ]
    [ "$(pj r1 .pct)" = "35" ]
    [ -f "$CAL" ]
    jq -e '.fleet.n == 0' "$CAL" >/dev/null
}

@test "mother-runner --progress-tick with MOTHER_PROGRESS_ENABLED=0 produces nothing" {
    export MOTHER_BROKER_ENABLED=0 MOTHER_PROGRESS_INTERVAL=0 MOTHER_PROGRESS_NOW="$(iso_at 0)"
    export MOTHER_PROGRESS_ENABLED=0
    build_job r1
    run_runner_tick
    [ "$status" -eq 0 ]
    [ ! -e "$PROG_DIR" ]
    [ ! -e "$CAL" ]
    [ "$(count_kind r1 progress_updated)" = "0" ]
}

@test "mother-runner --progress-tick is throttled by MOTHER_PROGRESS_INTERVAL (0 means always)" {
    export MOTHER_BROKER_ENABLED=0 MOTHER_PROGRESS_NOW="$(iso_at 0)"
    build_job r1
    MOTHER_PROGRESS_INTERVAL=3600 run_runner_tick
    [ "$status" -eq 0 ]
    [ -f "$PROG_DIR/r1.json" ]
    rm "$PROG_DIR/r1.json"
    MOTHER_PROGRESS_INTERVAL=3600 run_runner_tick
    [ "$status" -eq 0 ]
    [ ! -e "$PROG_DIR/r1.json" ]
    MOTHER_PROGRESS_INTERVAL=0 run_runner_tick
    [ "$status" -eq 0 ]
    [ -f "$PROG_DIR/r1.json" ]
}
