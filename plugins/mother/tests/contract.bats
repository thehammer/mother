#!/usr/bin/env bats
# Headless-crew client contract: the provisional fixtures must satisfy
# scripts/contract-check.sh, and the checker must reject drift (unknown event
# kind, missing required detail key, forbidden free-text key).

setup() {
    PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CHECK="$PLUGIN/scripts/contract-check.sh"
    FIX="$PLUGIN/tests/fixtures/contract"
    WORK="$(mktemp -d)"
}

teardown() {
    rm -rf "$WORK"
}

@test "gates_fix_pass fixture satisfies the contract" {
    run "$CHECK" "$FIX/gates_fix_pass.ndjson"
    [ "$status" -eq 0 ]
}

@test "lens_wave fixture satisfies the contract" {
    run "$CHECK" "$FIX/lens_wave.ndjson"
    [ "$status" -eq 0 ]
}

@test "gate_hold_answered fixture satisfies the contract" {
    run "$CHECK" "$FIX/gate_hold_answered.ndjson"
    [ "$status" -eq 0 ]
}

@test "checker reads an NDJSON stream from stdin" {
    run bash -c "'$CHECK' < '$FIX/lens_wave.ndjson'"
    [ "$status" -eq 0 ]
}

@test "checker accepts several files and fails if any is bad" {
    echo 'not json' > "$WORK/bad.ndjson"
    run "$CHECK" "$FIX/lens_wave.ndjson" "$WORK/bad.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad.ndjson:1:"* ]]
}

@test "unknown event kind fails and names file:line" {
    # Rename the lens_skipped event (line 2) to a kind the contract does not list.
    jq -c 'if .t == "lens_skipped" then .t = "lens_vanished" else . end' \
        "$FIX/lens_wave.ndjson" > "$WORK/unknown.ndjson"
    n=$(grep -n lens_vanished "$WORK/unknown.ndjson" | head -1 | cut -d: -f1)
    run "$CHECK" "$WORK/unknown.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown.ndjson:$n:"* ]]
    [[ "$output" == *"lens_vanished"* ]]
}

@test "missing required detail key fails and names file:line" {
    jq -c 'if .t == "gate_result" and .data.name == "lint" then del(.data.exit_code) else . end' \
        "$FIX/gates_fix_pass.ndjson" > "$WORK/missing.ndjson"
    n=$(grep -n '"gate_result"' "$WORK/missing.ndjson" | grep -v exit_code | head -1 | cut -d: -f1)
    [ -n "$n" ]
    run "$CHECK" "$WORK/missing.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing.ndjson:$n:"* ]]
    [[ "$output" == *"exit_code"* ]]
}

@test "forbidden free-text key in a new-kind detail fails and names file:line" {
    jq -c 'if .t == "gates_exhausted" then .data.excerpt = "FAIL: something leaked" else . end' \
        "$FIX/gate_hold_answered.ndjson" > "$WORK/leak.ndjson"
    n=$(grep -n excerpt "$WORK/leak.ndjson" | head -1 | cut -d: -f1)
    [ -n "$n" ]
    run "$CHECK" "$WORK/leak.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"leak.ndjson:$n:"* ]]
    [[ "$output" == *"excerpt"* ]]
}

@test "forbidden key nested in a new job key fails" {
    jq -c 'if .t == "snapshot" then .data.jobs[0].gates.summary = "lint failed" else . end' \
        "$FIX/gates_fix_pass.ndjson" > "$WORK/jobleak.ndjson"
    run "$CHECK" "$WORK/jobleak.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"jobleak.ndjson:"*"summary"* ]]
}

@test "text is allowed on the answer cmd but nowhere else" {
    run bash -c "grep -c '\"text\"' '$FIX/gate_hold_answered.ndjson'"
    [ "$output" -ge 1 ]
    jq -c 'if .t == "decision_resolved" then .data.text = "x" else . end' \
        "$FIX/gate_hold_answered.ndjson" > "$WORK/text.ndjson"
    run "$CHECK" "$WORK/text.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"text"* ]]
}

@test "fixture job records keep Nostromo's decoded keys and ISO-8601 millisecond Z timestamps" {
    for f in gates_fix_pass lens_wave gate_hold_answered; do
        run jq -e -s '
            [ .[] | select(.t == "snapshot") | .data.jobs[] ] as $jobs
            | ($jobs | length) > 0
            and ($jobs | all(
                has("id") and has("state") and has("repo") and has("isolation") and has("title")
                and has("created_at") and has("started_at") and has("finished_at")
                and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\\.[0-9]{3}Z$"))
            ))' "$FIX/$f.ndjson"
        [ "$status" -eq 0 ]
    done
}
