#!/usr/bin/env bats
# findings.bats — tests for plugins/mother/lib/findings.sh
#
# The lib does not exist yet. All tests here should FAIL until the lib is
# implemented. They define the behavioral contract for findings extraction,
# validation, filtering, and exit-decision logic.

load 'test_helper'

_LIB="$_LIB_DIR/findings.sh"

setup() {
    setup_mother_env
    export FINDINGS_TMP="$MOTHER_ROOT/findings-tmp"
    mkdir -p "$FINDINGS_TMP"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers — build test fixtures

_valid_findings_block() {
    # Emit text containing a ```findings block with a well-formed JSON array.
    cat <<'TEXT'
Here is my review of the diff.

```findings
[
  {"target": "cody", "severity": "blocking", "note": "Missing error handling"},
  {"target": "redd", "severity": "advisory", "note": "Add edge-case coverage"}
]
```
TEXT
}

_empty_findings_block() {
    cat <<'TEXT'
Looks good to me.

```findings
[]
```
TEXT
}

_no_findings_block() {
    cat <<'TEXT'
The diff looks fine. No issues to note.
TEXT
}

_multi_findings_blocks() {
    # Simulates a reviewer quoting the schema, then emitting the real block.
    cat <<'TEXT'
Schema reminder:
```findings
[{"target": "cody", "severity": "blocking", "note": "Schema example — ignore this"}]
```

After reviewing the diff, here are the actual findings:

```findings
[
  {"target": "human", "severity": "blocking", "note": "Needs product sign-off"}
]
```
TEXT
}

# ---------------------------------------------------------------------------
# findings_extract — from text passed as a file

@test "findings_extract: returns valid JSON from text with a findings block" {
    local f="$FINDINGS_TMP/input.txt"
    _valid_findings_block > "$f"

    run bash -c "source '$_LIB' && findings_extract '$f'"
    [ "$status" -eq 0 ]
    # Output must be valid JSON
    echo "$output" | jq . > /dev/null
}

@test "findings_extract: returns empty when no findings block is present" {
    local f="$FINDINGS_TMP/input.txt"
    _no_findings_block > "$f"

    run bash -c "source '$_LIB' && findings_extract '$f'"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "findings_extract: returns LAST block when multiple findings blocks present" {
    local f="$FINDINGS_TMP/input.txt"
    _multi_findings_blocks > "$f"

    run bash -c "source '$_LIB' && findings_extract '$f'"
    [ "$status" -eq 0 ]
    # The last block has target=human; verify it's the one returned
    local target
    target=$(echo "$output" | jq -r '.[0].target')
    [ "$target" = "human" ]
}

# ---------------------------------------------------------------------------
# findings_validate — accepts well-formed input

@test "findings_validate: accepts a valid array with known targets and severities" {
    local json='[{"target":"cody","severity":"blocking","note":"foo"},{"target":"redd","severity":"advisory","note":"bar"}]'
    run bash -c "source '$_LIB' && findings_validate '$json'"
    [ "$status" -eq 0 ]
}

@test "findings_validate: accepts an empty array" {
    run bash -c "source '$_LIB' && findings_validate '[]'"
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# findings_validate — rejects invalid input

@test "findings_validate: rejects target outside enum" {
    local json='[{"target":"foo","severity":"blocking","note":"bad target"}]'
    run bash -c "source '$_LIB' && findings_validate '$json'"
    [ "$status" -ne 0 ]
}

@test "findings_validate: rejects severity outside enum" {
    local json='[{"target":"cody","severity":"warn","note":"bad severity"}]'
    run bash -c "source '$_LIB' && findings_validate '$json'"
    [ "$status" -ne 0 ]
}

@test "findings_validate: rejects non-array JSON" {
    local json='{"target":"cody","severity":"blocking","note":"not an array"}'
    run bash -c "source '$_LIB' && findings_validate '$json'"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# findings_by_target — filter by target

@test "findings_by_target: returns only findings for the requested target" {
    local json='[{"target":"cody","severity":"blocking","note":"cody issue"},{"target":"redd","severity":"advisory","note":"redd issue"},{"target":"cody","severity":"advisory","note":"another cody"}]'

    run bash -c "source '$_LIB' && findings_by_target '$json' cody"
    [ "$status" -eq 0 ]

    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 2 ]

    local target
    target=$(echo "$output" | jq -r '.[0].target')
    [ "$target" = "cody" ]
}

@test "findings_by_target: returns empty array when no findings match target" {
    local json='[{"target":"cody","severity":"blocking","note":"cody issue"}]'

    run bash -c "source '$_LIB' && findings_by_target '$json' marty"
    [ "$status" -eq 0 ]

    local count
    count=$(echo "$output" | jq 'length')
    [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# findings_exit_decision — ship cases

@test "findings_exit_decision: empty array returns ship" {
    run bash -c "source '$_LIB' && findings_exit_decision '[]'"
    [ "$status" -eq 0 ]
    [ "$output" = "ship" ]
}

@test "findings_exit_decision: only human/advisory findings returns ship" {
    local json='[{"target":"human","severity":"advisory","note":"nice to have"}]'
    run bash -c "source '$_LIB' && findings_exit_decision '$json'"
    [ "$status" -eq 0 ]
    [ "$output" = "ship" ]
}

@test "findings_exit_decision: multiple human/advisory findings returns ship" {
    local json='[{"target":"human","severity":"advisory","note":"fyi 1"},{"target":"human","severity":"advisory","note":"fyi 2"}]'
    run bash -c "source '$_LIB' && findings_exit_decision '$json'"
    [ "$status" -eq 0 ]
    [ "$output" = "ship" ]
}

# ---------------------------------------------------------------------------
# findings_exit_decision — block_human cases

@test "findings_exit_decision: human/blocking finding alone returns block_human" {
    local json='[{"target":"human","severity":"blocking","note":"needs sign-off"}]'
    run bash -c "source '$_LIB' && findings_exit_decision '$json'"
    [ "$status" -eq 0 ]
    [ "$output" = "block_human" ]
}

@test "findings_exit_decision: human/blocking finding with agent findings returns block_human" {
    # human/blocking wins even when agent-actionable findings are also present
    local json='[{"target":"human","severity":"blocking","note":"needs sign-off"},{"target":"cody","severity":"blocking","note":"fix this too"}]'
    run bash -c "source '$_LIB' && findings_exit_decision '$json'"
    [ "$status" -eq 0 ]
    [ "$output" = "block_human" ]
}

# ---------------------------------------------------------------------------
# findings_exit_decision — continue cases

@test "findings_exit_decision: only agent-actionable/blocking findings returns continue" {
    # cody/blocking — actionable but not human-blocking
    local json='[{"target":"cody","severity":"blocking","note":"fix this"}]'
    run bash -c "source '$_LIB' && findings_exit_decision '$json'"
    [ "$status" -eq 0 ]
    [ "$output" = "continue" ]
}

@test "findings_exit_decision: agent-actionable findings plus human/advisory returns continue" {
    # human advisory does not block; agent findings trigger continue
    local json='[{"target":"redd","severity":"blocking","note":"missing test"},{"target":"human","severity":"advisory","note":"fyi"}]'
    run bash -c "source '$_LIB' && findings_exit_decision '$json'"
    [ "$status" -eq 0 ]
    [ "$output" = "continue" ]
}

# ---------------------------------------------------------------------------
# HC-12: findings_extract_examined — the optional ```examined block

@test "findings_extract_examined: returns the JSON array from an examined block" {
    local f="$FINDINGS_TMP/in.txt"
    printf 'ok\n\n```findings\n[]\n```\n\n```examined\n["a.php", "b/c.tf"]\n```\n' > "$f"
    run bash -c "source '$_LIB' && findings_extract_examined '$f'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '["a.php","b/c.tf"]' ]
}

@test "findings_extract_examined: returns the LAST examined block when several are present" {
    local f="$FINDINGS_TMP/in.txt"
    printf '```examined\n["quoted-schema.txt"]\n```\n\nreal:\n\n```examined\n["real.php"]\n```\n' > "$f"
    run bash -c "source '$_LIB' && findings_extract_examined '$f'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '["real.php"]' ]
}

@test "findings_extract_examined: prints [] when there is no examined block" {
    local f="$FINDINGS_TMP/in.txt"
    _valid_findings_block > "$f"
    run bash -c "source '$_LIB' && findings_extract_examined '$f'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '[]' ]
}

@test "findings_extract_examined: prints [] for an unreadable or missing file" {
    run bash -c "source '$_LIB' && findings_extract_examined '$FINDINGS_TMP/does-not-exist'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '[]' ]
}

@test "findings_extract_examined: a findings block is not mistaken for an examined block" {
    local f="$FINDINGS_TMP/in.txt"
    printf '```findings\n[{"target":"cody","severity":"advisory"}]\n```\n' > "$f"
    run bash -c "source '$_LIB' && findings_extract_examined '$f'"
    [ "$(printf '%s' "$output" | jq -c .)" = '[]' ]
}

@test "findings_extract still returns the findings block when an examined block follows it" {
    local f="$FINDINGS_TMP/in.txt"
    printf '```findings\n[{"target":"human","severity":"advisory","note":"x"}]\n```\n\n```examined\n["a"]\n```\n' > "$f"
    run bash -c "source '$_LIB' && findings_extract '$f'"
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.[0].target')" = "human" ]
}

# ---------------------------------------------------------------------------
# HC-12: findings_validate — optional claims / asserts_existing_code

_validate() { bash -c "source '$_LIB' && findings_validate \"\$1\"" _ "$1"; }

_with_field() { # <jq-object-fragment> — one valid finding plus extra fields
    jq -nc "[{target:\"cody\", severity:\"blocking\", summary:\"s\"} + $1]"
}

@test "findings_validate: a finding with no claims stays valid" {
    run _validate '[{"target":"cody","severity":"blocking","summary":"s"}]'
    [ "$status" -eq 0 ]
}

@test "findings_validate: accepts a well-formed claims array" {
    run _validate "$(_with_field '{claims:[{path:"app/Foo.php", line:3, quote:"if ($x) {"}]}')"
    [ "$status" -eq 0 ]
}

@test "findings_validate: accepts an empty claims array" {
    run _validate "$(_with_field '{claims:[]}')"
    [ "$status" -eq 0 ]
}

@test "findings_validate: accepts a quote of exactly 200 characters" {
    local q; q=$(head -c 200 /dev/zero | tr '\0' q)
    run _validate "$(_with_field "{claims:[{path:\"a\", line:1, quote:\"$q\"}]}")"
    [ "$status" -eq 0 ]
}

@test "findings_validate: rejects a quote longer than 200 characters" {
    local q; q=$(head -c 201 /dev/zero | tr '\0' q)
    run _validate "$(_with_field "{claims:[{path:\"a\", line:1, quote:\"$q\"}]}")"
    [ "$status" -ne 0 ]
}

@test "findings_validate: rejects claims that is not an array" {
    run _validate "$(_with_field '{claims:{path:"a", line:1, quote:"q"}}')"
    [ "$status" -ne 0 ]
}

@test "findings_validate: rejects a claim that is not an object" {
    run _validate "$(_with_field '{claims:["app/Foo.php:3"]}')"
    [ "$status" -ne 0 ]
}

@test "findings_validate: rejects a claim with an empty or missing path" {
    run _validate "$(_with_field '{claims:[{path:"", line:1, quote:"q"}]}')"
    [ "$status" -ne 0 ]
    run _validate "$(_with_field '{claims:[{line:1, quote:"q"}]}')"
    [ "$status" -ne 0 ]
}

@test "findings_validate: rejects a claim with a non-integer or missing line" {
    run _validate "$(_with_field '{claims:[{path:"a", line:"3", quote:"q"}]}')"
    [ "$status" -ne 0 ]
    run _validate "$(_with_field '{claims:[{path:"a", line:1.5, quote:"q"}]}')"
    [ "$status" -ne 0 ]
    run _validate "$(_with_field '{claims:[{path:"a", quote:"q"}]}')"
    [ "$status" -ne 0 ]
}

@test "findings_validate: rejects a claim with a non-string or missing quote" {
    run _validate "$(_with_field '{claims:[{path:"a", line:1, quote:7}]}')"
    [ "$status" -ne 0 ]
    run _validate "$(_with_field '{claims:[{path:"a", line:1}]}')"
    [ "$status" -ne 0 ]
}

@test "findings_validate: one malformed claim among valid findings fails the whole array" {
    local good bad
    good='{"target":"redd","severity":"advisory","summary":"ok"}'
    bad='{"target":"cody","severity":"blocking","summary":"s","claims":[{"path":"","line":1,"quote":"q"}]}'
    run _validate "[$good, $bad]"
    [ "$status" -ne 0 ]
}

@test "findings_validate: asserts_existing_code accepts true and false" {
    run _validate "$(_with_field '{asserts_existing_code:true}')"
    [ "$status" -eq 0 ]
    run _validate "$(_with_field '{asserts_existing_code:false}')"
    [ "$status" -eq 0 ]
}

@test "findings_validate: asserts_existing_code must be boolean" {
    run _validate "$(_with_field '{asserts_existing_code:"yes"}')"
    [ "$status" -ne 0 ]
    run _validate "$(_with_field '{asserts_existing_code:1}')"
    [ "$status" -ne 0 ]
}

@test "findings_validate: pre-existing rejections are unchanged when claims are present" {
    run _validate "$(jq -nc '[{target:"foo", severity:"blocking", claims:[{path:"a", line:1, quote:"q"}]}]')"
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# HC-12: the reviewer prompt documents the optional fields

@test "findings-prompt documents claims, asserts_existing_code and the examined block as optional" {
    local f="$_PLUGIN_DIR/templates/findings-prompt.md"
    grep -q 'claims' "$f"
    grep -q 'asserts_existing_code' "$f"
    grep -q 'examined' "$f"
    grep -qi 'optional' "$f"
}
