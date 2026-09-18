#!/usr/bin/env bats
# prdetect.bats — behavioral contract for plugins/mother/lib/prdetect.sh.
#
# lib/prdetect.sh does NOT exist yet. Every test in this file is expected to
# FAIL (red) until Cody implements it — sourcing the file itself will error,
# so every function call below fails with "command not found", which is red
# for the right reason.
#
# Functions under test (see the bug-fix plan for the full contract):
#   prd_owner_repo_from_url <remote_url>              -> "owner/repo" or ""
#   prd_owner_repo_from_dir <dir>                      -> "owner/repo" or ""
#   prd_candidate_shas <work_dir> <branch> <base_ref>  -> newline-separated SHAs
#   prd_pr_for_commit <owner_repo> <sha>               -> URL or ""
#   prd_pr_for_branch <owner_repo> <branch>            -> URL or ""
#   prd_pr_contains_sha <pr_url> <sha>                 -> exit 0/1/2
#   prd_detect_pr <work_dir> <branch> <base_ref>       -> "<url>\t<kind>\t<sha>"
#   prd_sha_on_origin <work_dir>                       -> exit 0/1
#
# All git-based functions are tested against real git repositories (never
# mocked) per house style (see teardown.bats). gh-based functions are tested
# against a mock `gh` installed into $_MOCK_BIN, following the pattern
# established in pr_url_capture.bats / teardown.bats: the mock returns the
# FINAL value the function needs (as if gh's own --json/--jq/-q processing had
# already run), except where the contract text explicitly commits to a
# specific gh invocation shape (--jq), in which case the mock actually
# evaluates the extracted --jq expression with the real `jq` binary against a
# canned fixture — see _install_mock_gh_multi below. This keeps the tests
# honest about *what gh endpoint gets called* without overfitting to exactly
# how Cody splits the selection logic between gh's --jq and bash.

load 'test_helper'

PRDETECT_LIB="$_LIB_DIR/prdetect.sh"

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Fixtures & helpers
# ---------------------------------------------------------------------------

# Real repo with an origin remote set to the given owner/repo (no push).
# Usage: _pd_repo_with_origin <dir> <owner/repo>
_pd_repo_with_origin() {
    local dir="$1" owner_repo="$2"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m init
    git -C "$dir" remote add origin "https://github.com/$owner_repo.git"
}

# Real repo + real bare "origin" remote, wired up for push. Usage:
# _pd_repo_with_bare_origin <dir> <bare_dir>
_pd_repo_with_bare_origin() {
    local dir="$1" bare_dir="$2"
    git init -q --bare "$bare_dir"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" remote add origin "$bare_dir"
    git -C "$dir" commit -q --allow-empty -m init
}

# Generic gh mock supporting multiple match rules. Each rule is
# "substring=fixture_file". On a call whose full argv (joined by spaces)
# contains substring, prints fixture_file's content — filtered through the
# REAL `jq` binary using whatever expression follows a `--jq` flag in argv, if
# present, else printed raw. No match -> prints empty and exits 0.
# MOCK_GH_EXIT forces every call to fail (simulates gh being broken/offline).
_install_mock_gh_multi() {
    local rules_file="$MOTHER_ROOT/gh-rules.txt"
    : > "$rules_file"
    local rule
    for rule in "$@"; do
        printf '%s\n' "$rule" >> "$rules_file"
    done
    cat > "$_MOCK_BIN/gh" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${MOTHER_ROOT:?}/mock-gh-calls"
if [ "\${MOCK_GH_EXIT:-0}" != "0" ]; then
    exit "\${MOCK_GH_EXIT}"
fi
jqexpr=""
prev=""
for a in "\$@"; do
    if [ "\$prev" = "--jq" ]; then jqexpr="\$a"; fi
    prev="\$a"
done
while IFS='=' read -r pat file; do
    [ -z "\$pat" ] && continue
    case "\$*" in
        *"\$pat"*)
            if [ -n "\$jqexpr" ]; then
                jq -r "\$jqexpr" "\$file" 2>/dev/null
            else
                cat "\$file"
            fi
            exit 0
            ;;
    esac
done < "$rules_file"
echo ""
exit 0
GHEOF
    chmod +x "$_MOCK_BIN/gh"
}

# ===========================================================================
# prd_owner_repo_from_url
# ===========================================================================

@test "prd_owner_repo_from_url: SSH remote with .git suffix" {
    source "$PRDETECT_LIB"
    result=$(prd_owner_repo_from_url "git@github.com:owner/repo.git")
    [ "$result" = "owner/repo" ]
}

@test "prd_owner_repo_from_url: SSH remote without .git suffix" {
    source "$PRDETECT_LIB"
    result=$(prd_owner_repo_from_url "git@github.com:owner/repo")
    [ "$result" = "owner/repo" ]
}

@test "prd_owner_repo_from_url: HTTPS remote with .git suffix" {
    source "$PRDETECT_LIB"
    result=$(prd_owner_repo_from_url "https://github.com/owner/repo.git")
    [ "$result" = "owner/repo" ]
}

@test "prd_owner_repo_from_url: HTTPS remote without .git suffix" {
    source "$PRDETECT_LIB"
    result=$(prd_owner_repo_from_url "https://github.com/owner/repo")
    [ "$result" = "owner/repo" ]
}

@test "prd_owner_repo_from_url: non-github remote returns empty" {
    source "$PRDETECT_LIB"
    result=$(prd_owner_repo_from_url "https://gitlab.com/owner/repo")
    [ "$result" = "" ]
}

# ===========================================================================
# prd_owner_repo_from_dir
# ===========================================================================

@test "prd_owner_repo_from_dir: reads origin remote from a real repo" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-origin"
    _pd_repo_with_origin "$dir" "thehammer/mother"
    result=$(prd_owner_repo_from_dir "$dir")
    [ "$result" = "thehammer/mother" ]
}

@test "prd_owner_repo_from_dir: empty when dir does not exist" {
    source "$PRDETECT_LIB"
    result=$(prd_owner_repo_from_dir "$MOTHER_ROOT/does-not-exist")
    [ "$result" = "" ]
}

@test "prd_owner_repo_from_dir: empty when dir is not a git repo" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/not-a-repo"
    mkdir -p "$dir"
    result=$(prd_owner_repo_from_dir "$dir")
    [ "$result" = "" ]
}

@test "prd_owner_repo_from_dir: empty when repo has no origin remote" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-no-origin"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m init
    result=$(prd_owner_repo_from_dir "$dir")
    [ "$result" = "" ]
}

# ===========================================================================
# prd_candidate_shas
# ===========================================================================

@test "prd_candidate_shas: HEAD plus base_ref..HEAD range, deduped, newest first" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-cand1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m c0
    git -C "$dir" branch base
    git -C "$dir" checkout -q -b feature
    git -C "$dir" commit -q --allow-empty -m c1
    git -C "$dir" commit -q --allow-empty -m c2
    git -C "$dir" commit -q --allow-empty -m c3

    local head_sha c2_sha c1_sha
    head_sha=$(git -C "$dir" rev-parse HEAD)
    c2_sha=$(git -C "$dir" rev-parse HEAD~1)
    c1_sha=$(git -C "$dir" rev-parse HEAD~2)

    run bash -c "source '$PRDETECT_LIB'; prd_candidate_shas '$dir' feature base"
    [ "$status" -eq 0 ]
    # First line is HEAD; the range's own duplicate of HEAD must not repeat.
    local first_line
    first_line=$(echo "$output" | head -1)
    [ "$first_line" = "$head_sha" ]
    [[ "$output" =~ $c2_sha ]]
    [[ "$output" =~ $c1_sha ]]
    # No duplicate lines.
    local total unique
    total=$(echo "$output" | grep -c .)
    unique=$(echo "$output" | sort -u | grep -c .)
    [ "$total" -eq "$unique" ]
}

@test "prd_candidate_shas: includes branch sha separately when it differs from HEAD" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-cand2"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m c0
    git -C "$dir" branch base
    git -C "$dir" branch sidebranch
    git -C "$dir" checkout -q -b feature
    git -C "$dir" commit -q --allow-empty -m c1

    local head_sha side_sha
    head_sha=$(git -C "$dir" rev-parse HEAD)
    side_sha=$(git -C "$dir" rev-parse sidebranch)
    [ "$head_sha" != "$side_sha" ]

    run bash -c "source '$PRDETECT_LIB'; prd_candidate_shas '$dir' sidebranch base"
    [ "$status" -eq 0 ]
    [[ "$output" =~ $head_sha ]]
    [[ "$output" =~ $side_sha ]]
}

@test "prd_candidate_shas: caps total output and never repeats a sha" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-cand3"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m c0
    git -C "$dir" branch base
    local i
    for i in $(seq 1 20); do
        git -C "$dir" commit -q --allow-empty -m "c$i"
    done

    run bash -c "source '$PRDETECT_LIB'; prd_candidate_shas '$dir' base base"
    [ "$status" -eq 0 ]
    local total unique
    total=$(echo "$output" | grep -c .)
    unique=$(echo "$output" | sort -u | grep -c .)
    [ "$total" -le 12 ]
    [ "$total" -eq "$unique" ]
}

@test "prd_candidate_shas: falls back to plain rev-list when base_ref does not resolve" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-cand4"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m c0
    local i
    for i in $(seq 1 14); do
        git -C "$dir" commit -q --allow-empty -m "c$i"
    done
    local head_sha
    head_sha=$(git -C "$dir" rev-parse HEAD)

    run bash -c "source '$PRDETECT_LIB'; prd_candidate_shas '$dir' main origin/does-not-exist"
    [ "$status" -eq 0 ]
    local first_line total
    first_line=$(echo "$output" | head -1)
    total=$(echo "$output" | grep -c .)
    [ "$first_line" = "$head_sha" ]
    # HEAD + up to 10 from the fallback -n10 rev-list, deduped -> at most 10.
    [ "$total" -le 10 ]
}

@test "prd_candidate_shas: empty when work_dir does not exist" {
    source "$PRDETECT_LIB"
    result=$(prd_candidate_shas "$MOTHER_ROOT/no-such-dir" "feature" "main")
    [ -z "$result" ]
}

# ===========================================================================
# prd_pr_for_commit
# ===========================================================================

@test "prd_pr_for_commit: prefers the OPEN pull request when multiple exist" {
    source "$PRDETECT_LIB"
    local sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    local fixture="$MOTHER_ROOT/commits-pulls.json"
    cat > "$fixture" <<'JSON'
[
  {"html_url": "https://github.com/thehammer/mother/pull/10", "state": "closed", "updated_at": "2026-01-01T00:00:00Z"},
  {"html_url": "https://github.com/thehammer/mother/pull/11", "state": "open", "updated_at": "2025-01-01T00:00:00Z"}
]
JSON
    _install_mock_gh_multi "commits/$sha/pulls=$fixture"

    result=$(prd_pr_for_commit "thehammer/mother" "$sha")
    [ "$result" = "https://github.com/thehammer/mother/pull/11" ]
}

@test "prd_pr_for_commit: falls back to most recently updated when none are open" {
    source "$PRDETECT_LIB"
    local sha="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    local fixture="$MOTHER_ROOT/commits-pulls2.json"
    cat > "$fixture" <<'JSON'
[
  {"html_url": "https://github.com/thehammer/mother/pull/20", "state": "closed", "updated_at": "2026-01-01T00:00:00Z"},
  {"html_url": "https://github.com/thehammer/mother/pull/21", "state": "closed", "updated_at": "2026-06-01T00:00:00Z"}
]
JSON
    _install_mock_gh_multi "commits/$sha/pulls=$fixture"

    result=$(prd_pr_for_commit "thehammer/mother" "$sha")
    [ "$result" = "https://github.com/thehammer/mother/pull/21" ]
}

@test "prd_pr_for_commit: empty when the commit has no associated pull requests" {
    source "$PRDETECT_LIB"
    local sha="cccccccccccccccccccccccccccccccccccccccc"
    local fixture="$MOTHER_ROOT/commits-pulls-empty.json"
    printf '[]' > "$fixture"
    _install_mock_gh_multi "commits/$sha/pulls=$fixture"

    result=$(prd_pr_for_commit "thehammer/mother" "$sha")
    [ "$result" = "" ]
}

@test "prd_pr_for_commit: empty on gh error" {
    source "$PRDETECT_LIB"
    export MOCK_GH_EXIT=1
    local sha="dddddddddddddddddddddddddddddddddddddddd"
    _install_mock_gh_multi "commits/$sha/pulls=$MOTHER_ROOT/unused.json"
    echo '[]' > "$MOTHER_ROOT/unused.json"

    result=$(prd_pr_for_commit "thehammer/mother" "$sha")
    [ "$result" = "" ]
}

# ===========================================================================
# prd_pr_for_branch
# ===========================================================================

@test "prd_pr_for_branch: returns the open PR url for the branch" {
    source "$PRDETECT_LIB"
    local fixture="$MOTHER_ROOT/pr-list.json"
    printf '{"url":"https://github.com/thehammer/mother/pull/42"}' > "$fixture"
    _install_mock_gh_multi "pr list=$fixture"

    result=$(prd_pr_for_branch "thehammer/mother" "feature/foo")
    [ "$result" = "https://github.com/thehammer/mother/pull/42" ]
}

@test "prd_pr_for_branch: empty when no open PR exists for the branch" {
    source "$PRDETECT_LIB"
    local fixture="$MOTHER_ROOT/pr-list-empty.json"
    printf '' > "$fixture"
    _install_mock_gh_multi "pr list=$fixture"

    result=$(prd_pr_for_branch "thehammer/mother" "feature/foo")
    [ "$result" = "" ]
}

# ===========================================================================
# prd_pr_contains_sha
# ===========================================================================

@test "prd_pr_contains_sha: exit 0 on a full sha match" {
    source "$PRDETECT_LIB"
    local sha="1111111111111111111111111111111111111111"
    local fixture="$MOTHER_ROOT/pr-commits-full.json"
    printf '{"commits":[{"oid":"%s"},{"oid":"2222222222222222222222222222222222222222"}]}' "$sha" > "$fixture"
    _install_mock_gh_multi "pull/50=$fixture"

    run bash -c "source '$PRDETECT_LIB'; prd_pr_contains_sha 'https://github.com/x/y/pull/50' '$sha'"
    [ "$status" -eq 0 ]
}

@test "prd_pr_contains_sha: exit 0 on a >=7-char prefix match (short sha vs full)" {
    source "$PRDETECT_LIB"
    local short="abc1234"
    local full="abc1234000000000000000000000000000000000"
    local fixture="$MOTHER_ROOT/pr-commits-prefix.json"
    printf '{"commits":[{"oid":"%s"}]}' "$full" > "$fixture"
    _install_mock_gh_multi "pull/51=$fixture"

    run bash -c "source '$PRDETECT_LIB'; prd_pr_contains_sha 'https://github.com/x/y/pull/51' '$short'"
    [ "$status" -eq 0 ]
}

@test "prd_pr_contains_sha: exit 1 on a clean miss" {
    source "$PRDETECT_LIB"
    local fixture="$MOTHER_ROOT/pr-commits-miss.json"
    printf '{"commits":[{"oid":"3333333333333333333333333333333333333333"}]}' > "$fixture"
    _install_mock_gh_multi "pull/52=$fixture"

    run bash -c "source '$PRDETECT_LIB'; prd_pr_contains_sha 'https://github.com/x/y/pull/52' '4444444444444444444444444444444444444444'"
    [ "$status" -eq 1 ]
}

@test "prd_pr_contains_sha: exit 2 when gh errors (indeterminate)" {
    source "$PRDETECT_LIB"
    export MOCK_GH_EXIT=1
    _install_mock_gh_multi "pull/53=$MOTHER_ROOT/unused2.json"
    echo '{"commits":[]}' > "$MOTHER_ROOT/unused2.json"

    run bash -c "source '$PRDETECT_LIB'; prd_pr_contains_sha 'https://github.com/x/y/pull/53' '5555555555555555555555555555555555555555'"
    [ "$status" -eq 2 ]
}

# ===========================================================================
# prd_detect_pr
# ===========================================================================

@test "prd_detect_pr: branch match wins and reports match_kind=branch with empty matched_sha" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-detect1"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m c0
    git -C "$dir" remote add origin "https://github.com/thehammer/mother.git"

    local fixture="$MOTHER_ROOT/detect-branch.json"
    printf '{"url":"https://github.com/thehammer/mother/pull/77"}' > "$fixture"
    _install_mock_gh_multi "pr list=$fixture"

    run bash -c "source '$PRDETECT_LIB'; prd_detect_pr '$dir' feature/foo main"
    [ "$status" -eq 0 ]
    IFS=$'\t' read -r url kind sha <<< "$output"
    [ "$url" = "https://github.com/thehammer/mother/pull/77" ]
    [ "$kind" = "branch" ]
    [ -z "$sha" ]
}

@test "prd_detect_pr: falls back to a commit match when the branch query finds nothing" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-detect2"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m c0
    git -C "$dir" remote add origin "https://github.com/thehammer/mother.git"
    git -C "$dir" branch base
    git -C "$dir" checkout -q -b feature
    git -C "$dir" commit -q --allow-empty -m c1

    local head_sha
    head_sha=$(git -C "$dir" rev-parse HEAD)

    # No open PR for the branch.
    local empty_fixture="$MOTHER_ROOT/detect-branch-empty.json"
    printf '' > "$empty_fixture"
    # A PR exists containing HEAD's commit.
    local commit_fixture="$MOTHER_ROOT/detect-commit-hit.json"
    printf '[{"html_url": "https://github.com/thehammer/mother/pull/88", "state": "open", "updated_at": "2026-01-01T00:00:00Z"}]' > "$commit_fixture"

    _install_mock_gh_multi \
        "pr list=$empty_fixture" \
        "commits/$head_sha/pulls=$commit_fixture"

    run bash -c "source '$PRDETECT_LIB'; prd_detect_pr '$dir' feature base"
    [ "$status" -eq 0 ]
    IFS=$'\t' read -r url kind sha <<< "$output"
    [ "$url" = "https://github.com/thehammer/mother/pull/88" ]
    [ "$kind" = "commit" ]
    [ "$sha" = "$head_sha" ]
}

@test "prd_detect_pr: empty result when neither branch nor any candidate commit resolves a PR" {
    source "$PRDETECT_LIB"
    local dir="$MOTHER_ROOT/repo-detect3"
    git init -q "$dir"
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" commit -q --allow-empty -m c0

    local empty_fixture="$MOTHER_ROOT/detect-nothing.json"
    printf '' > "$empty_fixture"
    _install_mock_gh_multi "pr list=$empty_fixture"

    run bash -c "source '$PRDETECT_LIB'; prd_detect_pr '$dir' main main"
    [ "$status" -eq 0 ]
    # Contract allows either a bare empty string or tab-separated empties;
    # we assert the simplest form (bare empty), per the spec's explicit
    # "pick whichever is simplest to assert on" allowance. If Cody instead
    # emits "\t\t", loosen this to strip tabs before comparing.
    [ -z "$output" ]
}

# ===========================================================================
# prd_sha_on_origin
# ===========================================================================

@test "prd_sha_on_origin: exit 0 when HEAD has been pushed to origin under any ref name" {
    source "$PRDETECT_LIB"
    local bare="$MOTHER_ROOT/bare-origin1.git"
    local dir="$MOTHER_ROOT/repo-sha-on-origin1"
    _pd_repo_with_bare_origin "$dir" "$bare"
    git -C "$dir" push -q origin HEAD:refs/heads/some-other-branch-name

    run bash -c "source '$PRDETECT_LIB'; prd_sha_on_origin '$dir'"
    [ "$status" -eq 0 ]
}

@test "prd_sha_on_origin: exit 1 when HEAD has not been pushed anywhere" {
    source "$PRDETECT_LIB"
    local bare="$MOTHER_ROOT/bare-origin2.git"
    local dir="$MOTHER_ROOT/repo-sha-on-origin2"
    _pd_repo_with_bare_origin "$dir" "$bare"
    # Never pushed — fetch so the remote-tracking namespace exists but is empty.
    git -C "$dir" fetch -q origin || true

    run bash -c "source '$PRDETECT_LIB'; prd_sha_on_origin '$dir'"
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# prd_sha_on_origin — optional base_ref parameter (commits-ahead requirement).
#
# The bug: prd_sha_on_origin only ever checked reachability from origin. A
# no-op HEAD (zero commits ahead of base_ref) has HEAD == base_ref, which is
# trivially already on origin whenever base_ref itself has been pushed, so a
# worker that ships nothing was accepted as "shipped work". The fix adds an
# optional second base_ref argument: when given, HEAD must be genuinely ahead
# of base_ref (via `git rev-list --count base_ref..HEAD` > 0) *and* reachable
# from origin. An unresolvable base_ref must fail closed, never silently fall
# back to the no-base_ref (reachability-only) behavior.
# ---------------------------------------------------------------------------

@test "prd_sha_on_origin: exit 1 when HEAD is on origin but has zero commits ahead of base_ref (no-op HEAD)" {
    source "$PRDETECT_LIB"
    local bare="$MOTHER_ROOT/bare-origin3.git"
    local dir="$MOTHER_ROOT/repo-sha-on-origin3"
    _pd_repo_with_bare_origin "$dir" "$bare"
    # Push the single base commit to origin under some branch name, then mark
    # that exact commit as base-marker. No further commits are made, so HEAD
    # is identical to base-marker — zero commits ahead.
    git -C "$dir" push -q origin HEAD:refs/heads/base-pushed
    git -C "$dir" branch base-marker HEAD

    run bash -c "source '$PRDETECT_LIB'; prd_sha_on_origin '$dir' 'base-marker'"
    [ "$status" -eq 1 ]
}

@test "prd_sha_on_origin: exit 0 when HEAD is both ahead of base_ref and reachable from origin" {
    source "$PRDETECT_LIB"
    local bare="$MOTHER_ROOT/bare-origin4.git"
    local dir="$MOTHER_ROOT/repo-sha-on-origin4"
    _pd_repo_with_bare_origin "$dir" "$bare"
    git -C "$dir" branch base-marker HEAD
    git -C "$dir" commit -q --allow-empty -m work
    git -C "$dir" push -q origin HEAD:refs/heads/some-other-branch-name

    run bash -c "source '$PRDETECT_LIB'; prd_sha_on_origin '$dir' 'base-marker'"
    [ "$status" -eq 0 ]
}

@test "prd_sha_on_origin: exit 1 when HEAD is ahead of base_ref but was never pushed to origin" {
    source "$PRDETECT_LIB"
    local bare="$MOTHER_ROOT/bare-origin5.git"
    local dir="$MOTHER_ROOT/repo-sha-on-origin5"
    _pd_repo_with_bare_origin "$dir" "$bare"
    git -C "$dir" branch base-marker HEAD
    git -C "$dir" commit -q --allow-empty -m work
    # Never pushed — fetch so the remote-tracking namespace exists but is empty.
    git -C "$dir" fetch -q origin || true

    run bash -c "source '$PRDETECT_LIB'; prd_sha_on_origin '$dir' 'base-marker'"
    [ "$status" -eq 1 ]
}

@test "prd_sha_on_origin: exit 1 (fails closed) when base_ref does not resolve, even though HEAD is on origin" {
    source "$PRDETECT_LIB"
    local bare="$MOTHER_ROOT/bare-origin6.git"
    local dir="$MOTHER_ROOT/repo-sha-on-origin6"
    _pd_repo_with_bare_origin "$dir" "$bare"
    git -C "$dir" push -q origin HEAD:refs/heads/some-other-branch-name

    run bash -c "source '$PRDETECT_LIB'; prd_sha_on_origin '$dir' 'no-such-ref'"
    [ "$status" -eq 1 ]
}
