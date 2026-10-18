#!/usr/bin/env bats
# lenses.bats — HC-12 lens runner.
#
# Covers:
#   lib/crew_config.py select       lens selection (path scopes, posture, plan add/remove, PHI)
#   mother add                      plan-level `lenses: {add, remove}` validation and storage
#   mother review-lens              one Perri lens review (prompt, flags, side file, usage, events)
#   agents/perri-lens.md, templates/lens-checklists/*.md
#   lib/request-types.sh, lib/phase-prompt.sh   (perri-lens:review, `patch` input)
#
# claude is the mock in mock-bin; replies are stream-json fixtures under
# tests/fixtures/lenses/ delivered through MOCK_CLAUDE_STDOUT_FILE.

bats_require_minimum_version 1.5.0
load 'test_helper'

FIX="$BATS_TEST_DIRNAME/fixtures/lenses"
CREW_PY="$_LIB_DIR/crew_config.py"
LENSES="correctness phi-security tests ops-infra"

setup() {
    setup_mother_env
    unset MOTHER_PHI_REPOS MOTHER_GATES_ENABLED MOTHER_JOB_ID
    export MOTHER_POSTURE_ENABLED=0

    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    ORIGIN="$MOTHER_ROOT/origin.git"
    REPO="$MOTHER_ROOT/work/lensrepo"
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
        git checkout -q -b feature/x
        mkdir -p app
        printf '<?php\nfunction provision($isApache) {\n    if ($isApache) {\n        return 1;\n    }\n}\n' > app/Foo.php
        git add .
        git commit -q -m "feature work"
    ) >/dev/null 2>&1

    export MOCK_CLAUDE_ARGS_FILE="$MOTHER_ROOT/mock-claude-args"
    export MOCK_CLAUDE_STDIN_FILE="$MOTHER_ROOT/mock-claude-stdin"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers

# _publish_crew <yaml> — commit .mother/crew.yml on main and push (origin/main has it).
_publish_crew() {
    (
        cd "$REPO"
        git checkout -q main
        mkdir -p .mother
        printf '%s\n' "$1" > .mother/crew.yml
        git add .mother/crew.yml
        git commit -q -m "crew config"
        git push -q origin main
        git checkout -q feature/x
        git merge -q --no-edit main
    ) >/dev/null 2>&1
}

_gates_only_yaml() {
    printf 'version: 1\ngates:\n  checks:\n    - name: pint\n      run: "true"\n'
}

# _resolve_crew <repo-name> — resolve main's crew.yml into $RESOLVED.
_resolve_crew() {
    RESOLVED="$MOTHER_ROOT/resolved.json"
    python3 "$CREW_PY" resolve "$REPO" main "$1" > "$RESOLVED"
}

# _select <posture> <plan-lenses-json> [files...]  (uses $RESOLVED)
_select() {
    local posture="$1" plan="$2"; shift 2
    run --separate-stderr python3 "$CREW_PY" select "$RESOLVED" "$posture" "$plan" "$@"
}

# _sel_field <lens> <field> — field of that lens's entry in $output
_sel_field() {
    printf '%s' "$output" | jq -r --arg l "$1" '.[] | select(.lens == $l) | '"$2"
}

_sel_lenses() { printf '%s' "$output" | jq -r '[.[].lens] | join(",")'; }

_ops_scope_yaml() {
    printf 'version: 1\ngates:\n  checks: []\nlenses:\n  default: [correctness, tests, ops-infra]\n  scopes:\n    ops-infra: ["infrastructure/**", "**/*.tf"]\n'
}

# ---------------------------------------------------------------------------
# select — path scopes

@test "select: an ops-infra lens scoped to infra paths is skipped (path_scope) for a UI-only diff" {
    _publish_crew "$(_ops_scope_yaml)"
    _resolve_crew lensrepo
    _select normal null "resources/js/App.vue" "resources/css/app.css"
    [ "$status" -eq 0 ]
    [ "$(_sel_field ops-infra .run)" = "false" ]
    [ "$(_sel_field ops-infra .skip_reason)" = "path_scope" ]
    [ "$(_sel_field correctness .run)" = "true" ]
    [ "$(_sel_field tests .run)" = "true" ]
}

@test "select: the scoped lens runs for a .tf diff" {
    _publish_crew "$(_ops_scope_yaml)"
    _resolve_crew lensrepo
    _select normal null "modules/vpc/main.tf" "README.md"
    [ "$status" -eq 0 ]
    [ "$(_sel_field ops-infra .run)" = "true" ]
    [ "$(_sel_field ops-infra .skip_reason)" = "null" ]
}

@test "select: the scoped lens runs for a file under infrastructure/" {
    _publish_crew "$(_ops_scope_yaml)"
    _resolve_crew lensrepo
    _select normal null "infrastructure/ecs/service.json"
    [ "$(_sel_field ops-infra .run)" = "true" ]
}

@test "select: a lone - reads changed files from stdin" {
    _publish_crew "$(_ops_scope_yaml)"
    _resolve_crew lensrepo
    run --separate-stderr bash -c "printf 'modules/vpc/main.tf\nREADME.md\n' | python3 '$CREW_PY' select '$RESOLVED' normal null -"
    [ "$status" -eq 0 ]
    [ "$(_sel_field ops-infra .run)" = "true" ]
}

@test "select: scope matching follows the glob rules (* does not cross /)" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, ops-infra]
  scopes:
    ops-infra: ["deploy/*.yml"]'
    _resolve_crew lensrepo
    _select normal null "deploy/sub/x.yml"
    [ "$(_sel_field ops-infra .skip_reason)" = "path_scope" ]
    _select normal null "deploy/x.yml"
    [ "$(_sel_field ops-infra .run)" = "true" ]
}

@test "select: output covers the default set in canonical lens order with the documented entry shape" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [ops-infra, tests, correctness]'
    _resolve_crew lensrepo
    _select normal null "a.php"
    [ "$status" -eq 0 ]
    [ "$(_sel_lenses)" = "correctness,tests,ops-infra" ]
    printf '%s' "$output" | jq -e '
        all(.[]; (.reviewer == ("perri:" + .lens)) and (.run | type == "boolean") and has("skip_reason"))' >/dev/null
}

# ---------------------------------------------------------------------------
# select — posture

@test "select: conservative posture runs only mandatory lenses; the rest are skipped for posture" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, tests, ops-infra]
  mandatory: [correctness]'
    _resolve_crew lensrepo
    _select conservative null "a.php"
    [ "$status" -eq 0 ]
    [ "$(_sel_field correctness .run)" = "true" ]
    [ "$(_sel_field tests .run)" = "false" ]
    [ "$(_sel_field tests .skip_reason)" = "posture" ]
    [ "$(_sel_field ops-infra .skip_reason)" = "posture" ]
}

@test "select: non-conservative postures do not skip anything" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, tests]'
    _resolve_crew lensrepo
    local p
    for p in normal elevated flush; do
        _select "$p" null "a.php"
        [ "$(printf '%s' "$output" | jq '[.[] | select(.run)] | length')" = "2" ]
    done
}

@test "select: path_scope takes precedence over posture as the skip reason" {
    _publish_crew "$(_ops_scope_yaml)"
    _resolve_crew lensrepo
    _select conservative null "resources/js/App.vue"
    [ "$(_sel_field ops-infra .skip_reason)" = "path_scope" ]
}

# ---------------------------------------------------------------------------
# select — plan add / remove

@test "select: a plan removal skips a non-mandatory lens with removed_by_plan" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, tests, ops-infra]'
    _resolve_crew lensrepo
    _select normal '{"add":[],"remove":["ops-infra"]}' "a.tf"
    [ "$(_sel_field ops-infra .run)" = "false" ]
    [ "$(_sel_field ops-infra .skip_reason)" = "removed_by_plan" ]
}

@test "select: removed_by_plan takes precedence over path_scope" {
    _publish_crew "$(_ops_scope_yaml)"
    _resolve_crew lensrepo
    _select normal '{"add":[],"remove":["ops-infra"]}' "resources/js/App.vue"
    [ "$(_sel_field ops-infra .skip_reason)" = "removed_by_plan" ]
}

@test "select: a plan add of a non-default lens runs it" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness]'
    _resolve_crew lensrepo
    _select normal '{"add":["tests"],"remove":[]}' "a.php"
    [ "$status" -eq 0 ]
    [ "$(_sel_lenses)" = "correctness,tests" ]
    [ "$(_sel_field tests .run)" = "true" ]
}

@test "select: mandatory lenses ignore plan removal, path scope and conservative posture" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, tests]
  mandatory: [tests]
  scopes:
    tests: ["tests/**"]'
    _resolve_crew lensrepo
    _select conservative '{"add":[],"remove":["tests"]}' "resources/js/App.vue"
    [ "$status" -eq 0 ]
    [ "$(_sel_field tests .run)" = "true" ]
    [ "$(_sel_field tests .skip_reason)" = "null" ]
}

# ---------------------------------------------------------------------------
# select — PHI repos always run phi-security

@test "select: phi-security always runs in admin-portal and referral-monitor with no lenses config" {
    _publish_crew "$(_gates_only_yaml)"
    local r
    for r in admin-portal referral-monitor; do
        _resolve_crew "$r"
        _select normal null "README.md"
        [ "$status" -eq 0 ]
        [ "$(_sel_field phi-security .run)" = "true" ]
    done
}

@test "select: phi-security runs under conservative posture in PHI repos" {
    _publish_crew "$(_gates_only_yaml)"
    local r
    for r in admin-portal referral-monitor; do
        _resolve_crew "$r"
        _select conservative null "README.md"
        [ "$(_sel_field phi-security .run)" = "true" ]
    done
}

@test "select: phi-security runs in PHI repos even with a scope configured on it" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, phi-security]
  scopes:
    phi-security: ["app/Phi/**"]'
    local r
    for r in admin-portal referral-monitor; do
        _resolve_crew "$r"
        _select normal null "resources/js/App.vue"
        [ "$(_sel_field phi-security .run)" = "true" ]
    done
}

@test "select: a plan removal attempt cannot skip phi-security in a PHI repo" {
    _publish_crew "$(_gates_only_yaml)"
    local r
    for r in admin-portal referral-monitor; do
        _resolve_crew "$r"
        _select normal '{"add":[],"remove":["phi-security"]}' "README.md"
        [ "$(_sel_field phi-security .run)" = "true" ]
    done
}

@test "select: a custom PHI repo via MOTHER_PHI_REPOS always runs phi-security, even scoped, conservative and plan-removed" {
    export MOTHER_PHI_REPOS="lensrepo"
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, phi-security]
  scopes:
    phi-security: ["app/Phi/**"]'
    _resolve_crew lensrepo
    _select conservative '{"add":[],"remove":["phi-security"]}' "resources/js/App.vue"
    [ "$status" -eq 0 ]
    [ "$(_sel_field phi-security .run)" = "true" ]
}

@test "select: a non-PHI repo does not get phi-security unless configured" {
    _publish_crew "$(_gates_only_yaml)"
    _resolve_crew lensrepo
    _select normal null "README.md"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq '[.[] | select(.lens == "phi-security")] | length')" = "0" ]
}

# ---------------------------------------------------------------------------
# mother add — plan-level lenses

_add_plan() { # <extra yaml appended after the suggested_config block (top-level)>
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
    rationale: \"x\"
${1:-}"
}

_add() { # [repo-name]
    run mother add --plan-file "$MOTHER_ROOT/plan.md" --repo "${1:-lensrepo}" \
        --repo-path "$REPO" --branch feature/test --base origin/main
}

@test "mother add: an unknown lens in add fails and names the lens" {
    _publish_crew "$(_gates_only_yaml)"
    _add_plan "lenses:
  add: [bogus-lens]"
    _add
    [ "$status" -eq 1 ]
    [[ "$output" == *"bogus-lens"* ]]
    [ -z "$(ls "$JOBS_DIR")" ]
}

@test "mother add: an unknown lens in remove fails and names the lens" {
    _publish_crew "$(_gates_only_yaml)"
    _add_plan "lenses:
  remove: [bogus-lens]"
    _add
    [ "$status" -eq 1 ]
    [[ "$output" == *"bogus-lens"* ]]
    [ -z "$(ls "$JOBS_DIR")" ]
}

@test "mother add: removing phi-security in admin-portal fails with the exact mandatory message" {
    _publish_crew "$(_gates_only_yaml)"
    _add_plan "lenses:
  remove: [phi-security]"
    _add admin-portal
    [ "$status" -eq 1 ]
    [[ "$output" == *"add: lens 'phi-security' is mandatory in admin-portal and cannot be removed by a plan"* ]]
    [ -z "$(ls "$JOBS_DIR")" ]
}

@test "mother add: removing phi-security in a PHI repo fails even when the repo has no crew.yml" {
    _add_plan "lenses:
  remove: [phi-security]"
    _add admin-portal
    [ "$status" -eq 1 ]
    [[ "$output" == *"add: lens 'phi-security' is mandatory in admin-portal and cannot be removed by a plan"* ]]
}

@test "mother add: removing phi-security in referral-monitor and in a MOTHER_PHI_REPOS repo fails" {
    _add_plan "lenses:
  remove: [phi-security]"
    _add referral-monitor
    [ "$status" -eq 1 ]
    [[ "$output" == *"lens 'phi-security' is mandatory in referral-monitor"* ]]

    export MOTHER_PHI_REPOS="lensrepo"
    _add lensrepo
    [ "$status" -eq 1 ]
    [[ "$output" == *"lens 'phi-security' is mandatory in lensrepo"* ]]
}

@test "mother add: removing a lens the repo's crew.yml marks mandatory fails" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, tests]
  mandatory: [tests]'
    _add_plan "lenses:
  remove: [tests]"
    _add lensrepo
    [ "$status" -eq 1 ]
    [[ "$output" == *"lens 'tests' is mandatory in lensrepo"* ]]
}

@test "mother add: removing ops-infra in a repo where it is not mandatory is accepted and stored" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, tests, ops-infra]'
    _add_plan "lenses:
  add: [tests]
  remove: [ops-infra]"
    _add lensrepo
    [ "$status" -eq 0 ]
    jq -e '.crew.lenses.plan == {"add": ["tests"], "remove": ["ops-infra"]}' \
        "$JOBS_DIR/$output.json" >/dev/null
}

@test "mother add: a plan lenses block with only remove stores an empty add list" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness, ops-infra]'
    _add_plan "lenses:
  remove: [ops-infra]"
    _add lensrepo
    [ "$status" -eq 0 ]
    jq -e '.crew.lenses.plan.remove == ["ops-infra"] and (.crew.lenses.plan.add // []) == []' \
        "$JOBS_DIR/$output.json" >/dev/null
}

@test "mother add: a plan without a lenses block stores no plan lens changes" {
    _publish_crew 'version: 1
gates:
  checks: []
lenses:
  default: [correctness]'
    _add_plan
    _add lensrepo
    [ "$status" -eq 0 ]
    jq -e '(.crew.lenses.plan // null) == null' "$JOBS_DIR/$output.json" >/dev/null
}

@test "mother add: a valid plan lenses block is accepted for a PHI repo when it does not remove phi-security" {
    _publish_crew "$(_gates_only_yaml)"
    _add_plan "lenses:
  add: [ops-infra]"
    _add admin-portal
    [ "$status" -eq 0 ]
    jq -e '.crew.lenses.plan.add == ["ops-infra"]' "$JOBS_DIR/$output.json" >/dev/null
}

# ---------------------------------------------------------------------------
# Static artifacts: agent, checklists, registry, patch input

@test "the perri-lens agent exists, is at most 120 lines, and never edits, commits or pushes" {
    local f="$_PLUGIN_DIR/agents/perri-lens.md"
    [ -f "$f" ]
    [ "$(wc -l < "$f" | tr -d ' ')" -le 120 ]
    grep -qi 'never' "$f"
    grep -qi 'edit' "$f"
    grep -qi 'commit' "$f"
    grep -qi 'push' "$f"
}

@test "each lens checklist exists, is at most 50 lines, and starts with '# Lens: <name>'" {
    local l f
    for l in $LENSES; do
        f="$_PLUGIN_DIR/templates/lens-checklists/$l.md"
        [ -f "$f" ] || { echo "missing $f" >&2; return 1; }
        [ "$(wc -l < "$f" | tr -d ' ')" -le 50 ] || { echo "$f too long" >&2; return 1; }
        [ "$(head -n 1 "$f")" = "# Lens: $l" ] || { echo "$f bad first line" >&2; return 1; }
    done
}

@test "the tests checklist treats suppressions and skips as blocking" {
    local f="$_PLUGIN_DIR/templates/lens-checklists/tests.md"
    grep -qi 'suppress' "$f"
    grep -qi 'blocking' "$f"
}

@test "the correctness checklist mentions Apache" {
    grep -q 'Apache' "$_PLUGIN_DIR/templates/lens-checklists/correctness.md"
}

@test "request registry: perri-lens:review exists and takes patch, tests and plan" {
    run bash -c "source '$_LIB_DIR/request-types.sh' && rt_exists perri-lens review"
    [ "$status" -eq 0 ]
    run bash -c "source '$_LIB_DIR/request-types.sh' && rt_inputs perri-lens review"
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'patch\ntests\nplan')" ]
}

@test "phase_render_input patch renders a Patch section with the git diff base...HEAD" {
    source "$_LIB_DIR/phase-prompt.sh"
    run phase_render_input patch "$REPO" "" "" main "" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"## Patch"* ]]
    [[ "$output" == *'+    if ($isApache) {'* ]]
    [[ "$output" == *"app/Foo.php"* ]]
}

@test "phase_render_input patch leaves a small diff untruncated" {
    source "$_LIB_DIR/phase-prompt.sh"
    run phase_render_input patch "$REPO" "" "" main "" ""
    [[ "$output" != *"truncated"* ]]
}

@test "phase_render_input patch caps a diff over 120 KB and says it was truncated" {
    (
        cd "$REPO"
        local i
        for i in $(seq 1 4000); do
            printf 'line %05d padding padding padding padding padding\n' "$i"
        done > big.txt
        git add big.txt
        git commit -q -m "big change"
    ) >/dev/null 2>&1
    local full
    full=$(git -C "$REPO" diff main...HEAD | wc -c | tr -d ' ')
    [ "$full" -gt 122880 ]

    source "$_LIB_DIR/phase-prompt.sh"
    run phase_render_input patch "$REPO" "" "" main "" ""
    [ "$status" -eq 0 ]
    [[ "$output" == *"truncated"* ]]
    [[ "$output" == *"## Patch"* ]]
    # The patch body is capped at 122880 bytes; allow a small header/note allowance.
    [ "${#output}" -lt $((122880 + 2048)) ]
}

# ---------------------------------------------------------------------------
# mother review-lens

# _make_lens_job <id> [extra-jq] — a succeeded job whose work_dir is $REPO.
_make_lens_job() {
    local id="$1" extra="${2:-.}"
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    make_job "$id" succeeded \
        ".repo = \"lensrepo\" | .repo_path = \"$REPO\" | .work_dir = \"$REPO\" | .base_ref = \"main\" | .branch = \"feature/x\" | .plan_path = \"$MOTHER_ROOT/plans/$id.md\" | .log_path = \"$LOGS_DIR/$id.log\" | $extra"
    touch "$LOGS_DIR/$id.log"
}

_reply() { export MOCK_CLAUDE_STDOUT_FILE="$FIX/$1"; }

_side_file() { echo "$MOTHER_ROOT/crew/$1/wave/c${3:-0}/$2.json"; }

_num_eq() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a + 0 == b + 0) }'; }

@test "review-lens: claude is invoked with --agent perri-lens, default model sonnet, effort medium and budget 3" {
    _make_lens_job rl1
    _reply reply_clean.jsonl
    run mother review-lens rl1 --lens correctness
    [ "$status" -eq 0 ]
    [ "$(mock_claude_flag_value --agent)" = "perri-lens" ]
    [ "$(mock_claude_flag_value --model)" = "sonnet" ]
    [ "$(mock_claude_flag_value --effort)" = "medium" ]
    _num_eq "$(mock_claude_flag_value --max-budget-usd)" 3
}

@test "review-lens: suggested_config.perri overrides model and effort" {
    _make_lens_job rl2 '.suggested_config.perri = {"model":"opus","effort":"high","rationale":"x"}'
    _reply reply_clean.jsonl
    run mother review-lens rl2 --lens correctness
    [ "$status" -eq 0 ]
    [ "$(mock_claude_flag_value --model)" = "opus" ]
    [ "$(mock_claude_flag_value --effort)" = "high" ]
}

@test "review-lens: budget comes from the job's crew lenses budget_usd when no flag is given" {
    _make_lens_job rl3 '.crew = {"lenses": {"budget_usd": 4}}'
    _reply reply_clean.jsonl
    run mother review-lens rl3 --lens correctness
    [ "$status" -eq 0 ]
    _num_eq "$(mock_claude_flag_value --max-budget-usd)" 4
}

@test "review-lens: --budget-usd overrides the job's configured budget" {
    _make_lens_job rl4 '.crew = {"lenses": {"budget_usd": 4}}'
    _reply reply_clean.jsonl
    run mother review-lens rl4 --lens correctness --budget-usd 1.5
    [ "$status" -eq 0 ]
    _num_eq "$(mock_claude_flag_value --max-budget-usd)" 1.5
}

@test "review-lens: the prompt carries the lens checklist, the patch and the findings instructions" {
    _make_lens_job rl5
    _reply reply_clean.jsonl
    run mother review-lens rl5 --lens correctness
    [ "$status" -eq 0 ]
    [ -s "$MOCK_CLAUDE_STDIN_FILE" ]
    grep -qF '# Lens: correctness' "$MOCK_CLAUDE_STDIN_FILE"
    grep -qF '## Patch' "$MOCK_CLAUDE_STDIN_FILE"
    grep -qF '+    if ($isApache) {' "$MOCK_CLAUDE_STDIN_FILE"
    grep -qF 'Emitting Structured Findings' "$MOCK_CLAUDE_STDIN_FILE"
}

@test "review-lens: the prompt contains only the requested lens's checklist" {
    _make_lens_job rl5b
    _reply reply_clean.jsonl
    run mother review-lens rl5b --lens tests
    [ "$status" -eq 0 ]
    grep -qF '# Lens: tests' "$MOCK_CLAUDE_STDIN_FILE"
    ! grep -qF '# Lens: correctness' "$MOCK_CLAUDE_STDIN_FILE"
}

@test "review-lens: side file holds findings tagged with reviewer and lens, examined paths, cost and decision" {
    _make_lens_job rl6
    _reply reply_findings.jsonl
    run mother review-lens rl6 --lens correctness
    [ "$status" -eq 0 ]
    local sf; sf=$(_side_file rl6 correctness)
    [ -f "$sf" ]
    jq -e '
        (.findings | length) == 1
        and .findings[0].reviewer == "perri:correctness"
        and .findings[0].lens == "correctness"
        and .findings[0].summary == "Apache detection is inverted in provisioning"
        and .examined == ["app/Foo.php", "infra/main.tf"]
        and (.cost_usd | type == "number")
        and .decision == "continue"' "$sf" >/dev/null
    # cost is computed by Mother's usage accounting from the transcript, so
    # assert only that a positive number was recorded.
    jq -e '.cost_usd > 0' "$sf" >/dev/null
}

@test "review-lens: a clean reply writes an empty findings array and decision ship" {
    _make_lens_job rl7
    _reply reply_clean.jsonl
    run mother review-lens rl7 --lens tests
    [ "$status" -eq 0 ]
    jq -e '.findings == [] and .examined == ["app/Foo.php"] and .decision == "ship"' \
        "$(_side_file rl7 tests)" >/dev/null
}

@test "review-lens: a reply with no examined block records an empty examined list" {
    _make_lens_job rl8
    _reply reply_no_examined.jsonl
    run mother review-lens rl8 --lens correctness
    [ "$status" -eq 0 ]
    jq -e '.examined == []' "$(_side_file rl8 correctness)" >/dev/null
}

@test "review-lens: the side file lands under the job's review cycle" {
    _make_lens_job rl9 '.pipeline = {"phase": "cody", "findings": [], "review_cycle": 1}'
    _reply reply_clean.jsonl
    run mother review-lens rl9 --lens correctness
    [ "$status" -eq 0 ]
    [ -f "$(_side_file rl9 correctness 1)" ]
    [ ! -e "$(_side_file rl9 correctness 0)" ]
    [ -f "$LOGS_DIR/rl9.lens-correctness-c1.log" ]
}

@test "review-lens: writes a per-lens log under the logs directory" {
    _make_lens_job rl10
    _reply reply_clean.jsonl
    run mother review-lens rl10 --lens ops-infra
    [ "$status" -eq 0 ]
    [ -e "$LOGS_DIR/rl10.lens-ops-infra-c0.log" ]
}

@test "review-lens: finding text never reaches the job JSON or the events file" {
    _make_lens_job rl11
    _reply reply_findings.jsonl
    run mother review-lens rl11 --lens correctness
    [ "$status" -eq 0 ]
    ! grep -qF 'Apache detection is inverted' "$JOBS_DIR/rl11.json"
    ! grep -qF 'Apache detection is inverted' "$EVENTS_DIR/rl11.jsonl"
    ! grep -qF 'Swap the arms' "$JOBS_DIR/rl11.json"
    ! grep -qF 'Swap the arms' "$EVENTS_DIR/rl11.jsonl"
}

@test "review-lens: emits a reviewed event with reviewer, finding_count and decision" {
    _make_lens_job rl12
    _reply reply_findings.jsonl
    run mother review-lens rl12 --lens correctness
    [ "$status" -eq 0 ]
    run jq -c 'select(.kind == "reviewed")' "$EVENTS_DIR/rl12.jsonl"
    [[ "$output" == *'"reviewer":"perri:correctness"'* ]]
    [[ "$output" == *'"finding_count":1'* ]]
    [[ "$output" == *'"decision":"continue"'* ]]
}

@test "review-lens: appends one usage row with stage, run_kind, actor, lens, model, effort and budget" {
    _make_lens_job rl13
    _reply reply_clean.jsonl
    run mother review-lens rl13 --lens phi-security --budget-usd 2
    [ "$status" -eq 0 ]
    local m="$MOTHER_ROOT/metrics/runs.jsonl"
    [ -f "$m" ]
    [ "$(grep -cF '"job_id":"rl13"' "$m")" = "1" ]
    grep -F '"job_id":"rl13"' "$m" | jq -e '
        .stage == "review-perri:phi-security"
        and .run_kind == "review"
        and .actor == "perri:phi-security"
        and .lens == "phi-security"
        and .model == "sonnet"
        and .effort == "medium"
        and .budget_usd == 2' >/dev/null
}

@test "review-lens: each lens is its own usage row and side file" {
    _make_lens_job rl14
    _reply reply_clean.jsonl
    mother review-lens rl14 --lens correctness
    mother review-lens rl14 --lens tests
    [ -f "$(_side_file rl14 correctness)" ]
    [ -f "$(_side_file rl14 tests)" ]
    [ "$(grep -cF '"job_id":"rl14"' "$MOTHER_ROOT/metrics/runs.jsonl")" = "2" ]
}

@test "review-lens: an invalid findings block exits 2, emits review_parse_error and writes no findings" {
    _make_lens_job rl15
    _reply reply_invalid.jsonl
    run mother review-lens rl15 --lens correctness
    [ "$status" -eq 2 ]
    assert_event_kind rl15 review_parse_error
    local sf; sf=$(_side_file rl15 correctness)
    if [ -f "$sf" ]; then
        [ "$(jq '.findings | length' "$sf")" = "0" ]
    fi
    ! grep -qF 'FINDING_SENTINEL_INVALID' "$EVENTS_DIR/rl15.jsonl"
    ! grep -qF 'FINDING_SENTINEL_INVALID' "$JOBS_DIR/rl15.json"
}

@test "review-lens: a run that produces no findings block is recorded as error, never as a clean pass" {
    _make_lens_job rl15b
    _reply reply_empty.jsonl
    run mother review-lens rl15b --lens phi-security
    [ "$status" -eq 2 ]
    assert_event_kind rl15b review_no_findings_block
    local sf; sf=$(_side_file rl15b phi-security)
    [ -f "$sf" ]
    [ "$(jq -r '.decision' "$sf")" = "error" ]
    [ "$(jq -r '.state' "$sf")" = "error" ]
    [ "$(jq '.findings | length' "$sf")" = "0" ]
}

@test "review-lens: a crashed claude run (non-zero exit, no output) is recorded as error" {
    _make_lens_job rl15c
    _reply reply_empty.jsonl
    export MOCK_CLAUDE_EXIT=1
    run mother review-lens rl15c --lens correctness
    [ "$status" -eq 2 ]
    local sf; sf=$(_side_file rl15c correctness)
    [ -f "$sf" ]
    [ "$(jq -r '.decision' "$sf")" = "error" ]
    [ "$(jq -r '.error_reason' "$sf")" = "exit_nonzero" ]
}

@test "review-lens: an unknown lens fails with a message and never invokes claude" {
    _make_lens_job rl16
    run mother review-lens rl16 --lens bogus
    [ "$status" -eq 1 ]
    [ -n "$output" ]
    [ ! -s "$MOCK_CLAUDE_ARGS_FILE" ]
}

@test "review-lens: a missing --lens fails with a message" {
    _make_lens_job rl17
    run mother review-lens rl17
    [ "$status" -eq 1 ]
    [ -n "$output" ]
    [ ! -s "$MOCK_CLAUDE_ARGS_FILE" ]
}

@test "review-lens: a missing job id fails with a message" {
    run mother review-lens --lens correctness
    [ "$status" -eq 1 ]
    [ -n "$output" ]
}

@test "review-lens: an unknown job id fails" {
    run mother review-lens no-such-job --lens correctness
    [ "$status" -ne 0 ]
    [ ! -s "$MOCK_CLAUDE_ARGS_FILE" ]
}

@test "review-lens: --budget-usd must be above 0 and at most 20" {
    _make_lens_job rl18
    _reply reply_clean.jsonl
    local b
    for b in 0 -1 21 abc; do
        run mother review-lens rl18 --lens correctness --budget-usd "$b"
        [ "$status" -eq 1 ] || { echo "budget $b: status $status" >&2; return 1; }
        [ -n "$output" ]
    done
    [ ! -s "$MOCK_CLAUDE_ARGS_FILE" ]
    run mother review-lens rl18 --lens correctness --budget-usd 20
    [ "$status" -eq 0 ]
}
