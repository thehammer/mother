#!/usr/bin/env bats
# limiter_enforce_admission.bats — the backpressure limiter's enforce mode (L3): the limiter decides what
# dispatch starts. End to end through the shell: `mother limiter mode`, `mother priority`, the runner's
# limiter tick and dispatch tick, `mother route-failure`, `mother status` and `mother ack`.
#
# Contract under test (acceptance criteria L3-1 .. L3-11):
#   L3-1   `mother limiter mode [observe|enforce|off]`: owner-only switch, audited, refused for workers.
#          MOTHER_LIMITER_MODE=off wins; MOTHER_LIMITER_MODE=enforce is NOT honoured (file only).
#   L3-7   `mother add --priority` / `mother priority <id> raise|lower|normal`; raising is owner-at-a-
#          terminal only. Company ranks before personal, a raised personal job ranks with company.
#   L3-2.. Under enforce the tick writes state.json `admit` (ordered ids, cumulative burn, never more than
#          allowed - running; advisory budget holds are admitted and consume a slot) and gives held ready
#          jobs limiter.wait {source: "limiter", advisory: false, code, reason}. Dispatch, while enforcing
#          (mode enforce + fresh state.json + no limiter-fault.json + state.mode == enforce), takes ids
#          from `admit` in order, bounded by min(MOTHER_CONCURRENCY, allowed), ignores ratelimit-until,
#          keeps the quota-gate cap as a backstop.
#   L3-8   route-failure of a rate-limited job under enforce: no elapsed-time give-up, retry-after honoured.
#   L3-9   a dead limiter degrades enforce to observe-style dispatch, loudly (limiter_fault attention).
#   L3-10  force_start skips budget holds, never backoff / ramp.
#   L3-11  no divergence between what the limiter admitted and what dispatch did.

load 'test_helper'
load 'gh_mock'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/limiter"

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME" "$MOTHER_ROOT/limiter"
    export MOTHER_BISHOP_POSTURE_FILE="$MOTHER_ROOT/bishop-posture.json"
    export MOTHER_RATE_LIMIT_CACHE="$MOTHER_ROOT/rate-limits.json"
    unset MOTHER_LIMITER_MODE MOTHER_LIMITER_INTERVAL MOTHER_LIMITER_TIMEOUT MOTHER_PHI_REPOS MOTHER_COMPANY_REPOS \
          MOTHER_QUOTA_CAP_7D_PCT MOTHER_QUOTA_FEED_MAX_AGE_S MOTHER_LIMITER_RESERVE_PCT \
          MOTHER_LIMITER_DEFAULT_BURN_USD_PER_MIN MOTHER_LIMITER_CALM_S MOTHER_LIMITER_RAMP_START \
          MOTHER_LIMITER_RAMP_STEP_S MOTHER_LIMITER_INTERACTIVE_SUSTAIN_S MOTHER_JOB_ID CLAUDECODE \
          CLAUDE_CODE_ENTRYPOINT MOTHER_TEST_FORCE_TTY MOTHER_BACKOFF_ENABLED MOTHER_BACKOFF_BASE_S \
          MOTHER_BACKOFF_CAP_S MOTHER_BACKOFF_MAX_S MOTHER_BACKOFF_MAX_COUNT
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_MIN_FREE_GB=0
    export MOTHER_CONCURRENCY=4
    export MOTHER_QUOTA_CAP_5H_PCT=95
    export MOTHER_BACKOFF_JITTER_PCT=0
    export MOTHER_ESCALATION_ENABLED=1
    export FAKE_REPO="$MOTHER_ROOT/testrepo"
    git init -q "$FAKE_REPO"

    # A mother-run-job stand-in that only logs its argv, and a real mother-limiter next to it.
    FAKE_BIN="$MOTHER_ROOT/fake-bin"; mkdir -p "$FAKE_BIN"
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/run-job-calls"\nexit 0\n' "$MOTHER_ROOT" > "$FAKE_BIN/mother-run-job"
    printf '#!/usr/bin/env bash\nexec "%s/mother-limiter" "$@"\n' "$_BIN_DIR" > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-run-job" "$FAKE_BIN/mother-limiter"
    gh_mock_install
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_now() { date +%s; }
_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }

_age() {   # <file> <seconds from now, negative = past>
    /usr/bin/perl -e 'my $t = time + $ARGV[1]; utime($t, $t, $ARGV[0]) or die "utime: $!"' "$1" "$2"
}

# Bishop-shaped feed. Usage: _bishop <5h pct> <7d pct> [5h resets_at]
_bishop() {
    local r5="${3:-$(( $(_now) + 3600 ))}" r7="$(( $(_now) + 86400 ))"
    jq -nc --argjson p5 "$1" --argjson p7 "$2" --argjson r5 "$r5" --argjson r7 "$r7" '
        {posture: "Cruise", stale_input: false,
         five_hour: {used_pct: $p5, resets_at: $r5},
         seven_day: {used_pct: $p7, resets_at: $r7}}' > "$MOTHER_BISHOP_POSTURE_FILE"
}

# Write the limiter mode file directly (the CLI is covered by its own tests below).
_mode() {
    jq -nc --arg m "$1" '{mode: $m, changed_at: "2026-11-06T00:00:00.000Z", changed_by: "cli"}' > "$MOTHER_ROOT/limiter/mode.json"
}

# The limiter tick the way the runner's loop runs it. Extra args are VAR=value pairs for that tick only.
_tick() { env MOTHER_LIMITER_INTERVAL=0 "$@" mother-runner --limiter-tick 3>&- >/dev/null 2>&1 || true; }

# One dispatch pass; SPAWNED = comma-separated ids in the order the runner started them.
_dispatch() {
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>"$MOTHER_ROOT/d.err" 3>&- >/dev/null || true
    SPAWNED=$(sed -n 's/.*spawned job \([^ ]*\) as pid.*/\1/p' "$MOTHER_ROOT/d.err" | paste -sd, -)
}

_st() { jq -r "$1" "$MOTHER_ROOT/limiter/state.json"; }
_admit() { _st '.admit | join(",")'; }
_jf() { jq -r "$2" "$JOBS_DIR/$1.json"; }
_ev() {   # last event of <kind>'s detail as compact JSON
    [ -f "$EVENTS_DIR/$1.jsonl" ] || { echo ""; return 0; }
    jq -c --arg k "$2" 'select(.kind==$k) | .detail' "$EVENTS_DIR/$1.jsonl" | tail -1
}

# A ready job. Usage: _ljob <id> <personal|company> <created_at> <usd/min estimate> [extra jq]
_ljob() {
    local id="$1" cls="$2" created="$3" usd="$4" extra="${5:-.}"
    make_job "$id" ready ".repo_path = \"$MOTHER_ROOT\" | .data_class = \"$cls\" | .created_at = \"$created\" \
        | .limiter = {estimate: {usd_per_min: $usd, source: \"history\", basis: \"x+cody\", samples: 3, computed_at: \"$(_iso)\"}} \
        | ($extra)"
}

# A previous tick's state with the 5h window's k calibrated (<k> % per USD) and optional burn samples
# ([[ts, cum_usd, used_pct], ...] as JSON). With bishop 40% and 150 minutes left (_bishop 40 10 <now+9000>)
# the sustainable pace is 0.3 %/min.
_seed_calibrated() {
    local k="$1" samples="${2:-}" now; now=$(_now)
    # no samples given: two minutes of zero Mother spend, so the fleet burn is known (0 USD/min)
    [ -n "$samples" ] || samples="[[$(( now - 120 )), 0, 40], [$(( now - 60 )), 0, 40]]"
    jq -nc --argjson now "$now" --argjson r5 "$(( now + 9000 ))" --argjson k "$k" --argjson s "$samples" '
        {v: 1, ts: $now,
         calib: {"5h": {last: {ts: ($now - 1), used_pct: 40, resets_at: $r5, usd: 0}, ratios: [range(12) | $k]},
                 "7d": {last: null, ratios: []}},
         samples: $s}' > "$MOTHER_ROOT/limiter/state.json"
}

# A hand-written enforce-mode state.json. Usage: _hand_state <allowed> [admitted ids...]
_hand_state() {
    local allowed="$1"; shift
    local ids; ids=$(printf '%s\n' "$@" | jq -R . | jq -sc 'map(select(length > 0))')
    jq -nc --argjson now "$(_now)" --argjson a "$allowed" --argjson ids "$ids" \
        '{v: 1, ts: $now, mode: "enforce", ceiling: 4, allowed: $a, admit: $ids, ready: [], running: []}' \
        > "$MOTHER_ROOT/limiter/state.json"
}

_needs() { mother status --format json | jq -c '.needs_attention'; }

# ===========================================================================
# L3-1  the mode switch
# ===========================================================================

@test "L3-1: with no argument the mode is printed, observe by default" {
    run mother limiter mode
    [ "$status" -eq 0 ]
    [[ "$output" == *observe* ]]
}

@test "L3-1: setting enforce writes mode.json {mode, changed_at, changed_by} and one audit line" {
    run mother limiter mode enforce --source cli
    [ "$status" -eq 0 ]
    jq -e '.mode == "enforce" and (.changed_at | length > 0) and (.changed_by | length > 0)' "$MOTHER_ROOT/limiter/mode.json" >/dev/null
    [ "$(wc -l < "$MOTHER_ROOT/limiter/mode-audit.jsonl" | tr -d ' ')" = "1" ]
    grep -q enforce "$MOTHER_ROOT/limiter/mode-audit.jsonl"
    run mother limiter mode
    [[ "$output" == *enforce* ]]
}

@test "L3-1: the same mode again writes nothing: file and audit trail are untouched" {
    mother limiter mode enforce --source cli
    local before_file before_audit
    before_file=$(cat "$MOTHER_ROOT/limiter/mode.json"); before_audit=$(cat "$MOTHER_ROOT/limiter/mode-audit.jsonl")
    sleep 1
    run mother limiter mode enforce --source cli
    [ "$status" -eq 0 ]
    [ "$(cat "$MOTHER_ROOT/limiter/mode.json")" = "$before_file" ]
    [ "$(cat "$MOTHER_ROOT/limiter/mode-audit.jsonl")" = "$before_audit" ]
}

@test "L3-1: changing the mode again appends a second audit line" {
    mother limiter mode enforce --source cli
    mother limiter mode observe --source cli
    [ "$(wc -l < "$MOTHER_ROOT/limiter/mode-audit.jsonl" | tr -d ' ')" = "2" ]
    [ "$(jq -r .mode "$MOTHER_ROOT/limiter/mode.json")" = "observe" ]
}

@test "L3-1: a worker (MOTHER_JOB_ID set) is refused, the refusal is logged and the mode is unchanged" {
    run env MOTHER_JOB_ID=job-w mother limiter mode enforce --source cli
    [ "$status" -ne 0 ]
    [ -s "$MOTHER_ROOT/limiter/mode-refusals.jsonl" ]
    [ ! -e "$MOTHER_ROOT/limiter/mode.json" ] || [ "$(jq -r .mode "$MOTHER_ROOT/limiter/mode.json")" = "observe" ]
    run mother limiter mode
    [[ "$output" == *observe* ]]
}

@test "L3-1: a set-but-empty MOTHER_JOB_ID is still a worker" {
    run env MOTHER_JOB_ID= mother limiter mode enforce --source cli
    [ "$status" -ne 0 ]
    [ -s "$MOTHER_ROOT/limiter/mode-refusals.jsonl" ]
    [ ! -e "$MOTHER_ROOT/limiter/mode.json" ] || [ "$(jq -r .mode "$MOTHER_ROOT/limiter/mode.json")" = "observe" ]
}

@test "L3-1: a refused worker cannot turn enforce off either" {
    mother limiter mode enforce --source cli
    run env MOTHER_JOB_ID=job-w mother limiter mode observe --source cli
    [ "$status" -ne 0 ]
    [ "$(jq -r .mode "$MOTHER_ROOT/limiter/mode.json")" = "enforce" ]
}

@test "L3-1: a call from beneath a mother-run-job process is refused" {
    mkdir -p "$MOTHER_ROOT/anc"
    printf '#!/usr/bin/env bash\nmother limiter mode enforce --source cli\necho $? > "%s/anc/rc"\n' "$MOTHER_ROOT" > "$MOTHER_ROOT/anc/mother-run-job"
    chmod +x "$MOTHER_ROOT/anc/mother-run-job"
    run bash "$MOTHER_ROOT/anc/mother-run-job"
    [ "$(cat "$MOTHER_ROOT/anc/rc")" != "0" ]
    [ -s "$MOTHER_ROOT/limiter/mode-refusals.jsonl" ]
    [ ! -e "$MOTHER_ROOT/limiter/mode.json" ] || [ "$(jq -r .mode "$MOTHER_ROOT/limiter/mode.json")" = "observe" ]
}

@test "L3-1: MOTHER_LIMITER_MODE=off overrides the file and the mode prints off" {
    _mode enforce
    run env MOTHER_LIMITER_MODE=off mother limiter mode
    [ "$status" -eq 0 ]
    [[ "$output" == *off* ]]
}

@test "L3-1: MOTHER_LIMITER_MODE=enforce in the environment is not honoured, only the file enables enforce" {
    run env MOTHER_LIMITER_MODE=enforce mother limiter mode
    [ "$status" -eq 0 ]
    [[ "$output" == *observe* ]]
    [[ "$output" != *enforce* ]]
    _bishop 10 10
    _ljob e-1 personal 2026-11-01T00:00:01Z 0.1
    env MOTHER_LIMITER_MODE=enforce MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1 || true
    [ "$(_st '.mode')" = "observe" ]
}

# ===========================================================================
# L3-7  priority
# ===========================================================================

_padd() {
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"
    mother add --plan-file "$plan" --repo testrepo --repo-path "$FAKE_REPO" --branch "feature/$RANDOM" "$@"
}

@test "L3-7: mother add --priority raise|lower|normal stores priority_adjust +1|-1|0 (raise as the owner at a terminal)" {
    local id
    id=$(MOTHER_TEST_FORCE_TTY=1 _padd --priority raise 2>/dev/null)
    [ "$(_jf "$id" '.priority_adjust')" = "1" ]
    id=$(_padd --priority lower 2>/dev/null)
    [ "$(_jf "$id" '.priority_adjust')" = "-1" ]
    id=$(_padd --priority normal 2>/dev/null)
    [ "$(_jf "$id" '.priority_adjust')" = "0" ]
}

@test "L3-7: mother add --priority raise without a terminal is refused and says why" {
    run _padd --priority raise
    [ "$status" -ne 0 ]
    [[ "$output" == *"only the owner, at a terminal"* ]]
    [ -z "$(ls "$JOBS_DIR")" ]
}

@test "L3-7: raise is refused for a worker, for CLAUDECODE and for CLAUDE_CODE_ENTRYPOINT even with a terminal" {
    make_job p-1 ready
    run env MOTHER_TEST_FORCE_TTY=1 MOTHER_JOB_ID=job-w mother priority p-1 raise
    [ "$status" -ne 0 ]
    [[ "$output" == *"only the owner, at a terminal"* ]]
    run env MOTHER_TEST_FORCE_TTY=1 CLAUDECODE=1 mother priority p-1 raise
    [ "$status" -ne 0 ]
    [[ "$output" == *"only the owner, at a terminal"* ]]
    run env MOTHER_TEST_FORCE_TTY=1 CLAUDE_CODE_ENTRYPOINT=cli mother priority p-1 raise
    [ "$status" -ne 0 ]
    [[ "$output" == *"only the owner, at a terminal"* ]]
    run mother priority p-1 raise     # no terminal (bats stdin is not a TTY)
    [ "$status" -ne 0 ]
    [[ "$output" == *"only the owner, at a terminal"* ]]
    [ "$(_jf p-1 '.priority_adjust // 0')" = "0" ]
}

@test "L3-7: the owner at a terminal can raise a ready job; the event records from, to and by" {
    make_job p-1 ready
    run env MOTHER_TEST_FORCE_TTY=1 mother priority p-1 raise
    [ "$status" -eq 0 ]
    [ "$(_jf p-1 '.priority_adjust')" = "1" ]
    local d; d=$(_ev p-1 priority_changed)
    [ "$(jq -r .from <<<"$d")" = "normal" ]
    [ "$(jq -r .to <<<"$d")" = "raise" ]
    jq -e 'has("by")' <<<"$d" >/dev/null
}

@test "L3-7: lower and normal are always allowed, even from a worker, and a queued job can be changed" {
    make_job p-1 queued ".priority_adjust = 1"
    run env MOTHER_JOB_ID=job-w mother priority p-1 lower
    [ "$status" -eq 0 ]
    [ "$(_jf p-1 '.priority_adjust')" = "-1" ]
    local d; d=$(_ev p-1 priority_changed)
    [ "$(jq -r .from <<<"$d")" = "raise" ]
    [ "$(jq -r .to <<<"$d")" = "lower" ]
    run env CLAUDECODE=1 mother priority p-1 normal
    [ "$status" -eq 0 ]
    [ "$(_jf p-1 '.priority_adjust')" = "0" ]
}

@test "L3-7: mother priority only works on queued or ready jobs" {
    local s
    for s in running awaiting succeeded failed cancelled; do
        make_job "p-$s" "$s"
        run mother priority "p-$s" lower
        [ "$status" -ne 0 ]
        [ "$(_jf "p-$s" '.priority_adjust // 0')" = "0" ]
    done
}

@test "L3-7: company is admitted before personal whatever the created_at" {
    _mode enforce; _bishop 10 10
    _ljob pers-old personal 2026-11-01T00:00:01Z 0.1
    _ljob comp-new company 2026-11-01T00:00:09Z 0.1
    _tick
    [ "$(_admit)" = "comp-new,pers-old" ]
}

@test "L3-7: a raised personal job ranks with company, by created_at; a lowered company job ranks with personal" {
    _mode enforce; _bishop 10 10
    _ljob pers-old personal 2026-11-01T00:00:01Z 0.1
    _ljob pers-raised personal 2026-11-01T00:00:02Z 0.1 ".priority_adjust = 1"
    _ljob comp-new company 2026-11-01T00:00:03Z 0.1
    _ljob comp-lowered company 2026-11-01T00:00:00Z 0.1 ".priority_adjust = -1"
    _tick
    [ "$(_admit)" = "pers-raised,comp-new,comp-lowered,pers-old" ]
}

@test "L3-7: dispatch starts the highest-ranked job first when there is one slot" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=1
    _ljob pers-old personal 2026-11-01T00:00:01Z 0.1
    _ljob comp-new company 2026-11-01T00:00:09Z 0.1
    _tick
    _dispatch
    [ "$SPAWNED" = "comp-new" ]
    [ "$(_jf pers-old .state)" = "ready" ]
}

# ===========================================================================
# L3-2  budget pace
# ===========================================================================

@test "L3-2: an over-pace job is held with 'throttled: 5h window pace N×' while a cheaper job behind it is spawned" {
    _mode enforce
    _bishop 40 10 "$(( $(_now) + 9000 ))"
    _seed_calibrated 0.2
    _ljob big personal 2026-11-01T00:00:01Z 2.0       # 0.4 %/min against 0.3 sustainable
    _ljob small personal 2026-11-01T00:00:02Z 0.5     # 0.1 %/min
    _tick
    [ "$(_st '.mode')" = "enforce" ]
    [ "$(_admit)" = "small" ]
    [ "$(_jf big '.limiter.wait.source')" = "limiter" ]
    [ "$(_jf big '.limiter.wait.code')" = "budget_pace" ]
    [ "$(_jf big '.limiter.wait.advisory')" = "false" ]
    [[ "$(_jf big '.limiter.wait.reason')" =~ ^throttled:\ 5h\ window\ pace\ [0-9.]+×$ ]]

    _dispatch
    [ "$SPAWNED" = "small" ]
    [ "$(_jf big .state)" = "ready" ]
    [ "$(_jf small .state)" = "running" ]
}

@test "L3-2: admissions are cumulative, the second job that no longer fits is held although it would fit alone" {
    _mode enforce
    _bishop 40 10 "$(( $(_now) + 9000 ))"
    _seed_calibrated 0.2
    _ljob a personal 2026-11-01T00:00:01Z 0.8     # 0.16 %/min
    _ljob b personal 2026-11-01T00:00:02Z 0.8     # 0.16 + 0.16 = 0.32 > 0.3
    _tick
    [ "$(_admit)" = "a" ]
    [ "$(_jf b '.limiter.wait.code')" = "budget_pace" ]
}

@test "L3-2: admit never exceeds allowed minus running" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=3
    make_job run-1 running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/run-1.log"
    local i
    for i in 1 2 3 4 5; do _ljob "rdy-$i" personal "2026-11-01T00:00:0${i}Z" 0.01; done
    _tick
    [ "$(_st '.allowed')" = "3" ]
    [ "$(_st '.admit | length')" = "2" ]
    [ "$(_admit)" = "rdy-1,rdy-2" ]
    [ "$(_jf rdy-3 '.limiter.wait.code')" = "concurrency_full" ]
    [ "$(_jf rdy-3 '.limiter.wait.source')" = "limiter" ]
}

# ===========================================================================
# L3-3  reserve and the quota-gate switch
# ===========================================================================

@test "L3-3: with the 5h window's remaining headroom inside the reserve nothing is admitted ('reserve held for interactive work')" {
    _mode enforce; _bishop 90 10
    _ljob rs-a personal 2026-11-01T00:00:01Z 0.1
    _ljob rs-b company 2026-11-01T00:00:02Z 0.1
    _tick
    [ "$(_admit)" = "" ]
    local id
    for id in rs-a rs-b; do
        [ "$(_jf $id '.limiter.wait.code')" = "reserve" ]
        [ "$(_jf $id '.limiter.wait.reason')" = "reserve held for interactive work" ]
        [ "$(_jf $id '.limiter.wait.advisory')" = "false" ]
        [ "$(_jf $id '.limiter.wait.source')" = "limiter" ]
    done
    _dispatch
    [ -z "$SPAWNED" ]
}

@test "L3-3: with the quota gate off_until_reset the reserve is advisory: jobs are admitted, spawned, and the budget term is shown as advisory" {
    _mode enforce; _bishop 90 10
    run mother quota off-until-reset
    [ "$status" -eq 0 ]
    _ljob rs-a personal 2026-11-01T00:00:01Z 0.1
    _ljob rs-b personal 2026-11-01T00:00:02Z 0.1
    _tick
    [ "$(_admit)" = "rs-a,rs-b" ]
    [ "$(_st '[.ready[] | select(.id == "rs-a")] | .[0].code')" = "reserve" ]
    [ "$(_st '[.ready[] | select(.id == "rs-a")] | .[0].advisory')" = "true" ]
    _dispatch
    [ "$SPAWNED" = "rs-a,rs-b" ]
}

@test "L3-3: an advisory hold consumes a slot like any admission" {
    _mode enforce; _bishop 90 10
    export MOTHER_CONCURRENCY=1
    mother quota off-until-reset
    _ljob rs-a personal 2026-11-01T00:00:01Z 0.1
    _ljob rs-b personal 2026-11-01T00:00:02Z 0.1
    _tick
    [ "$(_admit)" = "rs-a" ]
    [ "$(_jf rs-b '.limiter.wait.code')" = "concurrency_full" ]
}

@test "L3-3: a stale feed makes budget holds advisory too" {
    _mode enforce; _bishop 90 10
    _age "$MOTHER_BISHOP_POSTURE_FILE" -7200
    _ljob rs-a personal 2026-11-01T00:00:01Z 0.1
    _tick
    [ "$(_admit)" = "rs-a" ]
}

# ===========================================================================
# L3-4  interactive demand
# ===========================================================================

@test "L3-4: while interactive use is high personal jobs are held and company jobs are admitted" {
    _mode enforce
    _bishop 40 10 "$(( $(_now) + 9000 ))"
    # 10 points of the 5h window in the last 5 minutes with no Mother spend: 120 %/h of someone else's work.
    _seed_calibrated 0.2 "[[$(( $(_now) - 300 )), 0, 30]]"
    _ljob pers personal 2026-11-01T00:00:01Z 0.05
    _ljob comp company 2026-11-01T00:00:02Z 0.05
    _tick MOTHER_LIMITER_INTERACTIVE_SUSTAIN_S=0
    [ "$(_st '.interactive.state')" = "high" ]
    [ "$(_admit)" = "comp" ]
    [ "$(_jf pers '.limiter.wait.code')" = "interactive_personal" ]
    [ "$(_jf pers '.limiter.wait.advisory')" = "false" ]
    _dispatch
    [ "$SPAWNED" = "comp" ]
    [ "$(_jf pers .state)" = "ready" ]
}

# ===========================================================================
# L3-5  distress: cut, then recover one slot per calm period
# ===========================================================================

@test "L3-5: a 429 in a running job's log cuts allowed and nothing new starts beyond it; calm returns one slot at a time" {
    _mode enforce; _bishop 10 10
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    local i
    for i in 1 2 3 4 5; do _ljob "r$i" personal "2026-11-01T00:00:0${i}Z" 0.01; done
    _tick
    [ "$(_st '.allowed')" = "4" ]
    [ "$(_st '.admit | length')" = "3" ]

    cat "$FIXTURES/api_retry_429.jsonl" >> "$LOGS_DIR/d-run.log"
    _tick
    [ "$(_st '.allowed')" = "2" ]
    [ "$(_st '.admit | length')" = "1" ]
    _dispatch
    [ "$(printf '%s' "$SPAWNED" | tr ',' '\n' | grep -c .)" = "1" ]

    sleep 2
    _tick MOTHER_LIMITER_CALM_S=1
    [ "$(_st '.allowed')" = "3" ]
    [ "$(_st '.admit | length')" = "1" ]     # 3 allowed, 2 running now: one slot opened, not two
    [ "$(_st '.mode')" = "enforce" ]
}

@test "L3-5: repeated ticks after one 429 keep the cut and do not count it again" {
    _mode enforce; _bishop 10 10
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _ljob r1 personal 2026-11-01T00:00:01Z 0.01
    _ljob r2 personal 2026-11-01T00:00:02Z 0.01
    _ljob r3 personal 2026-11-01T00:00:03Z 0.01
    _tick
    cat "$FIXTURES/api_retry_429.jsonl" >> "$LOGS_DIR/d-run.log"
    _tick
    _tick
    _tick
    [ "$(_st '.allowed')" = "2" ]
    [ "$(_st '.admit | length')" = "1" ]
}

# ===========================================================================
# L3-6  ramp after a window reset
# ===========================================================================

@test "L3-6: after a window reset at most RAMP_START jobs start, then one more per RAMP_STEP_S" {
    _mode enforce
    export MOTHER_CONCURRENCY=6
    _bishop 80 10
    local i
    for i in 1 2 3 4 5 6; do _ljob "w$i" personal "2026-11-01T00:00:0${i}Z" 0.01; done
    _tick MOTHER_LIMITER_RAMP_STEP_S=2
    _bishop 3 10 "$(( $(_now) + 18000 ))"          # the window rolled over: usage fell by 77 points
    _tick MOTHER_LIMITER_RAMP_STEP_S=2
    [ "$(_st '.allowed')" = "2" ]
    [ "$(_admit)" = "w1,w2" ]
    [ "$(_jf w3 '.limiter.wait.code')" = "ramp" ]
    _dispatch
    [ "$SPAWNED" = "w1,w2" ]

    sleep 3
    _tick MOTHER_LIMITER_RAMP_STEP_S=2
    [ "$(_st '.allowed')" = "3" ]
    [ "$(_admit)" = "w3" ]
}

# ===========================================================================
# L3-10  force_start
# ===========================================================================

@test "L3-10: force_start skips the reserve hold, a job without it stays held" {
    _mode enforce; _bishop 90 10
    _ljob f personal 2026-11-01T00:00:02Z 0.1 ".force_start = true"
    _ljob g personal 2026-11-01T00:00:01Z 0.1
    _tick
    [ "$(_admit)" = "f" ]
    [ "$(_jf g '.limiter.wait.code')" = "reserve" ]
    _dispatch
    [ "$SPAWNED" = "f" ]
}

@test "L3-10: force_start skips the budget_pace hold" {
    _mode enforce
    _bishop 40 10 "$(( $(_now) + 9000 ))"
    _seed_calibrated 0.2
    _ljob big-f personal 2026-11-01T00:00:01Z 2.0 ".force_start = true"
    _ljob big personal 2026-11-01T00:00:02Z 2.0
    _tick
    [ "$(_admit)" = "big-f" ]
    [ "$(_jf big '.limiter.wait.code')" = "budget_pace" ]
}

@test "L3-10: force_start skips the interactive_personal hold" {
    _mode enforce
    _bishop 40 10 "$(( $(_now) + 9000 ))"
    _seed_calibrated 0.2 "[[$(( $(_now) - 300 )), 0, 30]]"
    _ljob pers-f personal 2026-11-01T00:00:01Z 0.05 ".force_start = true"
    _ljob pers personal 2026-11-01T00:00:02Z 0.05
    _tick MOTHER_LIMITER_INTERACTIVE_SUSTAIN_S=0
    [ "$(_admit)" = "pers-f" ]
    [ "$(_jf pers '.limiter.wait.code')" = "interactive_personal" ]
}

@test "L3-10: force_start does not skip a backoff (not_before in the future)" {
    _mode enforce; _bishop 10 10
    _ljob f personal 2026-11-01T00:00:01Z 0.1 ".force_start = true | .not_before = $(( $(_now) + 3600 ))"
    _tick
    [ "$(_admit)" = "" ]
    [ "$(_jf f '.limiter.wait.code')" = "backoff" ]
    _dispatch
    [ -z "$SPAWNED" ]
}

@test "L3-10: force_start does not skip the ramp" {
    _mode enforce
    export MOTHER_CONCURRENCY=6
    _bishop 80 10
    local i
    for i in 1 2 3 4; do _ljob "f$i" personal "2026-11-01T00:00:0${i}Z" 0.01 ".force_start = true"; done
    _tick MOTHER_LIMITER_RAMP_STEP_S=600
    _bishop 3 10 "$(( $(_now) + 18000 ))"
    _tick MOTHER_LIMITER_RAMP_STEP_S=600
    [ "$(_st '.admit | length')" = "2" ]
    [ "$(_jf f3 '.limiter.wait.code')" = "ramp" ]
}

# ===========================================================================
# Dispatch while enforcing (state.json is the only input; no tick involved)
# ===========================================================================

@test "L3-9: dispatch starts the admitted ids in admit order and nothing else" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=3
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b personal 2026-11-01T00:00:02Z 0.1
    _ljob c personal 2026-11-01T00:00:03Z 0.1
    _hand_state 3 b a
    _dispatch
    [ "$SPAWNED" = "b,a" ]
    [ "$(_jf c .state)" = "ready" ]
    [ "$(jq -r .enforcing "$RUNNER_DIR/dispatch-last.json")" = "true" ]
}

@test "L3-9: dispatch is bounded by the limiter's allowed even when MOTHER_CONCURRENCY is larger" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=4
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b personal 2026-11-01T00:00:02Z 0.1
    _ljob c personal 2026-11-01T00:00:03Z 0.1
    _hand_state 1 a b c
    _dispatch
    [ "$SPAWNED" = "a" ]
}

@test "L3-9: dispatch is bounded by MOTHER_CONCURRENCY even when allowed is larger" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=1
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b personal 2026-11-01T00:00:02Z 0.1
    _hand_state 4 a b
    _dispatch
    [ "$SPAWNED" = "a" ]
}

@test "L3-9: while enforcing, the ratelimit-until pause is ignored (the limiter owns backoff)" {
    _mode enforce; _bishop 10 10
    echo "$(( $(_now) + 3600 ))" > "$MOTHER_ROOT/ratelimit-until"
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _hand_state 2 a
    _dispatch
    [ "$SPAWNED" = "a" ]
}

@test "L3-9: the quota-gate cap stays a backstop: over the cap only an admitted force_start job starts" {
    _mode enforce; _bishop 60 10
    export MOTHER_QUOTA_CAP_5H_PCT=50
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b personal 2026-11-01T00:00:02Z 0.1 ".force_start = true"
    _hand_state 4 a b
    _dispatch
    [ "$SPAWNED" = "b" ]
    [ "$(_jf a .state)" = "ready" ]
}

@test "L3-9: a force_start job the limiter did not admit is not started over the cap" {
    _mode enforce; _bishop 60 10
    export MOTHER_QUOTA_CAP_5H_PCT=50
    _ljob b personal 2026-11-01T00:00:02Z 0.1 ".force_start = true"
    _hand_state 4
    _dispatch
    [ -z "$SPAWNED" ]
}

@test "L3-9: a state.json older than 3 x MOTHER_LIMITER_INTERVAL is not enforcing: fixed concurrency and the pause apply" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=2
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b personal 2026-11-01T00:00:02Z 0.1
    _ljob c personal 2026-11-01T00:00:03Z 0.1
    _hand_state 1 c
    _age "$MOTHER_ROOT/limiter/state.json" -120
    _dispatch
    [ "$SPAWNED" = "a,b" ]                       # exactly what observe does: oldest first, fixed concurrency
    [ "$(jq -r .enforcing "$RUNNER_DIR/dispatch-last.json")" = "false" ]
    rm -f "$RUNNER_DIR"/children/*.json
    echo "$(( $(_now) + 3600 ))" > "$MOTHER_ROOT/ratelimit-until"
    make_job a2 ready ".repo_path = \"$MOTHER_ROOT\""
    _dispatch
    [ -z "$SPAWNED" ]
}

@test "L3-9: a limiter-fault.json makes dispatch behave as observe, and the pause applies" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=2
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b personal 2026-11-01T00:00:02Z 0.1
    _ljob c personal 2026-11-01T00:00:03Z 0.1
    _hand_state 1 c
    mkdir -p "$RUNNER_DIR"
    jq -nc '{at: "2026-11-06T00:00:00Z", why: "timeout"}' > "$RUNNER_DIR/limiter-fault.json"
    _dispatch
    [ "$SPAWNED" = "a,b" ]
    [ "$(jq -r .enforcing "$RUNNER_DIR/dispatch-last.json")" = "false" ]
}

@test "L3-9: a state.json written in observe mode is not enforcing even when the mode file now says enforce" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=2
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b personal 2026-11-01T00:00:02Z 0.1
    _ljob c personal 2026-11-01T00:00:03Z 0.1
    _hand_state 1 c
    jq '.mode = "observe"' "$MOTHER_ROOT/limiter/state.json" > "$MOTHER_ROOT/s.tmp" && mv "$MOTHER_ROOT/s.tmp" "$MOTHER_ROOT/limiter/state.json"
    _dispatch
    [ "$SPAWNED" = "a,b" ]
    [ "$(jq -r .enforcing "$RUNNER_DIR/dispatch-last.json")" = "false" ]
}

@test "L3-9: in observe mode dispatch is unchanged: the pause holds everything and dispatch-last says enforcing false" {
    _mode observe; _bishop 10 10
    echo "$(( $(_now) + 3600 ))" > "$MOTHER_ROOT/ratelimit-until"
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _tick
    _dispatch
    [ -z "$SPAWNED" ]
    [ "$(jq -r .enforcing "$RUNNER_DIR/dispatch-last.json")" = "false" ]
}

# ===========================================================================
# L3-9  attention: a fault is loud, and acknowledgeable by the owner only
# ===========================================================================

@test "L3-9: enforce with a stale state.json raises limiter_fault in needs-attention" {
    _mode enforce; _bishop 10 10
    _hand_state 4
    _age "$MOTHER_ROOT/limiter/state.json" -120
    run _needs
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.[] | select(.kind == "limiter_fault")] | length' <<<"$output")" = "1" ]
    [ "$(jq -r '[.[] | select(.kind == "limiter_fault")][0].reason' <<<"$output")" = "limiter not running; dispatch fell back to fixed concurrency" ]
}

@test "L3-9: enforce with a limiter-fault.json raises limiter_fault even when state.json is fresh" {
    _mode enforce; _bishop 10 10
    _hand_state 4
    jq -nc '{at: "2026-11-06T00:00:00Z", why: "exit 1"}' > "$RUNNER_DIR/limiter-fault.json"
    run _needs
    [ "$(jq -r '[.[] | select(.kind == "limiter_fault")] | length' <<<"$output")" = "1" ]
}

@test "L3-9: a healthy enforcing limiter, and observe mode with a stale state, raise no limiter_fault" {
    _mode enforce; _bishop 10 10
    _hand_state 4
    run _needs
    [ "$(jq -r '[.[] | select(.kind == "limiter_fault")] | length' <<<"$output")" = "0" ]
    _mode observe
    _age "$MOTHER_ROOT/limiter/state.json" -120
    run _needs
    [ "$(jq -r '[.[] | select(.kind == "limiter_fault")] | length' <<<"$output")" = "0" ]
}

@test "L3-9: mother ack limiter limiter_fault acknowledges it: the item stays, marked acked" {
    _mode enforce; _bishop 10 10
    _hand_state 4
    _age "$MOTHER_ROOT/limiter/state.json" -120
    run mother ack limiter limiter_fault
    [ "$status" -eq 0 ]
    [ -s "$MOTHER_ROOT/acks/_limiter.json" ]
    run _needs
    [ "$(jq -r '[.[] | select(.kind == "limiter_fault")][0].detail.acked' <<<"$output")" = "true" ]
}

@test "L3-9: acking limiter_fault is refused for a worker" {
    _mode enforce; _bishop 10 10
    _hand_state 4
    _age "$MOTHER_ROOT/limiter/state.json" -120
    run env MOTHER_JOB_ID=job-w mother ack limiter limiter_fault
    [ "$status" -ne 0 ]
    [ ! -s "$MOTHER_ROOT/acks/_limiter.json" ]
}

@test "L3-9: acking limiter_fault when it is not raised is refused" {
    _mode enforce; _bishop 10 10
    _hand_state 4
    run mother ack limiter limiter_fault
    [ "$status" -ne 0 ]
    [ ! -s "$MOTHER_ROOT/acks/_limiter.json" ]
}

@test "L3-9: enforcing while the quota gate is off raises the info item limiter_enforcing_gate_off" {
    _mode enforce; _bishop 10 10
    _hand_state 4
    run _needs
    [ "$(jq -r '[.[] | select(.kind == "limiter_enforcing_gate_off")] | length' <<<"$output")" = "0" ]
    mother quota off
    run _needs
    [ "$(jq -r '[.[] | select(.kind == "limiter_enforcing_gate_off")] | length' <<<"$output")" = "1" ]
    [ "$(jq -r '[.[] | select(.kind == "limiter_enforcing_gate_off")][0].reason' <<<"$output")" = "budget terms advisory (quota gate off)" ]
    _mode observe
    run _needs
    [ "$(jq -r '[.[] | select(.kind == "limiter_enforcing_gate_off")] | length' <<<"$output")" = "0" ]
}

# ===========================================================================
# L3-8  route-failure under enforce
# ===========================================================================

# A failed, rate-limited job as the runner finds it. Usage: _rl_job <id> <extra jq> [failed detail JSON]
_rl_job() {
    local id="$1" extra="${2:-.}" detail="${3:-}"
    [ -n "$detail" ] || detail='{}'
    make_job "$id" failed '
        .failure_reason = "rate_limited"
        | .branch = "feature/'"$id"'"
        | .base_ref = "main"
        | .repo_path = "/nonexistent/rl-'"$id"'"
        | .work_dir = "/nonexistent/rl-'"$id"'"
        | .finished_at = "2026-09-01T00:00:00Z"
        | .current_tier = "tier_1" | .escalation_count = 1 | .retry_count = 3 | .auto_retry_count = 1
        | ('"$extra"')'
    jq -nc --arg ts "$(_iso)" --argjson d "$detail" \
        '{ts: $ts, kind: "failed", detail: ({reason: "rate_limited", exit_code: 1} + $d)}' >> "$EVENTS_DIR/$id.jsonl"
}

@test "L3-8: under enforce a rate-limited job goes back to ready with no not_before when the server gave no retry-after" {
    _mode enforce
    _rl_job rl-1 . '{"api_error_status":429}'
    run mother route-failure rl-1
    [ "$status" -eq 0 ]
    [ "$(_jf rl-1 .state)" = "ready" ]
    [ "$(_jf rl-1 .not_before)" = "null" ]
    [ "$(_jf rl-1 .current_tier)" = "tier_1" ]
    [ "$(_jf rl-1 .escalation_count)" = "1" ]
    [ "$(_jf rl-1 .backoff_count)" = "1" ]
    local d; d=$(_ev rl-1 failure_routed)
    [ "$(jq -r .action <<<"$d")" = "backed_off" ]
    [ "$(jq -r .limiter <<<"$d")" = "enforce" ]
}

@test "L3-8: under enforce a server-given retry-after is honoured as now + retry_after_s, and the shared pause is still written" {
    _mode enforce
    _rl_job rl-2 . '{"api_error_status":429,"retry_after_s":90}'
    local t0 t1; t0=$(_now)
    run mother route-failure rl-2
    [ "$status" -eq 0 ]
    t1=$(_now)
    local nb; nb=$(_jf rl-2 .not_before)
    [ "$nb" -ge $((t0 + 90)) ] && [ "$nb" -le $((t1 + 90)) ]
    [[ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" =~ ^[0-9]+$ ]]
    [ "$(tr -d '[:space:]' < "$MOTHER_ROOT/ratelimit-until")" -ge "$t0" ]
}

@test "L3-8: under enforce an absurd retry-after is clamped to the one hour maximum" {
    _mode enforce
    _rl_job rl-3 . '{"api_error_status":429,"retry_after_s":86400}'
    local t1
    run mother route-failure rl-3
    [ "$status" -eq 0 ]
    t1=$(_now)
    [ "$(_jf rl-3 .not_before)" -le $((t1 + 3600)) ]
    [ "$(_jf rl-3 .not_before)" -gt $((t1 + 3000)) ]
}

@test "L3-8: under enforce elapsed time alone never gives up: a first back-off a day ago is still a back-off" {
    _mode enforce
    _rl_job rl-4 ".backoff_count = 2 | .backoff_first_at = $(( $(_now) - 100000 ))" '{"api_error_status":429}'
    run mother route-failure rl-4
    [ "$status" -eq 0 ]
    [ "$(_jf rl-4 .state)" = "ready" ]
    [ "$(_jf rl-4 .backoff_count)" = "3" ]
    [ "$(_jf rl-4 '.operator_hold // null')" = "null" ]
}

@test "L3-8: under enforce the lifetime backoff count still holds the job backoff_exhausted" {
    _mode enforce
    _rl_job rl-5 ".backoff_count = 10 | .backoff_first_at = $(( $(_now) - 60 ))" '{"api_error_status":429}'
    run mother route-failure rl-5
    [ "$status" -eq 0 ]
    [ "$(_jf rl-5 .state)" = "awaiting" ]
    [ "$(_jf rl-5 .operator_hold.sub_reason)" = "backoff_exhausted" ]
}

@test "L3-8: in observe mode nothing changes: exponential delay, give-up on elapsed time, no limiter marker" {
    _mode observe
    _rl_job rl-6 . '{"api_error_status":429}'
    local t0; t0=$(_now)
    run mother route-failure rl-6
    [ "$status" -eq 0 ]
    [ "$(_jf rl-6 .state)" = "ready" ]
    local nb; nb=$(_jf rl-6 .not_before)
    [ "$nb" -ge $((t0 + 30)) ]
    [ "$(jq -r '.limiter // "none"' <<<"$(_ev rl-6 failure_routed)")" != "enforce" ]

    _rl_job rl-7 ".backoff_count = 2 | .backoff_first_at = $(( $(_now) - 100000 ))" '{"api_error_status":429}'
    run mother route-failure rl-7
    [ "$(_jf rl-7 .state)" = "awaiting" ]
    [ "$(_jf rl-7 .operator_hold.sub_reason)" = "backoff_exhausted" ]
}

# ===========================================================================
# L3-11  the limiter and dispatch agree
# ===========================================================================

_no_divergence() {
    [ -s "$MOTHER_ROOT/limiter/decisions.jsonl" ]
    jq -e -s 'length >= 1 and all(.[]; .mode == "enforce" and ((.divergence // []) | length) == 0)' \
        "$MOTHER_ROOT/limiter/decisions.jsonl" >/dev/null
}

@test "L3-11: a pace hold, a spawn and a following tick leave no divergence in decisions.jsonl" {
    _mode enforce
    _bishop 40 10 "$(( $(_now) + 9000 ))"
    _seed_calibrated 0.2
    _ljob big personal 2026-11-01T00:00:01Z 2.0
    _ljob small personal 2026-11-01T00:00:02Z 0.5
    _tick
    _dispatch
    [ "$SPAWNED" = "small" ]
    _tick
    _no_divergence
}

@test "L3-11: a reserve hold with nothing spawned leaves no divergence" {
    _mode enforce; _bishop 90 10
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b company 2026-11-01T00:00:02Z 0.1
    _tick
    _dispatch
    [ -z "$SPAWNED" ]
    _tick
    _no_divergence
}

@test "L3-11: an admitted batch that is spawned in admit order leaves no divergence" {
    _mode enforce; _bishop 10 10
    export MOTHER_CONCURRENCY=2
    _ljob a personal 2026-11-01T00:00:01Z 0.1
    _ljob b company 2026-11-01T00:00:02Z 0.1
    _ljob c personal 2026-11-01T00:00:03Z 0.1
    _tick
    _dispatch
    [ "$SPAWNED" = "b,a" ]
    _tick
    _no_divergence
}
