#!/usr/bin/env bats
# limiter_observe.bats — the backpressure limiter's observe-only slice (L1), end to end through the
# shell: `mother-limiter`, `mother add` annotations and the runner's limiter tick.
#
# Contract under test:
#   Annotations  `mother add` stores .data_class (company|personal) and .limiter.estimate
#                {usd_per_min, source: history|fleet_p75|default, samples}. Company = origin owner
#                `carefeed`, a MOTHER_PHI_REPOS repo or a MOTHER_COMPANY_REPOS repo (env or
#                $MOTHER_ROOT/config.env). Anything that can't be told (no git, no remote) is personal.
#   Observe only The limiter changes no dispatch behaviour: dispatch order is identical with it on and
#                off; job files only ever gain data_class / limiter.*; it logs what it WOULD do next to
#                what dispatch DID in $MOTHER_ROOT/limiter/decisions.jsonl, with a `divergence` entry
#                when a job it would have held was started.
#   Kill switch  MOTHER_LIMITER_MODE=off or limiter/mode.json {"mode":"off"}: no limiter files.
#   Fail safe    a hung or failing tick writes $RUNNER_DIR/limiter-fault.json and never delays or blocks
#                dispatch; the next good tick clears it.
#   Feed         the limiter reads the same Bishop/cache feed as the quota gate and agrees with it on
#                source, stale, used_pct and resets_at for both windows.
#   Distress     new 429/529 evidence in a running job's log (not overage-only rejections, not a null
#                error_status) cuts the allowed concurrency the same tick.

load 'test_helper'

FIXTURES="$BATS_TEST_DIRNAME/fixtures/limiter"

setup() {
    setup_mother_env
    export HOME="$MOTHER_ROOT/home"
    mkdir -p "$HOME"
    export MOTHER_BISHOP_POSTURE_FILE="$MOTHER_ROOT/bishop-posture.json"
    export MOTHER_RATE_LIMIT_CACHE="$MOTHER_ROOT/rate-limits.json"
    unset MOTHER_LIMITER_MODE MOTHER_LIMITER_INTERVAL MOTHER_LIMITER_TIMEOUT MOTHER_PHI_REPOS MOTHER_COMPANY_REPOS \
          MOTHER_QUOTA_CAP_5H_PCT MOTHER_QUOTA_CAP_7D_PCT MOTHER_QUOTA_FEED_MAX_AGE_S MOTHER_CONCURRENCY \
          MOTHER_LIMITER_RESERVE_PCT MOTHER_LIMITER_DEFAULT_BURN_USD_PER_MIN
    export MOTHER_NOTIFY_TRANSPORT=none
    export MOTHER_POSTURE_ENABLED=0
    export FAKE_REPO="$MOTHER_ROOT/testrepo"
    git init -q "$FAKE_REPO"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_now() { date +%s; }

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

# Set <file>'s mtime to now + <seconds> (negative = in the past).
_age() {
    /usr/bin/perl -e 'my $t = time + $ARGV[1]; utime($t, $t, $ARGV[0]) or die "utime: $!"' "$1" "$2"
}

_tick() { mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1; }

# One field of limiter state, e.g. _lstate '.allowed'. Prints "null" with no state.
_lstate() { mother-limiter status --raw --root "$MOTHER_ROOT" | jq -r ".state | $1"; }

# The limiter tick the way the runner's loop runs it (interval gate disabled).
_runner_tick() { MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1; }

# A mother-run-job stand-in that only logs its argv, plus the dispatch settings the scenarios share.
_fake_run_job() {
    FAKE_BIN="$MOTHER_ROOT/fake-bin"; mkdir -p "$FAKE_BIN"
    printf '#!/usr/bin/env bash\necho "$*" >> "%s/run-job-calls"\nexit 0\n' "$MOTHER_ROOT" > "$FAKE_BIN/mother-run-job"
    chmod +x "$FAKE_BIN/mother-run-job"
    export MOTHER_CONCURRENCY=2
}

# A `mother-limiter` that defers to the real one (a symlink would lose its lib/ path).
_real_limiter_wrapper() {
    printf '#!/usr/bin/env bash\nexec "%s/mother-limiter" "$@"\n' "$_BIN_DIR" > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
}

# Write a finished job. Usage: _finished <id> <repo> <cost usd> [kind]  (10 active minutes)
_finished() {
    make_job "$1" succeeded ".repo = \"$2\" | .created_at = \"2026-10-01T10:00:00Z\" | .started_at = \"2026-10-01T10:00:30Z\" \
        | .finished_at = \"2026-10-01T10:10:30Z\" | .actual_cost_usd = $3 ${4:+| .kind = \"$4\"}"
}

_add() {   # <repo name> [extra mother add args...]; prints the job id
    local repo="$1"; shift
    local plan="$MOTHER_ROOT/plan.md"
    make_plan "$plan"
    mother add --plan-file "$plan" --repo "$repo" --repo-path "$FAKE_REPO" --branch "feature/$RANDOM" "$@" 2>/dev/null
}

_add_pipeline() {
    local plan="$MOTHER_ROOT/pipeline-plan.md"
    make_plan_with_config "$plan" \
'pipeline:
  enabled: true
  reviewers:
    - perri
  cycle_cap: 2
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "x"
  redd:
    model: sonnet
    effort: medium
    rationale: "x"
  marty:
    model: sonnet
    effort: medium
    rationale: "x"
  perri:
    model: sonnet
    effort: medium
    rationale: "x"'
    mother add --plan-file "$plan" --repo "$1" --repo-path "$FAKE_REPO" --branch "feature/pipe$RANDOM" 2>/dev/null
}

_classify() { mother-limiter classify --work-dir "$1" --repo "$2"; }

# ===========================================================================
# L1-7  expected burn at `mother add`
# ===========================================================================

@test "L1-7: three finished same-repo jobs by the same actor give a history estimate" {
    _finished h1 testrepo 3
    _finished h2 testrepo 5
    _finished h3 testrepo 8
    id=$(_add testrepo)
    [ -n "$id" ]
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$id.json")" = "history" ]
    [ "$(jq -r '.limiter.estimate.samples >= 3' "$JOBS_DIR/$id.json")" = "true" ]
    # median of 0.3 / 0.5 / 0.8 USD per active minute
    jq -e '(.limiter.estimate.usd_per_min - 0.5) | fabs < 0.001' "$JOBS_DIR/$id.json" >/dev/null
}

@test "L1-7: a repo with no history falls back to the fleet 75th percentile when history exists elsewhere" {
    _finished o1 other-a 3
    _finished o2 other-b 5
    _finished o3 other-c 8
    _finished o4 other-d 10
    id=$(_add brand-new-repo)
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$id.json")" = "fleet_p75" ]
    [ "$(jq -r '.limiter.estimate.samples' "$JOBS_DIR/$id.json")" = "4" ]
    # between the 3rd and 4th of 0.3 / 0.5 / 0.8 / 1.0
    jq -e '.limiter.estimate.usd_per_min >= 0.8 and .limiter.estimate.usd_per_min <= 1.0' "$JOBS_DIR/$id.json" >/dev/null
}

@test "L1-7: two same-repo jobs are not enough for history" {
    _finished h1 testrepo 3
    _finished h2 testrepo 5
    id=$(_add testrepo)
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$id.json")" = "fleet_p75" ]
}

@test "L1-7: with no history anywhere the estimate is the configured default" {
    MOTHER_LIMITER_DEFAULT_BURN_USD_PER_MIN=0.37 run _add testrepo
    [ "$status" -eq 0 ]
    id="$output"
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$id.json")" = "default" ]
    [ "$(jq -r '.limiter.estimate.usd_per_min' "$JOBS_DIR/$id.json")" = "0.37" ]
    [ "$(jq -r '.limiter.estimate.samples' "$JOBS_DIR/$id.json")" = "0" ]
}

@test "L1-7: the shipped default burn is 0.5 USD per minute" {
    id=$(_add testrepo)
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$id.json")" = "default" ]
    jq -e '.limiter.estimate.usd_per_min == 0.5' "$JOBS_DIR/$id.json" >/dev/null
}

@test "L1-7: pipeline jobs are a different actor than cody jobs" {
    _finished p1 testrepo 20 pipeline
    _finished p2 testrepo 20 pipeline
    _finished p3 testrepo 20 pipeline
    cody_id=$(_add testrepo)
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$cody_id.json")" = "fleet_p75" ]
    pipe_id=$(_add_pipeline testrepo)
    [ -n "$pipe_id" ]
    [ "$(jq -r '.kind' "$JOBS_DIR/$pipe_id.json")" = "pipeline" ]
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$pipe_id.json")" = "history" ]
    jq -e '(.limiter.estimate.usd_per_min - 2.0) | fabs < 0.001' "$JOBS_DIR/$pipe_id.json" >/dev/null
}

@test "L1-7: finished history includes archived jobs" {
    mkdir -p "$ARCHIVE_DIR/2026-10"
    for n in 1 2 3; do
        make_job "arc$n" succeeded '.repo = "testrepo" | .created_at = "2026-10-01T10:00:00Z" | .started_at = "2026-10-01T10:00:30Z" | .finished_at = "2026-10-01T10:10:30Z" | .actual_cost_usd = 6'
        mv "$JOBS_DIR/arc$n.json" "$ARCHIVE_DIR/2026-10/arc$n.json"
    done
    id=$(_add testrepo)
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$id.json")" = "history" ]
}

@test "L1-7: jobs that cost nothing or never ran are not burn history" {
    for n in 1 2 3; do
        make_job "free$n" succeeded '.repo = "testrepo" | .created_at = "2026-10-01T10:00:00Z" | .finished_at = "2026-10-01T10:10:30Z" | .actual_cost_usd = 0'
    done
    id=$(_add testrepo)
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/$id.json")" = "default" ]
}

# ===========================================================================
# L1-8  data class
# ===========================================================================

@test "L1-8: a Carefeed origin (ssh, any case) is company" {
    git -C "$FAKE_REPO" remote add origin git@github.com:Carefeed/admin-portal.git
    run _classify "$FAKE_REPO" some-neutral-name
    [ "$status" -eq 0 ]
    [ "$output" = "company" ]
}

@test "L1-8: a Carefeed https origin (lower case, no .git) is company" {
    git -C "$FAKE_REPO" remote add origin https://github.com/carefeed/x
    run _classify "$FAKE_REPO" some-neutral-name
    [ "$status" -eq 0 ]
    [ "$output" = "company" ]
}

@test "L1-8: a Carefeed https origin with .git is company" {
    git -C "$FAKE_REPO" remote add origin https://github.com/carefeed/x.git
    run _classify "$FAKE_REPO" some-neutral-name
    [ "$output" = "company" ]
}

@test "L1-8: a personal origin is personal" {
    git -C "$FAKE_REPO" remote add origin git@github.com:thehammer/mother.git
    run _classify "$FAKE_REPO" mother
    [ "$status" -eq 0 ]
    [ "$output" = "personal" ]
}

@test "L1-8: a repo merely named carefeed, or an owner that only starts with it, is personal" {
    git -C "$FAKE_REPO" remote add origin https://github.com/thehammer/carefeed.git
    run _classify "$FAKE_REPO" carefeed
    [ "$output" = "personal" ]
    git -C "$FAKE_REPO" remote set-url origin https://github.com/carefeed-fan/thing.git
    run _classify "$FAKE_REPO" thing
    [ "$output" = "personal" ]
}

@test "L1-8: the default PHI repos are company whatever their origin says" {
    git -C "$FAKE_REPO" remote add origin git@github.com:thehammer/fork.git
    run _classify "$FAKE_REPO" admin-portal
    [ "$output" = "company" ]
    run _classify "$FAKE_REPO" referral-monitor
    [ "$output" = "company" ]
}

@test "L1-8: MOTHER_PHI_REPOS replaces the default list" {
    git -C "$FAKE_REPO" remote add origin git@github.com:thehammer/fork.git
    MOTHER_PHI_REPOS="secret-repo" run _classify "$FAKE_REPO" secret-repo
    [ "$output" = "company" ]
    MOTHER_PHI_REPOS="secret-repo" run _classify "$FAKE_REPO" fork
    [ "$output" = "personal" ]
}

@test "L1-8: MOTHER_COMPANY_REPOS forces company" {
    git -C "$FAKE_REPO" remote add origin git@github.com:thehammer/fork.git
    MOTHER_COMPANY_REPOS="one-repo two-repo" run _classify "$FAKE_REPO" two-repo
    [ "$output" = "company" ]
    MOTHER_COMPANY_REPOS="one-repo two-repo" run _classify "$FAKE_REPO" three-repo
    [ "$output" = "personal" ]
}

@test "L1-8: MOTHER_COMPANY_REPOS is also read from config.env, and the environment wins" {
    git -C "$FAKE_REPO" remote add origin git@github.com:thehammer/fork.git
    echo 'MOTHER_COMPANY_REPOS=file-repo' > "$MOTHER_ROOT/config.env"
    run _classify "$FAKE_REPO" file-repo
    [ "$output" = "company" ]
    MOTHER_COMPANY_REPOS="env-repo" run _classify "$FAKE_REPO" file-repo
    [ "$output" = "personal" ]
}

@test "L1-8: a directory that is not a git repo is personal, exit 0" {
    mkdir -p "$MOTHER_ROOT/plain"
    run _classify "$MOTHER_ROOT/plain" something
    [ "$status" -eq 0 ]
    [ "$output" = "personal" ]
}

@test "L1-8: a missing directory or a repo with no remote is personal, exit 0" {
    run _classify "$MOTHER_ROOT/does-not-exist" something
    [ "$status" -eq 0 ]
    [ "$output" = "personal" ]
    run _classify "$FAKE_REPO" something       # git repo, no origin
    [ "$status" -eq 0 ]
    [ "$output" = "personal" ]
    run mother-limiter classify --repo something
    [ "$status" -eq 0 ]
    [ "$output" = "personal" ]
}

@test "L1-8: mother add stores the data class, company for a Carefeed origin" {
    git -C "$FAKE_REPO" remote add origin git@github.com:Carefeed/admin-portal.git
    id=$(_add neutral-repo)
    [ "$(jq -r '.data_class' "$JOBS_DIR/$id.json")" = "company" ]
}

@test "L1-8: mother add stores personal and still succeeds with no remote" {
    run _add testrepo
    [ "$status" -eq 0 ]
    [ "$(jq -r '.data_class' "$JOBS_DIR/$output.json")" = "personal" ]
}

@test "L1-8: mother add on a PHI repo name stores company even with a personal origin" {
    git -C "$FAKE_REPO" remote add origin git@github.com:thehammer/fork.git
    id=$(_add referral-monitor)
    [ "$(jq -r '.data_class' "$JOBS_DIR/$id.json")" = "company" ]
}

@test "L1-8: a broken limiter never fails mother add and leaves the fields absent" {
    mkdir -p "$MOTHER_ROOT/broken-bin"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$MOTHER_ROOT/broken-bin/mother-limiter"
    chmod +x "$MOTHER_ROOT/broken-bin/mother-limiter"
    MOTHER_BIN_DIR="$MOTHER_ROOT/broken-bin" run _add testrepo
    [ "$status" -eq 0 ]
    id="$output"
    [ -f "$JOBS_DIR/$id.json" ]
    [ "$(jq -r 'has("data_class") or has("limiter")' "$JOBS_DIR/$id.json")" = "false" ]
}

@test "L1-8: with the limiter off mother add adds no limiter fields" {
    MOTHER_LIMITER_MODE=off run _add testrepo
    [ "$status" -eq 0 ]
    [ "$(jq -r 'has("data_class") or has("limiter")' "$JOBS_DIR/$output.json")" = "false" ]
}

# ===========================================================================
# L1-9  observe only: same dispatch, a decision log next to it
# ===========================================================================

# Run the three-job scenario in its own state tree (so it can be run twice from fresh state) and write
# the spawn order the runner logged to <tree>/order.txt. Usage: _scenario <observe|off> <5h used pct>
_scenario() {
    local mode="$1" used="$2" root="$MOTHER_ROOT/scn-$1"
    (
        export MOTHER_ROOT="$root" JOBS_DIR="$root/jobs" EVENTS_DIR="$root/events" LOGS_DIR="$root/logs" \
               DRAFTS_DIR="$root/drafts" CURSORS_DIR="$root/cursors" RUNNER_DIR="$root/runner" \
               ARCHIVE_DIR="$root/archive" TEARDOWN_DIR="$root/teardown-pending"
        mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" "$CURSORS_DIR" "$RUNNER_DIR" "$ARCHIVE_DIR" "$TEARDOWN_DIR"
        export MOTHER_QUOTA_CAP_5H_PCT=95 MOTHER_LIMITER_INTERVAL=0
        [ "$mode" = off ] && export MOTHER_LIMITER_MODE=off
        _bishop "$used" 10
        local n=0 id
        for id in a b c; do
            n=$((n + 1))
            make_job "ord-$id" ready ".repo_path = \"$root\" | .created_at = \"2026-11-01T00:00:0${n}Z\""
        done

        MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>"$root/d1.err" 3>&- >/dev/null || true
        mother-runner --limiter-tick 3>&- >/dev/null 2>&1 || true
        # the two supervisors finish; a slot frees up
        for id in ord-a ord-b; do
            jq '.state = "succeeded"' "$JOBS_DIR/$id.json" > "$root/t" && mv "$root/t" "$JOBS_DIR/$id.json"
        done
        rm -f "$RUNNER_DIR"/children/*.json
        MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>"$root/d2.err" 3>&- >/dev/null || true
        mother-runner --limiter-tick 3>&- >/dev/null 2>&1 || true
        cat "$root/d1.err" "$root/d2.err" | sed -n 's/.*spawned job \([^ ]*\) as pid.*/\1/p' > "$root/order.txt"
    )
}

@test "L1-9: dispatch order is the same with the limiter observing as with it off" {
    _fake_run_job
    _scenario observe 86
    _scenario off 86
    [ "$(cat "$MOTHER_ROOT/scn-observe/order.txt")" = "$(printf 'ord-a\nord-b\nord-c')" ]
    [ "$(cat "$MOTHER_ROOT/scn-observe/order.txt")" = "$(cat "$MOTHER_ROOT/scn-off/order.txt")" ]
}

@test "L1-9: with the limiter off no limiter files are produced" {
    _fake_run_job
    _scenario off 86
    local root="$MOTHER_ROOT/scn-off"
    [ ! -e "$root/limiter" ]
    [ ! -e "$root/runner/limiter-fault.json" ]
    [ ! -e "$root/runner/last-limiter.ts" ]
    for id in a b c; do
        [ "$(jq -r 'has("data_class") or has("limiter")' "$root/jobs/ord-$id.json")" = "false" ]
    done
}

@test "L1-9: observing writes state.json and a decision with would and actual blocks" {
    _fake_run_job
    _scenario observe 86
    local root="$MOTHER_ROOT/scn-observe"
    [ -s "$root/limiter/state.json" ]
    [ -s "$root/limiter/decisions.jsonl" ]
    jq -e -s 'length >= 1 and all(.[]; has("would") and has("actual") and has("divergence") and has("ts"))' \
        "$root/limiter/decisions.jsonl" >/dev/null
}

@test "L1-9: a job the limiter would have held but dispatch started is a divergence" {
    _fake_run_job
    _bishop 86 10
    export MOTHER_QUOTA_CAP_5H_PCT=95
    make_job div-a ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:01Z\""
    make_job div-b ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:02Z\""
    make_job div-c ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:03Z\""

    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null
    [ "$(jq -r .state "$JOBS_DIR/div-a.json")" = "running" ]
    [ "$(jq -r .state "$JOBS_DIR/div-b.json")" = "running" ]
    [ "$(jq -r .state "$JOBS_DIR/div-c.json")" = "ready" ]
    _runner_tick

    local line; line=$(tail -n 1 "$MOTHER_ROOT/limiter/decisions.jsonl")
    [ "$(jq -r '.actual.spawned | sort | join(",")' <<<"$line")" = "div-a,div-b" ]
    # what it would have done: hold all three, the reserve (14% left of a 15% reserve) is breached
    [ "$(jq -r '.would.hold | map(select(.code == "reserve") | .id) | sort | join(",")' <<<"$line")" = "div-a,div-b,div-c" ]
    [ "$(jq -r '.would.admit | length' <<<"$line")" = "0" ]
    [ "$(jq -r '[.divergence[] | select(.kind == "would_hold_but_spawned") | .id] | sort | join(",")' <<<"$line")" = "div-a,div-b" ]
    [ "$(jq -r '[.divergence[] | select(.kind == "would_hold_but_spawned") | .code] | unique | join(",")' <<<"$line")" = "reserve" ]
}

@test "L1-9: no divergence when the limiter would have admitted what dispatch started" {
    _fake_run_job
    _bishop 5 10
    make_job ok-a ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:01Z\""
    make_job ok-b ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:02Z\""
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null
    _runner_tick
    local line; line=$(tail -n 1 "$MOTHER_ROOT/limiter/decisions.jsonl")
    [ "$(jq -r '.divergence | length' <<<"$line")" = "0" ]
    [ "$(jq -r '.actual.spawned | length' <<<"$line")" = "2" ]
    [ "$(jq -r '.would.hold | length' <<<"$line")" = "0" ]
}

@test "L1-9: job files change only in data_class and limiter.* when the limiter observes" {
    _fake_run_job
    _bishop 86 10
    export MOTHER_QUOTA_CAP_5H_PCT=95
    make_job obs-a ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:01Z\""
    make_job obs-b ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:02Z\""
    make_job obs-c ready ".repo_path = \"$MOTHER_ROOT\" | .created_at = \"2026-11-01T00:00:03Z\" | .not_before = null | .pause_requested = false"
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null
    for id in obs-a obs-b obs-c; do jq -S 'del(.data_class, .limiter)' "$JOBS_DIR/$id.json" > "$MOTHER_ROOT/before-$id.json"; done

    _runner_tick

    for id in obs-a obs-b obs-c; do
        jq -S 'del(.data_class, .limiter)' "$JOBS_DIR/$id.json" > "$MOTHER_ROOT/after-$id.json"
        cmp "$MOTHER_ROOT/before-$id.json" "$MOTHER_ROOT/after-$id.json"
    done
    # ... and the still-ready job has been annotated with what the limiter would do
    [ "$(jq -r .state "$JOBS_DIR/obs-c.json")" = "ready" ]
    [ "$(jq -r .data_class "$JOBS_DIR/obs-c.json")" = "personal" ]
    [ "$(jq -r '.limiter.estimate.source' "$JOBS_DIR/obs-c.json")" = "default" ]
    [ "$(jq -r '.limiter.would.code' "$JOBS_DIR/obs-c.json")" = "reserve" ]
    [ "$(jq -r '.limiter.would | has("reason")' "$JOBS_DIR/obs-c.json")" = "true" ]
    # nothing but those keys under limiter (L2 adds `wait`: why the job is waiting)
    [ "$(jq -r '.limiter | keys | join(",")' "$JOBS_DIR/obs-c.json")" = "estimate,wait,would" ]
}

@test "L1-9: a held-for-backoff or not_before job is left exactly as it was" {
    _bishop 5 10
    future=$(( $(_now) + 3000 ))
    make_job nb-1 ready ".repo_path = \"$MOTHER_ROOT\" | .not_before = $future | .activity = \"cody_rework\""
    jq -S . "$JOBS_DIR/nb-1.json" > "$MOTHER_ROOT/nb-before.json"
    _runner_tick
    jq -S 'del(.data_class, .limiter)' "$JOBS_DIR/nb-1.json" > "$MOTHER_ROOT/nb-after.json"
    jq -S 'del(.data_class, .limiter)' "$MOTHER_ROOT/nb-before.json" | cmp - "$MOTHER_ROOT/nb-after.json"
}

@test "L1-9: an interval of N seconds gates the runner's limiter tick" {
    _bishop 5 10
    make_job iv-1 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_INTERVAL=3600 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ -s "$MOTHER_ROOT/limiter/state.json" ]
    ts1=$(_lstate '.ts')
    sleep 1
    MOTHER_LIMITER_INTERVAL=3600 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ "$(_lstate '.ts')" = "$ts1" ]               # inside the interval: no new tick
    MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ "$(_lstate '.ts')" != "$ts1" ]
}

# ===========================================================================
# L1-10  the limiter can never hurt dispatch
# ===========================================================================

@test "L1-10: a hung limiter tick is killed at the timeout, recorded, and does not stop dispatch" {
    _fake_run_job
    printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
    _bishop 5 10
    make_job hang-1 ready ".repo_path = \"$MOTHER_ROOT\""

    local t0 t1; t0=$(_now)
    MOTHER_LIMITER_INTERVAL=0 MOTHER_LIMITER_TIMEOUT=1 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    t1=$(_now)
    [ $(( t1 - t0 )) -lt 10 ]

    [ -f "$RUNNER_DIR/limiter-fault.json" ]
    jq -e 'has("at") and has("why") and (.why | type == "string" and length > 0) and (.at | type == "number")' \
        "$RUNNER_DIR/limiter-fault.json" >/dev/null
    [ "$(jq -r .state "$JOBS_DIR/hang-1.json")" = "ready" ]

    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null 3>&-
    [ "$(jq -r .state "$JOBS_DIR/hang-1.json")" = "running" ]
}

@test "L1-10: a limiter that exits non-zero is recorded as a fault and dispatch carries on" {
    _fake_run_job
    printf '#!/usr/bin/env bash\necho boom >&2\nexit 1\n' > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
    _bishop 5 10
    make_job crash-1 ready ".repo_path = \"$MOTHER_ROOT\""

    MOTHER_LIMITER_INTERVAL=0 MOTHER_LIMITER_TIMEOUT=2 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ -f "$RUNNER_DIR/limiter-fault.json" ]
    jq -e 'has("at") and has("why")' "$RUNNER_DIR/limiter-fault.json" >/dev/null

    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null 3>&-
    [ "$(jq -r .state "$JOBS_DIR/crash-1.json")" = "running" ]
}

@test "L1-10: a limiter that prints garbage on success changes no job" {
    _fake_run_job
    printf '#!/usr/bin/env bash\necho "not json {{{"\nexit 0\n' > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
    make_job junk-1 ready ".repo_path = \"$MOTHER_ROOT\""
    jq -S . "$JOBS_DIR/junk-1.json" > "$MOTHER_ROOT/junk-before.json"
    MOTHER_LIMITER_INTERVAL=0 MOTHER_LIMITER_TIMEOUT=2 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    jq -S . "$JOBS_DIR/junk-1.json" | cmp - "$MOTHER_ROOT/junk-before.json"
}

@test "L1-10: the next good tick clears the fault" {
    _fake_run_job
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
    _bishop 5 10
    make_job heal-1 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_INTERVAL=0 MOTHER_LIMITER_TIMEOUT=2 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ -f "$RUNNER_DIR/limiter-fault.json" ]

    rm -f "$RUNNER_DIR/limiter-backoff.json"   # the fault backoff has elapsed
    _real_limiter_wrapper
    MOTHER_LIMITER_INTERVAL=0 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/limiter-fault.json" ]
    [ -s "$MOTHER_ROOT/limiter/state.json" ]
}

@test "L1-10: a missing limiter binary is a fault, not a crash" {
    _fake_run_job
    make_job gone-1 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_INTERVAL=0 MOTHER_BIN_DIR="$FAKE_BIN" run mother-runner --limiter-tick
    [ "$status" -eq 0 ]
    [ -f "$RUNNER_DIR/limiter-fault.json" ]
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null 3>&-
    [ "$(jq -r .state "$JOBS_DIR/gone-1.json")" = "running" ]
}

# ===========================================================================
# L1-11  the limiter reads the same feed as the quota gate
# ===========================================================================

# Compare the quota gate's feed with the limiter's reading of it.
# Usage: _assert_feed_parity <expected source> <expected stale: true|false>
_assert_feed_parity() {
    local gate lim fields='[.source, .stale, .five_hour.used_pct, .five_hour.resets_at, .seven_day.used_pct, .seven_day.resets_at]'
    gate=$(bash -c "set -u; source '$_LIB_DIR/state.sh'; _quota_feed_json")
    rm -f "$MOTHER_ROOT/limiter/state.json"
    mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    lim=$(mother-limiter status --raw --root "$MOTHER_ROOT" | jq -c '.state.budget')
    echo "gate: $gate" >&2
    echo "limiter: $lim" >&2
    [ "$(jq -r .source <<<"$gate")" = "$1" ]
    [ "$(jq -r .stale <<<"$gate")" = "$2" ]
    [ "$(jq -c "$fields" <<<"$gate")" = "$(jq -c "$fields" <<<"$lim")" ]
}

@test "L1-11: normal Bishop feed" {
    cp "$FIXTURES/normal.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity bishop false
    [ "$(_lstate '.budget.five_hour.used_pct')" = "40" ]
}

@test "L1-11: pinned 5h window with overage enabled" {
    cp "$FIXTURES/pinned_overage.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity bishop false
    [ "$(_lstate '.budget.five_hour.used_pct')" = "100" ]
    [ "$(_lstate '.budget.overage_in_use')" = "true" ]
}

@test "L1-11: a feed after a window reset" {
    cp "$FIXTURES/after_reset.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity bishop false
    [ "$(_lstate '.budget.five_hour.used_pct')" = "3" ]
}

@test "L1-11: stale_input Bishop with no cache has no feed" {
    cp "$FIXTURES/stale_input.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity none true
    [ "$(_lstate '.budget.stale')" = "true" ]
}

@test "L1-11: stale_input Bishop falls back to the statusline cache" {
    cp "$FIXTURES/stale_input.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _cache 33 44
    _assert_feed_parity cache false
    [ "$(_lstate '.budget.five_hour.used_pct')" = "33" ]
}

@test "L1-11: cache only, with used_percentage keys" {
    rm -f "$MOTHER_BISHOP_POSTURE_FILE"
    _cache 21 12
    _assert_feed_parity cache false
}

@test "L1-11: Bishop file using used_percentage keys" {
    jq -nc --argjson r "$(( $(_now) + 3600 ))" \
        '{five_hour: {used_percentage: 61, resets_at: $r}, seven_day: {used_percentage: 7, resets_at: $r}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity bishop false
    [ "$(_lstate '.budget.five_hour.used_pct')" = "61" ]
}

@test "L1-11: a Bishop file older than the max age is not used" {
    cp "$FIXTURES/normal.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _age "$MOTHER_BISHOP_POSTURE_FILE" -7200
    _assert_feed_parity none true
}

@test "L1-11: an old Bishop file loses to a fresh cache" {
    cp "$FIXTURES/normal.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _age "$MOTHER_BISHOP_POSTURE_FILE" -7200
    _cache 50 20
    _assert_feed_parity cache false
}

@test "L1-11: the max age is configurable and both agree" {
    cp "$FIXTURES/normal.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _age "$MOTHER_BISHOP_POSTURE_FILE" -120
    MOTHER_QUOTA_FEED_MAX_AGE_S=60 _assert_feed_parity none true
    MOTHER_QUOTA_FEED_MAX_AGE_S=600 _assert_feed_parity bishop false
}

@test "L1-11: a file dated in the future is not a fresh reading" {
    cp "$FIXTURES/normal.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _age "$MOTHER_BISHOP_POSTURE_FILE" 7200
    _assert_feed_parity none true
}

@test "L1-11: windows whose resets_at is in the past read as 0 percent" {
    _bishop 70 80 "$(( $(_now) - 100 ))" "$(( $(_now) - 5 ))"
    _assert_feed_parity bishop false
    [ "$(_lstate '.budget.five_hour.used_pct')" = "0" ]
    [ "$(_lstate '.budget.seven_day.used_pct')" = "0" ]
}

@test "L1-11: only the expired window is zeroed" {
    _bishop 70 80 "$(( $(_now) - 100 ))" "$(( $(_now) + 5000 ))"
    _assert_feed_parity bishop false
    [ "$(_lstate '.budget.five_hour.used_pct')" = "0" ]
    [ "$(_lstate '.budget.seven_day.used_pct')" = "80" ]
}

@test "L1-11: a string used_pct makes the file unusable (never read as 0%)" {
    jq -nc --argjson r "$(( $(_now) + 3600 ))" \
        '{stale_input: false, five_hour: {used_pct: "40", resets_at: $r}, seven_day: {used_pct: 10, resets_at: $r}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity none true
}

@test "L1-11: a string used_pct in Bishop falls through to the cache" {
    jq -nc --argjson r "$(( $(_now) + 3600 ))" \
        '{stale_input: false, five_hour: {used_pct: "40", resets_at: $r}, seven_day: {used_pct: 10, resets_at: $r}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"
    _cache 17 9
    _assert_feed_parity cache false
}

@test "L1-11: a window missing from the file makes it unusable" {
    jq -nc --argjson r "$(( $(_now) + 3600 ))" '{five_hour: {used_pct: 40, resets_at: $r}}' > "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity none true
}

@test "L1-11: a corrupt file is unusable" {
    echo '{"five_hour": {"used_pct": 4' > "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity none true
}

@test "L1-11: no feed files at all" {
    rm -f "$MOTHER_BISHOP_POSTURE_FILE" "$MOTHER_RATE_LIMIT_CACHE"
    _assert_feed_parity none true
    [ "$(_lstate '.budget.five_hour.used_pct')" = "0" ]
}

@test "L1-11: fractional percentages and reset times are read the same way" {
    jq -nc --argjson r "$(( $(_now) + 3600 ))" \
        '{stale_input: false, five_hour: {used_pct: 12.5, resets_at: ($r + 0.75)}, seven_day: {used_pct: 99.9, resets_at: $r}}' \
        > "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity bishop false
}

@test "L1-11: a missing resets_at is read as 0 by both" {
    jq -nc '{stale_input: false, five_hour: {used_pct: 55}, seven_day: {used_pct: 10}}' > "$MOTHER_BISHOP_POSTURE_FILE"
    _assert_feed_parity bishop false
}

@test "L1-11: the status reports the feed source and a stale flag" {
    cp "$FIXTURES/normal.json" "$MOTHER_BISHOP_POSTURE_FILE"
    _tick
    [ "$(_lstate '.budget.source')" = "bishop" ]
    [ "$(_lstate '.budget.stale')" = "false" ]
    jq -e '(.state.budget.feed_age_s | type) == "number"' <(mother-limiter status --raw --root "$MOTHER_ROOT") >/dev/null
}

# ===========================================================================
# modes, status and knobs
# ===========================================================================

@test "status --json with no state prints mode observe and a null state" {
    run mother-limiter status --raw --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ "$(jq -cS . <<<"$output")" = '{"mode":"observe","state":null}' ]
}

@test "a tick writes state that status then reports" {
    _bishop 10 10
    make_job st-1 ready ".repo_path = \"$MOTHER_ROOT\""
    mother-limiter tick --root "$MOTHER_ROOT" >/dev/null
    run mother-limiter status --raw --root "$MOTHER_ROOT"
    [ "$(jq -r .mode <<<"$output")" = "observe" ]
    [ "$(jq -r '.state.ready | length' <<<"$output")" = "1" ]
    [ "$(jq -r '.state.ready[0].id' <<<"$output")" = "st-1" ]
    [ "$(jq -r '.state.ceiling' <<<"$output")" = "2" ]
}

@test "mode.json off: the tick does nothing and status says off" {
    mkdir -p "$MOTHER_ROOT/limiter"
    echo '{"mode":"off"}' > "$MOTHER_ROOT/limiter/mode.json"
    make_job m-1 ready ".repo_path = \"$MOTHER_ROOT\""
    run mother-limiter tick --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ ! -e "$MOTHER_ROOT/limiter/state.json" ]
    [ ! -e "$MOTHER_ROOT/limiter/decisions.jsonl" ]
    run mother-limiter status --raw --root "$MOTHER_ROOT"
    [ "$(jq -r .mode <<<"$output")" = "off" ]
    # the runner's tick, too, leaves the job and the state tree alone
    jq -S . "$JOBS_DIR/m-1.json" > "$MOTHER_ROOT/m-before.json"
    _runner_tick
    [ ! -e "$MOTHER_ROOT/limiter/state.json" ]
    [ ! -e "$RUNNER_DIR/limiter-fault.json" ]
    jq -S . "$JOBS_DIR/m-1.json" | cmp - "$MOTHER_ROOT/m-before.json"
}

@test "MOTHER_LIMITER_MODE=off wins over everything: no tick, status says off" {
    make_job e-1 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_MODE=off run mother-limiter tick --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ ! -e "$MOTHER_ROOT/limiter/state.json" ]
    MOTHER_LIMITER_MODE=off run mother-limiter status --raw --root "$MOTHER_ROOT"
    [ "$(jq -r .mode <<<"$output")" = "off" ]
}

@test "MOTHER_LIMITER_MODE=off stops the runner from ticking at all" {
    make_job e-2 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_MODE=off MOTHER_LIMITER_INTERVAL=0 mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ ! -e "$MOTHER_ROOT/limiter" ]
    [ ! -e "$RUNNER_DIR/limiter-fault.json" ]
}

@test "MOTHER_LIMITER_MODE=enforce behaves as observe and says so once on stderr" {
    _bishop 10 10
    make_job en-1 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_MODE=enforce mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>"$MOTHER_ROOT/enf.err"
    [ -s "$MOTHER_ROOT/limiter/state.json" ]
    [ "$(wc -l < "$MOTHER_ROOT/enf.err" | tr -d ' ')" = "1" ]
    grep -qi 'enforce' "$MOTHER_ROOT/enf.err"
    [ "$(MOTHER_LIMITER_MODE=enforce mother-limiter status --raw --root "$MOTHER_ROOT" 2>/dev/null | jq -r .mode)" = "observe" ]
    # it still only observes: the job is untouched but for annotations
    [ "$(jq -r .state "$JOBS_DIR/en-1.json")" = "ready" ]
}

@test "a non-numeric knob falls back to its default with a stderr line" {
    _bishop 86 10                                   # inside the default 15% reserve
    make_job kn-1 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_RESERVE_PCT=abc mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>"$MOTHER_ROOT/knob.err"
    grep -q 'MOTHER_LIMITER_RESERVE_PCT' "$MOTHER_ROOT/knob.err"
    [ "$(_lstate '.ready[0].code')" = "reserve" ]
    [ "$(_lstate '.budget.reserve_pct == 15')" = "true" ]
}

@test "a negative knob also falls back to its default" {
    _bishop 86 10
    make_job kn-2 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_RESERVE_PCT=-5 mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>"$MOTHER_ROOT/knob.err"
    grep -q 'MOTHER_LIMITER_RESERVE_PCT' "$MOTHER_ROOT/knob.err"
    [ "$(_lstate '.budget.reserve_pct == 15')" = "true" ]
}

@test "a valid knob from the environment moves the reserve" {
    _bishop 70 10
    make_job kn-3 ready ".repo_path = \"$MOTHER_ROOT\""
    MOTHER_LIMITER_RESERVE_PCT=30 mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    [ "$(_lstate '.ready[0].code')" = "reserve" ]
    rm -f "$MOTHER_ROOT/limiter/state.json"
    MOTHER_LIMITER_RESERVE_PCT=10 mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    [ "$(_lstate '.ready[0].decision')" = "admit" ]
}

@test "a knob in config.env applies, and the environment overrides it" {
    _bishop 70 10
    make_job kn-4 ready ".repo_path = \"$MOTHER_ROOT\""
    echo 'MOTHER_LIMITER_RESERVE_PCT=30' > "$MOTHER_ROOT/config.env"
    mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    [ "$(_lstate '.ready[0].code')" = "reserve" ]
    rm -f "$MOTHER_ROOT/limiter/state.json"
    MOTHER_LIMITER_RESERVE_PCT=5 mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    [ "$(_lstate '.ready[0].decision')" = "admit" ]
}

@test "the ceiling follows MOTHER_CONCURRENCY" {
    _bishop 10 10
    MOTHER_CONCURRENCY=5 mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    [ "$(_lstate '.ceiling')" = "5" ]
    [ "$(_lstate '.allowed')" = "5" ]
}

@test "the gate switch off makes reserve holds advisory in the limiter's view" {
    _bishop 90 10
    make_job g-1 ready ".repo_path = \"$MOTHER_ROOT\""
    mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    [ "$(_lstate '.ready[0].advisory')" = "false" ]
    jq -nc '{state: "off", changed_at: "2026-11-02T00:00:00.000Z", changed_by: "cli"}' > "$MOTHER_ROOT/quota-gate.json"
    rm -f "$MOTHER_ROOT/limiter/state.json"
    mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    [ "$(_lstate '.ready[0].code')" = "reserve" ]
    [ "$(_lstate '.ready[0].advisory')" = "true" ]
}

@test "queued jobs are annotated with a class and an estimate but never listed as ready to admit" {
    _bishop 10 10
    make_job q-1 queued ".repo_path = \"$MOTHER_ROOT\""
    run mother-limiter tick --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    jq -e '.annotations | length >= 1' <<<"$output" >/dev/null
    [ "$(_lstate '.ready | map(.id) | index("q-1")')" = "null" ]
}

@test "the tick's stdout is one JSON line of annotations" {
    _bishop 10 10
    make_job j-1 ready ".repo_path = \"$MOTHER_ROOT\""
    run mother-limiter tick --root "$MOTHER_ROOT"
    [ "$status" -eq 0 ]
    [ "$(printf '%s\n' "$output" | wc -l | tr -d ' ')" = "1" ]
    [ "$(jq -r '.annotations[0].id' <<<"$output")" = "j-1" ]
    [ "$(jq -r '.annotations[0].data_class' <<<"$output")" = "personal" ]
}

@test "a second tick with nothing changed annotates nothing" {
    _bishop 10 10
    make_job j-2 ready ".repo_path = \"$MOTHER_ROOT\""
    mother-limiter tick --root "$MOTHER_ROOT" >/dev/null 2>&1
    _runner_tick                      # lands the annotations
    run mother-limiter tick --root "$MOTHER_ROOT"
    [ "$(jq -r '.annotations | length' <<<"$output")" = "0" ]
}

@test "terminal jobs are ignored by the tick" {
    _bishop 10 10
    make_job done-1 succeeded ".repo_path = \"$MOTHER_ROOT\""
    make_job done-2 failed ".repo_path = \"$MOTHER_ROOT\""
    make_job done-3 cancelled ".repo_path = \"$MOTHER_ROOT\""
    run mother-limiter tick --root "$MOTHER_ROOT"
    [ "$(jq -r '.annotations | length' <<<"$output")" = "0" ]
    [ "$(_lstate '.ready | length')" = "0" ]
    [ "$(_lstate '.running | length')" = "0" ]
}

# ===========================================================================
# distress scan of live job logs and events
# ===========================================================================

_append_log() { cat "$FIXTURES/$1" >> "$LOGS_DIR/$2.log"; }

@test "distress: a 429 api_retry appearing in a running job's log cuts allowed concurrency" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _tick
    [ "$(_lstate '.allowed')" = "4" ]
    [ "$(_lstate '.components.distress_24h')" = "0" ]

    _append_log api_retry_429.jsonl d-run
    _tick
    [ "$(_lstate '.components.distress_24h')" = "1" ]
    [ "$(_lstate '.allowed')" = "2" ]
    [ "$(_lstate '.components.last_distress.job_id')" = "d-run" ]
}

@test "distress: the same log line is not counted again on the next tick" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _tick
    _append_log api_retry_429.jsonl d-run
    _tick
    _tick
    _tick
    [ "$(_lstate '.components.distress_24h')" = "1" ]
    [ "$(_lstate '.allowed')" = "2" ]
}

@test "distress: a result with api_error_status 429 counts" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _tick
    _append_log result_429.jsonl d-run
    _tick
    [ "$(_lstate '.components.distress_24h')" = "1" ]
    [ "$(_lstate '.allowed')" = "2" ]
}

@test "distress: a non-overage rejected rate_limit_event counts" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _tick
    _append_log rejected_not_overage.jsonl d-run
    _tick
    [ "$(_lstate '.allowed')" = "2" ]
}

@test "distress: overage-only rejections and a null error_status are not distress" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _tick
    _append_log overage_only.jsonl d-run
    _append_log api_retry_null.jsonl d-run
    _tick
    [ "$(_lstate '.components.distress_24h')" = "0" ]
    [ "$(_lstate '.allowed')" = "4" ]
    # ... but the overage is noticed
    [ "$(_lstate '.budget.overage_in_use')" = "true" ]
}

@test "distress: history already in a log when the limiter first looks is not replayed" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    _append_log api_retry_429.jsonl d-run
    _append_log result_429.jsonl d-run
    _tick
    _tick
    _tick
    [ "$(_lstate '.components.distress_24h')" = "0" ]
    [ "$(_lstate '.allowed')" = "4" ]
}

@test "distress: a job's logs are only read while it is running" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-done succeeded ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-done.log"
    make_job d-other running ".repo_path = \"$MOTHER_ROOT\""
    _tick
    _append_log api_retry_429.jsonl d-done
    _tick
    [ "$(_lstate '.components.distress_24h')" = "0" ]
}

@test "distress: a failure_routed rate_limited event on a job that went back to ready counts" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-back ready ".repo_path = \"$MOTHER_ROOT\""
    : > "$EVENTS_DIR/d-back.jsonl"
    _tick
    jq -nc '{ts: "2026-11-06T00:00:00Z", kind: "failure_routed", detail: {action: "backed_off", reason: "rate_limited", delay_s: 30}}' \
        >> "$EVENTS_DIR/d-back.jsonl"
    _tick
    [ "$(_lstate '.components.distress_24h')" = "1" ]
    [ "$(_lstate '.allowed')" = "2" ]
}

@test "distress: failure_routed for an unrelated reason is not distress" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-back ready ".repo_path = \"$MOTHER_ROOT\""
    : > "$EVENTS_DIR/d-back.jsonl"
    _tick
    jq -nc '{ts: "2026-11-06T00:00:00Z", kind: "failure_routed", detail: {action: "held", reason: "no_pr_no_push"}}' \
        >> "$EVENTS_DIR/d-back.jsonl"
    _tick
    [ "$(_lstate '.components.distress_24h')" = "0" ]
}

@test "distress: a half-written last line is not read until it is complete" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _tick
    local line; line=$(cat "$FIXTURES/api_retry_429.jsonl")
    printf '%s' "${line:0:40}" >> "$LOGS_DIR/d-run.log"
    _tick
    [ "$(_lstate '.components.distress_24h')" = "0" ]
    printf '%s\n' "${line:40}" >> "$LOGS_DIR/d-run.log"
    _tick
    [ "$(_lstate '.components.distress_24h')" = "1" ]
}

@test "distress: observing a cut changes nothing the runner does" {
    _fake_run_job
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job d-run running ".repo_path = \"$MOTHER_ROOT\""
    make_job d-wait ready ".repo_path = \"$MOTHER_ROOT\""
    : > "$LOGS_DIR/d-run.log"
    _tick
    _append_log api_retry_429.jsonl d-run
    _tick
    [ "$(_lstate '.allowed')" = "2" ]
    # dispatch has a free slot (1 of 4 running) and uses it, limiter or not
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null 3>&-
    [ "$(jq -r .state "$JOBS_DIR/d-wait.json")" = "running" ]
}

# ===========================================================================
# PR #109 review fix-ups
# ===========================================================================

@test "fixup-1: a job cancelled between tick and apply stays cancelled with no limiter fields" {
    _fake_run_job
    make_job race-1 ready ".repo_path = \"$MOTHER_ROOT\""
    # the tick reads the job as ready, then it is cancelled before the annotations are applied
    printf '#!/usr/bin/env bash\ncat <<JSON\n{"annotations":[{"id":"race-1","data_class":"company","would":{"code":"admit","reason":"x","advisory":false,"at":"2026-11-06T00:00:00Z"}}]}\nJSON\njq ".state = \\"cancelled\\"" "%s/race-1.json" > "%s/race-1.json.x" && mv "%s/race-1.json.x" "%s/race-1.json"\n' \
        "$JOBS_DIR" "$JOBS_DIR" "$JOBS_DIR" "$JOBS_DIR" > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
    MOTHER_LIMITER_INTERVAL=0 MOTHER_LIMITER_TIMEOUT=5 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ "$(jq -r .state "$JOBS_DIR/race-1.json")" = "cancelled" ]
    [ "$(jq -r 'has("limiter") or has("data_class")' "$JOBS_DIR/race-1.json")" = "false" ]
}

@test "fixup-2: a retried job's old rate-limit event is not replayed as fresh distress" {
    _bishop 10 10
    export MOTHER_CONCURRENCY=4
    make_job old-1 ready ".repo_path = \"$MOTHER_ROOT\""
    : > "$EVENTS_DIR/old-1.jsonl"
    _tick
    # the job fails terminally (its offset is pruned), having once been rate limited
    jq -nc '{ts: "2026-11-06T00:00:00Z", kind: "failure_routed", detail: {action: "backed_off", reason: "rate_limited", delay_s: 30}}' \
        >> "$EVENTS_DIR/old-1.jsonl"
    jq '.state = "failed"' "$JOBS_DIR/old-1.json" > "$JOBS_DIR/old-1.tmp" && mv "$JOBS_DIR/old-1.tmp" "$JOBS_DIR/old-1.json"
    _tick
    # retried: back to ready
    jq '.state = "ready"' "$JOBS_DIR/old-1.json" > "$JOBS_DIR/old-1.tmp" && mv "$JOBS_DIR/old-1.tmp" "$JOBS_DIR/old-1.json"
    _tick
    [ "$(_lstate '.components.distress_24h')" = "0" ]
    [ "$(_lstate '.allowed')" = "4" ]
}

@test "fixup-3: a limiter that always hangs is invoked a bounded number of times over many iterations" {
    _fake_run_job
    printf '#!/usr/bin/env bash\necho x >> "%s/limiter-calls"\nexec sleep 30\n' "$MOTHER_ROOT" > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
    make_job hang-b ready ".repo_path = \"$MOTHER_ROOT\""
    local i
    for i in 1 2 3 4 5; do
        MOTHER_LIMITER_INTERVAL=0 MOTHER_LIMITER_TIMEOUT=1 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    done
    [ "$(wc -l < "$MOTHER_ROOT/limiter-calls" | tr -d ' ')" = "1" ]
    # dispatch cadence is untouched
    MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --dispatch-tick 2>/dev/null 3>&-
    [ "$(jq -r .state "$JOBS_DIR/hang-b.json")" = "running" ]
}

@test "fixup-3: a clean tick resets the backoff" {
    _fake_run_job
    printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKE_BIN/mother-limiter"
    chmod +x "$FAKE_BIN/mother-limiter"
    _bishop 5 10
    MOTHER_LIMITER_INTERVAL=0 MOTHER_LIMITER_TIMEOUT=2 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ -f "$RUNNER_DIR/limiter-backoff.json" ]
    # backoff expires
    jq '.skip_until = 0' "$RUNNER_DIR/limiter-backoff.json" > "$RUNNER_DIR/b.tmp" && mv "$RUNNER_DIR/b.tmp" "$RUNNER_DIR/limiter-backoff.json"
    _real_limiter_wrapper
    MOTHER_LIMITER_INTERVAL=0 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ ! -e "$RUNNER_DIR/limiter-backoff.json" ]
}

@test "fixup-4: mother add succeeds quickly when the limiter hangs" {
    printf '#!/usr/bin/env bash\nexec sleep 30\n' > "$MOTHER_ROOT/hang-limiter"
    mkdir -p "$MOTHER_ROOT/fb"; cp "$MOTHER_ROOT/hang-limiter" "$MOTHER_ROOT/fb/mother-limiter"; chmod +x "$MOTHER_ROOT/fb/mother-limiter"
    local t0 id; t0=$(_now)
    id=$(MOTHER_BIN_DIR="$MOTHER_ROOT/fb" MOTHER_LIMITER_ADD_TIMEOUT=1 _add testrepo 3>&-)
    [ -n "$id" ]
    [ $(( $(_now) - t0 )) -lt 10 ]
    [ -f "$JOBS_DIR/$id.json" ]
}

@test "fixup-5: a repo whose crew config is phi_sensitive is company, never personal" {
    mkdir -p "$FAKE_REPO/.mother"
    printf 'version: 1\nphi_sensitive: true\ngates:\n  checks: []\n' > "$FAKE_REPO/.mother/crew.yml"
    run _classify "$FAKE_REPO" some-fork
    [ "$output" = "company" ]
}

@test "fixup-5: the tick treats a job whose crew snapshot is phi_sensitive as company" {
    _bishop 5 10
    _fake_run_job
    make_job phi-1 ready ".repo_path = \"$MOTHER_ROOT\" | .repo = \"some-fork\" | .crew = {phi_sensitive: true}"
    _real_limiter_wrapper
    MOTHER_LIMITER_INTERVAL=0 MOTHER_BIN_DIR="$FAKE_BIN" mother-runner --limiter-tick 3>&- >/dev/null 2>&1
    [ "$(jq -r .data_class "$JOBS_DIR/phi-1.json")" = "company" ]
}

@test "fixup: stale limiter tmp files of dead pids are swept at tick start" {
    _bishop 5 10
    mkdir -p "$MOTHER_ROOT/limiter"
    : > "$MOTHER_ROOT/limiter/state.json.tmp.999999"
    _tick
    [ ! -e "$MOTHER_ROOT/limiter/state.json.tmp.999999" ]
}
