# findings.sh — findings extraction, validation, and loop-exit logic.
#
# Sourced by the pipeline driver (W4) and the reviewer orchestration layer (W3).
# Do not invoke directly.
#
# Implements the B3 findings wire format and B4 loop-exit rules from the SDLC
# pipeline sequencing memo (docs/prds/mother-sdlc-pipeline.md).

# ---------- findings_extract ----------

# findings_extract <file>
# Extracts the JSON array from the LAST ```findings fenced block in <file>.
# Outputs the JSON array on stdout. Outputs nothing (empty) if no block is found.
# Using the LAST block means a reviewer that quotes the schema as an example
# before emitting the real block is parsed correctly.
findings_extract() {
    local file="$1"
    [ -r "$file" ] || return 0
    python3 - "$file" <<'PYEOF'
import sys, re

with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()

# Match all ```findings ... ``` blocks (DOTALL so . spans newlines).
blocks = re.findall(r'```findings\n(.*?)```', content, re.DOTALL)
if blocks:
    # Return the LAST block so schema-quoting reviewers are handled correctly.
    print(blocks[-1].strip())
PYEOF
}

# ---------- findings_extract_examined ----------

# findings_extract_examined <file>
# Prints the JSON array from the LAST ```examined fenced block in <file>:
# the changed files a lens reviewer says it looked at. Prints [] when the
# block is absent or the file is unreadable.
findings_extract_examined() {
    local file="$1"
    if [ ! -r "$file" ]; then echo "[]"; return 0; fi
    python3 - "$file" <<'PYEOF'
import sys, re

with open(sys.argv[1], "r", encoding="utf-8") as f:
    content = f.read()

blocks = re.findall(r'```examined\n(.*?)```', content, re.DOTALL)
print(blocks[-1].strip() if blocks else "[]")
PYEOF
}

# ---------- findings_validate ----------

# findings_validate <json>
# Returns 0 if <json> is a valid findings array: each element must have
#   target   ∈ {redd, cody, marty, human}
#   severity ∈ {blocking, advisory}
# Optional fields, type-checked only when present:
#   claims                [{path: non-empty string, line: integer, quote: string <= 200 chars}]
#   asserts_existing_code boolean
# An empty array [] is valid.
# Returns non-zero and prints a diagnostic to stderr on failure.
findings_validate() {
    local json="$1"
    local errmsg
    errmsg=$(printf '%s' "$json" | jq '
        if type != "array" then
            error("findings must be a JSON array, got \(type)")
        else
            .[] |
            if (.target != "redd" and .target != "cody" and .target != "marty" and .target != "human") then
                error("invalid target: \(.target // "null") (must be one of: redd cody marty human)")
            elif (.severity != "blocking" and .severity != "advisory") then
                error("invalid severity: \(.severity // "null") (must be one of: blocking advisory)")
            elif (has("asserts_existing_code") and (.asserts_existing_code | type) != "boolean") then
                error("invalid asserts_existing_code: must be a boolean")
            elif (has("claims") and (
                    (.claims | type) != "array"
                    or (.claims | any(
                        (type != "object")
                        or ((.path | type) != "string") or (.path == "")
                        or ((.line | type) != "number") or (.line != (.line | floor))
                        or ((.quote | type) != "string") or ((.quote | length) > 200)
                    )))) then
                error("invalid claims: must be an array of {path: string, line: integer, quote: string of at most 200 chars}")
            else
                empty
            end
        end
    ' 2>&1)
    local rc=$?
    [ $rc -ne 0 ] && { echo "$errmsg" >&2; return 1; }
    return 0
}

# ---------- findings_by_target ----------

# findings_by_target <json> <target>
# Outputs the sub-array of findings whose .target matches <target>.
findings_by_target() {
    local json="$1" target="$2"
    printf '%s' "$json" | jq --arg t "$target" 'map(select(.target == $t))'
}

# ---------- findings_exit_decision ----------

# findings_exit_decision <json>
# Pure function: input JSON findings array → one of: ship | block_human | continue
#
# Implements the B4 exit rules (from docs/prds/mother-sdlc-pipeline.md):
#
#   block_human — any finding with target=human AND severity=blocking is
#                 present. This short-circuits even if agent-actionable
#                 findings are also present.
#
#   continue    — one or more findings with target ∈ {redd,cody,marty} AND
#                 no human/blocking finding. The pipeline loops: build agents
#                 named in the findings run in forward order, then re-review.
#
#   ship        — all other cases (empty array, or only human/advisory findings).
#                 human/advisory findings do NOT block the ship; they are
#                 carried forward as advisories on the PR.
findings_exit_decision() {
    local json="$1"
    printf '%s' "$json" | jq -r '
        if map(select(.target == "human" and .severity == "blocking")) | length > 0 then
            "block_human"
        elif map(select(.target == "redd" or .target == "cody" or .target == "marty")) | length > 0 then
            "continue"
        else
            "ship"
        end
    '
}
