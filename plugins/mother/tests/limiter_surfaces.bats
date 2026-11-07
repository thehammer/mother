#!/usr/bin/env bats
# limiter_surfaces.bats — the backpressure limiter's visible surfaces (L2): the limiter block,
# `mother limiter [status|signals|report]`, wait reasons on ready/queued jobs, the list marker and
# the `mother status` lines. Observe-only: nothing here changes dispatch.
#
# Contract under test:
#   Block      `mother limiter --json` = tests/fixtures/limiter_block.json's `limiter_block` shape.
#   Wait       every ready/queued job carries limiter.wait {code, reason, source, advisory, would, since};
#              code is what ACTUALLY holds it, checked in order dep_wait, backoff (not_before),
#              ratelimit_paused, quota_over_cap, low_disk, concurrency_full, next. It is rewritten only
#              when the code changes.
#   Fail safe  a stale state.json or a limiter-fault.json is said plainly, in text and in the block.
#   Report     would-vs-actual divergences, distress per 10 job-hours, exhaustion while admitting,
#              calibration and PASS/FAIL verdicts against the MC-41 targets.

load 'test_helper'

FIXTURE="$BATS_TEST_DIRNAME/fixtures/limiter_block.json"

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME" "$MOTHER_ROOT/limiter"
    export MOTHER_BISHOP_POSTURE_FILE="$MOTHER_ROOT/bishop-posture.json"
    export MOTHER_RATE_LIMIT_CACHE="$MOTHER_ROOT/rate-limits.json"
    unset MOTHER_LIMITER_MODE MOTHER_LIMITER_INTERVAL MOTHER_CONCURRENCY MOTHER_QUOTA_CAP_5H_PCT \
          MOTHER_QUOTA_CAP_7D_PCT MOTHER_QUOTA_FEED_MAX_AGE_S MOTHER_PHI_REPOS MOTHER_COMPANY_REPOS
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_POSTURE_ENABLED=0
}

teardown() {
    teardown_mother_env
}

_now() { date +%s; }

_bishop() {   # <5h pct> <7d pct>
    jq -nc --argjson p5 "$1" --argjson p7 "$2" --argjson r5 "$(( $(_now) + 3600 ))" --argjson r7 "$(( $(_now) + 86400 ))" '
        {posture: "Cruise", stale_input: false,
         five_hour: {used_pct: $p5, resets_at: $r5}, seven_day: {used_pct: $p7, resets_at: $r7}}' > "$MOTHER_BISHOP_POSTURE_FILE"
}

_age() {   # <file> <seconds from now, negative = past>
    /usr/bin/perl -e 'my $t = time + $ARGV[1]; utime($t, $t, $ARGV[0]) or die "utime: $!"' "$1" "$2"
}

_mtime() { /usr/bin/perl -e 'print((stat($ARGV[0]))[9])' "$1"; }

_runner_tick() { MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1; }

# A hand-written state.json as the tick would leave it. <name> is one of steady|backoff|ramp|uncalibrated.
_state() {
    local now; now=$(_now)
    local bo=3 ramp=false cal=true cut_at=$((now - 360)) rlevel=5
    case "$1" in
        steady) bo=5; cut_at=null ;;
        ramp) bo=5; ramp=true; rlevel=3; cut_at=null ;;
        uncalibrated) bo=5; cal=false; cut_at=null ;;
    esac
    jq -nc --argjson now "$now" --argjson bo "$bo" --argjson ramp "$ramp" --argjson cal "$cal" \
        --argjson cut "$cut_at" --argjson rlevel "$rlevel" '
        {v: 1, ts: $now, ceiling: 5, allowed: ([$bo, (if $ramp then $rlevel else 5 end)] | min),
         admissions_paused_until: 0,
         components: {backoff_level: $bo, ramp_level: (if $ramp then $rlevel else 5 end), ramp_active: $ramp,
                      last_cut_at: $cut, cut: false, distress_24h: (if $cut then 1 else 0 end),
                      last_distress: (if $cut then {at: $cut, job_id: "job-x", kind: "api_retry", status: 429} else null end)},
         budget: {gate: "on", stale: false, advisory: false, overage_in_use: false, reserve_pct: 15, fleet_usd_per_min: 0.8412,
                  five_hour: {used_pct: 40, resets_at: ($now + 3600), k: (if $cal then 2.0 else null end), k_samples: (if $cal then 20 else 3 end),
                              calibrated: $cal, sustainable_pct_per_min: 1.22, projected_pct_per_min: (if $cal then 1.68 else null end),
                              pace: (if $cal then 1.3770 else null end)},
                  seven_day: {used_pct: 10, resets_at: ($now + 86400), k: null, k_samples: 0, calibrated: false,
                              sustainable_pct_per_min: 0.06, projected_pct_per_min: null, pace: null}},
         interactive: {state: "ok", pct_per_hour: 4.2, high_since: null},
         ready: [], running: [range(4)] | map({id: ("r\(.)"), class: "personal", would_hold: false, would_preempt: false, advisory: false}),
         backoff: {level: $bo, last_cut_at: $cut, last_distress_at: $cut, last_raise_at: $cut},
         ramp: {active: $ramp, level: $rlevel, last_step_at: ($now - 60)},
         windows: {}, distress_log: (if $cut then [$cut] else [] end),
         waiting: [{id: "w1", code: "next", reason: "next to start", source: "dispatch", advisory: false,
                    would: {code: "reserve", reason: "reserve held for interactive work"},
                    since: "2026-11-06T22:12:00Z"}]}' > "$MOTHER_ROOT/limiter/state.json"
}

_block() { mother limiter --json; }

# Paths of every leaf of a JSON document, with array indexes dropped: a comparable key set.
_keyset() { jq -r '[paths(scalars) | map(select(type == "string")) | join(".")] | unique | .[]'; }

# ===========================================================================
# L2-1  the block
# ===========================================================================

@test "L2-1: the block has every contract key and enum value in steady, backoff, ramp and uncalibrated" {
    local want='age_s,burn,concurrency,fault,gate,interactive,last_distress,distress_24h,mode,overage_in_use,reserve,stale,v,waiting'
    local name
    for name in steady backoff ramp uncalibrated; do
        _state "$name"
        run _block
        [ "$status" -eq 0 ]
        [ "$(jq -r 'keys | sort | join(",")' <<<"$output" | tr ',' '\n' | sort | paste -sd, -)" = "$(tr ',' '\n' <<<"$want" | sort | paste -sd, -)" ]
        jq -e '.v == 1 and .mode == "observe" and .stale == false and .fault == null' <<<"$output" >/dev/null
        jq -e '.concurrency.state | IN("steady", "backoff", "ramp", "uncalibrated")' <<<"$output" >/dev/null
        [ "$(jq -r '.concurrency.state' <<<"$output")" = "$name" ]
        jq -e '[.waiting[].source] | all(IN("dispatch", "limiter"))' <<<"$output" >/dev/null
        jq -e '.concurrency | (keys | join(",")) == "allowed,ceiling,detail,effective,state"' <<<"$output" >/dev/null
        jq -e '.burn | (keys | join(",")) == "calibrated,fleet_usd_per_min,pace,sustainable_usd_per_min,window"' <<<"$output" >/dev/null
        jq -e '.reserve | (keys | join(",")) == "enforceable,holding,pct"' <<<"$output" >/dev/null
    done
}

@test "L2-1: backoff after a 429 reports allowed below ceiling, effective = running jobs, and says why" {
    _state backoff
    run _block
    jq -e '.concurrency.ceiling == 5 and .concurrency.allowed == 3 and .concurrency.effective == 4' <<<"$output" >/dev/null
    jq -e '.concurrency.detail | test("cut 6m ago after 429; \\+1 in 9m")' <<<"$output" >/dev/null
    jq -e '.last_distress.status == 429 and .last_distress.job_id == "job-x" and (.last_distress.ago_s | . >= 360 and . < 380) and .distress_24h == 1' <<<"$output" >/dev/null
    jq -e '.burn.fleet_usd_per_min == 0.84 and .burn.sustainable_usd_per_min == 0.61 and .burn.pace == 1.38 and .burn.window == "five_hour" and .burn.calibrated == true' <<<"$output" >/dev/null
}

@test "L2-1: ramp after a reset and uncalibrated are named, with the null burn the block allows" {
    _state ramp
    run _block
    jq -e '.concurrency.state == "ramp" and .concurrency.allowed == 3 and (.concurrency.detail | test("ramp"))' <<<"$output" >/dev/null
    _state uncalibrated
    run _block
    jq -e '.concurrency.state == "uncalibrated" and .burn.calibrated == false and .burn.pace == null and .burn.sustainable_usd_per_min == null' <<<"$output" >/dev/null
    jq -e '.concurrency.detail | test("3 of 12")' <<<"$output" >/dev/null
}

@test "L2-1: mode off prints exactly {v:1, mode:off}" {
    _state steady
    MOTHER_LIMITER_MODE=off run mother limiter --json
    [ "$(jq -cS . <<<"$output")" = '{"mode":"off","v":1}' ]
}

@test "L2-1: a never-ticked limiter is a stale block with null sections, not an error" {
    run _block
    [ "$status" -eq 0 ]
    jq -e '.stale == true and .age_s == null and .concurrency == null and .waiting == []' <<<"$output" >/dev/null
}

# ===========================================================================
# L2-2  mother limiter / mother status text
# ===========================================================================

@test "L2-2: mother limiter prints the six summary lines and one line per waiting job" {
    _state backoff
    run mother limiter
    [ "$status" -eq 0 ]
    [[ "$output" == *"mode: observe  (enforcement off)"* ]]
    [[ "$output" == *"concurrency: allowed 3 of 5, effective 4"*"backoff: cut 6m ago after 429; +1 in 9m"* ]]
    [[ "$output" == *"burn: 0.84 \$/min vs sustainable 0.61 \$/min (5h pace 1.38×)"* ]]
    [[ "$output" == *"reserve: 15% of 5h (not holding)"* ]]
    [[ "$output" == *"interactive: ok (4.2 %/h)"* ]]
    [[ "$output" == *"last distress: 6m ago (429 on job-x) — 1 in 24h"* ]]
    [[ "$output" == *"waiting: w1  [next] next to start"* ]]
}

@test "L2-2: mother status shows allowed/effective, burn vs sustainable, reserve, last distress and the backoff state" {
    _state backoff
    run mother status
    [ "$status" -eq 0 ]
    local conc_line limiter_text
    [[ "$output" == *"Concurrency:"* ]]
    [[ "$output" == *"allowed 3 of 5, effective 4"* ]]
    [[ "$output" == *"backoff"* ]]
    [[ "$output" == *"burn 0.84 \$/min vs sustainable 0.61 \$/min"* ]]
    [[ "$output" == *"reserve 15%"* ]]
    [[ "$output" == *"last distress 6m ago"* ]]
    # the limiter lines sit under Concurrency:, before Queue:
    local c l q
    c=$(grep -n '^Concurrency:' <<<"$output" | head -1 | cut -d: -f1)
    l=$(grep -n 'allowed 3 of 5' <<<"$output" | head -1 | cut -d: -f1)
    q=$(grep -n '^Queue:' <<<"$output" | head -1 | cut -d: -f1)
    [ "$c" -lt "$l" ] && [ "$l" -lt "$q" ]
}

@test "L2-2: mother status --format json includes the limiter block" {
    _state steady
    run mother status --format json
    [ "$status" -eq 0 ]
    jq -e '.limiter.v == 1 and .limiter.mode == "observe" and .limiter.concurrency.state == "steady"' <<<"$output" >/dev/null
}

# ===========================================================================
# L2-3  wait reasons; L2-4 rewritten only on change
# ===========================================================================

_dispatch_last() {   # <paused 0|1> <over_cap 0|1> <low_disk 0|1> [running]
    mkdir -p "$RUNNER_DIR"
    jq -nc --argjson ts "$(_now)" --argjson p "$1" --argjson o "$2" --argjson l "$3" --argjson r "${4:-0}" \
        '{ts: $ts, running: $r, ceiling: 5, ratelimit_paused: ($p == 1), quota_over_cap: ($o == 1), low_disk: ($l == 1), spawned: [], skipped: []}' \
        > "$RUNNER_DIR/dispatch-last.json"
}

_wait() { jq -r ".limiter.wait.$2" "$JOBS_DIR/$1.json"; }

@test "L2-3: a queued job with dep_wait carries the dependency's reason" {
    _bishop 10 10
    make_job q-1 queued '.dep_wait = {dep_id: "dep-1", status: "wait", reason: "dependency dep-1 is still running"}'
    _runner_tick
    [ "$(_wait q-1 code)" = "dep_wait" ]
    [ "$(_wait q-1 reason)" = "dependency dep-1 is still running" ]
    [ "$(_wait q-1 source)" = "dispatch" ]
}

@test "L2-3: a ready job with a future not_before is backoff, with the countdown" {
    _bishop 10 10
    make_job b-1 ready ".not_before = $(( $(_now) + 125 ))"
    _runner_tick
    [ "$(_wait b-1 code)" = "backoff" ]
    [[ "$(_wait b-1 reason)" == "rate-limit backoff, starts in "[0-9]*m ]]
}

@test "L2-3: ratelimit_paused beats quota_over_cap and the rest" {
    _bishop 95 10
    _dispatch_last 1 1 1 5
    make_job p-1 ready
    export MOTHER_CONCURRENCY=1
    make_job p-run running
    _runner_tick
    [ "$(_wait p-1 code)" = "ratelimit_paused" ]
}

@test "L2-3: quota over cap names the window, its use and the cap" {
    _bishop 93 10
    _dispatch_last 0 1 0
    make_job o-1 ready
    _runner_tick
    [ "$(_wait o-1 code)" = "quota_over_cap" ]
    [ "$(_wait o-1 reason)" = "quota gate: 5h at 93% ≥ cap 90%" ]
}

@test "L2-3: a force-started job is not held by the quota cap" {
    _bishop 93 10
    _dispatch_last 0 1 0
    make_job f-1 ready '.force_start = true'
    _runner_tick
    [ "$(_wait f-1 code)" = "next" ]
}

@test "L2-3: low disk holds a ready job" {
    _bishop 10 10
    _dispatch_last 0 0 1
    make_job d-1 ready
    _runner_tick
    [ "$(_wait d-1 code)" = "low_disk" ]
}

@test "L2-3: concurrency full says how many of how many are running" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=2
    make_job c-run1 running
    make_job c-run2 running
    make_job c-1 ready
    _runner_tick
    [ "$(_wait c-1 code)" = "concurrency_full" ]
    [ "$(_wait c-1 reason)" = "2 of 2 running" ]
}

@test "L2-3: with nothing in the way a ready job is next" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=3
    make_job n-1 ready
    _runner_tick
    [ "$(_wait n-1 code)" = "next" ]
    [ "$(_wait n-1 reason)" = "next to start" ]
    [ "$(jq -r '.limiter.wait.advisory' "$JOBS_DIR/n-1.json")" = "false" ]
}

@test "L2-3: the limiter's own different decision rides along as would; an agreeing or admitting one does not" {
    _bishop 95 10   # 5h reserve held: the limiter would hold, dispatch (no flags) has nothing in the way
    export MOTHER_CONCURRENCY=3
    make_job w-1 ready
    _runner_tick
    [ "$(_wait w-1 code)" = "next" ]
    [ "$(_wait w-1 would.code)" = "reserve" ]
    [ "$(jq -r '.limiter.wait.would | has("reason")' "$JOBS_DIR/w-1.json")" = "true" ]
}

@test "L2-3: awaiting jobs get no wait annotation" {
    _bishop 10 10
    make_job aw-1 awaiting
    _runner_tick
    [ "$(jq -r '.limiter.wait // "none"' "$JOBS_DIR/aw-1.json")" = "none" ]
}

@test "L2-3: mother list shows [WAIT <code>] and mother status <id> shows the Waiting: line" {
    _bishop 93 10
    _dispatch_last 0 1 0
    make_job l-1 ready
    make_job l-2 queued '.dep_wait = {dep_id: "x", status: "wait", reason: "dependency x is open"}'
    _runner_tick
    run mother list
    [ "$status" -eq 0 ]
    [[ "$(grep '^l-1 ' <<<"$output")" == *"[WAIT quota_over_cap]"* ]]
    [[ "$(grep '^l-2 ' <<<"$output")" == *"[WAIT dep_wait]"* ]]
    run mother status l-1
    [[ "$output" == *"Waiting: quota gate: 5h at 93% ≥ cap 90%"* ]]
}

@test "L2-3: a running job shows no wait marker even with a stale annotation" {
    make_job r-1 running '.limiter = {wait: {code: "next", reason: "next to start"}}'
    run mother list
    [[ "$(grep '^r-1 ' <<<"$output")" != *"WAIT"* ]]
    run mother status r-1
    [[ "$output" != *"Waiting:"* ]]
}

@test "L2-4: the wait annotation is written once: three unchanged ticks leave the job file's mtime alone" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=3
    make_job m-1 ready
    _runner_tick
    local first; first=$(_mtime "$JOBS_DIR/m-1.json")
    local since; since=$(_wait m-1 since)
    sleep 1.1
    _runner_tick
    sleep 1.1
    _runner_tick
    [ "$(_mtime "$JOBS_DIR/m-1.json")" = "$first" ]
    [ "$(_wait m-1 since)" = "$since" ]
}

@test "L2-4: when the code changes the annotation is rewritten and since moves" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=3
    make_job m-2 ready
    _runner_tick
    [ "$(_wait m-2 code)" = "next" ]
    local since; since=$(_wait m-2 since)
    sleep 1.1
    _dispatch_last 0 0 1
    _runner_tick
    [ "$(_wait m-2 code)" = "low_disk" ]
    [ "$(_wait m-2 since)" != "$since" ]
}

@test "L2-3: the waiting rows of the block are the same rows, oldest job first" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=3
    make_job k-2 ready '.created_at = "2026-11-01T10:00:02Z"'
    make_job k-1 ready '.created_at = "2026-11-01T10:00:01Z"'
    _runner_tick
    run _block
    [ "$(jq -r '[.waiting[].id] | join(",")' <<<"$output")" = "k-1,k-2" ]
    jq -e '.waiting | all(.source == "dispatch" and .code == "next" and (.since | test("^[0-9]{4}-")))' <<<"$output" >/dev/null
}

# ===========================================================================
# L2-5  signals
# ===========================================================================

@test "L2-5: signals prints per window used %, reset, pace, sustainable and projected rate, k and samples, plus the rest" {
    _state backoff
    run mother limiter signals
    [ "$status" -eq 0 ]
    [[ "$output" == *"five_hour:"* && "$output" == *"seven_day:"* ]]
    [[ "$output" == *"used: 40%"* ]]
    [[ "$output" == *"pace: 1.38"* ]]
    [[ "$output" == *"sustainable: 1.22 %/min"* && "$output" == *"projected: 1.68 %/min"* ]]
    [[ "$output" == *"k: 2 %/USD"*"samples: 20 (calibrated)"* ]]
    [[ "$output" == *"resets: "*"CST"*"UTC)"* || "$output" == *"resets: "*"CDT"*"UTC)"* ]]
    [[ "$output" == *"fleet burn: 0.84 \$/min"* ]]
    [[ "$output" == *"reserve: 15% of 5h (not holding)"* ]]
    [[ "$output" == *"interactive: ok (4.2 %/h)"* ]]
    [[ "$output" == *"overage in use: false"* ]]
    [[ "$output" == *"distress: 1 in 1h, 1 in 24h"* ]]
}

@test "L2-5: signals --json carries the same values" {
    _state backoff
    run mother limiter signals --json
    jq -e '.windows.five_hour.k == 2 and .windows.five_hour.k_samples == 20 and .windows.five_hour.pace == 1.38
           and .distress.h1 == 1 and .distress.h24 == 1 and .reserve_pct == 15 and .overage_in_use == false' <<<"$output" >/dev/null
}

# ===========================================================================
# L2-6  report
# ===========================================================================

# Decision-log fixture, all times 2026-11-01 (the report is asked --since an ISO time):
#   rotated file (.1): 09:55 running 1                                   (in range: the .1 is read too)
#   10:00 running 2, would_hold_but_spawned (reserve), 5h 50% gate on
#   10:05 running 3 (ceiling 3), limiter would admit j9, not spawned  -> would_admit_but_waited concurrency_full
#   10:10 running 3, 5h 100% gate on, spawned [j7]                    \ one exhaustion-while-admitting run
#   10:15 running 3, 5h 100% gate on                                  /
#   10:20 running 3, 5h 50%
#   08:00 (before --since 09:00) running 9 must not count
# Job-seconds: 09:55->10:00 1*300 + 10:00->10:05 2*300 + 3*300*3 = 300 + 600 + 2700 = 3600 = 1.0 job-hours
# Two distress events in range, one before: 2 / 1.0 * 10 = 20.0 per 10 job-hours  -> FAIL (< 1)
_seed_decisions() {
    local d="$MOTHER_ROOT/limiter"
    _row() {   # ts running ceiling used5 gate spawned-json would-json div-json
        jq -nc --arg ts "$1" --argjson run "$2" --argjson c "$3" --argjson u "$4" --arg g "$5" --argjson sp "$6" --argjson w "$7" --argjson dv "$8" \
            '{ts: $ts, mode: "observe", allowed: 3, running: $run, would: $w,
              actual: {spawned: $sp, skipped: [], ratelimit_paused: false, quota_over_cap: false, low_disk: false, running: $run, ceiling: $c},
              divergence: $dv, window: {used_pct_5h: $u, gate: $g}}'
    }
    local none='{"admit":[],"hold":[],"advisory":[],"hold_running":[],"preempt":[]}'
    {
        _row 2026-11-01T08:00:00Z 9 3 10 on '[]' "$none" '[]'
    } > "$d/decisions.jsonl.1"
    echo '{"x":' >> "$d/decisions.jsonl.1"   # a torn line is skipped
    {
        _row 2026-11-01T09:55:00Z 1 3 40 on '[]' "$none" '[]'
        _row 2026-11-01T10:00:00Z 2 3 50 on '["j1"]' '{"admit":[],"hold":[{"id":"j1","code":"reserve"}],"advisory":[],"hold_running":[],"preempt":[]}' \
            '[{"id":"j1","kind":"would_hold_but_spawned","code":"reserve"}]'
        _row 2026-11-01T10:05:00Z 3 3 60 on '[]' '{"admit":["j9"],"hold":[],"advisory":[],"hold_running":[],"preempt":[]}' '[]'
        _row 2026-11-01T10:10:00Z 3 3 100 on '["j7"]' "$none" '[]'
        _row 2026-11-01T10:15:00Z 3 3 100 on '[]' "$none" '[]'
        _row 2026-11-01T10:20:00Z 3 3 50 on '[]' "$none" '[]'
    } > "$d/decisions.jsonl"
    {
        echo '{"ts":"2026-11-01T07:00:00Z","job_id":"old","kind":"api_retry","status":429}'
        echo '{"ts":"2026-11-01T10:03:00Z","job_id":"j1","kind":"api_retry","status":429}'
        echo '{"ts":"2026-11-01T10:12:00Z","job_id":"j2","kind":"result_error","status":529}'
    } > "$d/distress.jsonl"
    _state steady
}

@test "L2-6: report --json counts divergences by type and code, distress per 10 job-hours, exhaustion and verdicts" {
    _seed_decisions
    run mother limiter report --since 2026-11-01T09:00:00Z --json
    [ "$status" -eq 0 ]
    jq -e '.divergences.would_hold_but_spawned.count == 1 and .divergences.would_hold_but_spawned.top_codes[0] == {code: "reserve", count: 1}' <<<"$output" >/dev/null
    jq -e '.divergences.would_admit_but_waited.count == 1 and .divergences.would_admit_but_waited.top_codes[0] == {code: "concurrency_full", count: 1}' <<<"$output" >/dev/null
    jq -e '.distress.count == 2 and .distress.job_hours == 1 and .distress.per_10_job_hours == 20' <<<"$output" >/dev/null
    jq -e '.exhaustion_while_admitting.count == 1' <<<"$output" >/dev/null
    jq -e '.decisions == 6' <<<"$output" >/dev/null
    jq -e '(.verdicts[] | select(.name == "429 rate per 10 job-hours")).result == "FAIL"' <<<"$output" >/dev/null
    jq -e '(.verdicts[] | select(.name == "5h exhausted while admitting")).result == "FAIL"' <<<"$output" >/dev/null
    jq -e '.calibration.five_hour.calibrated == true and .calibration.five_hour.k == 2' <<<"$output" >/dev/null
}

@test "L2-6: without a spawn in the exhausted stretch the exhaustion verdict passes" {
    _seed_decisions
    sed -i.bak 's/"spawned":\["j7"\]/"spawned":[]/' "$MOTHER_ROOT/limiter/decisions.jsonl"
    run mother limiter report --since 2026-11-01T09:00:00Z --json
    jq -e '.exhaustion_while_admitting.count == 0' <<<"$output" >/dev/null
    jq -e '(.verdicts[] | select(.name == "5h exhausted while admitting")).result == "PASS"' <<<"$output" >/dev/null
}

@test "L2-6: the text report prints the verdict lines, and a 429 rate under 1 per 10 job-hours passes" {
    local d="$MOTHER_ROOT/limiter" i ts
    : > "$d/decisions.jsonl"
    # 13 samples, 3 running, 5 minutes apart: 12 intervals * 300s * 3 = 10800 job-s = 3.0 job-hours
    for i in 0 1 2 3 4 5 6 7 8 9 10 11 12; do
        ts=$(printf '2026-11-01T%02d:%02d:00Z' $((10 + i * 5 / 60)) $((i * 5 % 60)))
        jq -nc --arg ts "$ts" '{ts: $ts, mode: "observe", allowed: 3, running: 3, would: {admit: []},
            actual: {spawned: [], running: 3, ceiling: 3}, divergence: [], window: {used_pct_5h: 20, gate: "on"}}' >> "$d/decisions.jsonl"
    done
    : > "$d/distress.jsonl"
    run mother limiter report --since 2026-11-01T09:00:00Z
    [ "$status" -eq 0 ]
    [[ "$output" == *"429 rate: 0.0 per 10 job-hours (target < 1) PASS"* ]]
    [[ "$output" == *"5h exhausted while admitting: 0 (target 0) PASS"* ]]
    echo '{"ts":"2026-11-01T10:30:00Z","job_id":"j1","kind":"api_retry","status":429}' > "$d/distress.jsonl"
    run mother limiter report --since 2026-11-01T09:00:00Z --json
    jq -e '.distress.job_hours == 3 and .distress.per_10_job_hours == 3.33' <<<"$output" >/dev/null
    run mother limiter report --since 2026-11-01T09:00:00Z
    [[ "$output" == *"429 rate: 3.3 per 10 job-hours (target < 1) FAIL"* ]]
}

@test "L2-6: an empty range says n/a instead of passing the 429 target" {
    run mother limiter report --since 24h
    [ "$status" -eq 0 ]
    [[ "$(grep '429 rate:' <<<"$output")" == *"n/a"* ]]
    [[ "$(grep '429 rate:' <<<"$output")" != *"PASS"* ]]
}

@test "L2-6: a bad --since is refused" {
    run mother limiter report --since yesterday
    [ "$status" -ne 0 ]
}

# ===========================================================================
# L2-7  stale and fault
# ===========================================================================

@test "L2-7: a stale state.json is reported as not running, in text, status and the block" {
    _state backoff
    _age "$MOTHER_ROOT/limiter/state.json" -240
    run mother limiter
    [[ "$output" == *"limiter: not running (last tick 4m ago) — dispatch uses fixed concurrency"* ]]
    run mother status
    [[ "$output" == *"limiter: not running"*"dispatch uses fixed concurrency"* ]]
    run _block
    jq -e '.stale == true and .age_s >= 240' <<<"$output" >/dev/null
}

@test "L2-7: a limiter-fault.json is reported plainly and shows up as fault" {
    _state steady
    mkdir -p "$RUNNER_DIR"
    echo '{"at":"2026-11-06T22:00:00Z","why":"tick exited 2"}' > "$RUNNER_DIR/limiter-fault.json"
    run mother limiter
    [[ "$output" == *"limiter: not running (last tick failed: tick exited 2) — dispatch uses fixed concurrency"* ]]
    run mother status
    [[ "$output" == *"limiter: not running"*"dispatch uses fixed concurrency"* ]]
    run _block
    jq -e '.fault.why == "tick exited 2" and .stale == false' <<<"$output" >/dev/null
}

# ===========================================================================
# L2-9  golden fixture
# ===========================================================================

@test "L2-9: the fixture's limiter_block has the same key set as the CLI emits for a populated state" {
    _state backoff
    run _block
    [ "$status" -eq 0 ]
    local got want
    got=$(_keyset <<<"$output")
    want=$(jq '.limiter_block' "$FIXTURE" | _keyset)
    [ "$got" = "$want" ]
}

@test "L2-9: the fixture's _doc names every field of the block, every enum value and the category" {
    local doc; doc=$(jq -r '._doc' "$FIXTURE")
    local k
    for k in $(jq '.limiter_block' "$FIXTURE" | jq -r '[paths | map(select(type == "string")) | .[-1]] | unique | .[]'); do
        [[ "$doc" == *"$k"* ]] || { echo "_doc does not mention $k" >&2; false; }
    done
    for k in steady backoff ramp uncalibrated observe off dispatch limiter dep_wait ratelimit_paused quota_over_cap low_disk \
             concurrency_full next budget_pace interactive_personal retry_after off_until_reset; do
        [[ "$doc" == *"$k"* ]] || { echo "_doc does not mention $k" >&2; false; }
    done
    jq -e '.snapshot_envelope.data | has("limiter") and has("quota") and has("jobs") and has("sub")' "$FIXTURE" >/dev/null
    jq -e '.event_envelope.t == "limiter" and .event_envelope.data.category == "limiter"' "$FIXTURE" >/dev/null
}

@test "L2-9: the fixture's block uses only contract enum values" {
    jq -e '.limiter_block | .mode == "observe" and (.concurrency.state | IN("steady","backoff","ramp","uncalibrated"))
           and ([.waiting[].source] | all(IN("dispatch","limiter"))) and (.interactive.state | IN("ok","high","unknown"))
           and (.gate | IN("on","off","off_until_reset"))' "$FIXTURE" >/dev/null
}
