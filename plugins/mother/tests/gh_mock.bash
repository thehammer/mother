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
#   gh pr ready <url> [--undo]
#       Flips the fixture's isDraft: false for `pr ready`, true for `--undo`.
#       Exits 1 when no fixture is registered (or when GH_MOCK_FAIL_DRAFT=1).
#   gh pr edit <url> --body-file <path>
#       Replaces the fixture's `.body` with the file's content AND saves a copy
#       at $MOTHER_ROOT/gh/last-body-<key>.md (gh_mock_last_body prints it) so a
#       test can read the body that was written. Exits 1 when no fixture.
#   gh pr list --head <branch> ... [--json url]
#       Prints the JSON array registered with gh_mock_set_branch_pr, else [].
#   gh api repos/<o>/<r>/commits/<sha>/pulls
#       Prints the JSON array registered with gh_mock_set_commit_pulls, else [].
#   gh api repos/<o>/<r>/commits/<sha>/check-runs
#       Prints the {"check_runs": [...]} registered with gh_mock_set_check_runs,
#       else {"check_runs": []}.
#   gh pr checks <url> --json name,state,bucket
#       Prints the JSON array registered with gh_mock_set_pr_checks, else [].
#
# PR fixtures are STATEFUL: `pr ready` / `pr edit` mutate the fixture file, so a
# later `pr view --json isDraft,body` reflects what Mother did. New fixtures
# default to isDraft=false, body="".
#
# Failure knob: GH_MOCK_FAIL_DRAFT=1 makes `pr view ... --json <fields incl.
# isDraft>` and `pr ready` exit 1 (a gh outage that only affects draft handling;
# PR detection via `--json state,headRefName` keeps working).
#
# Every invocation's argv is appended (space-joined) to $MOTHER_ROOT/mock-gh-calls.
#
# Fixture helpers (call from tests):
#   gh_mock_set_pr <url> <state> <headRefName> [commit-sha ...]
#   gh_mock_set_pr_draft <url> <true|false>
#   gh_mock_set_pr_body <url> <text>
#   gh_mock_pr_draft <url>        prints true|false (current fixture state)
#   gh_mock_pr_body <url>         prints the fixture's current body
#   gh_mock_last_body <url>       prints the last body written via `pr edit`
#   gh_mock_set_branch_pr / gh_mock_set_commit_pulls / gh_mock_calls (as before)

gh_mock_install() {
    mkdir -p "$MOTHER_ROOT/gh/pr" "$MOTHER_ROOT/gh/pr-list" "$MOTHER_ROOT/gh/commit-pulls" \
        "$MOTHER_ROOT/gh/check-runs" "$MOTHER_ROOT/gh/pr-checks"
    : > "$MOTHER_ROOT/mock-gh-calls"
    cat > "$_MOCK_BIN/gh" <<'GHEOF'
#!/usr/bin/env bash
root="${MOTHER_ROOT:?}/gh"
printf '%s\n' "$*" >> "${MOTHER_ROOT}/mock-gh-calls"
_key() { printf '%s' "$1" | tr -c 'a-zA-Z0-9' '_'; }
case "${1:-} ${2:-}" in
    "pr view")
        url="${3:-}"; expr=""; fields=""
        shift 3
        while [ $# -gt 0 ]; do
            case "$1" in
                --json) fields="${2:-}"; shift 2 ;;
                --jq|-q) expr="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        f="$root/pr/$(_key "$url").json"
        [ -f "$f" ] || exit 1
        if [ "${GH_MOCK_FAIL_DRAFT:-0}" = "1" ]; then
            case ",$fields," in *isDraft*) exit 1 ;; esac
        fi
        if [ -n "$expr" ]; then jq -r "$expr" "$f"; else cat "$f"; fi
        ;;
    "pr checks")
        f="$root/pr-checks/$(_key "${3:-}").json"
        if [ -f "$f" ]; then cat "$f"; else echo "[]"; fi
        ;;
    "pr ready")
        url="${3:-}"; undo=false
        shift 3
        while [ $# -gt 0 ]; do
            case "$1" in
                --undo) undo=true; shift ;;
                *) shift ;;
            esac
        done
        [ "${GH_MOCK_FAIL_DRAFT:-0}" = "1" ] && exit 1
        f="$root/pr/$(_key "$url").json"
        [ -f "$f" ] || exit 1
        tmp="$f.tmp.$$"
        jq --argjson d "$undo" '.isDraft = $d' "$f" > "$tmp" && mv "$tmp" "$f"
        ;;
    "pr edit")
        url="${3:-}"; bodyfile=""
        shift 3
        while [ $# -gt 0 ]; do
            case "$1" in
                --body-file) bodyfile="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        f="$root/pr/$(_key "$url").json"
        [ -f "$f" ] || exit 1
        [ -n "$bodyfile" ] && [ -f "$bodyfile" ] || exit 1
        cp "$bodyfile" "$root/last-body-$(_key "$url").md"
        tmp="$f.tmp.$$"
        jq --rawfile b "$bodyfile" '.body = $b' "$f" > "$tmp" && mv "$tmp" "$f"
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
        csha=$(printf '%s' "${2:-}" | sed -n 's|.*/commits/\([^/]*\)/check-runs.*|\1|p')
        if [ -n "$csha" ]; then
            if [ -f "$root/check-runs/$csha.json" ]; then cat "$root/check-runs/$csha.json"; else echo '{"check_runs":[]}'; fi
            exit 0
        fi
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
        '{state: $state, headRefName: $head, commits: $commits, isDraft: false, body: ""}' \
        > "$MOTHER_ROOT/gh/pr/$(_gh_mock_key "$url").json"
}

# _gh_mock_pr_file <url> — fixture path (fails when none registered).
_gh_mock_pr_file() {
    local f="$MOTHER_ROOT/gh/pr/$(_gh_mock_key "$1").json"
    [ -f "$f" ] || { echo "gh_mock: no PR fixture for $1" >&2; return 1; }
    printf '%s' "$f"
}

# gh_mock_set_pr_draft <url> <true|false>
gh_mock_set_pr_draft() {
    local f tmp; f=$(_gh_mock_pr_file "$1") || return 1
    tmp="$f.tmp.$$"
    jq --argjson d "$2" '.isDraft = $d' "$f" > "$tmp" && mv "$tmp" "$f"
}

# gh_mock_set_pr_body <url> <text>
gh_mock_set_pr_body() {
    local f tmp; f=$(_gh_mock_pr_file "$1") || return 1
    tmp="$f.tmp.$$"
    jq --arg b "$2" '.body = $b' "$f" > "$tmp" && mv "$tmp" "$f"
}

# gh_mock_pr_draft <url> — prints true|false.
gh_mock_pr_draft() {
    local f; f=$(_gh_mock_pr_file "$1") || return 1
    jq -r '.isDraft' "$f"
}

# gh_mock_pr_body <url> — the fixture's current body.
gh_mock_pr_body() {
    local f; f=$(_gh_mock_pr_file "$1") || return 1
    jq -r '.body' "$f"
}

# gh_mock_last_body <url> — the last body written by `gh pr edit --body-file`.
gh_mock_last_body() {
    cat "$MOTHER_ROOT/gh/last-body-$(_gh_mock_key "$1").md" 2>/dev/null
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

# gh_mock_set_check_runs <sha> <name:conclusion> ...
#   conclusion "pending" registers an in-progress run (no conclusion yet).
gh_mock_set_check_runs() {
    local sha="$1"; shift
    local runs='[]' spec
    for spec in "$@"; do
        runs=$(printf '%s' "$runs" | jq -c --arg n "${spec%%:*}" --arg c "${spec#*:}" '
            . + [if $c == "pending" then {name: $n, status: "in_progress", conclusion: null}
                 else {name: $n, status: "completed", conclusion: $c} end]')
    done
    jq -nc --argjson r "$runs" '{check_runs: $r}' > "$MOTHER_ROOT/gh/check-runs/$sha.json"
}

# gh_mock_set_pr_checks <url> <name:bucket> ...   (`gh pr checks --json name,state,bucket`)
gh_mock_set_pr_checks() {
    local url="$1"; shift
    local out='[]' spec
    for spec in "$@"; do
        out=$(printf '%s' "$out" | jq -c --arg n "${spec%%:*}" --arg b "${spec#*:}" \
            '. + [{name: $n, state: ($b | ascii_upcase), bucket: $b}]')
    done
    printf '%s' "$out" > "$MOTHER_ROOT/gh/pr-checks/$(_gh_mock_key "$url").json"
}
