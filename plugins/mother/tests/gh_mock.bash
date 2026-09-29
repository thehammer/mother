#!/usr/bin/env bash
# gh_mock.bash — a small, faithful stand-in for the `gh` CLI, driven by
# per-test fixture files, so tests don't have to hand-roll a `case "$*"`
# shell script for every scenario.
#
# Load after test_helper (needs $_MOCK_BIN / $MOTHER_ROOT):
#   load 'test_helper'
#   load 'gh_mock'
#
# Supported gh invocations (anything else prints nothing and exits 0):
#
#   gh pr view <url> --json <fields> [--jq|-q <expr>]
#       Prints the JSON fixture registered with gh_mock_set_pr (all fields,
#       regardless of --json), piped through `jq -r <expr>` when --jq/-q is
#       given — exactly what real gh does. Exits 1 (gh failure) when no
#       fixture is registered for <url>.
#   gh pr list --head <branch> ... [--json url]
#       Prints the JSON array registered with gh_mock_set_branch_pr, else [].
#   gh api repos/<o>/<r>/commits/<sha>/pulls
#       Prints the JSON array registered with gh_mock_set_commit_pulls, else [].
#
# Every invocation's argv is appended (space-joined) to $MOTHER_ROOT/mock-gh-calls.

gh_mock_install() {
    mkdir -p "$MOTHER_ROOT/gh/pr" "$MOTHER_ROOT/gh/pr-list" "$MOTHER_ROOT/gh/commit-pulls"
    : > "$MOTHER_ROOT/mock-gh-calls"
    cat > "$_MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
root="${MOTHER_ROOT:?}/gh"
printf '%s\n' "$*" >> "${MOTHER_ROOT}/mock-gh-calls"
_key() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }
case "${1:-} ${2:-}" in
    "pr view")
        url="${3:-}"; expr=""
        shift 3
        while [ $# -gt 0 ]; do
            case "$1" in
                --json) shift 2 ;;
                --jq|-q) expr="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        f="$root/pr/$(_key "$url").json"
        [ -f "$f" ] || exit 1
        if [ -n "$expr" ]; then jq -r "$expr" "$f"; else cat "$f"; fi
        ;;
    "pr list")
        head=""
        shift 2
        while [ $# -gt 0 ]; do
            case "$1" in
                --head) head="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        f="$root/pr-list/$(_key "$head").json"
        if [ -f "$f" ]; then cat "$f"; else echo "[]"; fi
        ;;
    "api "*)
        sha=$(printf '%s' "${2:-}" | sed -n 's|.*/commits/\([^/]*\)/pulls.*|\1|p')
        if [ -n "$sha" ] && [ -f "$root/commit-pulls/$sha.json" ]; then
            cat "$root/commit-pulls/$sha.json"
        else
            echo "[]"
        fi
        ;;
    *)
        exit 0
        ;;
esac
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"
}

_gh_mock_key() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }

# gh_mock_set_pr <url> <state> <headRefName> [commit-sha ...]
gh_mock_set_pr() {
    local url="$1" state="$2" head="$3"; shift 3
    local commits='[]' sha
    for sha in "$@"; do
        commits=$(printf '%s' "$commits" | jq -c --arg s "$sha" '. + [{oid: $s}]')
    done
    jq -nc --arg state "$state" --arg head "$head" --argjson commits "$commits" \
        '{state: $state, headRefName: $head, commits: $commits}' \
        > "$MOTHER_ROOT/gh/pr/$(_gh_mock_key "$url").json"
}

# gh_mock_set_branch_pr <branch> <url>   (`gh pr list --head <branch>` hit)
gh_mock_set_branch_pr() {
    jq -nc --arg u "$2" '[{url: $u}]' \
        > "$MOTHER_ROOT/gh/pr-list/$(_gh_mock_key "$1").json"
}

# gh_mock_set_commit_pulls <sha> <url> <open|closed>
gh_mock_set_commit_pulls() {
    jq -nc --arg u "$2" --arg s "$3" \
        '[{state: $s, updated_at: "2026-09-01T00:00:00Z", html_url: $u}]' \
        > "$MOTHER_ROOT/gh/commit-pulls/$1.json"
}

# gh_mock_calls — print the recorded call log.
gh_mock_calls() { cat "$MOTHER_ROOT/mock-gh-calls" 2>/dev/null || true; }
