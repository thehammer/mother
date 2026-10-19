#!/usr/bin/env bats
# review_wave.bats — the reviewer wave inside the job lifecycle (HC-14).
#
# A job whose `.crew.lenses` is an object (and whose run is heading for success,
# not held by gates, not a pipeline job) does not just present its PR: after the
# post-run gate step `mother-run-job` runs a REVIEW WAVE. Per cycle N (1, 2, ...):
#
#   * the adherence reviewer (`mother adherence-review <id> --pre-ready`, claude
#     --agent archie) and every selected lens (`mother review-lens <id> --lens L`,
#     claude --agent perri-lens) run IN PARALLEL; a lens that is out of scope, out
#     of budget, removed by the plan or clamped by posture is skipped, not run;
#   * the lens findings are merged (claims verified mechanically at HEAD; a
#     refuted finding never reaches anyone), and the cycle decides:
#         blocking human finding / lens error / second adherence fail -> HOLD
#         blocking redd|cody|marty finding / first adherence fail     -> REWORK
#         otherwise                                                   -> SHIP
#     advisory findings never cause rework;
#   * REWORK resumes the worker's own claude session with the blocking findings
#     (never a refuted one), re-runs the gates on the new head, then reviews again;
#     a cycle that wants rework once the per-run cycle cap is spent HOLDS instead;
#   * HOLD is awaiting/review_hold with a structured decision
#     [resume_with_guidance, override_open, cancel] and a Mother-written question;
#   * SHIP writes ONE <!-- mother:review --> block into the PR body and only then
#     marks the PR ready. With gates enforced or `lenses.mode: enforce` the PR is a
#     draft until that moment. `lenses.mode: observe` records everything but
#     never reworks, holds, or touches the PR.
#
# Observable contract asserted here (job JSON, events, side files, runs.jsonl,
# claude's argv/stdin, the gh call log + PR fixture, `mother status|list` text,
# scripts/contract-check.sh) — not how mother-run-job is wired.
#
# Harness (same shape as gates_enforce.bats): a temp repo with a BARE origin; a
# main-dir job on a pre-seeded branch; a real `mother-run-job` subprocess; gh is
# gh_mock (stateful PR fixture); `claude` is ONE scriptable stand-in that tells
# the worker apart from the reviewers by argv:
#
#   worker (anything but --agent archie|perri-lens)
#     $MOTHER_ROOT/ge-count          worker invocations so far
#     $MOTHER_ROOT/argv.<n>          worker n's argv, one arg per line
#     $MOTHER_ROOT/stdin.<n>         worker n's stdin (the prompt)
#     $MOTHER_ROOT/wk-draft.<n>      the PR's isDraft when worker n started
#     $MOTHER_ROOT/ge-behave.<n>     optional script sourced by worker n (see _rw_behave)
#   reviewer (--agent archie | --agent perri-lens); <key> = archie | perri-lens.<lens>
#     $MOTHER_ROOT/rv-argv.<key>.<k>   the k-th invocation's argv
#     $MOTHER_ROOT/rv-stdin.<key>.<k>  ... and its stdin
#     $MOTHER_ROOT/rv-log              one line per invocation: <key> <k> <start-ms> <end-ms> <isDraft>
#     $MOTHER_ROOT/rv-seq.<key>        invocations of <key> so far
#     $MOTHER_ROOT/rv/<key>.jsonl      its canned reply (mock_claude's
#                                      MOCK_CLAUDE_STDOUT_BY_AGENT_DIR); a reply
#                                      staged at rv-script/<key>.<k> replaces it for
#                                      the k-th invocation only (cycle-specific replies)
#     rv-sleep[.<key>] seconds to linger; rv-exit.<key> exit code; rv-block = hold
#                      every reviewer until $MOTHER_ROOT/release exists
#
# The worker env has MOTHER_LIVE_ROOT, not MOTHER_ROOT (CLAUDE.md "State safety"),
# so the stand-in resolves its root from MOTHER_LIVE_ROOT.

bats_require_minimum_version 1.5.0
load 'test_helper'
load 'gh_mock'

RW_PR="https://github.com/Carefeed/test/pull/42"

# Distinctive texts. Finding text, claim quotes and adherence notes must reach
# the PR/worker/side files only — never the job JSON or the event log (HC14-8).
RW_SUM_CODY="SUMMARY_MARKER_cody_a1b2"
RW_DET_CODY="DETAIL_MARKER_cody_a1b2"
RW_SUM_HUMAN="SUMMARY_MARKER_human_c3d4"
RW_DET_HUMAN="DETAIL_MARKER_human_c3d4"
RW_SUM_REFUTED="SUMMARY_MARKER_refuted_e5f6"
RW_DET_REFUTED="DETAIL_MARKER_refuted_e5f6"
RW_SUM_ADV1="SUMMARY_MARKER_advisory_one"
RW_SUM_ADV2="SUMMARY_MARKER_advisory_two"
RW_SUM_UNVERIFIED="SUMMARY_MARKER_unverified_77"
RW_NOTES="ADHERENCE_NOTES_MARKER_5c2e"
# Lives in app/Foo.php line 3, so it is a claim quote that really is in the file.
RW_CLAIM_MARKER="CLAIM_MARKER_77e1"
RW_QUOTE='if ($isApache) { // CLAIM_MARKER_77e1'
# Lives far (> 15 lines) from line 3: a quote found only elsewhere is `unverified`.
RW_FAR_QUOTE='$far = 2; // FAR_MARKER_c3d9'
RW_ABSENT_QUOTE="QUOTE_ABSENT_zz9"

RW_EXAMINED='["app/Foo.php","resources/js/App.vue"]'
RW_LENSES='{"mode":"enforce","default":["correctness","tests","phi-security","ops-infra"],"mandatory":["correctness"],"scopes":{"ops-infra":["infra/**",".github/**"]},"budget_usd":3,"cycle_cap":2}'

# The worker's rework "fix": touch an already-changed file (so every changed
# file stays covered by the clean reviewers' examined lists) and commit.
RW_FIX_SNIPPET='echo "// reworked" >> app/Foo.php; git add app/Foo.php; git commit -q -m "address review"'

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_LENSES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID GH_MOCK_FAIL_DRAFT
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120
    GL_BG_PID=""

    gh_mock_install
    mkdir -p "$MOTHER_ROOT/rv" "$MOTHER_ROOT/rv-script"
    _rw_install_claude
    _rw_clean_all

    ORIGIN="$MOTHER_ROOT/origin.git"
    REPO="$MOTHER_ROOT/work/rwrepo"
    mkdir -p "$REPO"
    git init -q --bare "$ORIGIN"
    (
        cd "$REPO"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add .
        git commit -q -m "init"
        git remote add origin "$ORIGIN"
        git push -q -u origin main
    ) >/dev/null 2>&1
}

teardown() {
    # Release anything blocked on $MOTHER_ROOT/release, and reap a supervisor a
    # failed assertion left behind (only the pid this test started).
    touch "$MOTHER_ROOT/release" 2>/dev/null || true
    if [ -n "${GL_BG_PID:-}" ]; then
        kill "$GL_BG_PID" 2>/dev/null || true
    fi
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Harness: the claude stand-in

_rw_install_claude() {
    {
        printf '#!/usr/bin/env bash\nMOCK_CLAUDE_BIN=%q\nPR_KEY=%q\n' \
            "$_HELPER_DIR/mock_claude" "$(printf '%s' "$RW_PR" | tr -c 'a-zA-Z0-9' '_')"
        cat <<'CLAUDE'
ROOT="${MOTHER_LIVE_ROOT:-${MOTHER_ROOT:-}}"
_now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
_draft() { jq -r '.isDraft' "$ROOT/gh/pr/$PR_KEY.json" 2>/dev/null || echo unknown; }

agent=""; prev=""
for a in "$@"; do
    if [ "$prev" = "--agent" ]; then agent="$a"; break; fi
    prev="$a"
done

case "$agent" in
archie|perri-lens)
    # ---- a reviewer ----
    lens="${MOTHER_REVIEW_LENS:-}"
    [ "$agent" = "archie" ] && lens=""
    key="$agent${lens:+.$lens}"
    k=$(( $(cat "$ROOT/rv-seq.$key" 2>/dev/null || echo 0) + 1 ))
    echo "$k" > "$ROOT/rv-seq.$key"
    printf '%s\n' "$@" > "$ROOT/rv-argv.$key.$k"
    if [ -f "$ROOT/rv-script/$key.$k" ]; then cp "$ROOT/rv-script/$key.$k" "$ROOT/rv/$key.jsonl"; fi
    start=$(_now_ms)
    draft=$(_draft)
    sleep_s=$(cat "$ROOT/rv-sleep.$key" 2>/dev/null || cat "$ROOT/rv-sleep" 2>/dev/null || echo 0)
    exit_c=$(cat "$ROOT/rv-exit.$key" 2>/dev/null || echo 0)
    while [ -f "$ROOT/rv-block" ] && [ ! -f "$ROOT/release" ]; do sleep 0.2; done
    MOCK_CLAUDE_STDOUT_BY_AGENT_DIR="$ROOT/rv" \
        MOCK_CLAUDE_ARGS_FILE="$ROOT/rv-mockargs.$key.$k" \
        MOCK_CLAUDE_STDIN_FILE="$ROOT/rv-stdin.$key.$k" \
        MOCK_CLAUDE_SLEEP="$sleep_s" MOCK_CLAUDE_EXIT="$exit_c" \
        "$MOCK_CLAUDE_BIN" "$@"
    rc=$?
    end=$(_now_ms)
    echo "$key $k $start $end $draft" >> "$ROOT/rv-log"
    exit "$rc"
    ;;
esac

# ---- the worker ----
n=$(( $(cat "$ROOT/ge-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/ge-count"
printf '%s\n' "$@" > "$ROOT/argv.$n"
cat > "$ROOT/stdin.$n"
_draft > "$ROOT/wk-draft.$n"
PUSH=1; EXIT=0; SLEEP=0; POST=""; OUT_FILE="default"
BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -f "$ROOT/ge-behave.$n" ]; then . "$ROOT/ge-behave.$n"; fi
if [ "$PUSH" = "1" ]; then
    git push -q origin "HEAD:refs/heads/$BR" >/dev/null 2>&1 || true
fi
if [ "$n" = "1" ]; then
    echo "opened https://github.com/Carefeed/test/pull/42"
fi
if [ "$OUT_FILE" = "default" ]; then
    cat <<'EOF'
{"type":"assistant","message":{"id":"msg_rw","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
elif [ -n "$OUT_FILE" ]; then
    cat "$OUT_FILE"
fi
[ "$SLEEP" = "0" ] || sleep "$SLEEP"
[ -z "$POST" ] || eval "$POST"
exit "$EXIT"
CLAUDE
    } > "$_MOCK_BIN/claude"
    chmod +x "$_MOCK_BIN/claude"
}

# _rw_behave <n> <shell-snippet> — script WORKER invocation <n> (sourced inside the
# stand-in, cwd = the job's work dir; may set PUSH, EXIT, SLEEP, POST, OUT_FILE).
_rw_behave() { printf '%s\n' "$2" > "$MOTHER_ROOT/ge-behave.$1"; }

# ---------------------------------------------------------------------------
# Harness: canned reviewer replies (stream-json, the way real claude prints them)

# _rw_emit <result-text> — a stream-json reply whose .result is the text.
_rw_emit() {
    jq -nc '{type: "assistant", message: {id: "msg_rv", model: "claude-sonnet-5", parent_tool_use_id: null,
             usage: {input_tokens: 1000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 150}}}'
    jq -nc --arg r "$1" '{type: "result", subtype: "success", is_error: false, total_cost_usd: 0.02, result: $r}'
}

# _rw_dest <key> [k] — where <key>'s reply for invocation k (default: every one) goes.
_rw_dest() {
    if [ -n "${2:-}" ]; then printf '%s' "$MOTHER_ROOT/rv-script/$1.$2"; else printf '%s' "$MOTHER_ROOT/rv/$1.jsonl"; fi
}

# _rw_lens_reply <lens> <findings-json> [k] [examined-json]
_rw_lens_reply() {
    local text
    text=$(printf 'Reviewed the patch.\n\n```findings\n%s\n```\n\n```examined\n%s\n```' "$2" "${4:-$RW_EXAMINED}")
    _rw_emit "$text" > "$(_rw_dest "perri-lens.$1" "${3:-}")"
}

# _rw_adh_reply <pass|fail> [notes] [k]
_rw_adh_reply() {
    _rw_emit "$(printf 'ADHERENCE: %s\nNOTES:\n%s' "$1" "${2:-$RW_NOTES}")" > "$(_rw_dest archie "${3:-}")"
}

# Everyone clean: adherence passes, every lens reports nothing and examined everything.
_rw_clean_all() {
    local l
    _rw_adh_reply pass
    for l in correctness phi-security tests ops-infra; do _rw_lens_reply "$l" '[]'; done
}

# _rw_finding <id> <target> <severity> <location> <summary> <detail> [claims-json]
_rw_finding() {
    jq -nc --arg id "$1" --arg t "$2" --arg s "$3" --arg l "$4" --arg sm "$5" --arg d "$6" \
        --argjson claims "${7:-null}" '
        {id: $id, target: $t, severity: $s, location: $l, summary: $sm, detail: $d}
        + (if $claims == null then {} else {claims: $claims, asserts_existing_code: true} end)'
}

# A claim that really is in app/Foo.php at the cited line.
_rw_good_claim() { jq -nc --arg q "$RW_QUOTE" '[{path: "app/Foo.php", line: 3, quote: $q}]'; }
# A claim whose quote is nowhere in the cited file: refuted.
_rw_refuted_claim() { jq -nc --arg q "$RW_ABSENT_QUOTE" '[{path: "resources/js/App.vue", line: 1, quote: $q}]'; }
# A claim whose quote is in the file, but far from the cited line: unverified.
_rw_unverified_claim() { jq -nc --arg q "$RW_FAR_QUOTE" '[{path: "app/Foo.php", line: 3, quote: $q}]'; }

# _rw_cody_finding — the standard real blocking finding for cody.
_rw_cody_finding() {
    _rw_finding f1 cody blocking "app/Foo.php:3" "$RW_SUM_CODY" "$RW_DET_CODY" "$(_rw_good_claim)"
}
_rw_human_finding() {
    _rw_finding f1 human blocking "app/Foo.php:3" "$RW_SUM_HUMAN" "$RW_DET_HUMAN" "$(_rw_good_claim)"
}

# ---------------------------------------------------------------------------
# Harness: repo, crew, job

# _rw_seed_branch <branch> — local-only branch, one commit ahead of origin/main,
# touching a UI file and a PHP file whose line 3 carries the claim marker.
_rw_seed_branch() {
    (
        cd "$REPO"
        git checkout -q -B "$1" origin/main
        mkdir -p app resources/js
        {
            printf '<?php\nfunction provision($isApache) {\n    if ($isApache) { // %s\n        return 1;\n    }\n}\n' "$RW_CLAIM_MARKER"
            local i
            for i in $(seq 1 30); do printf '// pad %s\n' "$i"; done
            printf '%s\n' "$RW_FAR_QUOTE"
        } > app/Foo.php
        printf '<template><div>hello</div></template>\n' > resources/js/App.vue
        git add app/Foo.php resources/js/App.vue
        git commit -q -m "feature work for $1"
        git checkout -q main
    ) >/dev/null 2>&1
}

# _rw_lenses <jq-filter> — the default lenses object, adjusted.
_rw_lenses() { printf '%s' "$RW_LENSES" | jq -c "${1:-.}"; }

# _rw_crew <lenses-json|null> [gates-mode] — the resolved `.crew` snapshot. One
# passing blocking gate; RW_PHI=true makes the repo phi_sensitive.
_rw_crew() {
    jq -nc --argjson lenses "$1" --arg gm "${2:-enforce}" --argjson phi "${RW_PHI:-false}" '{
        version: 1, source_ref: "origin/main", source_sha: "abc", phi_sensitive: $phi,
        gates: {mode: $gm, max_attempts: 3, budget_minutes: 15,
                checks: [{name: "fine", run: "true", when: null, blocking: true, where: "any",
                          timeout_s: 60, hint: null}]},
        lenses: $lenses}'
}

# _rw_job <id> <crew-json> [extra-jq] — a ready main-dir job on its own seeded branch.
_rw_job() {
    local id="$1" crew="$2" extra="${3:-.}"
    _rw_seed_branch "feature/rw-$id"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo = "rwrepo"
         | .repo_path = "'"$REPO"'"
         | .base_ref = "origin/main"
         | .branch = "feature/rw-'"$id"'"
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }
         | .crew = '"$crew"'
         | ('"$extra"')'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    # adherence-review reads the plan from the legacy events/<id>-plan.md.
    make_plan "$EVENTS_DIR/$id-plan.md"
    touch "$LOGS_DIR/$id.log"
}

# _rw_pr <id> — the open (non-draft) PR the worker "opens" for job <id>.
_rw_pr() { gh_mock_set_pr "$RW_PR" OPEN "feature/rw-$1"; }

_rw_run() {
    run mother-run-job "$1"
    echo "$output"
}

_rw_bg_run() {
    mother-run-job "$1" >"$MOTHER_ROOT/run-job.out" 2>&1 3>&- &
    GL_BG_PID=$!
}

# _rw_wait_activity <id> <activity> — poll (<= 30s) until the job shows it; fails
# early when the background supervisor has already exited.
_rw_wait_activity() {
    local id="$1" want="$2" i act=""
    for i in $(seq 1 150); do
        act=$(jq -r '.activity // ""' "$JOBS_DIR/$id.json" 2>/dev/null)
        [ "$act" = "$want" ] && return 0
        kill -0 "$GL_BG_PID" 2>/dev/null || return 1
        sleep 0.2
    done
    return 1
}

# _rw_finish — release everything and wait for the background supervisor.
_rw_finish() {
    touch "$MOTHER_ROOT/release"
    wait "$GL_BG_PID" || true
    GL_BG_PID=""
}

_rw_assert_not() {
    if "$@"; then
        echo "unexpectedly succeeded: $*" >&2
        return 1
    fi
}

_rw_job_json() { jq -r "$2" "$JOBS_DIR/$1.json"; }
_rw_head() { git -C "$REPO" rev-parse "refs/heads/$1"; }
_rw_workers() { cat "$MOTHER_ROOT/ge-count" 2>/dev/null || echo 0; }
_rw_ev() { jq -s -e "$2" "$EVENTS_DIR/$1.jsonl" >/dev/null; }
_rw_argv_flag() { awk -v f="$2" '$0 == f {getline; print; exit}' "$MOTHER_ROOT/argv.$1" 2>/dev/null; }
_rw_argv_has() { grep -qxF -- "$2" "$MOTHER_ROOT/argv.$1" 2>/dev/null; }

# Reviewer views. <key> is archie or perri-lens.<lens>.
_rw_rv_count() { cat "$MOTHER_ROOT/rv-seq.$1" 2>/dev/null || echo 0; }
_rw_rv_flag() { awk -v f="$3" '$0 == f {getline; print; exit}' "$MOTHER_ROOT/rv-argv.$1.$2" 2>/dev/null; }
_rw_rv_keys() { cut -d' ' -f1 "$MOTHER_ROOT/rv-log" 2>/dev/null | sort | tr '\n' ' ' | sed 's/ $//'; }
_rw_rv_lines() { if [ -f "$MOTHER_ROOT/rv-log" ]; then wc -l < "$MOTHER_ROOT/rv-log" | tr -d ' '; else echo 0; fi; }

# _rw_lens <id> <lens> <jq-field> — a field of one entry of .review_wave.lenses.
_rw_lens() {
    jq -r --arg l "$2" '.review_wave.lenses[] | select(.lens == $l) | '"$3" "$JOBS_DIR/$1.json"
}

# gh call-log views.
_rw_undo_calls()  { gh_mock_calls | grep -n -E "^pr ready ${RW_PR} --undo" | cut -d: -f1; }
_rw_ready_calls() { gh_mock_calls | grep -n -E "^pr ready ${RW_PR}( |\$)" | grep -v -- '--undo' | cut -d: -f1; }
_rw_edit_calls()  { gh_mock_calls | grep -n -E "^pr edit ${RW_PR} .*--body-file" | cut -d: -f1; }

# _rw_block — the mother:review block of a PR body on stdin (markers included).
_rw_block() {
    awk '/<!-- mother:review -->/ {f = 1} f {print} /<!-- \/mother:review -->/ {f = 0}'
}

# _rw_ev_ms <id> <kind> — epoch ms of the first event of <kind>.
_rw_ev_ms() {
    jq -s -r --arg k "$2" '
        [.[] | select(.kind == $k)][0].ts as $t
        | (($t | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) * 1000)
          + ((($t | capture("\\.(?<m>[0-9]+)Z$").m) // "0") | tonumber)' "$EVENTS_DIR/$1.jsonl"
}

# _rw_assert_no_text <id> <marker>... — none of the markers is in the job JSON or
# the event log (HC14-8).
_rw_assert_no_text() {
    local id="$1" m; shift
    for m in "$@"; do
        run grep -c "$m" "$JOBS_DIR/$id.json"
        [ "$output" = "0" ]
        run grep -c "$m" "$EVENTS_DIR/$id.jsonl"
        [ "$output" = "0" ]
    done
}

_rw_envelopes() {
    jq -c -s --arg job "$1" '
        to_entries[]
        | {v: 1, dir: "event", t: .value.kind, id: ((.key + 1) | tostring), ts: .value.ts,
           data: (.value.detail + {job: $job, category: "activity"})}' \
        "$EVENTS_DIR/$1.jsonl"
}

# _rw_contract <id> — the whole event log passes scripts/contract-check.sh.
_rw_contract() {
    _rw_envelopes "$1" > "$MOTHER_ROOT/all.ndjson"
    [ -s "$MOTHER_ROOT/all.ndjson" ]
    run "$_PLUGIN_DIR/scripts/contract-check.sh" "$MOTHER_ROOT/all.ndjson"
    echo "$output"
    [ "$status" -eq 0 ]
}

# _rw_hold <id> — a PR job whose correctness lens raises a blocking HUMAN finding;
# runs to the review hold and checks it got there.
_rw_hold() {
    local id="$1"
    _rw_lens_reply correctness "[$(_rw_human_finding)]"
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_run "$id"
    [ "$(_rw_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_rw_job_json "$id" '.activity')" = "review_hold" ]
}

# ---------------------------------------------------------------------------
# (a) enforce lenses, everyone clean: parallel wave, scoped-out lens skipped,
#     PR ready only after the wave

@test "wave: reviewers run in parallel, an out-of-scope lens is skipped, and the PR is marked ready only after the wave ships" {
    local id="w-a1"
    _rw_pr "$id"
    gh_mock_set_pr_body "$RW_PR" "ORIGINAL_BODY_TEXT"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    echo 5 > "$MOTHER_ROOT/rv-sleep"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "1" ]

    # Adherence + the three in-scope lenses ran, once each; ops-infra did not.
    [ "$(_rw_rv_keys)" = "archie perri-lens.correctness perri-lens.phi-security perri-lens.tests" ]
    [ "$(_rw_rv_lines)" = "4" ]
    grep -qxF -- "archie" "$MOTHER_ROOT/rv-argv.archie.1"
    grep -qxF -- "perri-lens" "$MOTHER_ROOT/rv-argv.perri-lens.tests.1"

    cat "$MOTHER_ROOT/rv-log"
    # All four started before any finished (parallel) ...
    awk '{ if (NR == 1 || $3 > ms) ms = $3; if (NR == 1 || $4 < me) me = $4 } END { exit !(ms < me) }' \
        "$MOTHER_ROOT/rv-log"
    # ... so the reviewers' whole span is about one reviewer's time (5s sleep plus
    # startup), not four (serial would be >= 20s) ...
    local first_start last_end span
    first_start=$(awk 'NR == 1 || $3 < m { m = $3 } END { print m }' "$MOTHER_ROOT/rv-log")
    last_end=$(awk 'NR == 1 || $4 > m { m = $4 } END { print m }' "$MOTHER_ROOT/rv-log")
    span=$((last_end - first_start))
    echo "reviewer span: ${span} ms"
    [ "$span" -ge 4900 ]
    [ "$span" -le 11500 ]
    # ... and the cycle events bracket the reviewers' runs (1s of clock slack).
    local t0 t1
    t0=$(_rw_ev_ms "$id" review_cycle_started)
    t1=$(_rw_ev_ms "$id" review_cycle_completed)
    [ "$t0" -le "$((first_start + 1000))" ]
    [ "$t1" -ge "$((last_end - 1000))" ]

    # Events: the cycle names its reviewers; the scoped-out lens is skipped, not run.
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started") | .detail] as $s
        | ($s | length) == 1 and $s[0].cycle == 1 and $s[0].wave == true
          and ($s[0].reviewers | sort) == ["archie:adherence", "perri:correctness", "perri:phi-security", "perri:tests"]
          and ($s[0].pending_reviewers | sort) == ($s[0].reviewers | sort)'
    _rw_ev "$id" '[.[] | select(.kind == "lens_skipped") | .detail | {reviewer, lens, reason}]
        == [{reviewer: "perri:ops-infra", lens: "ops-infra", reason: "path_scope"}]'
    _rw_ev "$id" '[.[] | select(.kind == "reviewed") | .detail.reviewer] | sort
        == ["archie:adherence", "perri:correctness", "perri:phi-security", "perri:tests"]'
    _rw_ev "$id" '[.[] | select(.kind == "claims_verified") | .detail | {verified, refuted, unverified}]
        == [{verified: 0, refuted: 0, unverified: 0}]'
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_completed") | .detail] as $c
        | ($c | length) == 1 and $c[0].cycle == 1 and $c[0].decision == "ship" and $c[0].wave == true
          and $c[0].findings_count == 0 and $c[0].coverage_gaps == 0'
    _rw_ev "$id" '[.[] | select(.kind == "review_wave_completed") | .detail | {cycles, status}] == [{cycles: 1, status: "shipped"}]'
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started" or .kind == "review_wave_completed") | .kind]
        == ["review_cycle_started", "review_wave_completed"]'

    # Each lens got a share of the per-job budget (3 USD): at least the 0.5 floor, at
    # most an equal split of what is left; together never more than the budget.
    local l f total=0
    for l in correctness phi-security tests; do
        f=$(_rw_rv_flag "perri-lens.$l" 1 --max-budget-usd)
        [ -n "$f" ]
        awk -v f="$f" 'BEGIN { exit !(f >= 0.5 && f <= 1.0) }'
    done
    awk -v a="$(_rw_rv_flag perri-lens.correctness 1 --max-budget-usd)" \
        -v b="$(_rw_rv_flag perri-lens.phi-security 1 --max-budget-usd)" \
        -v c="$(_rw_rv_flag perri-lens.tests 1 --max-budget-usd)" 'BEGIN { exit !(a + b + c <= 3.0001) }'

    # Draft discipline: the PR was a draft whenever a reviewer ran, and `gh pr ready`
    # (no --undo) happened once, after the undo, only now.
    [ -z "$(grep -v ' true$' "$MOTHER_ROOT/rv-log")" ]
    local undo ready
    undo=$(_rw_undo_calls | head -1)
    ready=$(_rw_ready_calls | head -1)
    [ -n "$undo" ] && [ -n "$ready" ] && [ "$undo" -lt "$ready" ]
    [ "$(_rw_ready_calls | wc -l | tr -d ' ')" = "1" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "false" ]

    # The PR body: the author's text, one review block (and still one gates block).
    local body; body=$(gh_mock_last_body "$RW_PR")
    [[ "$body" == *"ORIGINAL_BODY_TEXT"* ]]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:review -->')" = "1" ]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- /mother:review -->')" = "1" ]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:gates -->')" = "1" ]

    # The job record.
    jq -e '.review_wave
        | .mode == "enforce" and .cycle == 1 and .cycle_cap == 2 and .status == "shipped"
          and .budget_usd == 3 and .over_budget == false and .pending_reviewers == []
          and .decision == "ship" and .coverage_gaps == 0
          and (.claims | {verified, refuted, unverified}) == {verified: 0, refuted: 0, unverified: 0}
          and (.cycles | length) == 1 and .cycles[0].cycle == 1 and .cycles[0].decision == "ship"
          and .cycles[0].pending_reviewers == []
          and ((.adherence.verdict | tostring) | test("^pass"))' "$JOBS_DIR/$id.json" >/dev/null
    [ "$(_rw_lens "$id" correctness '.state')" = "done" ]
    [ "$(_rw_lens "$id" correctness '.reviewer')" = "perri:correctness" ]
    [ "$(_rw_lens "$id" correctness '.findings | [.blocking, .advisory] | tostring')" = "[0,0]" ]
    [ "$(_rw_lens "$id" ops-infra '.state')" = "skipped" ]
    [ "$(_rw_lens "$id" ops-infra '.skip_reason')" = "path_scope" ]
    # Spend is the sum of the lenses' costs, and is real (the replies carry a cost).
    jq -e '(.review_wave.spent_usd | . > 0)
        and (.review_wave.spent_usd - ([.review_wave.lenses[] | .cost_usd // 0] | add) | fabs < 0.0001)' \
        "$JOBS_DIR/$id.json" >/dev/null
    [ "$(_rw_job_json "$id" '.activity // "none"')" != "review_wave" ]

    # The adherence leg: recorded on the job exactly like the post-PR review.
    [ "$(_rw_job_json "$id" '.adherence_status')" = "passed" ]
    [ "$(_rw_job_json "$id" '.adherence_attempts')" = "1" ]
    [ "$(_rw_job_json "$id" '.adherence_pending')" = "false" ]
    [ "$(_rw_job_json "$id" '.adherence_reviewed_sha')" = "$(_rw_head "feature/rw-$id")" ]

    # Side files.
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/correctness.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/tests.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/phi-security.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/merged.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/summary.json" ]

    # The ladder was not touched; no reviewer text leaked.
    [ "$(_rw_job_json "$id" '.current_tier')" = "tier_0" ]
    [ "$(_rw_job_json "$id" '.escalation_count')" = "0" ]
    _rw_assert_no_text "$id" "$RW_NOTES"

    # mother status: the wave section, each lens's state, skip reason, spend vs budget.
    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== review wave ==="* ]]
    [[ "$output" == *"perri:correctness"* ]]
    printf '%s\n' "$output" | grep -E 'ops-infra.*skipped' >/dev/null
    printf '%s\n' "$output" | grep -E 'path[_ ]scope' >/dev/null
    printf '%s\n' "$output" | grep -i 'budget' >/dev/null

    _rw_contract "$id"
}

@test "wave: the job is running with activity review_wave while the reviewers work, and shows each lens as pending or running" {
    local id="w-a2"
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    touch "$MOTHER_ROOT/rv-block"

    _rw_bg_run "$id"
    _rw_wait_activity "$id" review_wave
    [ "$(_rw_job_json "$id" '.state')" = "running" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "running" ]
    [ "$(_rw_job_json "$id" '.review_wave.cycle')" = "1" ]
    [ "$(_rw_job_json "$id" '.review_wave.pending_reviewers | length')" -ge 1 ]
    [ "$(_rw_job_json "$id" '.review_wave.lenses | map(select(.state == "pending" or .state == "running")) | length')" -ge 1 ]
    [ "$(_rw_lens "$id" ops-infra '.state')" = "skipped" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "true" ]
    run mother list --format json
    [ "$(printf '%s' "$output" | jq -r --arg id "$id" '.[] | select(.id == $id) | .activity')" = "review_wave" ]
    run mother status "$id"
    [[ "$output" == *"=== review wave ==="* ]]

    _rw_finish
    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "shipped" ]
}

# ---------------------------------------------------------------------------
# (b) a blocking cody finding: rework in the same session, gates again, ship

@test "wave: a blocking cody finding resumes the worker's own session with the finding, re-runs the gates, reviews again and ships" {
    local id="w-b1"
    _rw_pr "$id"
    gh_mock_set_pr_body "$RW_PR" "ORIGINAL_BODY_TEXT"
    # Cycle 1: correctness blocks (real, verified claim). Cycle 2: it is clean.
    _rw_lens_reply correctness "[$(_rw_cody_finding)]"
    _rw_lens_reply correctness '[]' 2
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    # Worker 2 is the rework run: it waits for the release (so the live state can be
    # observed), then makes the fix.
    _rw_behave 2 'while [ ! -f "$ROOT/release" ]; do sleep 0.2; done
'"$RW_FIX_SNIPPET"

    _rw_bg_run "$id"
    _rw_wait_activity "$id" review_rework
    [ "$(_rw_job_json "$id" '.state')" = "running" ]
    [ "$(_rw_job_json "$id" '.activity')" = "review_rework" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "true" ]
    _rw_finish

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "2" ]

    # The rework run re-enters the SAME session the first spawn created ...
    local sid; sid=$(_rw_argv_flag 1 --session-id)
    [ -n "$sid" ]
    [ "$(_rw_argv_flag 2 --resume)" = "$sid" ]
    _rw_assert_not _rw_argv_has 2 --session-id
    # ... and its prompt carries the finding's text.
    grep -qF "$RW_SUM_CODY" "$MOTHER_ROOT/stdin.2"
    grep -qF "$RW_DET_CODY" "$MOTHER_ROOT/stdin.2"
    # It ran while the PR was still a draft.
    [ "$(cat "$MOTHER_ROOT/wk-draft.2")" = "true" ]

    # Its own usage row; the ladder untouched.
    jq -s -e --arg id "$id" '[.[] | select(.job_id == $id and .run_kind == "review_rework")] | length == 1' \
        "$MOTHER_ROOT/metrics/runs.jsonl" >/dev/null
    [ "$(_rw_job_json "$id" '.current_tier')" = "tier_0" ]
    [ "$(_rw_job_json "$id" '.escalation_count')" = "0" ]
    [ "$(_rw_job_json "$id" '.retry_count')" = "0" ]

    # Events: two cycles, the rework in between, gates again on the NEW head.
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started") | .detail.cycle] == [1, 2]'
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_completed") | .detail | {cycle, decision}]
        == [{cycle: 1, decision: "continue"}, {cycle: 2, decision: "ship"}]'
    _rw_ev "$id" '[.[] | select(.kind == "review_rework_started") | .detail] as $r
        | ($r | length) == 1 and $r[0].cycle == 1 and $r[0].session_id == "'"$sid"'" and ($r[0] | has("findings"))'
    _rw_ev "$id" '[.[] | select(.kind == "review_wave_completed") | .detail | {cycles, status}] == [{cycles: 2, status: "shipped"}]'
    _rw_ev "$id" '[.[] | select(.kind == "gates_started") | .detail.head_sha] as $h
        | ($h | length) == 2 and $h[0] != $h[1] and $h[1] == "'"$(_rw_head "feature/rw-$id")"'"'
    _rw_ev "$id" '
        to_entries as $e
        | ([$e[] | select(.value.kind == "review_cycle_started" and .value.detail.cycle == 1) | .key] | first) as $s1
        | ([$e[] | select(.value.kind == "review_cycle_completed" and .value.detail.cycle == 1) | .key] | first) as $c1
        | ([$e[] | select(.value.kind == "review_rework_started") | .key] | first) as $rw
        | ([$e[] | select(.value.kind == "gates_started") | .key] | last) as $g2
        | ([$e[] | select(.value.kind == "review_cycle_started" and .value.detail.cycle == 2) | .key] | first) as $s2
        | ([$e[] | select(.value.kind == "review_wave_completed") | .key] | first) as $done
        | [$s1, $c1, $rw, $g2, $s2, $done] | all(. != null) and . == sort'
    _rw_ev "$id" '[.[] | select(.kind == "claims_verified") | .detail | {verified, refuted, unverified}] as $c
        | ($c | length) == 2 and $c[0] == {verified: 1, refuted: 0, unverified: 0}
          and $c[1] == {verified: 0, refuted: 0, unverified: 0}'

    # The job record carries both cycles.
    jq -e '.review_wave | .cycle == 2 and .status == "shipped" and (.cycles | length) == 2
        and .cycles[0].decision == "continue" and .cycles[1].decision == "ship"
        and (.cycles[0].reviewers | index("perri:correctness") != null)
        and (.cycles[0].reviewers | index("archie:adherence") != null)' "$JOBS_DIR/$id.json" >/dev/null
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/merged.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c2/merged.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c2/summary.json" ]
    # Both cycles' reviewers ran: correctness twice, the others once per cycle too.
    [ "$(_rw_rv_count perri-lens.correctness)" = "2" ]
    [ "$(_rw_rv_count archie)" = "2" ]

    # The PR is ready only after the second cycle shipped.
    [ "$(_rw_ready_calls | wc -l | tr -d ' ')" = "1" ]
    [ -z "$(grep -v ' true$' "$MOTHER_ROOT/rv-log")" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "false" ]
    local body; body=$(gh_mock_last_body "$RW_PR")
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:review -->')" = "1" ]
    [[ "$body" == *"ORIGINAL_BODY_TEXT"* ]]

    # mother list --format json: the derived cycles array, lens-qualified names.
    run mother list --format json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e --arg id "$id" '
        .[] | select(.id == $id) | .cycles
        | length == 2 and (.[0] | keys | sort) == ["cycle", "decision", "pending_reviewers", "reviewers"]
          and .[0].cycle == 1 and .[1].cycle == 2
          and (.[0].reviewers | index("perri:correctness") != null)' >/dev/null

    # HC14-8: no finding text, claim quote or notes in the job JSON or events.
    _rw_assert_no_text "$id" "$RW_SUM_CODY" "$RW_DET_CODY" "$RW_CLAIM_MARKER" "$RW_NOTES"
    _rw_contract "$id"
}

# ---------------------------------------------------------------------------
# (c) a blocking human finding: hold, decision, override

@test "wave: a blocking human finding holds the job for the operator with a Mother-written question and never marks the PR ready" {
    local id="w-c1"
    _rw_hold "$id"

    [ "$(_rw_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_rw_job_json "$id" '.activity')" = "review_hold" ]
    [ "$(_rw_job_json "$id" '.paused_reason')" = "review_hold" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "held" ]
    # No rework run: the finding is the human's.
    [ "$(_rw_workers)" = "1" ]
    _rw_ev "$id" '[.[] | select(.kind == "succeeded" or .kind == "failed" or .kind == "cancelled" or .kind == "review_rework_started")] | length == 0'

    # The PR stays a draft, never marked ready, no review block written.
    [ -z "$(_rw_ready_calls)" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "true" ]
    _rw_ev "$id" '[.[] | select(.kind == "pr_marked_ready")] | length == 0'
    [[ "$(gh_mock_last_body "$RW_PR")" != *"<!-- mother:review -->"* ]]

    # A structured decision with exactly three options, plus the attention flag.
    [ "$(_rw_job_json "$id" '.decision.kind')" = "review_hold" ]
    [ "$(jq -c '[.decision.options[].id]' "$JOBS_DIR/$id.json")" \
        = '["resume_with_guidance","override_open","cancel"]' ]
    [ "$(_rw_job_json "$id" '.decision.resolved_at')" = "null" ]
    [ "$(_rw_job_json "$id" '[(.attention // [])[] | .reason] | index("decision_awaiting") != null')" = "true" ]

    # Events.
    _rw_ev "$id" '[.[] | select(.kind == "decision_opened") | .detail] | length == 1 and .[0].kind == "review_hold"'
    _rw_ev "$id" '[.[] | select(.kind == "awaiting_input") | .detail] | last
        | .paused_reason == "review_hold" and (.question | length > 0)'
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_completed") | .detail] as $c
        | ($c | length) == 1 and ($c[0].decision == "block_human" or $c[0].decision == "hold")'
    _rw_ev "$id" '[.[] | select(.kind == "review_wave_completed") | .detail | {cycles, status}] == [{cycles: 1, status: "held"}]'

    # The question names the lens counts and where to look; it carries no finding text.
    local q; q=$(_rw_job_json "$id" '.question')
    [[ "$q" == *"mother status $id"* ]]
    printf '%s\n' "$q" | grep -E 'correctness[^0-9]*1' >/dev/null
    [[ "$q" != *"$RW_SUM_HUMAN"* ]]
    [[ "$q" != *"$RW_DET_HUMAN"* ]]
    [[ "$q" != *"$RW_CLAIM_MARKER"* ]]
    _rw_assert_no_text "$id" "$RW_SUM_HUMAN" "$RW_DET_HUMAN" "$RW_CLAIM_MARKER" "$RW_NOTES"

    # The finding itself lives in the side file for the operator to read.
    grep -qF "$RW_SUM_HUMAN" "$MOTHER_ROOT/crew/$id/wave/c1/correctness.json"

    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== review wave ==="* ]]
    [[ "$output" == *"mother resume $id"* ]]

    _rw_contract "$id"
}

@test "wave: --option override_open on a review hold writes the review block, marks the PR ready and succeeds the job" {
    local id="w-c2"
    _rw_hold "$id"
    [ -z "$(_rw_ready_calls)" ]

    run mother resume "$id" --option override_open
    echo "$output"
    [ "$status" -eq 0 ]

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "overridden" ]
    [ "$(_rw_job_json "$id" '.decision.resolved_at != null')" = "true" ]
    [ "$(_rw_job_json "$id" '.decision.resolution.option')" = "override_open" ]
    [ "$(_rw_job_json "$id" '[(.attention // [])[] | .reason] | index("decision_awaiting")')" = "null" ]
    _rw_ev "$id" '[.[] | select(.kind == "decision_resolved") | .detail.option] == ["override_open"]'

    [ -n "$(_rw_ready_calls)" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "false" ]
    local body; body=$(gh_mock_last_body "$RW_PR")
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:review -->')" = "1" ]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- /mother:review -->')" = "1" ]

    [ "$(_rw_job_json "$id" '.activity // "none"')" != "review_hold" ]
    run mother status "$id"
    [[ "$output" == *[Oo]verrid* ]]
    _rw_assert_no_text "$id" "$RW_SUM_HUMAN" "$RW_DET_HUMAN" "$RW_CLAIM_MARKER"
}

@test "wave: a lens that crashes did not review, so it holds the job rather than counting as a clean pass" {
    local id="w-c3"
    echo 1 > "$MOTHER_ROOT/rv-exit.perri-lens.tests"
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_rw_job_json "$id" '.activity')" = "review_hold" ]
    [ "$(_rw_job_json "$id" '.decision.kind')" = "review_hold" ]
    [ "$(_rw_lens "$id" tests '.state')" = "error" ]
    [ "$(_rw_lens "$id" correctness '.state')" = "done" ]
    [ "$(_rw_workers)" = "1" ]
    [ -z "$(_rw_ready_calls)" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "held" ]
}

# ---------------------------------------------------------------------------
# (d) refuted findings never reach anyone

@test "wave: a finding whose claim is refuted is kept out of the rework prompt while the real finding is in it" {
    local id="w-d1"
    _rw_pr "$id"
    local real refuted
    real=$(_rw_cody_finding)
    refuted=$(_rw_finding f2 cody blocking "resources/js/App.vue:1" "$RW_SUM_REFUTED" "$RW_DET_REFUTED" "$(_rw_refuted_claim)")
    _rw_lens_reply correctness "[$real, $refuted]"
    _rw_lens_reply correctness '[]' 2
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_behave 2 "$RW_FIX_SNIPPET"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "2" ]
    grep -qF "$RW_SUM_CODY" "$MOTHER_ROOT/stdin.2"
    grep -qF "$RW_DET_CODY" "$MOTHER_ROOT/stdin.2"
    _rw_assert_not grep -qF "$RW_SUM_REFUTED" "$MOTHER_ROOT/stdin.2"
    _rw_assert_not grep -qF "$RW_DET_REFUTED" "$MOTHER_ROOT/stdin.2"
    _rw_assert_not grep -qF "$RW_ABSENT_QUOTE" "$MOTHER_ROOT/stdin.2"
    _rw_ev "$id" '[.[] | select(.kind == "claims_verified") | .detail | {verified, refuted, unverified}][0] == {verified: 1, refuted: 1, unverified: 0}'
    # The refuted finding is still on record for the operator, in the merged file.
    grep -qF "$RW_SUM_REFUTED" "$MOTHER_ROOT/crew/$id/wave/c1/merged.json"
    _rw_assert_no_text "$id" "$RW_SUM_REFUTED" "$RW_DET_REFUTED" "$RW_ABSENT_QUOTE" "$RW_SUM_CODY"
}

@test "wave: advisory, unverified and refuted findings never force a rework; the PR body lists the advisories and counts the refuted" {
    local id="w-d2"
    _rw_pr "$id"
    gh_mock_set_pr_body "$RW_PR" "ORIGINAL_BODY_TEXT"
    local adv1 refuted unverified adv2
    adv1=$(_rw_finding f1 cody advisory "app/Foo.php:3" "$RW_SUM_ADV1" "detail one" "$(_rw_good_claim)")
    refuted=$(_rw_finding f2 cody blocking "resources/js/App.vue:1" "$RW_SUM_REFUTED" "$RW_DET_REFUTED" "$(_rw_refuted_claim)")
    unverified=$(_rw_finding f3 cody blocking "app/Foo.php:37" "$RW_SUM_UNVERIFIED" "detail three" "$(_rw_unverified_claim)")
    adv2=$(_rw_finding f1 redd advisory "app/Foo.php:20" "$RW_SUM_ADV2" "detail two")
    _rw_lens_reply correctness "[$adv1, $refuted, $unverified]"
    _rw_lens_reply tests "[$adv2]"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_run "$id"

    # Nothing here is a real blocking agent finding: one cycle, no rework, shipped.
    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "1" ]
    _rw_ev "$id" '[.[] | select(.kind == "review_rework_started")] | length == 0'
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_completed") | .detail | {cycle, decision}] == [{cycle: 1, decision: "ship"}]'
    _rw_ev "$id" '[.[] | select(.kind == "claims_verified") | .detail | {verified, refuted, unverified}] == [{verified: 1, refuted: 1, unverified: 1}]'
    [ "$(_rw_job_json "$id" '.review_wave.claims | [.verified, .refuted, .unverified] | tostring')" = "[1,1,1]" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "shipped" ]

    # The one review block: advisories as `- [<lens>] <severity>: <summary>`, a refuted count.
    local body block
    body=$(gh_mock_last_body "$RW_PR")
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:review -->')" = "1" ]
    [[ "$body" == *"ORIGINAL_BODY_TEXT"* ]]
    block=$(printf '%s\n' "$body" | _rw_block)
    printf '%s\n' "$block" | grep -qF -- "- [correctness] advisory: $RW_SUM_ADV1"
    printf '%s\n' "$block" | grep -qF -- "- [tests] advisory: $RW_SUM_ADV2"
    # The downgraded (unverified) finding is listed too, under the correctness lens.
    printf '%s\n' "$block" | grep -E -- "^- \[correctness\] [a-z]+: $RW_SUM_UNVERIFIED" >/dev/null
    printf '%s\n' "$block" | grep -i 'refuted' | grep -E '1' >/dev/null
    [[ "$block" != *"$RW_SUM_REFUTED"* ]]
    [[ "$block" != *"$RW_DET_REFUTED"* ]]
    _rw_assert_no_text "$id" "$RW_SUM_ADV1" "$RW_SUM_ADV2" "$RW_SUM_REFUTED" "$RW_SUM_UNVERIFIED"
}

# ---------------------------------------------------------------------------
# Adherence inside the wave

@test "wave: a failed adherence review sends the adherence notes to the worker as a rework, and the notes stay out of the job JSON and events" {
    local id="w-m1"
    _rw_pr "$id"
    _rw_adh_reply fail "$RW_NOTES the plan asks for X but the diff does Y"
    _rw_adh_reply pass "fine" 2
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_behave 2 "$RW_FIX_SNIPPET"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "2" ]
    local sid; sid=$(_rw_argv_flag 1 --session-id)
    [ "$(_rw_argv_flag 2 --resume)" = "$sid" ]
    grep -qF "$RW_NOTES" "$MOTHER_ROOT/stdin.2"
    [ "$(_rw_job_json "$id" '.adherence_attempts')" = "2" ]
    [ "$(_rw_job_json "$id" '.adherence_status')" = "passed" ]
    [ "$(_rw_job_json "$id" '.adherence_pending')" = "false" ]
    [ "$(_rw_job_json "$id" '.adherence_reviewed_sha')" = "$(_rw_head "feature/rw-$id")" ]
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_completed") | .detail | {cycle, decision}]
        == [{cycle: 1, decision: "continue"}, {cycle: 2, decision: "ship"}]'
    [ "$(_rw_job_json "$id" '.escalation_count')" = "0" ]
    _rw_assert_no_text "$id" "$RW_NOTES"
}

@test "wave: an adherence review that fails again after a rework holds the job instead of reworking a second time" {
    local id="w-m2"
    _rw_pr "$id"
    _rw_adh_reply fail "$RW_NOTES still wrong"
    _rw_job "$id" "$(_rw_crew "$(_rw_lenses '.cycle_cap = 3')")"
    _rw_behave 2 "$RW_FIX_SNIPPET"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_rw_job_json "$id" '.activity')" = "review_hold" ]
    [ "$(_rw_job_json "$id" '.decision.kind')" = "review_hold" ]
    # One rework (cycle 1 -> 2); the second failure is the hold, with cycles to spare.
    [ "$(_rw_workers)" = "2" ]
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started")] | length == 2'
    [ -z "$(_rw_ready_calls)" ]
    _rw_assert_no_text "$id" "$RW_NOTES"
}

@test "wave: a cycle that wants rework once the per-run cycle cap is spent holds the job" {
    local id="w-m3"
    _rw_pr "$id"
    # Correctness blocks on a real cody finding in EVERY cycle; the cap is 2.
    _rw_lens_reply correctness "[$(_rw_cody_finding)]"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_behave 2 "$RW_FIX_SNIPPET"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_rw_job_json "$id" '.activity')" = "review_hold" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "held" ]
    [ "$(_rw_job_json "$id" '.review_wave.cycle')" = "2" ]
    [ "$(_rw_job_json "$id" '.review_wave.cycle_cap')" = "2" ]
    [ "$(_rw_workers)" = "2" ]
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started")] | length == 2'
    _rw_ev "$id" '[.[] | select(.kind == "review_wave_completed") | .detail | {cycles, status}] == [{cycles: 2, status: "held"}]'
    [ -z "$(_rw_ready_calls)" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "true" ]
    [ "$(_rw_job_json "$id" '.escalation_count')" = "0" ]
    _rw_assert_no_text "$id" "$RW_SUM_CODY" "$RW_DET_CODY"
}

# ---------------------------------------------------------------------------
# (e) posture, (f) budget

@test "wave under conservative posture runs only the phi-security lens (plus adherence) on a PHI repo and skips the rest as posture" {
    local id="w-e1"
    cat > "$_MOCK_BIN/bishop" <<'BISHOP'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ] && [ "${2:-}" = "posture" ]; then
    echo "conservative"
fi
exit 0
BISHOP
    chmod +x "$_MOCK_BIN/bishop"
    export MOTHER_POSTURE_ENABLED=1
    RW_PHI=true
    local lenses
    lenses=$(_rw_lenses '.default = ["correctness","tests","ops-infra","phi-security"]
                         | .mandatory = ["phi-security"] | .scopes = {}')
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew "$lenses")"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_rv_keys)" = "archie perri-lens.phi-security" ]
    _rw_ev "$id" '[.[] | select(.kind == "lens_skipped") | .detail | {lens, reason}] | sort_by(.lens)
        == [{lens: "correctness", reason: "posture"}, {lens: "ops-infra", reason: "posture"}, {lens: "tests", reason: "posture"}]'
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started") | .detail.reviewers] == [["archie:adherence", "perri:phi-security"]]'
    [ "$(_rw_lens "$id" phi-security '.state')" = "done" ]
    [ "$(_rw_lens "$id" tests '.state')" = "skipped" ]
    [ "$(_rw_lens "$id" tests '.skip_reason')" = "posture" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "shipped" ]
}

@test "wave: once spend has reached the budget the non-mandatory lenses are skipped as budget, the mandatory one still runs on the floor, and the job says it is over budget" {
    local id="w-f1"
    local lenses
    lenses=$(_rw_lenses '.default = ["correctness","tests","phi-security"] | .scopes = {}')
    _rw_pr "$id"
    # 5 USD already spent on earlier waves of this job; the budget is 3.
    _rw_job "$id" "$(_rw_crew "$lenses")" '.review_wave = {spent_usd: 5}'
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_rv_keys)" = "archie perri-lens.correctness" ]
    _rw_ev "$id" '[.[] | select(.kind == "lens_skipped") | .detail | {lens, reason}] | sort_by(.lens)
        == [{lens: "phi-security", reason: "budget"}, {lens: "tests", reason: "budget"}]'
    awk -v f="$(_rw_rv_flag perri-lens.correctness 1 --max-budget-usd)" 'BEGIN { exit !(f == 0.5) }'
    [ "$(_rw_job_json "$id" '.review_wave.over_budget')" = "true" ]
    jq -e '.review_wave.spent_usd >= 5' "$JOBS_DIR/$id.json" >/dev/null
    [ "$(_rw_lens "$id" tests '.skip_reason')" = "budget" ]

    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"over review budget"* ]]
}

# ---------------------------------------------------------------------------
# (g) observe mode, and draft discipline without enforced gates

@test "observe mode runs and records the whole wave but ships despite blocking findings: no rework, no hold, no PR edits" {
    local id="w-g1"
    _rw_pr "$id"
    gh_mock_set_pr_body "$RW_PR" "UNTOUCHED_BODY"
    _rw_lens_reply correctness "[$(_rw_cody_finding)]"
    _rw_lens_reply tests "[$(_rw_finding f1 human blocking "app/Foo.php:20" "$RW_SUM_HUMAN" "$RW_DET_HUMAN")]"
    local lenses; lenses=$(_rw_lenses '.mode = "observe"')
    _rw_job "$id" "$(_rw_crew "$lenses" observe)"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "1" ]
    [ "$(_rw_job_json "$id" '.review_wave.mode')" = "observe" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "observed" ]
    [ "$(_rw_lens "$id" correctness '.findings | [.blocking, .advisory] | tostring')" = "[1,0]" ]
    [ "$(_rw_lens "$id" tests '.findings | [.blocking, .advisory] | tostring')" = "[1,0]" ]
    [ "$(_rw_job_json "$id" '.review_wave.decision // "none"')" != "none" ]

    # Everything is on record ...
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started")] | length == 1'
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_completed")] | length == 1'
    _rw_ev "$id" '[.[] | select(.kind == "review_wave_completed") | .detail | {cycles, status}] == [{cycles: 1, status: "observed"}]'
    _rw_ev "$id" '[.[] | select(.kind == "reviewed") | .detail.reviewer] | sort
        == ["archie:adherence", "perri:correctness", "perri:phi-security", "perri:tests"]'
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/correctness.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/tests.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/merged.json" ]
    [ -f "$MOTHER_ROOT/crew/$id/wave/c1/summary.json" ]

    # ... but nothing acted on it.
    _rw_ev "$id" '[.[] | select(.kind == "review_rework_started" or .kind == "decision_opened" or .kind == "awaiting_input")] | length == 0'
    [ -z "$(_rw_undo_calls)" ]
    [ -z "$(_rw_ready_calls)" ]
    [ -z "$(_rw_edit_calls)" ]
    [ "$(gh_mock_pr_body "$RW_PR")" = "UNTOUCHED_BODY" ]

    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== review wave ==="* ]]
    [[ "$output" == *"observe"* ]]
    _rw_assert_no_text "$id" "$RW_SUM_CODY" "$RW_DET_CODY" "$RW_SUM_HUMAN" "$RW_CLAIM_MARKER"
}

@test "wave with lenses enforced but gates only observed still keeps the PR a draft until the wave ships" {
    local id="w-g2"
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES" observe)"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_job_json "$id" '.review_wave.status')" = "shipped" ]
    local undo ready
    undo=$(_rw_undo_calls | head -1)
    ready=$(_rw_ready_calls | head -1)
    [ -n "$undo" ] && [ -n "$ready" ] && [ "$undo" -lt "$ready" ]
    [ "$(_rw_ready_calls | wc -l | tr -d ' ')" = "1" ]
    # Every reviewer saw a draft.
    [ "$(_rw_rv_lines)" -ge 4 ]
    [ -z "$(grep -v ' true$' "$MOTHER_ROOT/rv-log")" ]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "false" ]
    [ "$(gh_mock_last_body "$RW_PR" | grep -c '<!-- mother:review -->')" = "1" ]
}

# ---------------------------------------------------------------------------
# (h) no wave without lenses

@test "a crew with no lenses behaves exactly as enforced gates did before the wave: no reviewers, no wave events, no review block" {
    local id="w-h1"
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew null)"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "1" ]
    [ "$(_rw_job_json "$id" 'has("review_wave")')" = "false" ]
    [ "$(_rw_rv_lines)" = "0" ]
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started" or .kind == "review_cycle_completed"
                                or .kind == "lens_skipped" or .kind == "review_wave_completed"
                                or .kind == "claims_verified" or .kind == "reviewed"
                                or .kind == "review_rework_started")] | length == 0'
    # HC-08 as before: gates passed, a gates block, ready exactly once.
    [ "$(_rw_job_json "$id" '.gates.status')" = "passed" ]
    [ "$(_rw_ready_calls | wc -l | tr -d ' ')" = "1" ]
    local body; body=$(gh_mock_last_body "$RW_PR")
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:gates -->')" = "1" ]
    [[ "$body" != *"<!-- mother:review -->"* ]]
    [ "$(gh_mock_pr_draft "$RW_PR")" = "false" ]
}

@test "MOTHER_LENSES_ENABLED=0 turns the wave off for a job that has lenses configured" {
    local id="w-h2"
    export MOTHER_LENSES_ENABLED=0
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_run "$id"

    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_workers)" = "1" ]
    [ "$(_rw_job_json "$id" 'has("review_wave")')" = "false" ]
    [ "$(_rw_rv_lines)" = "0" ]
    _rw_ev "$id" '[.[] | select(.kind == "review_cycle_started" or .kind == "lens_skipped"
                                or .kind == "review_wave_completed" or .kind == "reviewed")] | length == 0'
    [ "$(_rw_job_json "$id" '.gates.status')" = "passed" ]
    [[ "$(gh_mock_last_body "$RW_PR")" != *"<!-- mother:review -->"* ]]
    [ "$(_rw_ready_calls | wc -l | tr -d ' ')" = "1" ]
}

# ---------------------------------------------------------------------------
# (i) mother list / status derive from .review_wave

@test "mother list --format json derives a cycles array of lens-qualified reviewers from a job's review wave" {
    make_job "w-i1" "running" '.activity = "review_wave" | .review_wave = {
        mode: "enforce", cycle: 2, cycle_cap: 2, status: "running",
        cycles: [
          {cycle: 1, reviewers: ["archie:adherence", "perri:correctness", "perri:tests"],
           pending_reviewers: [], decision: "continue"},
          {cycle: 2, reviewers: ["archie:adherence", "perri:correctness"],
           pending_reviewers: ["perri:correctness"], decision: null}]}'
    make_job "w-i2" "running" '.activity = "gating"'
    run mother list --format json
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '
        (.[] | select(.id == "w-i1") | .cycles) as $c
        | ($c | length) == 2
          and $c[0] == {cycle: 1, reviewers: ["archie:adherence", "perri:correctness", "perri:tests"],
                        pending_reviewers: [], decision: "continue"}
          and $c[1].pending_reviewers == ["perri:correctness"]' >/dev/null
    # A job without a wave gets no derived cycles.
    printf '%s' "$output" | jq -e '.[] | select(.id == "w-i2") | has("cycles") | not' >/dev/null
}

# ---------------------------------------------------------------------------
# adherence --pre-ready (also callable directly)

# _rw_pre_job <id> — a RUNNING job with a PR, its worktree on the job branch.
_rw_pre_job() {
    local id="$1"
    _rw_seed_branch "feature/rw-$id"
    git -C "$REPO" checkout -q "feature/rw-$id"
    make_job "$id" "running" \
        '.pr_url = "'"$RW_PR"'" | .work_dir = "'"$REPO"'" | .repo_path = "'"$REPO"'"
         | .branch = "feature/rw-'"$id"'" | .activity = "review_wave"
         | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null
         | .pending_answer = null
         | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}'
    make_plan "$EVENTS_DIR/$id-plan.md"
    _rw_pr "$id"
}

# _rw_pre_unchanged <id> — pre-ready never moves state, activity or pending_answer.
_rw_pre_unchanged() {
    [ "$(_rw_job_json "$1" '.state')" = "running" ]
    [ "$(_rw_job_json "$1" '.activity')" = "review_wave" ]
    [ "$(_rw_job_json "$1" '.pending_answer')" = "null" ]
}

@test "adherence-review --pre-ready records a pass on a running job without moving its state" {
    local id="w-p1"
    _rw_pre_job "$id"
    _rw_adh_reply pass "$RW_NOTES looks right"
    run mother adherence-review "$id" --pre-ready
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(_rw_job_json "$id" '.adherence_status')" = "passed" ]
    [ "$(_rw_job_json "$id" '.adherence_attempts')" = "1" ]
    [ "$(_rw_job_json "$id" '.adherence_pending')" = "false" ]
    [ "$(_rw_job_json "$id" '.adherence_reviewed_sha')" = "$(git -C "$REPO" rev-parse HEAD)" ]
    _rw_pre_unchanged "$id"
    [ "$(_rw_rv_count archie)" = "1" ]
    _rw_assert_no_text "$id" "$RW_NOTES"
}

@test "adherence-review --pre-ready: a first fail exits 1 and a second exits 3, neither moving the job out of running" {
    local id="w-p2"
    _rw_pre_job "$id"
    _rw_adh_reply fail "$RW_NOTES not what the plan asked"
    run mother adherence-review "$id" --pre-ready
    [ "$status" -eq 1 ]
    [ "$(_rw_job_json "$id" '.adherence_status')" = "failed_first" ]
    [ "$(_rw_job_json "$id" '.adherence_attempts')" = "1" ]
    [ "$(_rw_job_json "$id" '.adherence_reviewed_sha')" = "$(git -C "$REPO" rev-parse HEAD)" ]
    _rw_pre_unchanged "$id"

    run mother adherence-review "$id" --pre-ready
    [ "$status" -eq 3 ]
    [ "$(_rw_job_json "$id" '.adherence_status')" = "blocked_for_human" ]
    [ "$(_rw_job_json "$id" '.adherence_attempts')" = "2" ]
    _rw_pre_unchanged "$id"
    _rw_assert_no_text "$id" "$RW_NOTES"
}

@test "adherence-review --pre-ready: a reply with no ADHERENCE line is an error (exit 2) and records no verdict" {
    local id="w-p3"
    _rw_pre_job "$id"
    _rw_emit "I looked at it and have thoughts but no verdict." > "$MOTHER_ROOT/rv/archie.jsonl"
    run mother adherence-review "$id" --pre-ready
    [ "$status" -eq 2 ]
    [ "$(_rw_job_json "$id" '.adherence_status // "none"')" = "none" ]
    _rw_pre_unchanged "$id"
}

@test "adherence-review --pre-ready: a verdict that cannot be recorded exits 2 and claims no verdict" {
    local id="w-p4"
    _rw_pre_job "$id"
    _rw_adh_reply pass "$RW_NOTES looks right"
    # A string sha_runs on a matching head makes the verdict filter's `+ 1` error, so the write fails.
    local head merged
    head=$(git -C "$REPO" rev-parse HEAD)
    merged=$(jq --arg h "$head" '.adherence_reviewed_sha = $h | .adherence_sha_runs = "x"' "$JOBS_DIR/$id.json") \
        && printf '%s' "$merged" > "$JOBS_DIR/$id.json"

    run mother adherence-review "$id" --pre-ready
    echo "$output"
    [ "$status" -eq 2 ]
    [[ "$output" != *"(pre-ready): PASS"* ]]
    run grep -q '"kind":"adherence_reviewed"' "$EVENTS_DIR/$id.jsonl"
    [ "$status" -ne 0 ]
    [ "$(_rw_job_json "$id" '.adherence_status')" = "null" ]
    _rw_pre_unchanged "$id"
}

# ---------------------------------------------------------------------------
# (j) the runner's post-PR adherence loop and the wave

# _rw_runner_job <id> [extra-jq] — a SUCCEEDED PR job, never reviewed.
_rw_runner_job() {
    local id="$1" extra="${2:-.}"
    make_job "$id" "succeeded" \
        '.pr_url = "'"$RW_PR"'" | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null
         | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}
         | ('"$extra"')'
    make_plan "$EVENTS_DIR/$id-plan.md"
}

@test "runner: the post-PR adherence loop leaves a job alone while its review wave is running, and still reviews a plain succeeded job" {
    _rw_pr w-j1
    _rw_runner_job "w-j1" '.review_wave = {status: "running", cycle: 1}'
    _rw_runner_job "w-j2"
    run mother-runner --adherence-tick
    echo "$output"
    [ "$status" -eq 0 ]

    # The control proves the tick works ...
    [ "$(_rw_job_json w-j2 '.adherence_status')" = "passed" ]
    [ "$(_rw_rv_count archie)" = "1" ]
    # ... and the job mid-wave was neither marked pending nor reviewed.
    [ "$(_rw_job_json w-j1 '.adherence_pending // false')" != "true" ]
    [ "$(_rw_job_json w-j1 '.adherence_status // "none"')" = "none" ]
    [ "$(_rw_job_json w-j1 '.adherence_attempts')" = "0" ]
    [ "$(cat "$EVENTS_DIR/w-j1.jsonl" 2>/dev/null | grep -c 'adherence_review_spawned' || true)" = "0" ]
}

@test "runner: a head the wave's adherence review already passed is never re-reviewed after the PR is up" {
    local id="w-j3"
    _rw_pr "$id"
    _rw_job "$id" "$(_rw_crew "$RW_LENSES")"
    _rw_run "$id"
    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_rw_job_json "$id" '.adherence_status')" = "passed" ]
    local head; head=$(_rw_head "feature/rw-$id")
    [ "$(_rw_job_json "$id" '.adherence_reviewed_sha')" = "$head" ]

    # The PR's head on GitHub is the head the wave reviewed; the loop is asked to
    # (re)review the job anyway.
    local f="$MOTHER_ROOT/gh/pr/$(printf '%s' "$RW_PR" | tr -c 'a-zA-Z0-9' '_').json" tmp
    tmp=$(jq --arg h "$head" '.headRefOid = $h' "$f") && printf '%s' "$tmp" > "$f"
    tmp=$(jq '.adherence_pending = true' "$JOBS_DIR/$id.json") && printf '%s' "$tmp" > "$JOBS_DIR/$id.json"
    local before_archie before_spawned
    before_archie=$(_rw_rv_count archie)
    before_spawned=$(grep -c 'adherence_review_spawned' "$EVENTS_DIR/$id.jsonl" || true)

    run mother-runner --adherence-tick
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(_rw_rv_count archie)" = "$before_archie" ]
    [ "$(grep -c 'adherence_review_spawned' "$EVENTS_DIR/$id.jsonl" || true)" = "$before_spawned" ]
    [ "$(_rw_job_json "$id" '.adherence_status')" = "passed" ]
    [ "$(_rw_job_json "$id" '.state')" = "succeeded" ]
}
