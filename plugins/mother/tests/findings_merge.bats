#!/usr/bin/env bats
# findings_merge.bats — HC-13: merge a lens wave (attribution, dedup, conflicts,
# coverage gaps, mechanical claim verification) and its status rendering.
#
# Fixtures: tests/fixtures/wave/{correctness,tests,ops-infra}.json copied into a
# job's wave dir; a temp git repo whose src/C.php has `catch (\Throwable $e)` on line 5.

bats_require_minimum_version 1.5.0
load 'test_helper'

FIX="$BATS_TEST_DIRNAME/fixtures/wave"
MERGE_PY="$_LIB_DIR/findings_merge.py"

setup() {
    setup_mother_env
    unset MOTHER_CLAIM_VERIFY_ENABLED
    REPO="$MOTHER_ROOT/work/waverepo"
    mkdir -p "$REPO/src"
    (
        cd "$REPO"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "t@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        git add . && git commit -q -m init
        git checkout -q -b feature/x
        seq 1 20 | sed 's/^/line /' > src/A.php
        printf 'echo 1;\n\n\n}\n    catch (\\Throwable   $e) {\n}\n' > src/C.php
        seq 1 5 > src/B.php
        git add . && git commit -q -m work
    ) >/dev/null 2>&1
    SHA=$(git -C "$REPO" rev-parse HEAD)

    ID="job-wave1"
    make_pipeline_job "$ID" "cody"
    jq --arg w "$REPO" '.work_dir = $w | .base_ref = "main"' "$JOBS_DIR/$ID.json" > "$JOBS_DIR/$ID.tmp"
    mv "$JOBS_DIR/$ID.tmp" "$JOBS_DIR/$ID.json"
    WAVE="$MOTHER_ROOT/crew/$ID/wave/c0"
    mkdir -p "$WAVE"
    cp "$FIX"/*.json "$WAVE/"
}

teardown() { teardown_mother_env; }

_merge() { mother merge-findings "$ID" --wave "$ID" --cycle 0; }
_m() { jq -r "$1" "$WAVE/merged.json"; }
_only_lens() { # keep one lens file
    find "$WAVE" -name '*.json' ! -name "$1.json" -delete
}
_set_findings() { # <lens> <findings-json> [examined-json]
    printf '{"findings":%s,"examined":%s,"cost_usd":0,"decision":"continue"}' "$2" "${3:-[\"src/A.php\"]}" > "$WAVE/$1.json"
}

@test "dedup: same path, overlapping lines, same target -> one finding tagged with both lenses" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '[.findings[] | select(.lenses == ["correctness","tests"])] | length')" = "1" ]
    [ "$(_m '.findings[] | select(.lenses == ["correctness","tests"]) | .severity')" = "blocking" ]
    [ "$(_m '.findings[] | select(.lenses == ["correctness","tests"]) | .merged_from | length')" = "2" ]
}

@test "attribution: every finding keeps its lens(es)" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '[.findings[] | select(.kind != "coverage_gap") | select((.lenses | length) == 0)] | length')" = "0" ]
    [ "$(_m '.findings[] | select(.id != null and .lenses == ["ops-infra"] and .target == "human") | .lenses[0]')" = "ops-infra" ]
}

@test "conflict: same location, different target -> both marked and cross-referenced" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '[.findings[] | select(.conflict == true)] | length')" = "2" ]
    local human cody
    human=$(_m '.findings[] | select(.target == "human" and .kind != "coverage_gap") | .id')
    cody=$(_m '.findings[] | select(.lenses == ["correctness","tests"]) | .id')
    [ "$(_m ".findings[] | select(.id == \"$human\") | .conflicts_with[0]")" = "$cody" ]
    [ "$(_m ".findings[] | select(.id == \"$cody\") | .conflicts_with[0]")" = "$human" ]
}

@test "dedup: findings on the same lines with different targets are NOT merged" {
    _only_lens correctness
    _set_findings correctness '[
      {"id":"a","target":"cody","severity":"advisory","summary":"x","location":"src/A.php:10-12","lens":"correctness"},
      {"id":"b","target":"human","severity":"advisory","summary":"y","location":"src/A.php:10-12","lens":"correctness"}]'
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.findings | map(select(.kind != "coverage_gap")) | length')" = "2" ]
}

@test "dedup: ranges within 3 lines merge, 4 lines apart do not" {
    _only_lens correctness
    _set_findings correctness '[
      {"id":"a","target":"cody","severity":"advisory","summary":"x","location":"src/A.php:5-6","lens":"correctness"},
      {"id":"b","target":"cody","severity":"advisory","summary":"y","location":"src/A.php:9","lens":"correctness"},
      {"id":"c","target":"cody","severity":"advisory","summary":"z","location":"src/A.php:14","lens":"correctness"}]' '["src/A.php","src/B.php","src/C.php"]'
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.findings | length')" = "2" ]
}

@test "coverage: a changed file no lens examined becomes an advisory coverage_gap" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.coverage_gaps | length')" = "1" ]
    [ "$(_m '.coverage_gaps[0].location')" = "src/B.php" ]
    [ "$(_m '.coverage_gaps[0] | [.id, .target, .severity, .kind] | join(",")')" = "cov-1,human,advisory,coverage_gap" ]
    [ "$(_m '[.actionable[] | select(.kind == "coverage_gap")] | length')" = "1" ]
}

@test "claims: quote at the cited line is verified (whitespace-normalised)" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.findings[] | select(.location == "src/C.php:5") | .verification')" = "verified" ]
    [ "$(_m '[.actionable[] | select(.location == "src/C.php:5")] | .[0].severity')" = "blocking" ]
}

@test "claims: missing file or absent quote is refuted, kept in refuted, excluded from actionable" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.refuted | length')" = "1" ]
    [ "$(_m '.refuted[0].location')" = "src/Gone.php:1" ]
    [ "$(_m '[.actionable[] | select(.verification == "refuted")] | length')" = "0" ]
    [ "$(_m '.findings[] | select(.location == "src/Gone.php:1") | .verification')" = "refuted" ]
    # worker-facing output never contains it
    [[ "$output" != *"missing file claim"* ]]

    _only_lens correctness
    _set_findings correctness '[{"id":"a","target":"cody","severity":"blocking","summary":"x","location":"src/C.php:5","lens":"correctness",
      "claims":[{"path":"src/C.php","line":5,"quote":"catch (Exception $e)"}]}]'
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.refuted | length')" = "1" ]
    [ "$(_m '.actionable | map(select(.kind != "coverage_gap")) | length')" = "0" ]
}

@test "claims: quote found only far from the cited line is unverified and downgraded to advisory" {
    _only_lens correctness
    _set_findings correctness '[{"id":"a","target":"cody","severity":"blocking","summary":"x","location":"src/A.php:2","lens":"correctness",
      "claims":[{"path":"src/A.php","line":2,"quote":"line 18"}]}]'
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.findings[0].verification')" = "unverified" ]
    [ "$(_m '.findings[0].severity')" = "blocking" ]
    [ "$(_m '.actionable[0].severity')" = "advisory" ]
    [ "$(_m '.refuted | length')" = "0" ]
}

@test "claims: asserts_existing_code with no claims is unverified and advisory" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.findings[] | select(.summary == "no claim given") | .verification')" = "unverified" ]
    [ "$(_m '.actionable[] | select(.summary == "no claim given") | .severity')" = "advisory" ]
}

@test "claims: a finding with no claims and no assertion flag is not asserting" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.findings[] | select(.lenses == ["correctness","tests"]) | .verification')" = "none" ]
    [ "$(_m '.actionable[] | select(.lenses == ["correctness","tests"]) | .severity')" = "blocking" ]
}

@test "MOTHER_CLAIM_VERIFY_ENABLED=0: every claim is unverified, asserting findings advisory" {
    MOTHER_CLAIM_VERIFY_ENABLED=0 run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.claims.verified')" = "0" ]
    [ "$(_m '.claims.refuted')" = "0" ]
    [ "$(_m '.refuted | length')" = "0" ]
    [ "$(_m '.findings[] | select(.location == "src/C.php:5") | .verification')" = "unverified" ]
    [ "$(_m '.actionable[] | select(.location == "src/C.php:5") | .severity')" = "advisory" ]
}

@test "summary.json and the claims_verified event carry counts only" {
    run _merge; [ "$status" -eq 0 ]
    jq -e '.findings | type == "number"' "$WAVE/summary.json" >/dev/null
    jq -e '(.claims | keys) == ["refuted","unverified","verified"]' "$WAVE/summary.json" >/dev/null
    ! grep -q -e 'Gone' -e 'Throwable' -e 'src/' -e 'off by one' "$WAVE/summary.json"
    local ev; ev=$(jq -c 'select(.event == "claims_verified" or .kind == "claims_verified")' "$EVENTS_DIR/$ID.jsonl" | tail -n 1)
    [ -n "$ev" ]
    ! printf '%s' "$ev" | grep -q -e 'Gone' -e 'Throwable' -e 'src/' -e 'off by one'
    [ "$(printf '%s' "$ev" | jq '[.. | numbers] | length')" -ge 3 ]
}

@test "merge-findings --wave prints the actionable list (no refuted)" {
    run --separate-stderr _merge; [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq 'length')" = "$(_m '.actionable | length')" ]
    [ "$(printf '%s' "$output" | jq '[.[] | select(.verification == "refuted")] | length')" = "0" ]
}

@test "merge-findings without --wave is the unchanged pipeline merge" {
    local merged
    merged=$(jq '.pipeline.reviewer_findings = {
        "ada": [{"id":"f1","target":"cody","severity":"blocking","summary":"A","reviewer":"ada"}],
        "archie": [{"id":"f1","target":"redd","severity":"advisory","summary":"B","reviewer":"archie"}]}' "$JOBS_DIR/$ID.json")
    printf '%s' "$merged" > "$JOBS_DIR/$ID.json"
    run mother merge-findings "$ID"
    [ "$status" -eq 0 ]
    local expected
    expected=$(jq '[ .pipeline.reviewer_findings | to_entries | sort_by(.key) | .[].value[] ]
        | to_entries | map(.value + {id: ("f" + ((.key + 1) | tostring))})' "$JOBS_DIR/$ID.json")
    [ "$output" = "$expected" ]
    [ ! -f "$WAVE/merged.json" ]
}

@test "status renderer: lenses, severity, target, CONFLICT, claim lines, refuted and gaps" {
    run _merge; [ "$status" -eq 0 ]
    run mother status "$ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"=== review findings ==="* ]]
    [[ "$output" == *"[correctness,tests] blocking -> cody"* ]]
    [[ "$output" == *"CONFLICT"* ]]
    [[ "$output" == *"citation found"* ]]
    [[ "$output" == *"citation REFUTED (not in file)"* ]]
    [[ "$output" == *"citation not verified"* ]]
    [[ "$output" == *"Refuted (not sent to worker)"* ]]
    [[ "$output" == *"Coverage gaps"* ]]
    [[ "$output" == *"src/B.php"* ]]
    [[ "$output" != *"verified correct"* ]]
}

@test "findings_merge.py: usage error exits 2; missing wave dir exits 1" {
    run python3 "$MERGE_PY"
    [ "$status" -eq 2 ]
    echo '[]' > "$MOTHER_ROOT/ch.json"
    run python3 "$MERGE_PY" merge "$MOTHER_ROOT/nope" "$REPO" "$SHA" "$MOTHER_ROOT/ch.json"
    [ "$status" -eq 1 ]
}

@test "claims: one lens's refuted claim does not remove another lens's merged finding" {
    _only_lens correctness
    _set_findings correctness '[
      {"id":"a","target":"cody","severity":"blocking","summary":"x","location":"src/C.php:5","lens":"correctness",
       "claims":[{"path":"src/C.php","line":5,"quote":"catch (Exception $e)"}]},
      {"id":"b","target":"cody","severity":"blocking","summary":"y","location":"src/C.php:5","lens":"tests"}]'
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.refuted | length')" = "0" ]
    [ "$(_m '.actionable | map(select(.kind != "coverage_gap")) | .[0].severity')" = "blocking" ]
}

@test "lens errors: an errored lens is surfaced even when other lenses covered its files" {
    _only_lens correctness
    printf '{"findings":[],"examined":[],"cost_usd":null,"decision":"error","state":"error","error_reason":"exit_nonzero"}' > "$WAVE/phi-security.json"
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '[.findings[] | select(.kind == "lens_error")] | length')" = "1" ]
    [ "$(_m '.findings[] | select(.kind == "lens_error") | .lenses[0]')" = "phi-security" ]
    [ "$(_m '.findings[] | select(.kind == "lens_error") | .severity')" = "blocking" ]
    [ "$(_m '.findings[] | select(.kind == "lens_error") | .target')" = "human" ]
    [ "$(_m '.lens_errors | length')" = "1" ]
    [ "$(jq -r '.lens_errors' "$WAVE/summary.json")" = "1" ]
    run mother status "$ID"
    [[ "$output" == *"phi-security"* ]]
    [[ "$output" == *"did not complete"* ]]
}

@test "lens errors: an unreadable side file is surfaced, not silently skipped" {
    _only_lens correctness
    printf '{not json' > "$WAVE/tests.json"
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.lens_errors | map(.lens) | index("tests") != null')" = "true" ]
    [ "$(_m '.lens_errors[] | select(.lens == "tests") | .reason')" = "unreadable" ]
}

@test "lens errors: a clean wave reports zero lens errors" {
    run _merge; [ "$status" -eq 0 ]
    [ "$(_m '.lens_errors | length')" = "0" ]
    [ "$(jq -r '.lens_errors' "$WAVE/summary.json")" = "0" ]
}
