#!/usr/bin/env bats
# checklist.bats — HC-10 "ledger-lite checklist" (HC10-1..6).
#
# Contract: lib/criteria.sh (mother_criteria_seed / mother_criteria_view),
# `mother add` seeding, `mother check`, the `=== checklist ===` status section,
# and `mother-usage progress-tick` using done/total during the build stage.
# Criterion TEXT lives only in $MOTHER_ROOT/checklists/<id>.json; it must never
# reach job JSON, events or progress files.
#
# Exact numbers use write_std_cal: build share .80, median 1200s; the build_job
# fixture has 600 active seconds at T0, so the elapsed-only figure is
# 0.80 * 0.5 = 40%.  3/4 done -> 0.80 * 0.75 = 60%.  4/4 done -> capped at
# 0.9 of the stage -> 0.80 * 0.9 = 72 -> 70.

load 'test_helper'

T0=1792238400   # 2026-10-17T12:00:00Z
SECRET="ZEBRA-SECRET-CRITERION"

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_NOTIFY_TRANSPORT=none
    unset MOTHER_PROGRESS_ENABLED MOTHER_PROGRESS_NOW MOTHER_PROGRESS_INTERVAL
    JOB_REPO="Carefeed/big-repo"
    PROG_DIR="$MOTHER_ROOT/progress"
    CAL="$RUNNER_DIR/progress-calibration.json"
    CK="$MOTHER_ROOT/checklists"
    export FAKE_REPO="$MOTHER_ROOT/testrepo"
    git init -q "$FAKE_REPO"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers (copied from progress.bats)
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


# ---------------------------------------------------------------------------
# Checklist helpers
# ---------------------------------------------------------------------------

# Seed a checklist from a plan file via the library, in a clean subshell.
seed() {
    run bash -c 'source "$MOTHER_LIB_DIR/criteria.sh" && mother_criteria_seed "$1" "$2"' _ "$1" "$2"
    [ "$status" -eq 0 ] || { echo "seed failed: $output" >&2; return 1; }
}

view() {
    bash -c 'source "$MOTHER_LIB_DIR/criteria.sh" && mother_criteria_view "$1"' _ "$1"
}

# Write a checklist file directly. Usage: write_ck <id> <n-total> <n-done>
write_ck() {
    mkdir -p "$CK"
    jq -nc --argjson n "$2" --argjson d "$3" --arg s "$SECRET" '
        {v: 1, items: [range(0; $n) | {id: ("HC10-" + (. + 1 | tostring)),
            text: ($s + " " + (. | tostring)),
            status: (if . < $d then "done" else "open" end),
            evidence: (if . < $d then "abc123" else null end)}]}' > "$CK/$1.json"
}

archie_plan() {
    cat > "$1" <<'PLAN'
# Plan

## Context
Example of the format:
- [ ] **HC05-9** this is only an example in Context

## Acceptance criteria
- [ ] **HC05-1** first criterion
- [ ] **HC05-2** second criterion
- [ ] **HC05-3** third criterion
- [ ] **HC05-1** duplicate of the first, must be dropped

## Out of scope
- [ ] **HC05-7** not a criterion
PLAN
}

ids_of() { jq -r '[.items[].id] | join(",")' "$CK/$1.json"; }

# =============================================================================
# (a) seeding  (HC10-1)
# =============================================================================

@test "seed: Archie-style list lines become open items; Context examples, later sections and duplicate ids are ignored" {
    archie_plan "$MOTHER_ROOT/plan.md"
    seed j1 "$MOTHER_ROOT/plan.md"
    [ "$(jq '.v' "$CK/j1.json")" = "1" ]
    [ "$(ids_of j1)" = "HC05-1,HC05-2,HC05-3" ]
    [ "$(jq -r '.items[0].text' "$CK/j1.json")" = "first criterion" ]
    [ "$(jq -r '[.items[] | .status] | unique | join(",")' "$CK/j1.json")" = "open" ]
    [ "$(jq -r '[.items[] | .evidence] | unique | map(tostring) | join(",")' "$CK/j1.json")" = "null" ]
}

@test "seed: Ada-style bullets (plain and 'ambitious bet') become items with ids G5, R11" {
    cat > "$MOTHER_ROOT/ada.md" <<'PLAN'
# PRD

### Acceptance criteria (behavioural)

- **G5.** the first goal
- **G5 — ambitious bet.** duplicate id keeps the first
- **R11 — ambitious bet.** a bet requirement

### Non-goals
- **X1.** not a criterion
PLAN
    seed j2 "$MOTHER_ROOT/ada.md"
    [ "$(ids_of j2)" = "G5,R11" ]
    [ "$(jq -r '.items[0].text' "$CK/j2.json")" = "the first goal" ]
}

@test "seed: a plan with no acceptance criteria produces an empty items list" {
    printf '# Plan\n\n## Context\n- **HC05-1** nothing here\n' > "$MOTHER_ROOT/none.md"
    seed j3 "$MOTHER_ROOT/none.md"
    [ "$(jq -c '.items' "$CK/j3.json")" = "[]" ]
}

@test "view: reports source and id/status/evidence only, never text" {
    archie_plan "$MOTHER_ROOT/plan.md"
    seed j1 "$MOTHER_ROOT/plan.md"
    mkjob j1 running
    out=$(view j1)
    [ "$(echo "$out" | jq -r .source)" = "checklist" ]
    [ "$(echo "$out" | jq '.items | length')" = "3" ]
    [ "$(echo "$out" | jq -r '.items[0] | keys | join(",")')" = "evidence,id,status" ]
    [[ "$out" != *"first criterion"* ]]
}

@test "view: missing or corrupt checklist gives items null; ledger source gives source ledger, items null" {
    mkjob m1 running
    [ "$(view m1 | jq -c '[.source, .items]')" = '["checklist",null]' ]
    mkdir -p "$CK"; echo '{not json' > "$CK/m1.json"
    [ "$(view m1 | jq -c '[.source, .items]')" = '["checklist",null]' ]
    mkjob m2 running '.criteria_source = "ledger"'
    write_ck m2 2 1
    [ "$(view m2 | jq -c '[.source, .items]')" = '["ledger",null]' ]
}

# =============================================================================
# (i) mother add seeds  (HC10-1)
# =============================================================================

@test "mother add seeds the checklist from the plan and records criteria_source=checklist" {
    make_plan "$MOTHER_ROOT/base.md"
    archie_plan "$MOTHER_ROOT/plan.md"
    # archie_plan lacks suggested_config; append the valid yaml block
    sed -n '/^```yaml/,$p' "$MOTHER_ROOT/base.md" >> "$MOTHER_ROOT/plan.md"
    run mother add --plan-file "$MOTHER_ROOT/plan.md" --repo testrepo \
        --repo-path "$FAKE_REPO" --branch feature/test
    [ "$status" -eq 0 ]
    id="$output"
    [ "$(jq -r .criteria_source "$JOBS_DIR/$id.json")" = "checklist" ]
    [ -f "$CK/$id.json" ]
    [ "$(ids_of "$id")" = "HC05-1,HC05-2,HC05-3" ]
    [ "$(jq -r '[.items[].status] | unique | join(",")' "$CK/$id.json")" = "open" ]
}

# =============================================================================
# (b)(c) mother check  (HC10-2)
# =============================================================================

@test "check: marks a criterion done with evidence, via MOTHER_JOB_ID, and the event carries no text" {
    write_ck j1 4 0
    mkjob j1 running
    MOTHER_JOB_ID=j1 run mother check HC10-2 --done --evidence abc123
    [ "$status" -eq 0 ]
    [ "$(jq -r '.items[] | select(.id=="HC10-2") | [.status, .evidence] | join(",")' "$CK/j1.json")" = "done,abc123" ]
    [ "$(jq -r '.items[] | select(.id=="HC10-1") | .status' "$CK/j1.json")" = "open" ]
    [ "$(count_kind j1 criterion_checked)" = "1" ]
    d=$(jq -c 'select(.kind=="criterion_checked") | .detail' "$EVENTS_DIR/j1.jsonl")
    [ "$(echo "$d" | jq -r .id)" = "HC10-2" ]
    [ "$(echo "$d" | jq -r .status)" = "done" ]
    [ "$(echo "$d" | jq -r .has_evidence)" = "true" ]
    [[ "$d" != *"$SECRET"* ]]
}

@test "check: --job selects the job explicitly and --open reopens a done criterion" {
    write_ck j1 2 2
    mkjob j1 running
    run mother check HC10-1 --open --job j1
    [ "$status" -eq 0 ]
    [ "$(jq -r '.items[0].status' "$CK/j1.json")" = "open" ]
}

@test "check: an unknown criterion id exits 1, lists the valid ids, and changes nothing" {
    write_ck j1 3 0
    mkjob j1 running
    before=$(cksum < "$CK/j1.json")
    MOTHER_JOB_ID=j1 run mother check NOPE-9 --done
    [ "$status" -eq 1 ]
    [[ "$output" == *"HC10-1"* && "$output" == *"HC10-2"* && "$output" == *"HC10-3"* ]]
    [ "$(cksum < "$CK/j1.json")" = "$before" ]
    [ "$(count_kind j1 criterion_checked)" = "0" ]
}

@test "status: text output has a checklist section with [x]/[ ] lines, id, text and evidence" {
    write_ck j1 3 1
    mkjob j1 running
    run mother status j1
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== checklist ==="* ]]
    echo "$output" | grep -F "[x] HC10-1 $SECRET 0" | grep -q "abc123"
    echo "$output" | grep -qF "[ ] HC10-2 $SECRET 1"
}

# =============================================================================
# (d) progress uses done/total  (HC10-3)
# =============================================================================

@test "progress: without a checklist the build figure is elapsed-only (baseline 40)" {
    write_std_cal
    build_job r0 '.criteria_source = "ledger"'
    tick_ok 0
    [ "$(pj r0 .pct)" = "40" ]
}

@test "progress: 3/4 done during build lifts pct above elapsed-only and stays below the gates stage" {
    write_std_cal
    write_ck r1 4 3
    build_job r1 '.criteria_source = "checklist"'
    tick_ok 0
    [ "$(pj r1 .pct)" = "60" ]
    [ "$(pj r1 .signals.checklist | jq -c '[.status,.done,.total,.source]')" = '["available",3,4,"checklist"]' ]
    [ "$(pj r1 .signals.stage)" = "build" ]
}

@test "progress: fewer done than elapsed fraction does not lower the figure" {
    write_std_cal
    write_ck r1 4 1
    build_job r1
    tick_ok 0
    [ "$(pj r1 .pct)" = "40" ]
}

@test "progress: all done is capped at 0.9 of the build stage (72 -> 70), never reaching gates" {
    write_std_cal
    write_ck r1 4 4
    build_job r1
    tick_ok 0
    [ "$(pj r1 .pct)" = "70" ]
    [ "$(pj r1 .signals.stage)" = "build" ]
}

# =============================================================================
# (e)(f)(g) unavailable / ledger / default source  (HC10-4)
# =============================================================================

@test "progress: missing checklist file is unavailable and equals the no-checklist figure" {
    write_std_cal
    build_job r1
    tick_ok 0
    [ "$(pj r1 .signals.checklist.status)" = "unavailable" ]
    [ "$(pj r1 .signals.checklist.source)" = "checklist" ]
    [ "$(pj r1 .pct)" = "40" ]
}

@test "progress: corrupt checklist file is unavailable and does not crash the tick" {
    write_std_cal
    mkdir -p "$CK"; echo '{not json' > "$CK/r1.json"
    build_job r1
    tick_ok 0
    [ "$(pj r1 .signals.checklist.status)" = "unavailable" ]
    [ "$(pj r1 .pct)" = "40" ]
}

@test "progress: empty checklist (no items) is unavailable and equals the no-checklist figure" {
    write_std_cal
    mkdir -p "$CK"; echo '{"v":1,"items":[]}' > "$CK/r1.json"
    build_job r1
    tick_ok 0
    [ "$(pj r1 .signals.checklist.status)" = "unavailable" ]
    [ "$(pj r1 .pct)" = "40" ]
}

@test "progress: criteria_source=ledger is unavailable (source ledger) even if a checklist file exists" {
    write_std_cal
    write_ck r1 4 4
    build_job r1 '.criteria_source = "ledger"'
    tick_ok 0
    [ "$(pj r1 .signals.checklist | jq -c '[.status,.source]')" = '["unavailable","ledger"]' ]
    [ "$(pj r1 .pct)" = "40" ]
}

@test "progress: a job without criteria_source behaves as checklist" {
    write_std_cal
    write_ck r1 4 3
    build_job r1
    [ "$(jq 'has("criteria_source")' "$JOBS_DIR/r1.json")" = "false" ]
    tick_ok 0
    [ "$(pj r1 .signals.checklist.source)" = "checklist" ]
    [ "$(pj r1 .pct)" = "60" ]
}

# =============================================================================
# (h) status json and no criterion text leakage  (HC10-5/6)
# =============================================================================

@test "status --format json progress shows done/total, and criterion text is nowhere outside the checklist file" {
    write_std_cal
    write_ck r1 4 3
    build_job r1
    tick_ok 0
    MOTHER_JOB_ID=r1 run mother check HC10-4 --done --evidence deadbee
    [ "$status" -eq 0 ]
    tick_ok 30
    out=$(mother status r1 --format json)
    [ "$(echo "$out" | jq '.job.progress.signals.checklist.total')" = "4" ]
    [ "$(echo "$out" | jq '.job.progress.signals.checklist.done')" = "4" ]
    [[ "$out" != *"$SECRET"* ]]
    ! grep -rF "$SECRET" "$JOBS_DIR" "$EVENTS_DIR" "$PROG_DIR"
    grep -qF "$SECRET" "$CK/r1.json"
}
