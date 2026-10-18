#!/usr/bin/env bats
# gates_enforce.bats — enforce-mode quality gates inside the job lifecycle (HC-08).
#
# A job whose `.crew.gates.mode` is "enforce" does not just record its gate
# results (HC-06 observe mode): `mother-run-job` makes the gates GATE the PR.
# After the worker exits successfully and the PR url is settled:
#
#   gates red, attempts left   -> resume the worker's own claude session with the
#                                 red gates' excerpts + hints (activity gate_fix,
#                                 run_kind "gate_fix" usage row), then re-run the
#                                 gates as attempt n+1. A resume that fails
#                                 immediately is retried once with a fresh session.
#   gates red, attempts spent  -> HOLD: state awaiting, activity/paused_reason
#                                 gate_hold, a structured `.decision` with four
#                                 options. Never succeeded, never failed.
#   gates passed / incomplete  -> write the `<!-- mother:gates -->` block into the
#                                 PR body, mark the PR ready, job succeeds.
#   draft discipline           -> an enforce job's PR is kept a draft while any
#                                 blocking gate is red; `gh pr ready` (no --undo)
#                                 is never called while one is.
#
# Operator answers on a gate_hold: `mother resume <id> --option override_open |
# escalate | cancel`, or plain guidance text (resumes the same claude session).
#
# Observable contract asserted here (job JSON, events, runs.jsonl, `mother
# status|list` text, the gh call log + PR fixture, claude's argv/stdin, and
# scripts/contract-check.sh) — not how mother-run-job is wired internally.
#
# Harness (same shape as gates_lifecycle.bats): a temp repo with a BARE origin;
# main-dir jobs on a pre-seeded branch; real `mother-run-job` subprocesses; gh is
# gh_mock (stateful PR fixture); `claude` is a scriptable stand-in that counts
# its invocations and records each one's argv and stdin:
#
#   $MOTHER_ROOT/ge-count         number of claude invocations so far
#   $MOTHER_ROOT/argv.<n>         invocation n's argv, one arg per line
#   $MOTHER_ROOT/stdin.<n>        invocation n's stdin (the prompt)
#   $MOTHER_ROOT/ge-behave.<n>    optional script sourced by invocation n (see
#                                 _ge_behave); by default an invocation pushes
#                                 the branch, prints a result event, exits 0.
#
# The worker env has MOTHER_LIVE_ROOT, not MOTHER_ROOT (CLAUDE.md "State safety"),
# so the stand-in resolves its root from MOTHER_LIVE_ROOT.

bats_require_minimum_version 1.5.0
load 'test_helper'
load 'gh_mock'

GE_PR="https://github.com/Carefeed/test/pull/42"
GE_FIXTURES="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd -P)/fixtures/usage"

# The marker is printed by a failing gate. It is assembled at run time so the
# literal string never appears in the check's `run` text (which legitimately
# lives in the job's .crew snapshot) — only real gate OUTPUT can contain it.
GE_MARKER="GATE_MARKER_c0ffee"
GE_FAIL_CMD="printf 'GATE_%s_%s\\n' MARKER c0ffee; exit 1"
# Red until the worker creates .gate-fixed (the "fix" a gate_fix run makes).
GE_FIXME_RUN="[ -f .gate-fixed ] || { printf 'GATE_%s_%s\\n' MARKER c0ffee; exit 1; }"
GE_HINT="HINT_apply_the_fixer"

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID GE_MAX GH_MOCK_FAIL_DRAFT
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120
    GL_BG_PID=""

    gh_mock_install
    _ge_install_claude

    ORIGIN="$MOTHER_ROOT/origin.git"
    REPO="$MOTHER_ROOT/work/gaterepo"
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
    # Release a fix run blocked on $MOTHER_ROOT/release, and reap any supervisor
    # a failed assertion left behind (only the pid this test started).
    touch "$MOTHER_ROOT/release" 2>/dev/null || true
    if [ -n "${GL_BG_PID:-}" ]; then
        kill "$GL_BG_PID" 2>/dev/null || true
    fi
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Harness helpers

# The scriptable worker. Invocation 1 also prints the PR url (live/final capture
# finds it, gh_mock vouches for it) unless $MOTHER_ROOT/ge-no-pr-url exists.
_ge_install_claude() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
ROOT="${MOTHER_LIVE_ROOT:-${MOTHER_ROOT:-}}"
n=$(( $(cat "$ROOT/ge-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/ge-count"
printf '%s\n' "$@" > "$ROOT/argv.$n"
cat > "$ROOT/stdin.$n"
PUSH=1; EXIT=0; SLEEP=0; POST=""; OUT_FILE="default"
BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -f "$ROOT/ge-behave.$n" ]; then . "$ROOT/ge-behave.$n"; fi
if [ "$PUSH" = "1" ]; then
    git push -q origin "HEAD:refs/heads/$BR" >/dev/null 2>&1 || true
fi
if [ "$n" = "1" ] && [ ! -f "$ROOT/ge-no-pr-url" ]; then
    echo "opened https://github.com/Carefeed/test/pull/42"
fi
if [ "$OUT_FILE" = "default" ]; then
    cat <<'EOF'
{"type":"assistant","message":{"id":"msg_ge","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
elif [ -n "$OUT_FILE" ]; then
    cat "$OUT_FILE"
fi
[ "$SLEEP" = "0" ] || sleep "$SLEEP"
[ -z "$POST" ] || eval "$POST"
exit "$EXIT"
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

# _ge_behave <n> <shell-snippet> — script claude invocation <n>. The snippet is
# sourced inside the stand-in (cwd = the job's work dir) and may set PUSH (1),
# EXIT (0), SLEEP (0), POST (a command run after the sleep) and OUT_FILE
# ("default" = result event; "" = print nothing; else a file to cat).
_ge_behave() { printf '%s\n' "$2" > "$MOTHER_ROOT/ge-behave.$1"; }

# The worker's "fix": create .gate-fixed, commit (the stand-in pushes after).
GE_FIX_SNIPPET='touch .gate-fixed; git add .gate-fixed; git commit -q -m "fix the gates"'

# _ge_check <name> <run> [extra-jq-object] — one resolved check with defaults.
_ge_check() {
    jq -nc --arg name "$1" --arg run "$2" --argjson extra "${3:-{\}}" '
        {name: $name, run: $run, when: null, blocking: true, where: "any",
         timeout_s: 60, hint: null} + $extra'
}

# _ge_crew <check-json>... — the resolved `.crew` snapshot, enforce mode.
# GE_MAX (default 3) is gates.max_attempts.
_ge_crew() {
    local checks
    checks=$(printf '%s\n' "$@" | jq -sc '.')
    jq -nc --argjson checks "$checks" --argjson max "${GE_MAX:-3}" '{
        version: 1, source_ref: "origin/main", source_sha: "abc", phi_sensitive: false,
        gates: {mode: "enforce", max_attempts: $max, budget_minutes: 15, checks: $checks},
        lenses: null}'
}

# _ge_seed_branch <branch> — local-only branch, one commit ahead of origin/main.
_ge_seed_branch() {
    (
        cd "$REPO"
        git checkout -q -B "$1" origin/main
        mkdir -p app
        echo '<?php' > app/Foo.php
        git add app/Foo.php
        git commit -q -m "feature work for $1"
        git checkout -q main
    ) >/dev/null 2>&1
}

# _ge_job <id> [extra-jq] — a ready main-dir job on its own seeded branch.
_ge_job() {
    local id="$1" extra="${2:-.}"
    _ge_seed_branch "feature/gl-$id"
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo = "gaterepo"
         | .repo_path = "'"$REPO"'"
         | .base_ref = "origin/main"
         | .branch = "feature/gl-'"$id"'"
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }
         | ('"$extra"')'
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"
}

# _ge_pr <id> — the open (non-draft) PR the worker "opens" for job <id>.
_ge_pr() { gh_mock_set_pr "$GE_PR" OPEN "feature/gl-$1"; }

# _ge_run <id> — one real supervisor run to completion. The exit status is not
# part of the contract; the job's state is. Output is echoed for failure triage.
_ge_run() {
    run mother-run-job "$1"
    echo "$output"
}

# _ge_bg_run <id> — a supervisor run in the background (GL_BG_PID).
_ge_bg_run() {
    mother-run-job "$1" >"$MOTHER_ROOT/run-job.out" 2>&1 3>&- &
    GL_BG_PID=$!
}

# _ge_wait_activity <id> <activity> — poll (<= 30s) until the job shows it;
# fails early when the background supervisor has already exited.
_ge_wait_activity() {
    local id="$1" want="$2" i act=""
    for i in $(seq 1 150); do
        act=$(jq -r '.activity // ""' "$JOBS_DIR/$id.json" 2>/dev/null)
        [ "$act" = "$want" ] && return 0
        kill -0 "$GL_BG_PID" 2>/dev/null || return 1
        sleep 0.2
    done
    return 1
}

# _ge_assert_not <cmd...> — fails the test when the command succeeds. (A bare
# `! cmd` never trips bats' errexit, so it can't be used for negative asserts.)
_ge_assert_not() {
    if "$@"; then
        echo "unexpectedly succeeded: $*" >&2
        return 1
    fi
}

_ge_job_json() { jq -r "$2" "$JOBS_DIR/$1.json"; }
_ge_head() { git -C "$REPO" rev-parse "refs/heads/$1"; }
_ge_origin_head() { git -C "$ORIGIN" rev-parse "refs/heads/$1"; }
_ge_claude_count() { cat "$MOTHER_ROOT/ge-count" 2>/dev/null || echo 0; }

# _ge_result <id> <name> <field> — a field of one entry of .gates.results.
_ge_result() {
    jq -r --arg n "$2" '.gates.results[] | select(.name == $n) | .'"$3" "$JOBS_DIR/$1.json"
}

# _ge_ev <id> <jq-expr> — succeeds when the expression is truthy over the
# slurped event array (each event {ts, kind, detail}).
_ge_ev() { jq -s -e "$2" "$EVENTS_DIR/$1.jsonl" >/dev/null; }

# _ge_argv_flag <n> <flag> — the value following <flag> in invocation n's argv.
_ge_argv_flag() {
    awk -v f="$2" '$0 == f {getline; print; exit}' "$MOTHER_ROOT/argv.$1" 2>/dev/null
}
_ge_argv_has() { grep -qxF -- "$2" "$MOTHER_ROOT/argv.$1" 2>/dev/null; }

# gh call-log views.
_ge_undo_calls()  { gh_mock_calls | grep -n -E "^pr ready ${GE_PR} --undo" | cut -d: -f1; }
_ge_ready_calls() { gh_mock_calls | grep -n -E "^pr ready ${GE_PR}( |\$)" | grep -v -- '--undo' | cut -d: -f1; }
_ge_edit_calls()  { gh_mock_calls | grep -n -E "^pr edit ${GE_PR} .*--body-file" | cut -d: -f1; }

# _ge_block — the mother:gates block of a PR body on stdin (markers included).
_ge_block() {
    awk '/<!-- mother:gates -->/ {f = 1} f {print} /<!-- \/mother:gates -->/ {f = 0}'
}

# _ge_assert_no_output_text <id> — gate output text never reaches job JSON
# (.gates, .question, .decision, ...) or the event log.
_ge_assert_no_output_text() {
    run grep -c "$GE_MARKER" "$JOBS_DIR/$1.json"
    [ "$output" = "0" ]
    run grep -c "$GE_MARKER" "$EVENTS_DIR/$1.jsonl"
    [ "$output" = "0" ]
}

# _ge_hold <id> [extra-jq] — a PR job whose one blocking gate (`fixme`, with a
# hint) is red until the worker creates .gate-fixed — which, by default, it
# never does; max_attempts 2. Runs to the gate hold and checks it got there.
_ge_hold() {
    local id="$1" extra="${2:-.}"
    GE_MAX=2
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check fixme "$GE_FIXME_RUN" "{\"hint\":\"$GE_HINT\"}")") | $extra"
    case "$extra" in
        *no_pr*) touch "$MOTHER_ROOT/ge-no-pr-url" ;;
        *) _ge_pr "$id" ;;
    esac
    _ge_run "$id"
    [ "$(_ge_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_ge_job_json "$id" '.activity')" = "gate_hold" ]
}

# _ge_envelopes <id> — the job's events as broker envelopes.
_ge_envelopes() {
    jq -c -s --arg job "$1" '
        to_entries[]
        | {v: 1, dir: "event", t: .value.kind, id: ((.key + 1) | tostring), ts: .value.ts,
           data: (.value.detail + {job: $job, category: "activity"})}' \
        "$EVENTS_DIR/$1.jsonl"
}

# _ge_contract <id> — the whole event log passes scripts/contract-check.sh.
_ge_contract() {
    _ge_envelopes "$1" > "$MOTHER_ROOT/all.ndjson"
    [ -s "$MOTHER_ROOT/all.ndjson" ]
    run "$_PLUGIN_DIR/scripts/contract-check.sh" "$MOTHER_ROOT/all.ndjson"
    echo "$output"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# (a) fail -> fix -> pass

@test "enforce: a red gate is fixed by resuming the worker's own session, then the PR is opened ready with a gates block" {
    local id="g-a1"
    GE_MAX=3
    _ge_pr "$id"
    gh_mock_set_pr_body "$GE_PR" "ORIGINAL_BODY_TEXT"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check fixme "$GE_FIXME_RUN" "{\"hint\":\"$GE_HINT\"}")")"
    # Invocation 2 is the fix run: it blocks until released, so the live state
    # can be observed deterministically, then makes the fix.
    _ge_behave 2 'while [ ! -f "$ROOT/release" ]; do sleep 0.2; done
'"$GE_FIX_SNIPPET"

    _ge_bg_run "$id"
    _ge_wait_activity "$id" gate_fix
    [ "$(_ge_job_json "$id" '.state')" = "running" ]
    [ "$(_ge_job_json "$id" '.activity')" = "gate_fix" ]
    run mother list
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | grep -F "$id")" == *"[GATES-FIXING]"* ]]
    run mother list --format json
    [ "$(printf '%s' "$output" | jq -r --arg id "$id" '.[] | select(.id == $id) | .activity')" = "gate_fix" ]
    # The PR is still a draft while the gate is red.
    [ "$(gh_mock_pr_draft "$GE_PR")" = "true" ]

    touch "$MOTHER_ROOT/release"
    wait "$GL_BG_PID" || true
    GL_BG_PID=""

    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_ge_job_json "$id" '.pr_url')" = "$GE_PR" ]
    [ "$(_ge_claude_count)" = "2" ]

    # The fix run re-enters the SAME session the first spawn created.
    local sid; sid=$(_ge_argv_flag 1 --session-id)
    [ -n "$sid" ]
    [ "$(_ge_argv_flag 2 --resume)" = "$sid" ]
    _ge_assert_not _ge_argv_has 2 --session-id
    [ "$(_ge_job_json "$id" '.session_id')" = "$sid" ]

    # Its prompt names the red gate, shows its excerpt and hint, and the attempt.
    grep -qF "fixme" "$MOTHER_ROOT/stdin.2"
    grep -qF "$GE_MARKER" "$MOTHER_ROOT/stdin.2"
    grep -qF "$GE_HINT" "$MOTHER_ROOT/stdin.2"
    grep -qF "attempt 1/3" "$MOTHER_ROOT/stdin.2"

    # Gates: attempt 2 passed; the tier ladder was not touched.
    [ "$(_ge_job_json "$id" '.gates.status')" = "passed" ]
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "2" ]
    [ "$(_ge_job_json "$id" '.gates.max_attempts')" = "3" ]
    [ "$(_ge_job_json "$id" '.gates.mode')" = "enforce" ]
    [ "$(_ge_job_json "$id" '.gates.effective_mode')" = "enforce" ]
    [ "$(_ge_result "$id" fixme result)" = "passed" ]
    [ -f "$MOTHER_ROOT/crew/$id/gates/1/fixme.log" ]
    [ -f "$MOTHER_ROOT/crew/$id/gates/2/fixme.log" ]
    grep -q "$GE_MARKER" "$MOTHER_ROOT/crew/$id/gates/1/fixme.excerpt"
    [ "$(_ge_job_json "$id" '.current_tier')" = "tier_0" ]
    [ "$(_ge_job_json "$id" '.escalation_count')" = "0" ]
    [ "$(_ge_job_json "$id" '.retry_count')" = "0" ]
    [ "$(_ge_job_json "$id" '.activity // "none"')" != "gate_fix" ]

    # The fix run's usage is its own runs.jsonl row.
    jq -s -e --arg id "$id" '[.[] | select(.job_id == $id and .run_kind == "gate_fix")] | length == 1' \
        "$MOTHER_ROOT/metrics/runs.jsonl" >/dev/null

    # Events: one gate_fix_started (resume), in order, before the success.
    jq -s -e --arg sid "$sid" '
        [.[] | select(.kind == "gate_fix_started") | .detail] as $f
        | ($f | length) == 1
          and $f[0].attempt == 1 and $f[0].mode == "resume" and $f[0].red == ["fixme"]
          and $f[0].session_id == $sid' "$EVENTS_DIR/$id.jsonl" >/dev/null
    _ge_ev "$id" '
        to_entries as $e
        | ([$e[] | select(.value.kind == "gates_completed" and .value.detail.attempt == 1
                          and .value.detail.status == "failed") | .key] | first) as $c1
        | ([$e[] | select(.value.kind == "gate_fix_started") | .key] | first) as $fx
        | ([$e[] | select(.value.kind == "gates_started" and .value.detail.attempt == 2) | .key] | first) as $s2
        | ([$e[] | select(.value.kind == "gates_completed" and .value.detail.attempt == 2
                          and .value.detail.status == "passed") | .key] | first) as $c2
        | ([$e[] | select(.value.kind == "pr_marked_ready") | .key] | first) as $rd
        | ([$e[] | select(.value.kind == "succeeded") | .key] | first) as $ok
        | [$c1, $fx, $s2, $c2, $rd, $ok] | all(. != null) and . == sort'
    _ge_ev "$id" '[.[] | select(.kind == "pr_marked_ready") | .detail.reason] == ["gates_passed"]'
    _ge_ev "$id" '[.[] | select(.kind == "pr_marked_draft") | .detail.reason] | length >= 1 and all(. == "gates_pending")'

    # The PR: undone to draft first, marked ready only after the gates passed;
    # its body carries exactly one gates block and keeps the author's text.
    [ "$(gh_mock_pr_draft "$GE_PR")" = "false" ]
    local undo ready
    undo=$(_ge_undo_calls | head -1)
    ready=$(_ge_ready_calls | head -1)
    [ -n "$undo" ] && [ -n "$ready" ] && [ "$undo" -lt "$ready" ]
    [ -n "$(_ge_edit_calls)" ]
    local view_body; view_body=$(gh_mock_calls | grep -n -E "^pr view ${GE_PR} .*body" | head -1 | cut -d: -f1)
    [ -n "$view_body" ] && [ "$view_body" -lt "$(_ge_edit_calls | head -1)" ]
    local body; body=$(gh_mock_last_body "$GE_PR")
    [[ "$body" == *"ORIGINAL_BODY_TEXT"* ]]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:gates -->')" = "1" ]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- /mother:gates -->')" = "1" ]
    local block; block=$(printf '%s\n' "$body" | _ge_block)
    [[ "$block" == *"fixme"* ]]
    [[ "$block" == *"passed"* ]]
    [[ "$block" != *"Gates incomplete"* ]]
    [[ "$body" != *"$GE_MARKER"* ]]

    # Contract: the whole event log passes the client contract check.
    _ge_contract "$id"
}

@test "enforce: a gates block already in the PR body is replaced, not duplicated, and text around it survives" {
    local id="g-a3"
    _ge_pr "$id"
    gh_mock_set_pr_body "$GE_PR" "$(printf 'LEADING_TEXT\n\n<!-- mother:gates -->\nSTALE_BLOCK_CONTENT\n<!-- /mother:gates -->\n\nTRAILING_TEXT')"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check fine 'true')")"
    _ge_run "$id"
    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_ge_claude_count)" = "1" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "passed" ]
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "1" ]
    local body; body=$(gh_mock_last_body "$GE_PR")
    [[ "$body" == *"LEADING_TEXT"* ]]
    [[ "$body" == *"TRAILING_TEXT"* ]]
    [[ "$body" != *"STALE_BLOCK_CONTENT"* ]]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- mother:gates -->')" = "1" ]
    [ "$(printf '%s\n' "$body" | grep -c '<!-- /mother:gates -->')" = "1" ]
    [[ "$(printf '%s\n' "$body" | _ge_block)" == *"fine"* ]]
    [ "$(gh_mock_pr_draft "$GE_PR")" = "false" ]
    _ge_ev "$id" '[.[] | select(.kind == "pr_marked_ready") | .detail.reason] == ["gates_passed"]'
    # Nothing was red: no fix run, no hold, no incomplete flag.
    _ge_ev "$id" '[.[] | select(.kind == "gate_fix_started")] | length == 0'
    [ "$(_ge_job_json "$id" '(.attention // []) | map(.reason) | length')" = "0" ]
}

@test "enforce: when the resume fails immediately the fix is retried once in a fresh session carrying the same findings" {
    local id="g-a2"
    GE_MAX=3
    _ge_pr "$id"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check fixme "$GE_FIXME_RUN" "{\"hint\":\"$GE_HINT\"}")")"
    # Invocation 2 (the --resume): dies at once, no result event.
    _ge_behave 2 'PUSH=0; EXIT=1; OUT_FILE=""'
    # Invocation 3 (the fresh fallback): makes the fix.
    _ge_behave 3 "$GE_FIX_SNIPPET"
    _ge_run "$id"

    [ "$(_ge_claude_count)" = "3" ]
    _ge_argv_has 2 --resume
    _ge_argv_has 3 --session-id
    _ge_assert_not _ge_argv_has 3 --resume
    # The fresh session gets a new id and the gate findings in its prompt.
    [ -n "$(_ge_argv_flag 3 --session-id)" ]
    [ "$(_ge_argv_flag 3 --session-id)" != "$(_ge_argv_flag 1 --session-id)" ]
    grep -qF "fixme" "$MOTHER_ROOT/stdin.3"
    grep -qF "$GE_MARKER" "$MOTHER_ROOT/stdin.3"
    grep -qF "$GE_HINT" "$MOTHER_ROOT/stdin.3"

    jq -s -e '
        [.[] | select(.kind == "gate_fix_started") | .detail] as $f
        | ($f | length) == 2
          and $f[0].mode == "resume" and $f[0].attempt == 1
          and $f[1].mode == "fresh_fallback" and $f[1].attempt == 1
          and $f[1].red == ["fixme"]' "$EVENTS_DIR/$id.jsonl" >/dev/null

    # The fallback is part of the same attempt: the gates then re-run as attempt 2.
    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "passed" ]
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "2" ]
    [ "$(_ge_job_json "$id" '.current_tier')" = "tier_0" ]
}

# ---------------------------------------------------------------------------
# (b) exhausted -> gate hold

@test "enforce: gates still red after the last attempt hold the job for the operator (awaiting/gate_hold), never succeeded or failed" {
    local id="g-b1"
    _ge_hold "$id"

    [ "$(_ge_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_ge_job_json "$id" '.activity')" = "gate_hold" ]
    [ "$(_ge_job_json "$id" '.paused_reason')" = "gate_hold" ]
    # Initial run + exactly one fix run (max_attempts 2).
    [ "$(_ge_claude_count)" = "2" ]
    _ge_argv_has 2 --resume
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "2" ]
    [ "$(_ge_job_json "$id" '.gates.max_attempts')" = "2" ]
    [ "$(_ge_job_json "$id" '.gates.effective_mode')" = "enforce" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "failed" ]
    # Escalation machinery untouched.
    [ "$(_ge_job_json "$id" '.escalation_count')" = "0" ]
    [ "$(_ge_job_json "$id" '.current_tier')" = "tier_0" ]
    [ "$(_ge_job_json "$id" '.retry_count')" = "0" ]
    _ge_ev "$id" '[.[] | select(.kind == "succeeded" or .kind == "failed" or .kind == "cancelled")] | length == 0'

    # The PR is left a draft and was never marked ready.
    [ "$(gh_mock_pr_draft "$GE_PR")" = "true" ]
    [ -z "$(_ge_ready_calls)" ]
    _ge_ev "$id" '[.[] | select(.kind == "pr_marked_ready")] | length == 0'

    # A structured decision with exactly the four options, plus the attention flag.
    [ "$(_ge_job_json "$id" '.decision.kind')" = "gate_hold" ]
    [ "$(jq -c '[.decision.options[].id]' "$JOBS_DIR/$id.json")" \
        = '["resume_with_guidance","escalate","override_open","cancel"]' ]
    [ "$(_ge_job_json "$id" '.decision.resolved_at')" = "null" ]
    [ "$(_ge_job_json "$id" '[(.attention // [])[] | .reason] | index("decision_awaiting") != null')" = "true" ]

    # Events.
    _ge_ev "$id" '
        [.[] | select(.kind == "gates_exhausted") | .detail] as $x
        | ($x | length) == 1 and $x[0].attempts == 2 and $x[0].red == ["fixme"]'
    _ge_ev "$id" '[.[] | select(.kind == "decision_opened") | .detail] | length == 1 and .[0].kind == "gate_hold"'
    _ge_ev "$id" '[.[] | select(.kind == "awaiting_input") | .detail] | last | .paused_reason == "gate_hold" and (.question | length > 0)'
    _ge_ev "$id" '[.[] | select(.kind == "gates_started") | .detail.attempt] == [1, 2]'
    _ge_ev "$id" '[.[] | select(.kind == "gates_completed") | .detail.attempt] == [1, 2]'
    _ge_ev "$id" '[.[] | select(.kind == "gate_result" and .detail.name == "fixme") | .detail.attempt] == [1, 2]'
    [ -f "$MOTHER_ROOT/crew/$id/gates/1/fixme.excerpt" ]
    [ -f "$MOTHER_ROOT/crew/$id/gates/2/fixme.excerpt" ]

    # The question names what the operator needs and carries no gate output.
    local q; q=$(_ge_job_json "$id" '.question')
    [[ "$q" == *"fixme"* ]]
    [[ "$q" == *"2"* ]]
    [[ "$q" == *"feature/gl-$id"* ]]
    [[ "$q" == *"$(_ge_head feature/gl-$id | cut -c1-7)"* ]]
    [[ "$q" == *"mother status $id"* ]]
    [[ "$q" == *"mother resume $id"* ]]
    [[ "$q" == *"--option escalate"* ]]
    [[ "$q" == *"--option override_open"* ]]
    [[ "$q" == *"mother cancel $id"* || "$q" == *"--option cancel"* ]]
    [[ "$q" != *"$GE_MARKER"* ]]
    _ge_assert_no_output_text "$id"

    # mother status: the hold, the red gate and its excerpt (read from the side
    # file), the branch, and the four commands.
    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[GATES-HELD]"* ]]
    [[ "$output" == *"fixme"* ]]
    [[ "$output" == *"$GE_MARKER"* ]]
    [[ "$output" == *"feature/gl-$id"* ]]
    [[ "$output" == *"mother resume $id"* ]]
    [[ "$output" == *"--option escalate"* ]]
    [[ "$output" == *"--option override_open"* ]]
    [[ "$output" == *"mother cancel $id"* || "$output" == *"--option cancel"* ]]
    # ... and the JSON form of status stays free of output text.
    run mother status "$id" --format json
    [ "$status" -eq 0 ]
    [[ "$output" != *"$GE_MARKER"* ]]

    run mother list
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | grep -F "$id")" == *"[GATES-HELD]"* ]]

    _ge_contract "$id"
}

@test "enforce: exhaustion pushes an unpushed head (non-force) so the held branch is what the operator reviews" {
    local id="g-b2"
    # The fix run commits but does not push.
    _ge_behave 2 'PUSH=0; echo extra > fix.txt; git add fix.txt; git commit -q -m "unpushed fix"'
    _ge_hold "$id"
    local local_tip; local_tip=$(_ge_head "feature/gl-$id")
    # The branch on origin caught up to the local tip.
    [ "$(_ge_origin_head "feature/gl-$id")" = "$local_tip" ]
    [[ "$(_ge_job_json "$id" '.question')" == *"$(printf '%s' "$local_tip" | cut -c1-7)"* ]]
    [[ "$(_ge_job_json "$id" '.question')" != *"not pushed"* ]]
}

# ---------------------------------------------------------------------------
# (c) override_open

@test "enforce: --option override_open opens the PR with the red gates recorded, and the job succeeds" {
    local id="g-c1"
    _ge_hold "$id"
    [ -z "$(_ge_ready_calls)" ]

    run mother resume "$id" --option override_open
    echo "$output"
    [ "$status" -eq 0 ]

    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "overridden" ]
    jq -e '.gates.override | (.at | type == "string" and length > 0) and .source == "cli" and .red == ["fixme"]' \
        "$JOBS_DIR/$id.json" >/dev/null
    _ge_ev "$id" '[.[] | select(.kind == "gates_overridden") | .detail] | length == 1 and .[0].red == ["fixme"] and .[0].source == "cli"'

    # The PR body records the override; the PR is marked ready.
    local body; body=$(gh_mock_last_body "$GE_PR")
    [[ "$body" == *"Opened with red gates (operator override): fixme"* ]]
    [ -n "$(_ge_ready_calls)" ]
    [ "$(gh_mock_pr_draft "$GE_PR")" = "false" ]
    _ge_ev "$id" '[.[] | select(.kind == "pr_marked_ready") | .detail.reason] == ["override"]'

    # The decision is resolved and no longer demands attention.
    [ "$(_ge_job_json "$id" '.decision.resolved_at != null')" = "true" ]
    [ "$(_ge_job_json "$id" '.decision.resolution.option')" = "override_open" ]
    [ "$(_ge_job_json "$id" '[(.attention // [])[] | .reason] | index("decision_awaiting")')" = "null" ]
    _ge_ev "$id" '[.[] | select(.kind == "decision_resolved") | .detail.option] == ["override_open"]'

    # The operator sees the override when they look at the job.
    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *[Oo]verrid* ]]
    [[ "$output" != *"[GATES-HELD]"* ]]
    run mother list
    [[ "$(printf '%s\n' "$output" | grep -F "$id")" != *"[GATES-HELD]"* ]]

    _ge_contract "$id"
}

# ---------------------------------------------------------------------------
# (d) escalate, resume_with_guidance, cancel

@test "enforce: --option escalate re-queues the job one tier higher with the gate summary as the next instruction" {
    local id="g-d1"
    _ge_hold "$id"

    run mother resume "$id" --option escalate
    echo "$output"
    [ "$status" -eq 0 ]

    [ "$(_ge_job_json "$id" '.state')" = "ready" ]
    [ "$(_ge_job_json "$id" '.current_tier')" = "tier_1" ]
    [ "$(_ge_job_json "$id" '.escalation_count')" = "1" ]
    [ -n "$(_ge_job_json "$id" '.pending_answer // ""')" ]
    [[ "$(_ge_job_json "$id" '.pending_answer')" == *"fixme"* ]]
    # A fresh gate budget for the stronger attempt.
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "0" ]
    [ "$(_ge_job_json "$id" '.decision.resolved_at != null')" = "true" ]
    [ "$(_ge_job_json "$id" '.decision.resolution.option')" = "escalate" ]
    [ "$(_ge_job_json "$id" '[(.attention // [])[] | .reason] | index("decision_awaiting")')" = "null" ]
    [ "$(_ge_job_json "$id" '.activity // "none"')" != "gate_hold" ]
    _ge_ev "$id" '[.[] | select(.kind == "decision_resolved") | .detail.option] == ["escalate"]'
    # Not terminal, and the PR was not opened.
    [ -z "$(_ge_ready_calls)" ]
}

@test "enforce: escalate is capped at tier_3" {
    local id="g-d3"
    _ge_hold "$id" '.current_tier = "tier_3"'
    run mother resume "$id" --option escalate
    echo "$output"
    [ "$(_ge_job_json "$id" '.current_tier')" = "tier_3" ]
}

@test "enforce: plain guidance on a gate hold resumes the same claude session, and the gate budget starts over" {
    local id="g-d2"
    _ge_hold "$id"
    local sid; sid=$(_ge_argv_flag 1 --session-id)
    [ -n "$sid" ]

    run mother resume "$id" "GUIDANCE_use_the_fixer_script"
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(_ge_job_json "$id" '.state')" = "ready" ]
    [ "$(_ge_job_json "$id" '.resume_session_id')" = "$sid" ]
    [ "$(_ge_job_json "$id" '.resume_session_id')" = "$(_ge_job_json "$id" '.session_id')" ]
    [ "$(_ge_job_json "$id" '.decision.resolution.option')" = "resume_with_guidance" ]

    # The next run (this time the worker makes the fix) re-enters that session
    # with the guidance as its prompt, and gates again from attempt 1.
    _ge_behave 3 "$GE_FIX_SNIPPET"
    _ge_run "$id"
    [ "$(_ge_claude_count)" = "3" ]
    [ "$(_ge_argv_flag 3 --resume)" = "$sid" ]
    _ge_assert_not _ge_argv_has 3 --session-id
    grep -qF "GUIDANCE_use_the_fixer_script" "$MOTHER_ROOT/stdin.3"
    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "passed" ]
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "1" ]
    [ "$(_ge_job_json "$id" '.gates.budget_reset_by')" = "resume" ]
    [ "$(_ge_job_json "$id" '.escalation_count')" = "0" ]
    [ -n "$(_ge_ready_calls)" ]
}

@test "enforce: --option cancel on a gate hold cancels the job" {
    local id="g-d4"
    _ge_hold "$id"
    run mother resume "$id" --option cancel
    echo "$output"
    [ "$status" -eq 0 ]
    [ "$(_ge_job_json "$id" '.state')" = "cancelled" ]
    [ "$(_ge_job_json "$id" '.decision.resolution.option')" = "cancel" ]
    [ -z "$(_ge_ready_calls)" ]
}

# ---------------------------------------------------------------------------
# (e) incomplete gates: presented, flagged

@test "enforce: an unavailable gate (incomplete) still presents the PR, flagged as incomplete, and the job succeeds" {
    local id="g-e1"
    _ge_pr "$id"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check ok 'true')" "$(_ge_check sbx 'true' '{"where":"sandbox"}')")"
    _ge_run "$id"

    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "incomplete" ]
    [ "$(_ge_job_json "$id" '.gates.effective_mode')" = "enforce" ]
    [ "$(_ge_result "$id" sbx result)" = "unavailable" ]
    # Nothing was red, so nothing to fix: one run, one gate pass.
    [ "$(_ge_claude_count)" = "1" ]
    _ge_ev "$id" '[.[] | select(.kind == "gates_started")] | length == 1'

    [ -n "$(_ge_ready_calls)" ]
    [ "$(gh_mock_pr_draft "$GE_PR")" = "false" ]
    _ge_ev "$id" '[.[] | select(.kind == "pr_marked_ready") | .detail.reason] == ["gates_incomplete"]'

    local body; body=$(gh_mock_last_body "$GE_PR")
    local block; block=$(printf '%s\n' "$body" | _ge_block)
    [[ "$block" == *"**Gates incomplete: sbx did not run**"* ]]
    [[ "$block" == *"ok"* ]]
    # The incomplete notice leads the block, ahead of the per-gate listing.
    local notice_line ok_line
    notice_line=$(printf '%s\n' "$block" | grep -n 'Gates incomplete' | head -1 | cut -d: -f1)
    ok_line=$(printf '%s\n' "$block" | grep -n -w 'ok' | head -1 | cut -d: -f1)
    [ "$notice_line" -lt "$ok_line" ]

    [ "$(_ge_job_json "$id" '[(.attention // [])[] | select(.reason == "gates_incomplete") | .since | type] | . == ["string"]')" = "true" ]

    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[GATES-INCOMPLETE]"* ]]
}

# ---------------------------------------------------------------------------
# (f) conservative posture

@test "enforce under conservative posture: one attempt, advisory checks skipped, a red blocking gate holds without a fix run" {
    local id="g-f1"
    cat > "$_MOCK_BIN/bishop" <<'BISHOP'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ] && [ "${2:-}" = "posture" ]; then
    echo "conservative"
fi
exit 0
BISHOP
    chmod +x "$_MOCK_BIN/bishop"
    export MOTHER_POSTURE_ENABLED=1
    GE_MAX=4
    _ge_pr "$id"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check fixme "$GE_FAIL_CMD")" "$(_ge_check style 'true' '{"blocking":false}')")"
    _ge_run "$id"

    [ "$(_ge_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_ge_job_json "$id" '.activity')" = "gate_hold" ]
    [ "$(_ge_job_json "$id" '.gates.max_attempts')" = "1" ]
    [ "$(_ge_job_json "$id" '.gates.posture')" = "conservative" ]
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "1" ]
    [ "$(_ge_result "$id" style result)" = "skipped" ]
    [ "$(_ge_result "$id" style skip_reason)" = "posture" ]
    [ "$(_ge_result "$id" fixme result)" = "failed" ]
    # No fix spawn: the worker ran exactly once.
    [ "$(_ge_claude_count)" = "1" ]
    _ge_ev "$id" '[.[] | select(.kind == "gate_fix_started")] | length == 0'
    _ge_ev "$id" '[.[] | select(.kind == "gates_exhausted") | .detail.attempts] == [1]'
}

# ---------------------------------------------------------------------------
# (g) no_pr jobs

@test "enforce: a no_pr job that exhausts its attempts holds identically and never talks to gh about a PR" {
    local id="g-g1"
    _ge_hold "$id" '.no_pr = true'
    [ "$(_ge_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_ge_job_json "$id" '.paused_reason')" = "gate_hold" ]
    [ "$(_ge_job_json "$id" '.decision.kind')" = "gate_hold" ]
    [ "$(jq -c '[.decision.options[].id]' "$JOBS_DIR/$id.json")" \
        = '["resume_with_guidance","escalate","override_open","cancel"]' ]
    [ "$(_ge_job_json "$id" '[(.attention // [])[] | .reason] | index("decision_awaiting") != null')" = "true" ]
    [ "$(_ge_claude_count)" = "2" ]
    [[ "$(_ge_job_json "$id" '.question')" == *"fixme"* ]]
    [ "$(_ge_job_json "$id" '.pr_url // "none"')" = "none" ]
    # No PR, so no PR call of any kind (view, ready, edit, list).
    run bash -c "grep -c '^pr ' '$MOTHER_ROOT/mock-gh-calls' || true"
    [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# (i) cost cap while a fix runs

@test "enforce: a cost cap reached during a fix run says which gates were red" {
    local id="g-i1"
    export MOTHER_USAGE_CHECK_INTERVAL=0
    export MOTHER_COST_CAP_GRACE_SECONDS=120
    GE_MAX=3
    touch "$MOTHER_ROOT/ge-no-pr-url"
    _ge_job "$id" ".no_pr = true | .max_cost_usd = 0.001 | .crew = $(_ge_crew "$(_ge_check fixme "$GE_FIXME_RUN" "{\"hint\":\"$GE_HINT\"}")")"
    # Invocation 1 spends nothing; the fix run (2) spends past the cap, lingers
    # long enough for the poll loop to see it, then copies the flag file aside
    # (it may be removed later) and makes the fix.
    _ge_behave 1 'OUT_FILE=""'
    cat > "$MOTHER_ROOT/ge-behave.2" <<BEHAVE
$GE_FIX_SNIPPET
OUT_FILE="$GE_FIXTURES/full_run.jsonl"; SLEEP=7
POST='cp "\$ROOT/runner/\$MOTHER_JOB_ID.cost-cap" "\$ROOT/cap-copy" 2>/dev/null || true'
BEHAVE
    _ge_run "$id"

    [ "$(_ge_claude_count)" -ge 2 ]
    _ge_ev "$id" '[.[] | select(.kind == "cost_cap_breached")] | length >= 1'
    [ -f "$MOTHER_ROOT/cap-copy" ]
    grep -qF "Gates red: fixme" "$MOTHER_ROOT/cap-copy"
}

# ---------------------------------------------------------------------------
# (j) adherence

# _ge_adherence_job <id> <gates-json|null> — a succeeded PR job with a plan.
_ge_adherence_job() {
    local id="$1" gates="$2"
    cp "$_HELPER_DIR/mock_claude" "$_MOCK_BIN/claude"
    chmod +x "$_MOCK_BIN/claude"
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
    # adherence-review reads the plan from the legacy events/<id>-plan.md.
    make_plan "$EVENTS_DIR/$id-plan.md"
    make_job "$id" "succeeded" \
        '.pr_url = "https://github.com/Carefeed/test/pull/42"
         | .adherence_attempts = 0 | .adherence_status = null | .adherence_pending = null
         | .suggested_config = {"cody":{"model":"sonnet","effort":"medium","rationale":"t"},"redd":{"model":"sonnet","effort":"medium","rationale":"t"},"marty":{"model":"sonnet","effort":"medium","rationale":"t"},"perri":{"model":"sonnet","effort":"medium","rationale":"t"}}
         | (if '"$gates"' != null then .gates = '"$gates"' else . end)'
}

GE_GATES_JSON='{"mode":"enforce","effective_mode":"enforce","posture":"normal","status":"passed","attempt":2,"max_attempts":3,
 "head_sha":"abc1234","started_at":"2026-10-18T00:00:00Z","finished_at":"2026-10-18T00:01:00Z",
 "results":[{"name":"lintcheck","result":"passed","blocking":true,"duration_s":1,"exit_code":0},
            {"name":"unitsuite","result":"failed","blocking":true,"duration_s":2,"exit_code":1}],
 "not_run":[]}'

@test "adherence-review: the prompt has a Gate results section (names and results, no excerpts) and tells the reviewer not to re-report them" {
    local id="g-j1"
    _ge_adherence_job "$id" "$GE_GATES_JSON"
    mkdir -p "$MOTHER_ROOT/crew/$id/gates/2"
    printf 'EXCERPT_%s\n' "$GE_MARKER" > "$MOTHER_ROOT/crew/$id/gates/2/unitsuite.excerpt"
    export MOCK_CLAUDE_STDIN_FILE="$MOTHER_ROOT/adherence-stdin"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
fine"
    run mother adherence-review "$id"
    echo "$output"
    [ "$status" -eq 0 ]
    local p="$MOCK_CLAUDE_STDIN_FILE"
    grep -qF '## Gate results' "$p"
    grep -qF 'Gates already enforce these; do not re-report lint/test failures they cover.' "$p"
    local section; section=$(awk '/^## Gate results/ {f = 1; print; next} /^## / {f = 0} f' "$p")
    [[ "$section" == *"lintcheck"* ]]
    [[ "$section" == *"unitsuite"* ]]
    printf '%s\n' "$section" | grep -E 'lintcheck.*passed|passed.*lintcheck' >/dev/null
    printf '%s\n' "$section" | grep -E 'unitsuite.*failed|failed.*unitsuite' >/dev/null
    _ge_assert_not grep -qF "$GE_MARKER" "$p"
}

@test "adherence-review: a job that never ran gates gets no Gate results section" {
    local id="g-j2"
    _ge_adherence_job "$id" null
    export MOCK_CLAUDE_STDIN_FILE="$MOTHER_ROOT/adherence-stdin"
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
fine"
    run mother adherence-review "$id"
    [ "$status" -eq 0 ]
    _ge_assert_not grep -qF '## Gate results' "$MOCK_CLAUDE_STDIN_FILE"
    _ge_assert_not grep -qF 'Gates already enforce these' "$MOCK_CLAUDE_STDIN_FILE"
}

@test "adherence loop: a succeeded job whose gates failed is not marked or reviewed; a clean one still is" {
    _ge_adherence_job "g-j3" '{"mode":"observe","effective_mode":"observe","status":"failed","attempt":1,"max_attempts":3,"results":[],"not_run":[]}'
    _ge_adherence_job "g-j4" '{"mode":"observe","effective_mode":"observe","status":"passed","attempt":1,"max_attempts":3,"results":[],"not_run":[]}'
    export MOCK_CLAUDE_STDOUT="ADHERENCE: pass
NOTES:
fine"
    run mother-runner --adherence-tick
    [ "$status" -eq 0 ]

    # The clean job proves the tick itself works...
    [ "$(_ge_job_json g-j4 '.adherence_status')" = "passed" ]
    # ... and the red-gated one was left alone.
    [ "$(_ge_job_json g-j3 '.adherence_pending // false')" != "true" ]
    [ "$(_ge_job_json g-j3 '.adherence_status // "none"')" = "none" ]
    [ "$(_ge_job_json g-j3 '.adherence_attempts')" = "0" ]
    [ "$(cat "$EVENTS_DIR/g-j3.jsonl" 2>/dev/null | grep -c 'adherence_review_spawned')" = "0" ]
}

# ---------------------------------------------------------------------------
# Draft discipline under a gh outage

@test "enforce: when gh cannot report draft state, pr_draft_unverified is recorded and the fix loop still runs" {
    local id="g-l1"
    export GH_MOCK_FAIL_DRAFT=1
    GE_MAX=3
    _ge_pr "$id"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check fixme "$GE_FIXME_RUN" "{\"hint\":\"$GE_HINT\"}")")"
    _ge_behave 2 "$GE_FIX_SNIPPET"
    _ge_run "$id"

    _ge_ev "$id" '[.[] | select(.kind == "pr_draft_unverified")] | length >= 1'
    # Never claimed to have drafted a PR it could not check.
    _ge_ev "$id" '[.[] | select(.kind == "pr_marked_draft")] | length == 0'
    # The loop carried on: the red gate got its fix run and a second gate pass.
    [ "$(_ge_claude_count)" = "2" ]
    _ge_ev "$id" '[.[] | select(.kind == "gate_fix_started")] | length == 1'
    _ge_ev "$id" '[.[] | select(.kind == "gates_started")] | length == 2'
}

# ---------------------------------------------------------------------------
# Kill switch

@test "MOTHER_GATES_ENABLED=0: an enforce-mode job runs ungated — no gates, no hold, no PR handling" {
    local id="g-k1"
    export MOTHER_GATES_ENABLED=0
    _ge_pr "$id"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check bad "$GE_FAIL_CMD")")"
    _ge_run "$id"
    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(jq 'has("gates")' "$JOBS_DIR/$id.json")" = "false" ]
    [ "$(_ge_claude_count)" = "1" ]
    [ -z "$(_ge_undo_calls)" ]
    [ -z "$(_ge_ready_calls)" ]
    [ -z "$(_ge_edit_calls)" ]
    _ge_ev "$id" '[.[] | select(.kind | test("^gate|^pr_marked|^decision_"))] | length == 0'
}

# ---------------------------------------------------------------------------
# Observe mode is untouched

@test "observe mode never touches the PR: no draft handling, no ready, no body edit, no fix run" {
    local id="g-o1"
    _ge_pr "$id"
    gh_mock_set_pr_body "$GE_PR" "UNTOUCHED_BODY"
    local crew
    crew=$(GE_MAX=3 _ge_crew "$(_ge_check bad "$GE_FAIL_CMD")" | jq -c '.gates.mode = "observe"')
    _ge_job "$id" ".crew = $crew"
    _ge_run "$id"

    [ "$(_ge_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "failed" ]
    [ "$(_ge_job_json "$id" '.gates.effective_mode')" = "observe" ]
    [ "$(_ge_claude_count)" = "1" ]
    [ -z "$(_ge_undo_calls)" ]
    [ -z "$(_ge_ready_calls)" ]
    [ -z "$(_ge_edit_calls)" ]
    [ "$(gh_mock_pr_body "$GE_PR")" = "UNTOUCHED_BODY" ]
    _ge_ev "$id" '[.[] | select(.kind == "gate_fix_started" or .kind == "gates_exhausted" or .kind == "pr_marked_ready" or .kind == "pr_marked_draft" or .kind == "decision_opened")] | length == 0'
}

# ---------------------------------------------------------------------------
# Edge cases found in review (Cody)

@test "enforce: plain mother cancel on a gate hold leaves no hold markers behind" {
    local id="g-x1"
    _ge_hold "$id"
    run mother cancel "$id"
    [ "$status" -eq 0 ]
    [ "$(_ge_job_json "$id" '.state')" = "cancelled" ]
    [ "$(_ge_job_json "$id" '.activity // "none"')" = "none" ]
    [ "$(_ge_job_json "$id" '.paused_reason // "none"')" = "none" ]
    [ "$(_ge_job_json "$id" '[(.attention // [])[] | select(.reason == "decision_awaiting")] | length')" = "0" ]
    run mother list
    [[ "$(printf '%s\n' "$output" | grep -F "$id")" != *"[GATES-HELD]"* ]]
}

@test "enforce: override_open is refused (job untouched) when a PR job has no PR to open" {
    local id="g-x2"
    _ge_hold "$id"
    merged=$(jq '.pr_url = null' "$JOBS_DIR/$id.json") && printf '%s' "$merged" > "$JOBS_DIR/$id.json"
    run mother resume "$id" --option override_open
    [ "$status" -ne 0 ]
    [[ "$output" == *"no PR to open"* ]]
    [ "$(_ge_job_json "$id" '.state')" = "awaiting" ]
    [ "$(_ge_job_json "$id" '.gates.status')" = "failed" ]
    [ "$(_ge_job_json "$id" '.decision.resolved_at // "open"')" = "open" ]
}

@test "enforce: guidance on a gate hold resets the gate budget in the same write that readies the job" {
    local id="g-x3"
    _ge_hold "$id"
    run mother resume "$id" "try again"
    [ "$status" -eq 0 ]
    [ "$(_ge_job_json "$id" '.state')" = "ready" ]
    [ "$(_ge_job_json "$id" '.resume_session_id == .session_id')" = "true" ]
    [ "$(_ge_job_json "$id" '.gates.attempt')" = "0" ]
}

@test "enforce: a gate run that produces no result is incomplete and names every configured gate as not run" {
    local id="g-x4"
    _ge_pr "$id"
    _ge_job "$id" ".crew = $(_ge_crew "$(_ge_check slow 'sleep 30')")"
    export MOTHER_GATES_TOTAL_TIMEOUT_S=2
    _ge_run "$id"
    [ "$(_ge_job_json "$id" '.gates.status')" = "incomplete" ]
    [ "$(jq -c '.gates.not_run' "$JOBS_DIR/$id.json")" = '["slow"]' ]
    [ "$(_ge_result "$id" slow unavailable_reason)" = "gates_timeout" ]
    local block; block=$(gh_mock_last_body "$GE_PR" | _ge_block)
    [[ "$block" == *"**Gates incomplete: slow did not run**"* ]]
}
