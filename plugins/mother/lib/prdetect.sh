# prdetect.sh — evidence-based PR detection helpers.
#
# Sourced by bin/mother, bin/mother-run-job, and lib/teardown.sh (siblings of
# this lib dir). Does not call `set -u` itself — inherits shell options from
# the sourcing script. Bash 3.2-safe: no `declare -A`, no `mapfile`, no
# `export -f` across `bash -c`.
#
# Every function here must be safe to call when `gh` is missing, offline, or
# unauthenticated: echo empty / return non-zero, never fail (let alone crash)
# the caller. Nothing here ever mutates job state or the filesystem — pure
# read-only detection. Callers decide what to do with the answer.
#
# See CLAUDE.md ("PR detection" / the bug-fix plan this shipped with) for the
# full contract each function below implements.

# prd_owner_repo_from_url <remote_url> -> "owner/repo" or "".
# Handles SSH (git@github.com:o/r[.git]) and HTTPS (https://github.com/o/r[.git]).
# Empty for non-GitHub remotes.
prd_owner_repo_from_url() {
    local url="${1:-}"
    url="${url%.git}"
    local or
    or=$(echo "$url" | sed -n 's|.*github\.com[:/]\(.*\)|\1|p')
    echo "${or:-}"
}

# prd_owner_repo_from_dir <dir> -> "owner/repo" or "". Reads <dir>'s origin
# remote. Empty when <dir> is missing, not a repo, or has no origin remote.
prd_owner_repo_from_dir() {
    local dir="${1:-}"
    [ -n "$dir" ] && [ -d "$dir" ] || { echo ""; return 0; }
    local url
    url=$(cd "$dir" && git remote get-url origin 2>/dev/null) || { echo ""; return 0; }
    prd_owner_repo_from_url "$url"
}

# prd_candidate_shas <work_dir> <branch> <base_ref> -> newline-separated
# candidate SHAs identifying "what this job produced", most specific first:
#   1. HEAD
#   2. <branch>'s own sha, if it resolves and differs from HEAD
#   3. up to 10 entries of `git rev-list <base_ref>..HEAD` (or, when base_ref
#      doesn't resolve, `git rev-list -n 10 HEAD`)
# De-duped, capped at 12 total. Empty when work_dir is missing.
prd_candidate_shas() {
    local work_dir="${1:-}" branch="${2:-}" base_ref="${3:-}"
    [ -n "$work_dir" ] && [ -d "$work_dir" ] || return 0

    local head_sha
    head_sha=$(cd "$work_dir" && git rev-parse HEAD 2>/dev/null)
    [ -n "$head_sha" ] || return 0

    local raw="$head_sha"

    if [ -n "$branch" ]; then
        local branch_sha
        branch_sha=$(cd "$work_dir" && git rev-parse --verify -q "$branch" 2>/dev/null)
        if [ -n "$branch_sha" ] && [ "$branch_sha" != "$head_sha" ]; then
            raw="$raw
$branch_sha"
        fi
    fi

    local range_list
    if [ -n "$base_ref" ] && (cd "$work_dir" && git rev-parse --verify -q "$base_ref" >/dev/null 2>&1); then
        range_list=$(cd "$work_dir" && git rev-list "${base_ref}..HEAD" 2>/dev/null | head -10)
    else
        range_list=$(cd "$work_dir" && git rev-list -n 10 HEAD 2>/dev/null)
    fi
    if [ -n "$range_list" ]; then
        raw="$raw
$range_list"
    fi

    printf '%s\n' "$raw" | awk '!seen[$0]++' | head -12
}

# prd_pr_for_commit <owner_repo> <sha> -> PR URL or "". Prefers an OPEN PR;
# falls back to the most recently updated one when none are open. Empty on
# any gh error or when the commit has no associated pull requests.
prd_pr_for_commit() {
    local owner_repo="${1:-}" sha="${2:-}"
    [ -n "$owner_repo" ] && [ -n "$sha" ] || { echo ""; return 0; }
    command -v gh >/dev/null 2>&1 || { echo ""; return 0; }
    local json
    json=$(gh api "repos/${owner_repo}/commits/${sha}/pulls" 2>/dev/null) || { echo ""; return 0; }
    [ -n "$json" ] || { echo ""; return 0; }
    printf '%s' "$json" | jq -r '
        if (type=="array") then
            (map(select(.state=="open")) | sort_by(.updated_at) | last | .html_url) //
            (sort_by(.updated_at) | last | .html_url) //
            empty
        else empty end
    ' 2>/dev/null
}

# prd_pr_for_branch <owner_repo> <branch> -> URL of the open PR whose head is
# <branch>, or "". Never reads the transcript.
prd_pr_for_branch() {
    local owner_repo="${1:-}" branch="${2:-}"
    [ -n "$owner_repo" ] || { echo ""; return 0; }
    command -v gh >/dev/null 2>&1 || { echo ""; return 0; }
    local out
    out=$(gh pr list --repo "$owner_repo" --head "$branch" --state open --json url 2>/dev/null) || { echo ""; return 0; }
    [ -n "$out" ] || { echo ""; return 0; }
    echo "$out" | jq -r 'if type == "array" then .[0].url // empty else .url // empty end' 2>/dev/null || echo ""
}

# prd_pr_contains_sha <pr_url> <sha> -> 0 the PR's commit list contains sha
# (full match or a >=7-char prefix match either direction), 1 a clean miss,
# 2 indeterminate (gh error / PR didn't resolve).
prd_pr_contains_sha() {
    local pr_url="${1:-}" sha="${2:-}"
    [ -n "$pr_url" ] && [ -n "$sha" ] || return 2
    command -v gh >/dev/null 2>&1 || return 2

    local oids rc
    oids=$(gh pr view "$pr_url" --json commits --jq '.commits[].oid' 2>/dev/null)
    rc=$?
    [ "$rc" -eq 0 ] || return 2

    local short_sha="$sha"
    [ "${#sha}" -gt 7 ] && short_sha="${sha:0:7}"

    local oid short_oid
    while IFS= read -r oid; do
        [ -n "$oid" ] || continue
        case "$oid" in "$sha"*) return 0 ;; esac
        case "$sha" in "$oid"*) return 0 ;; esac
        short_oid="$oid"
        [ "${#oid}" -gt 7 ] && short_oid="${oid:0:7}"
        [ "$short_oid" = "$short_sha" ] && return 0
    done <<PRD_OIDS
$oids
PRD_OIDS

    return 1
}

# prd_detect_pr <work_dir> <branch> <base_ref> -> "<pr_url>\t<match_kind>\t<matched_sha>"
# where match_kind is "branch" or "commit" (matched_sha empty for "branch").
# Resolution order, stopping at the first hit: (1) prd_pr_for_branch on the
# assigned branch; (2) prd_pr_for_commit over prd_candidate_shas, in order;
# (3) empty (bare empty string — no tabs).
prd_detect_pr() {
    local work_dir="${1:-}" branch="${2:-}" base_ref="${3:-}"
    local owner_repo
    owner_repo=$(prd_owner_repo_from_dir "$work_dir")

    if [ -n "$owner_repo" ]; then
        local url
        url=$(prd_pr_for_branch "$owner_repo" "$branch")
        if [ -n "$url" ]; then
            printf '%s\t%s\t%s\n' "$url" "branch" ""
            return 0
        fi

        local shas sha commit_url
        shas=$(prd_candidate_shas "$work_dir" "$branch" "$base_ref")
        if [ -n "$shas" ]; then
            while IFS= read -r sha; do
                [ -n "$sha" ] || continue
                commit_url=$(prd_pr_for_commit "$owner_repo" "$sha")
                if [ -n "$commit_url" ]; then
                    printf '%s\t%s\t%s\n' "$commit_url" "commit" "$sha"
                    return 0
                fi
            done <<PRD_SHAS
$shas
PRD_SHAS
        fi
    fi

    echo ""
    return 0
}

# prd_sha_on_origin <work_dir> -> 0 when HEAD has been pushed to origin under
# ANY ref name, 1 otherwise (never pushed, or work_dir missing/not a repo).
prd_sha_on_origin() {
    local work_dir="${1:-}"
    [ -n "$work_dir" ] && [ -d "$work_dir" ] || return 1
    local refs
    refs=$(cd "$work_dir" && git branch -r --contains HEAD 2>/dev/null | grep -c 'origin/')
    case "${refs:-0}" in ''|*[!0-9]*) refs=0 ;; esac
    [ "$refs" -gt 0 ]
}
