#!/usr/bin/env bash
# lib/prbody.sh — Mother-owned blocks inside a PR body, written idempotently.
#
# A block is the text between `<!-- mother:<name> -->` and
# `<!-- /mother:<name> -->` (markers on their own lines). Rewriting a block
# replaces it in place; text outside the markers is never touched. HC-08 writes
# the `gates` block; HC-14 reuses the same writer for the review block.
#
# PR bodies go to GitHub: never put gate output (excerpts, logs) in a block.
# Sourced under `set -u`, bash 3.2. Functions return non-zero on gh failure and
# never `exit`.

# _prbody_compose <body-file> <name> <block-file> — prints the new body: the
# existing body with the named block replaced (first occurrence) or appended.
_prbody_compose() {
    local body_file="$1" name="$2" block_file="$3"
    awk -v op="<!-- mother:$name -->" -v cl="<!-- /mother:$name -->" -v blockf="$block_file" '
        function emit(   l) {
            print op
            while ((getline l < blockf) > 0) print l
            close(blockf)
            print cl
        }
        { line = $0; sub(/[ \t\r]+$/, "", line) }
        line == op { if (!done) { emit(); done = 1 }; skip = 1; nheld = 0; next }
        skip && line == cl { skip = 0; next }
        skip { held[++nheld] = $0; next }
        { print; n++ }
        END {
            # An opening marker with no closing one: keep what followed it.
            if (skip) for (i = 1; i <= nheld; i++) print held[i]
            if (!done) { if (n > 0) print ""; emit() }
        }
    ' "$body_file"
}

# mother_prbody_upsert <pr-url> <name> <block-file>
# Reads the PR body (`gh pr view --json body`), replaces or appends the named
# block with the contents of <block-file>, and writes it back with
# `gh pr edit --body-file`.
mother_prbody_upsert() {
    local url="$1" name="$2" block_file="$3" tmp_body tmp_new rc=0
    command -v gh >/dev/null 2>&1 || return 1
    tmp_body=$(mktemp "${TMPDIR:-/tmp}/mother-prbody.XXXXXX") || return 1
    tmp_new=$(mktemp "${TMPDIR:-/tmp}/mother-prbody-new.XXXXXX") || { rm -f "$tmp_body"; return 1; }
    if gh pr view "$url" --json body --jq '.body // ""' >"$tmp_body" 2>/dev/null \
        && _prbody_compose "$tmp_body" "$name" "$block_file" >"$tmp_new" \
        && gh pr edit "$url" --body-file "$tmp_new" >/dev/null 2>&1; then
        rc=0
    else
        rc=1
    fi
    rm -f "$tmp_body" "$tmp_new"
    return "$rc"
}

# mother_prbody_gates_block <gates-json> — prints the markdown body of the
# `gates` block from a job's `.gates` object: an incomplete or override line
# first, then one row per gate (name and result only).
mother_prbody_gates_block() {
    printf '%s' "$1" | jq -r '
        . as $g
        | ([($g.results // [])[] | select(.result == "unavailable") | .name]) as $nr
        | "### Mother quality gates",
          "",
          (if $g.status == "incomplete" then "**Gates incomplete: \($nr | join(", ")) did not run**", "" else empty end),
          (if $g.override != null then
              "**Opened with red gates (operator override): \(($g.override.red // []) | join(", "))**", ""
           else empty end),
          "| Gate | Result |",
          "|---|---|",
          (($g.results // [])[] |
              "| `\(.name)` | \(.result)"
              + (if .result == "unavailable" and .unavailable_reason != null then " (\(.unavailable_reason))"
                 elif .result == "skipped" and .skip_reason != null then " (\(.skip_reason))"
                 elif .result == "failed" and .blocking == false then " (advisory)"
                 else "" end)
              + " |"),
          "",
          "_Attempt \($g.attempt // 1)/\($g.max_attempts // "?") on `\(($g.head_sha // "") | .[0:7])`, posture \($g.posture // "normal")._"'
}

# mother_prbody_write_gates <pr-url> <gates-json> — renders the `gates` block
# from a job's `.gates` object and upserts it into the PR body.
mother_prbody_write_gates() {
    local url="$1" block_file rc
    block_file=$(mktemp "${TMPDIR:-/tmp}/mother-gates-block.XXXXXX") || return 1
    mother_prbody_gates_block "$2" >"$block_file" 2>/dev/null
    mother_prbody_upsert "$url" gates "$block_file"
    rc=$?
    rm -f "$block_file"
    return "$rc"
}
