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
