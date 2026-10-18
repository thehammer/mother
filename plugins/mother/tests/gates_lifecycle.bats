#!/usr/bin/env bats
# gates_lifecycle.bats — observe-mode quality gates inside the job lifecycle (HC-06).
#
# A job whose snapshot carries `.crew.gates` (written by `mother add` from the
# base ref's .mother/crew.yml) gets its gates run by `mother-run-job` once the
# worker is done and the run is heading for success — BEFORE the terminal
# transition and before the main-dir stash restore / lock release. Observe mode
# only records: it never changes the job's state, failure_reason, PR or prompt.
#
# Observable contract asserted here (job JSON, events, status/list output, side
# files, contract-check.sh) — not how mother-run-job is wired internally:
#   .gates      {mode, effective_mode, status, results[], not_run[], head_sha,
#                attempt, max_attempts, started_at, finished_at, posture}
#   events      gates_started -> gate_result (one per result) -> gates_completed
#   .activity   "gating" while the gates run (state stays `running`); restored after
#   side files  $MOTHER_ROOT/crew/<id>/gates/1/<name>.log|.excerpt
#   mother status <id>   `=== gates ===` section (before `=== origin ===`)
#   NO gate output text in .gates, events or `mother status --format json`.
#
# Harness: real `mother-run-job` subprocesses against a temp git repo with a
# BARE origin. Most jobs are main-dir jobs on a pre-seeded local branch with one
# commit ahead of origin/main (so artifact verification passes with no PR and no
# gh); one test goes through real `mother add` + a worktree job whose fake
# worker commits and pushes. `claude` is a stand-in that exits 0 after a
# `result` event. Gate commands are trivial shell. A run takes ~3s (the
# supervisor polls every 2s), so the file is kept to the cases that matter.

bats_require_minimum_version 1.5.0
load 'test_helper'

# The marker is printed by a failing gate. It is assembled at run time so the
# literal string never appears in the check's `run` text (which legitimately
# lives in the job's .crew snapshot) — only real gate OUTPUT can contain it.
GL_MARKER="GATE_MARKER_c0ffee"
GL_MARKER_CMD="printf 'GATE_%s_%s\\n' MARKER c0ffee; exit 1"

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID GL_MODE GL_MAX GL_BUDGET
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120
    GL_BG_PID=""

    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
    _gl_install_claude_ok

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
    # Release a gate that is blocking on $MOTHER_ROOT/release, and reap any
    # supervisor a failed assertion left behind.
    touch "$MOTHER_ROOT/release" 2>/dev/null || true
    if [ -n "${GL_BG_PID:-}" ]; then
        kill "$GL_BG_PID" 2>/dev/null || true
    fi
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Harness helpers

# A worker that finishes cleanly: a stream-json `result` event, exit 0.
_gl_install_claude_ok() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
# A real worker pushes its branch before it finishes; GL_NO_PUSH=1 is one that didn't.
[ "${GL_NO_PUSH:-0}" = "1" ] || git push -q -u origin HEAD >/dev/null 2>&1 || true
cat <<'EOF'
{"type":"assistant","message":{"id":"msg_gl","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

# _gl_check <name> <run> [extra-jq-object] — one resolved check with defaults.
_gl_check() {
    jq -nc --arg name "$1" --arg run "$2" --argjson extra "${3:-{\}}" '
        {name: $name, run: $run, when: null, blocking: true, where: "any",
         timeout_s: 60, hint: null} + $extra'
}

# _gl_crew <check-json>... — the resolved job `.crew` snapshot (as `mother add`
# stores it). Knobs: GL_MODE (observe), GL_MAX (4), GL_BUDGET (15).
_gl_crew() {
    local checks
    checks=$(printf '%s\n' "$@" | jq -sc '.')
    jq -nc --argjson checks "$checks" --arg mode "${GL_MODE:-observe}" \
        --argjson max "${GL_MAX:-4}" --argjson budget "${GL_BUDGET:-15}" '{
        version: 1, source_ref: "origin/main", source_sha: "abc", phi_sensitive: false,
        gates: {mode: $mode, max_attempts: $max, budget_minutes: $budget, checks: $checks},
        lenses: null}'
}

# _gl_seed_branch <branch> — local-only branch, one commit (app/Foo.php) ahead
# of origin/main, left checked-out-elsewhere (REPO ends on main). The worker
# stand-in pushes it, as a real worker does (unless GL_NO_PUSH=1).
_gl_seed_branch() {
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

# _gl_job <id> [extra-jq] — a ready main-dir job on its own seeded branch.
# `extra-jq` may add `.crew = ...`, `.no_pr = true`, `.activity = ...`.
_gl_job() {
    local id="$1" extra="${2:-.}"
    _gl_seed_branch "feature/gl-$id"
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

# _gl_run <id> — one real supervisor run to completion.
_gl_run() {
    run mother-run-job "$1"
    [ "$status" -eq 0 ]
}

# _gl_publish_crew <yaml> — commit .mother/crew.yml on main and push it.
_gl_publish_crew() {
    (
        cd "$REPO"
        git checkout -q main
        mkdir -p .mother
        printf '%s\n' "$1" > .mother/crew.yml
        git add .mother/crew.yml
        git commit -q -m "crew config"
        git push -q origin main
    ) >/dev/null 2>&1
}

_gl_job_json() { jq -r "$2" "$JOBS_DIR/$1.json"; }

# _gl_head <branch> — the branch tip in REPO.
_gl_head() { git -C "$REPO" rev-parse "refs/heads/$1"; }

# _gl_kinds <id> — event kinds, in order, space-separated.
_gl_kinds() { jq -r '.kind' "$EVENTS_DIR/$1.jsonl" | tr '\n' ' '; }

# _gl_gate_event_count <id> — gates_started / gate_result / gates_completed lines.
_gl_gate_event_count() {
    jq -s '[.[] | select(.kind == "gates_started" or .kind == "gate_result" or .kind == "gates_completed")] | length' \
        "$EVENTS_DIR/$1.jsonl"
}

# _gl_result <id> <name> <field> — a field of one entry of .gates.results.
_gl_result() {
    jq -r --arg n "$2" '.gates.results[] | select(.name == $n) | .'"$3" "$JOBS_DIR/$1.json"
}

# _gl_section <text> — the body of the `=== gates ===` section of status output.
_gl_section() {
    printf '%s\n' "$1" | awk '/^=== gates ===/ {f = 1; next} /^=== / {f = 0} f'
}

# _gl_keys <id> — the job's key set, minus keys that depend on whether the poll
# loop happened to observe the worker's result event before it exited.
_gl_keys() {
    jq -S -c 'del(.final_result_at, .live_cost_usd, .live_tokens) | keys' "$JOBS_DIR/$1.json"
}

# _gl_kind_set <id> — distinct event kinds (same timing caveat as _gl_keys).
_gl_kind_set() {
    jq -r '.kind' "$EVENTS_DIR/$1.jsonl" | grep -v '^final_result_observed$' | sort -u
}

# _gl_assert_ungated <id> — a job that must show no trace of the gates feature.
_gl_assert_ungated() {
    local id="$1"
    [ "$(jq 'has("gates")' "$JOBS_DIR/$id.json")" = "false" ]
    [ "$(_gl_gate_event_count "$id")" = "0" ]
    [ "$(_gl_job_json "$id" '.activity // ""')" != "gating" ]
    run mother status "$id"
    [ "$status" -eq 0 ]
    [[ "$output" != *"=== gates ==="* ]]
    run mother list --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq --arg id "$id" '[.[] | select(.id == $id)][0] | has("gates")')" = "false" ]
}

# ---------------------------------------------------------------------------
# (a) no crew config: nothing changes

@test "a job without .crew runs exactly as before: no crew/gates keys, no gates events, no gates section" {
    _gl_job g-a1
    _gl_run g-a1
    [ "$(_gl_job_json g-a1 '.state')" = "succeeded" ]
    [ "$(jq 'has("crew")' "$JOBS_DIR/g-a1.json")" = "false" ]
    _gl_assert_ungated g-a1
}

@test "an ungated job's key set and event kinds are the same across runs (no-change guard)" {
    _gl_job g-a2
    _gl_job g-a3
    _gl_run g-a2
    _gl_run g-a3
    [ "$(_gl_keys g-a2)" = "$(_gl_keys g-a3)" ]
    [ "$(_gl_kind_set g-a2)" = "$(_gl_kind_set g-a3)" ]
    _gl_assert_ungated g-a2
    _gl_assert_ungated g-a3
}

# ---------------------------------------------------------------------------
# (b) opted in, one passing + one failing blocking gate, observe mode

@test "observe: a failing blocking gate is recorded in .gates but the job still ends succeeded" {
    _gl_job g-b1 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad "$GL_MARKER_CMD")")"
    _gl_run g-b1
    [ "$(_gl_job_json g-b1 '.state')" = "succeeded" ]
    [ "$(_gl_job_json g-b1 '.failure_reason // "none"')" = "none" ]
    [ "$(_gl_job_json g-b1 '.gates.status')" = "failed" ]
    [ "$(_gl_result g-b1 ok result)" = "passed" ]
    [ "$(_gl_result g-b1 ok exit_code)" = "0" ]
    [ "$(_gl_result g-b1 bad result)" = "failed" ]
    [ "$(_gl_result g-b1 bad exit_code)" = "1" ]
    [ "$(_gl_result g-b1 bad blocking)" = "true" ]
    jq -e '.gates.results | map(select(.name == "ok" or .name == "bad")) | length == 2 and all(.duration_s | type == "number")' \
        "$JOBS_DIR/g-b1.json" >/dev/null

    # Gate logs and excerpts land under crew/<id>/gates/1/
    local dir="$MOTHER_ROOT/crew/g-b1/gates/1"
    [ -f "$dir/ok.log" ]
    [ -f "$dir/bad.log" ]
    [ -f "$dir/bad.excerpt" ]
    grep -q "$GL_MARKER" "$dir/bad.log"
    grep -q "$GL_MARKER" "$dir/bad.excerpt"
}

@test "observe: .gates carries mode, effective_mode, attempt, max_attempts, head_sha, posture and timestamps" {
    _gl_job g-b2 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad 'exit 1')")"
    _gl_run g-b2
    [ "$(_gl_job_json g-b2 '.gates.mode')" = "observe" ]
    [ "$(_gl_job_json g-b2 '.gates.effective_mode')" = "observe" ]
    [ "$(_gl_job_json g-b2 '.gates.attempt')" = "1" ]
    [ "$(_gl_job_json g-b2 '.gates.max_attempts')" = "4" ]
    [ "$(_gl_job_json g-b2 '.gates.head_sha')" = "$(_gl_head feature/gl-g-b2)" ]
    [ "$(jq -c '.gates.not_run' "$JOBS_DIR/g-b2.json")" = "[]" ]
    jq -e '(.gates.posture | type == "string" and length > 0)
           and (.gates.started_at | type == "string" and length > 0)
           and (.gates.finished_at | type == "string" and length > 0)
           and (.gates.results | type == "array")' "$JOBS_DIR/g-b2.json" >/dev/null
}

@test "observe: emits gates_started, then one gate_result per result, then gates_completed, all before the job is declared succeeded" {
    _gl_job g-b3 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad 'exit 1')")"
    _gl_run g-b3
    jq -s -e '
        (map(.kind)) as $k
        | ($k | index("gates_started")) as $s
        | ($k | index("gates_completed")) as $c
        | ($k | index("succeeded")) as $done
        | [range(0; $k | length) | select($k[.] == "gate_result")] as $r
        | $s != null and $c != null and $done != null
          and ($r | length) > 0
          and ($r | all(. > $s and . < $c))
          and $c < $done
          and ([$k[] | select(. == "gates_started")] | length) == 1
          and ([$k[] | select(. == "gates_completed")] | length) == 1' \
        "$EVENTS_DIR/g-b3.jsonl" >/dev/null
    # Every result in .gates has exactly one gate_result event.
    [ "$(jq -s '[.[] | select(.kind == "gate_result")] | length' "$EVENTS_DIR/g-b3.jsonl")" \
        = "$(jq '.gates.results | length' "$JOBS_DIR/g-b3.json")" ]

    # Documented detail keys.
    local head; head=$(_gl_head feature/gl-g-b3)
    jq -s -e --arg head "$head" '
        (.[] | select(.kind == "gates_started") | .detail) as $s
        | $s.attempt == 1 and $s.max_attempts == 4 and $s.head_sha == $head and $s.mode == "observe"
          and ($s.posture | type == "string") and ($s.gates | type == "array")
          and ($s.gates | index("ok") != null and index("bad") != null)' \
        "$EVENTS_DIR/g-b3.jsonl" >/dev/null
    jq -s -e '
        [.[] | select(.kind == "gate_result") | .detail] as $rs
        | ($rs | all(.attempt == 1 and has("name") and has("result") and has("blocking")
                     and has("duration_s") and has("exit_code")))
          and ($rs | map(select(.name == "ok"))[0] | .result == "passed" and .exit_code == 0 and .blocking == true)
          and ($rs | map(select(.name == "bad"))[0] | .result == "failed" and .exit_code == 1)' \
        "$EVENTS_DIR/g-b3.jsonl" >/dev/null
    # The completed counts agree with .gates.results.
    jq -s -e --slurpfile job "$JOBS_DIR/g-b3.json" '
        ($job[0].gates.results) as $r
        | (.[] | select(.kind == "gates_completed") | .detail) as $c
        | $c.attempt == 1 and $c.status == "failed"
          and $c.passed == ([$r[] | select(.result == "passed")] | length)
          and $c.failed == ([$r[] | select(.result == "failed")] | length)
          and $c.unavailable == 0
          and $c.not_run == []' \
        "$EVENTS_DIR/g-b3.jsonl" >/dev/null
}

@test "observe: restores the job's previous .activity once the gates are done" {
    _gl_job g-b5 ".activity = \"cody_rework\" | .crew = $(_gl_crew "$(_gl_check ok 'true')")"
    _gl_run g-b5
    [ "$(_gl_job_json g-b5 '.state')" = "succeeded" ]
    [ "$(_gl_job_json g-b5 '.gates.status')" = "passed" ]
    [ "$(_gl_job_json g-b5 '.activity')" = "cody_rework" ]
    run mother list
    [[ "$output" != *"[gating]"* ]]
}

# ---------------------------------------------------------------------------
# While gating

@test "while the gates run the job is state running with activity gating, and mother list shows [gating]" {
    local rel="$MOTHER_ROOT/release" id="g-live"
    _gl_job "$id" ".crew = $(_gl_crew "$(_gl_check hold "while [ ! -f $rel ]; do sleep 0.2; done")")"
    mother-run-job "$id" >"$MOTHER_ROOT/run-job.out" 2>&1 3>&- &
    GL_BG_PID=$!

    local i act=""
    for i in $(seq 1 250); do
        act=$(jq -r '.activity // ""' "$JOBS_DIR/$id.json" 2>/dev/null)
        [ "$act" = "gating" ] && break
        sleep 0.2
    done
    [ "$act" = "gating" ]
    [ "$(_gl_job_json "$id" '.state')" = "running" ]

    run mother list
    [ "$status" -eq 0 ]
    [[ "$(printf '%s\n' "$output" | grep -F "$id")" == *"[gating]"* ]]
    run mother list --format json
    [ "$(printf '%s' "$output" | jq -r --arg id "$id" '.[] | select(.id == $id) | .activity')" = "gating" ]

    touch "$rel"
    wait "$GL_BG_PID"
    GL_BG_PID=""
    [ "$(_gl_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_gl_job_json "$id" '.activity // "none"')" != "gating" ]
}

# ---------------------------------------------------------------------------
# (c) mother status / mother list; output text never leaks into JSON

@test "mother status shows a gates section before origin, with a failing gate's excerpt" {
    _gl_job g-c1 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad "$GL_MARKER_CMD")")"
    _gl_run g-c1
    run mother status g-c1
    [ "$status" -eq 0 ]
    local text="$output"
    [[ "$text" == *"=== gates ==="* ]]
    local gl ol
    gl=$(printf '%s\n' "$text" | grep -n '^=== gates ===' | head -1 | cut -d: -f1)
    ol=$(printf '%s\n' "$text" | grep -n '^=== origin ===' | head -1 | cut -d: -f1)
    [ -n "$gl" ] && [ -n "$ol" ] && [ "$gl" -lt "$ol" ]

    local sec; sec=$(_gl_section "$text")
    [[ "$sec" == *"observe"* ]]
    [[ "$sec" == *"effective: observe"* ]]
    [[ "$sec" == *"1/4"* ]]
    [[ "$sec" == *"$(_gl_head feature/gl-g-c1 | cut -c1-7)"* ]]
    printf '%s\n' "$sec" | grep -E 'ok.*passed|passed.*ok' >/dev/null
    printf '%s\n' "$sec" | grep -E 'bad.*failed|failed.*bad' >/dev/null
    # the failing gate's excerpt is shown, read from the side file
    [[ "$sec" == *"$GL_MARKER"* ]]
    # budget vs actual duration
    printf '%s\n' "$sec" | grep -iE 'budget' | grep -q '15'

    # mother list --format json carries .gates raw
    run mother list --format json
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r --arg id g-c1 '.[] | select(.id == $id) | .gates.status')" = "failed" ]
    [ "$(printf '%s' "$output" | jq -S -c --arg id g-c1 '.[] | select(.id == $id) | .gates')" \
        = "$(jq -S -c '.gates' "$JOBS_DIR/g-c1.json")" ]
}

@test "gate output text appears in no JSON: not in .gates, not in gates events, not in status --format json" {
    _gl_job g-c3 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad "$GL_MARKER_CMD")")"
    _gl_run g-c3
    grep -q "$GL_MARKER" "$MOTHER_ROOT/crew/g-c3/gates/1/bad.log"   # the gate did print it

    run mother status g-c3 --format json
    [ "$status" -eq 0 ]
    [[ "$output" != *"$GL_MARKER"* ]]
    printf '%s' "$output" | jq -e '.job.gates.status == "failed"' >/dev/null

    run grep -c "$GL_MARKER" "$JOBS_DIR/g-c3.json"
    [ "$output" = "0" ]
    run grep -c "$GL_MARKER" "$EVENTS_DIR/g-c3.jsonl"
    [ "$output" = "0" ]

    # None of the contract's forbidden free-text keys appear in .gates or in
    # the gates events' detail.
    jq -e '[.gates | .. | objects | keys[]]
           | map(select(. == "excerpt" or . == "output" or . == "detail_text" or . == "summary"
                        or . == "quote" or . == "text" or . == "criterion_text"))
           | length == 0' "$JOBS_DIR/g-c3.json" >/dev/null
    jq -s -e '[.[] | select(.kind | test("^gate")) | .detail | .. | objects | keys[]]
              | map(select(. == "excerpt" or . == "output" or . == "detail_text" or . == "summary"
                           or . == "quote" or . == "text" or . == "criterion_text"))
              | length == 0' "$EVENTS_DIR/g-c3.jsonl" >/dev/null
}

# ---------------------------------------------------------------------------
# (d) kill switch

@test "MOTHER_GATES_ENABLED=0: a job with .crew runs ungated, identical to a job without it" {
    _gl_job g-d0
    _gl_job g-d1 ".crew = $(_gl_crew "$(_gl_check bad 'exit 1')")"
    _gl_run g-d0
    export MOTHER_GATES_ENABLED=0
    _gl_run g-d1
    [ "$(_gl_job_json g-d1 '.state')" = "succeeded" ]
    [ "$(jq 'has("crew")' "$JOBS_DIR/g-d1.json")" = "true" ]
    [ "$(jq -S -c 'del(.crew, .final_result_at, .live_cost_usd, .live_tokens) | keys' "$JOBS_DIR/g-d1.json")" = "$(_gl_keys g-d0)" ]
    [ "$(_gl_kind_set g-d1)" = "$(_gl_kind_set g-d0)" ]
    _gl_assert_ungated g-d1
    [ ! -d "$MOTHER_ROOT/crew/g-d1/gates" ]
}

# ---------------------------------------------------------------------------
# (e) the job snapshot is the only source

@test "a job enqueued without .crew stays ungated even if its repo has since committed a crew.yml" {
    _gl_job g-e1
    _gl_publish_crew 'version: 1
gates:
  checks:
    - name: late
      run: "exit 1"'
    _gl_run g-e1
    [ "$(_gl_job_json g-e1 '.state')" = "succeeded" ]
    _gl_assert_ungated g-e1
}

# ---------------------------------------------------------------------------
# (f) only a run heading for success gets gated

@test "a worker that exits non-zero runs no gates" {
    _gl_job g-f1 ".crew = $(_gl_crew "$(_gl_check ok 'true')")"
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
exit 1
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    _gl_run g-f1
    [ "$(_gl_job_json g-f1 '.state')" = "failed" ]
    _gl_assert_ungated g-f1
    [ ! -d "$MOTHER_ROOT/crew/g-f1/gates" ]
}

@test "a worker that pauses with mother await runs no gates" {
    _gl_job g-f2 ".crew = $(_gl_crew "$(_gl_check ok 'true')")"
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
mother await --question "need clarification before continuing" >/dev/null 2>&1
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    _gl_run g-f2
    [ "$(_gl_job_json g-f2 '.state')" = "awaiting" ]
    _gl_assert_ungated g-f2
    [ ! -d "$MOTHER_ROOT/crew/g-f2/gates" ]
}

@test "a cancelled run runs no gates" {
    _gl_job g-f3 ".cancel_requested = true | .crew = $(_gl_crew "$(_gl_check ok 'true')")"
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
sleep 5
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    _gl_run g-f3
    [ "$(_gl_job_json g-f3 '.state')" = "cancelled" ]
    _gl_assert_ungated g-f3
}

@test "a stale supervisor (job's worker_pid moved on) runs no gates" {
    _gl_job g-f4 ".crew = $(_gl_crew "$(_gl_check ok 'true')")"
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
# Simulate a resume cycle having handed the job to a newer supervisor.
sleep 1
f="$MOTHER_ROOT/jobs/${MOTHER_JOB_ID}.json"
merged=$(jq '.worker_pid = 99999' "$f") && printf '%s' "$merged" > "$f"
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    _gl_run g-f4
    [ "$(_gl_job_json g-f4 '.worker_pid')" = "99999" ]
    [ "$(_gl_job_json g-f4 '.state')" = "running" ]
    _gl_assert_ungated g-f4
    [ ! -d "$MOTHER_ROOT/crew/g-f4/gates" ]
}

@test "a worker reaped after its result event still gets gated and the job succeeds" {
    export MOTHER_RESULT_GRACE_SECONDS=1
    _gl_job g-f5 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad 'exit 1')")"
    # A worker that reports its result and then refuses to exit.
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}'
sleep 30
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    _gl_run g-f5
    assert_event_kind g-f5 reaping_after_result_grace
    [ "$(_gl_job_json g-f5 '.state')" = "succeeded" ]
    [ "$(_gl_job_json g-f5 '.gates.status')" = "failed" ]
    assert_event_kind g-f5 gates_completed
}

# ---------------------------------------------------------------------------
# (g) no_pr jobs

@test "a no_pr job is gated on its branch head" {
    _gl_job g-g1 ".no_pr = true | .crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad 'exit 1')")"
    _gl_run g-g1
    [ "$(_gl_job_json g-g1 '.state')" = "succeeded" ]
    [ "$(_gl_job_json g-g1 '.pr_url // "none"')" = "none" ]
    [ "$(_gl_job_json g-g1 '.gates.status')" = "failed" ]
    [ "$(_gl_job_json g-g1 '.gates.head_sha')" = "$(_gl_head feature/gl-g-g1)" ]
    [ "$(_gl_result g-g1 ok result)" = "passed" ]
}

@test "a PR job whose branch head was never pushed fails the pushed pre-check (gates never run against an unshipped commit)" {
    _gl_job g-g2 ".crew = $(_gl_crew "$(_gl_check ok 'true')")"
    export GL_NO_PUSH=1
    _gl_run g-g2
    [ "$(_gl_result g-g2 pushed result)" = "failed" ]
    [ "$(_gl_job_json g-g2 '.gates.status')" = "failed" ]
}

@test "a gate run that overruns the total budget is cut off and recorded as incomplete, never passed" {
    _gl_job g-b1 ".crew = $(_gl_crew "$(_gl_check slow 'sleep 30')")"
    export MOTHER_GATES_TOTAL_TIMEOUT_S=2
    local t0 t1; t0=$(date +%s)
    _gl_run g-b1
    t1=$(date +%s)
    [ $((t1 - t0)) -lt 25 ]
    [ "$(_gl_job_json g-b1 '.state')" = "succeeded" ]
    [ "$(_gl_job_json g-b1 '.gates.status')" = "incomplete" ]
    [ "$(_gl_job_json g-b1 '.activity // "none"')" != "gating" ]
}

# ---------------------------------------------------------------------------
# Mode, availability and scoping

@test "mode enforce is recorded as enforce but run as observe: the job still succeeds" {
    _gl_job g-m1 ".crew = $(GL_MODE=enforce _gl_crew "$(_gl_check bad 'exit 1')")"
    _gl_run g-m1
    [ "$(_gl_job_json g-m1 '.state')" = "succeeded" ]
    [ "$(_gl_job_json g-m1 '.failure_reason // "none"')" = "none" ]
    [ "$(_gl_job_json g-m1 '.gates.mode')" = "enforce" ]
    [ "$(_gl_job_json g-m1 '.gates.effective_mode')" = "observe" ]
    [ "$(_gl_job_json g-m1 '.gates.status')" = "failed" ]
    run mother status g-m1
    [[ "$(_gl_section "$output")" == *"effective: observe"* ]]
}

@test "an unavailable gate makes the status incomplete and is listed in not_run; the job still succeeds" {
    _gl_job g-m2 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check sbx 'true' '{"where":"sandbox"}')")"
    _gl_run g-m2
    [ "$(_gl_job_json g-m2 '.state')" = "succeeded" ]
    [ "$(_gl_job_json g-m2 '.gates.status')" = "incomplete" ]
    [ "$(jq -c '.gates.not_run' "$JOBS_DIR/g-m2.json")" = '["sbx"]' ]
    [ "$(_gl_result g-m2 sbx result)" = "unavailable" ]
    [ "$(_gl_result g-m2 ok result)" = "passed" ]
    jq -s -e '
        (.[] | select(.kind == "gates_completed") | .detail) as $c
        | $c.status == "incomplete" and $c.unavailable == 1 and $c.not_run == ["sbx"]' \
        "$EVENTS_DIR/g-m2.jsonl" >/dev/null
    jq -s -e '[.[] | select(.kind == "gate_result" and .detail.name == "sbx")][0].detail.result == "unavailable"' \
        "$EVENTS_DIR/g-m2.jsonl" >/dev/null
    run mother status g-m2
    [ "$status" -eq 0 ]
    [[ "$(_gl_section "$output")" == *"gates incomplete: sbx"* ]]
}

@test "a path-scoped gate that does not match the diff is skipped and does not fail the run" {
    _gl_job g-m3 ".crew = $(_gl_crew \
        "$(_gl_check jsonly 'exit 1' '{"when":{"paths":["**/*.js"]}}')" \
        "$(_gl_check phponly 'true' '{"when":{"paths":["**/*.php"]}}')")"
    _gl_run g-m3
    [ "$(_gl_job_json g-m3 '.state')" = "succeeded" ]
    [ "$(_gl_result g-m3 jsonly result)" = "skipped" ]
    [ "$(_gl_result g-m3 phponly result)" = "passed" ]
    [ "$(_gl_job_json g-m3 '.gates.status')" = "passed" ]
}

# ---------------------------------------------------------------------------
# Through real `mother add`

@test "end to end: mother add snapshots crew.yml from the base ref and the worktree job is gated on its pushed head" {
    _gl_publish_crew 'version: 1
gates:
  max_attempts: 2
  budget_minutes: 7
  checks:
    - name: fast
      run: "true"
    - name: nope
      run: "exit 3"'
    make_plan_with_config "$MOTHER_ROOT/plan.md" "suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: \"x\"
  redd:
    model: sonnet
    effort: medium
    rationale: \"x\"
  marty:
    model: sonnet
    effort: medium
    rationale: \"x\"
  perri:
    model: sonnet
    effort: medium
    rationale: \"x\""
    run mother add --plan-file "$MOTHER_ROOT/plan.md" --repo gaterepo \
        --repo-path "$REPO" --branch feature/gl-add --base origin/main
    [ "$status" -eq 0 ]
    local id; id=$(printf '%s\n' "$output" | tail -1)   # add may print warnings before the id
    [ -f "$JOBS_DIR/$id.json" ]
    [ "$(_gl_job_json "$id" '.crew.gates.checks | length')" = "2" ]
    # `add` leaves the job queued; the daemon would promote it. Do that by hand.
    merged=$(jq '.state = "ready"' "$JOBS_DIR/$id.json") && printf '%s' "$merged" > "$JOBS_DIR/$id.json"

    # The fake worker does real work in its worktree: commit and push the branch.
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
# Workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT (resolve like the real CLI does).
MOTHER_ROOT="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
mkdir -p app
echo '<?php' > app/Foo.php
git add app/Foo.php
git commit -q -m "worker change"
git push -q origin HEAD:refs/heads/feature/gl-add
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}'
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"

    _gl_run "$id"
    [ "$(_gl_job_json "$id" '.state')" = "succeeded" ]
    [ "$(_gl_job_json "$id" '.gates.mode')" = "observe" ]
    [ "$(_gl_job_json "$id" '.gates.max_attempts')" = "2" ]
    [ "$(_gl_job_json "$id" '.gates.status')" = "failed" ]
    [ "$(_gl_result "$id" fast result)" = "passed" ]
    [ "$(_gl_result "$id" nope result)" = "failed" ]
    [ "$(_gl_result "$id" nope exit_code)" = "3" ]
    [ "$(_gl_job_json "$id" '.gates.head_sha')" = "$(_gl_head feature/gl-add)" ]
    [ "$(_gl_job_json "$id" '.gates.head_sha')" = "$(git -C "$ORIGIN" rev-parse refs/heads/feature/gl-add)" ]
}

# ---------------------------------------------------------------------------
# (h) client contract

# _gl_envelopes <id> [kind-regex] — the job's events as broker envelopes.
_gl_envelopes() {
    jq -c -s --arg job "$1" --arg re "${2:-.}" '
        to_entries[]
        | select(.value.kind | test($re))
        | {v: 1, dir: "event", t: .value.kind, id: ((.key + 1) | tostring), ts: .value.ts,
           data: (.value.detail + {job: $job, category: "activity"})}' \
        "$EVENTS_DIR/$1.jsonl"
}

@test "scripts/contract-check.sh accepts the gates events, and the whole event log, of a gated run" {
    _gl_job g-h1 ".crew = $(_gl_crew "$(_gl_check ok 'true')" "$(_gl_check bad "$GL_MARKER_CMD")" \
        "$(_gl_check sbx 'true' '{"where":"sandbox"}')" "$(_gl_check skipme 'true' '{"when":{"paths":["**/*.js"]}}')")"
    _gl_run g-h1

    _gl_envelopes g-h1 '^gate' > "$MOTHER_ROOT/gates.ndjson"
    # gates_started + gates_completed + at least one gate_result
    [ "$(wc -l < "$MOTHER_ROOT/gates.ndjson" | tr -d ' ')" -ge 3 ]
    run "$_PLUGIN_DIR/scripts/contract-check.sh" "$MOTHER_ROOT/gates.ndjson"
    echo "$output"
    [ "$status" -eq 0 ]

    _gl_envelopes g-h1 > "$MOTHER_ROOT/all.ndjson"
    run "$_PLUGIN_DIR/scripts/contract-check.sh" "$MOTHER_ROOT/all.ndjson"
    echo "$output"
    [ "$status" -eq 0 ]
}
