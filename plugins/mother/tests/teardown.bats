#!/usr/bin/env bats
# teardown.bats — behavioral contract for Mother resource teardown.
#
# `plugins/mother/lib/teardown.sh` does NOT exist yet. Every test in this file
# is expected to FAIL (red) until Cody implements it and wires it into
# `mother archive` / a new `mother teardowns` subcommand. This file IS the
# acceptance bar for that work — do not weaken an assertion because the
# implementation doesn't exist; that's the point of red/green.
#
# Functions under test (see plugins/mother/CLAUDE.md-adjacent spec for the
# full contract):
#   mother_compose_project(id)          — lib/state.sh (sanitizes id -> compose project name)
#   _teardown_pr_disposition <pr_url>   — lib/teardown.sh (merged|closed|open|inconclusive)
#   _teardown_gate <facts_json>         — lib/teardown.sh (proceed:<reason> | defer:<reason>)
#   _teardown_race_check <facts_json>   — lib/teardown.sh (0 clear | 1 conflict, echoes id)
#   _teardown_docker <facts_json> <dry> — lib/teardown.sh (0 clean | 1 skipped | 2 defer)
#   _teardown_worktree <facts_json> <dry> — lib/teardown.sh (0 removed | 1 skipped | 2 error)
#   _teardown_execute <facts_json> <dry>  — lib/teardown.sh (orchestrator)
#   _teardown_drain <dry>                 — lib/teardown.sh (sweeps $TEARDOWN_DIR)
#
# Required-case index (see task spec) -> test name:
#   1  PR open -> deferred                          "PR open on a succeeded job defers teardown..."
#   2  PR merged -> torn down                        "PR merged tears down worktree and docker..."
#   3  no pr_url + failed -> immediate, no gh call   "no PR URL on a failed job tears down immediately..."
#   4  gh fails -> deferred gh_inconclusive          "gh failure defers teardown as gh_inconclusive..."
#   5  race guard                                    "a running job sharing repo_path and branch..."
#   6  isolation main-dir -> skipped main_dir         "isolation=main-dir never removes the checkout..."
#   7  --dry-run                                      "--dry-run leaves worktree, pending queue..."
#   8  drain via bulk archive                         "bulk archive drains a pending teardown record..."
#   9  docker unreachable -> deferred                 "docker daemon unreachable defers teardown..."
#   10 kill switch MOTHER_TEARDOWN_ENABLED=0          "MOTHER_TEARDOWN_ENABLED=0 skips teardown..."
#   11 mother_compose_project sanitization             (unit tests, below)
#   12 repo_path missing -> archive still exits 0     "archiving a job whose repo_path no longer exists..."

load 'test_helper'

# ---------------------------------------------------------------------------
# Fixtures & helpers
# ---------------------------------------------------------------------------

# Real git repo (never mocked — these are the safety net for destructive
# filesystem ops). Usage: _make_teardown_repo <repo_dir>
_make_teardown_repo() {
    local repo_dir="$1"
    git init -q "$repo_dir"
    git -C "$repo_dir" config user.email "test@test.com"
    git -C "$repo_dir" config user.name "Test"
    git -C "$repo_dir" commit -q --allow-empty -m init
}

# Real git worktree off a real repo. Usage: _make_teardown_worktree <repo_dir> <wt_dir> <branch>
_make_teardown_worktree() {
    local repo_dir="$1" wt_dir="$2" branch="$3"
    git -C "$repo_dir" worktree add -q -b "$branch" "$wt_dir"
}

# Build a full teardown job: real repo + real worktree + job JSON pointed at
# both, in a terminal state with finished_at set. Echoes the worktree path.
# Usage: _make_teardown_job <id> <state> [extra-jq-filter]
_make_teardown_job() {
    local id="$1" state="$2" extra="${3:-.}"
    local repo_dir="$MOTHER_ROOT/repo-$id"
    local wt_dir="$MOTHER_ROOT/wt-$id"
    local branch="feature/$id"
    _make_teardown_repo "$repo_dir"
    _make_teardown_worktree "$repo_dir" "$wt_dir" "$branch"
    make_job "$id" "$state" \
        ".repo_path = \"$repo_dir\" | .branch = \"$branch\" | .work_dir = \"$wt_dir\" | .isolation = \"worktree\" | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\" | ($extra)"
    echo "$wt_dir"
}

# Build a standalone facts JSON blob (no job file needed) for pure
# unit-level calls into lib/teardown.sh functions.
# Usage: _facts_json <id> <repo_path> <branch> <work_dir> <isolation> <pr_url|""> <state> <no_pr:true|false>
_facts_json() {
    local id="$1" repo_path="$2" branch="$3" work_dir="$4" isolation="$5" pr_url="$6" state="$7" no_pr="$8"
    local pr_url_json="null"
    [ -n "$pr_url" ] && pr_url_json="\"$pr_url\""
    jq -nc \
        --arg id "$id" --arg repo_path "$repo_path" --arg branch "$branch" \
        --arg work_dir "$work_dir" --arg isolation "$isolation" \
        --arg state "$state" --argjson no_pr "$no_pr" --argjson pr_url "$pr_url_json" \
        '{id: $id, repo: "testrepo", repo_path: $repo_path, branch: $branch,
          work_dir: $work_dir, isolation: $isolation, pr_url: $pr_url,
          state: $state, no_pr: $no_pr, events_path: ""}'
}

# Locate a job's events file whether it's still live (EVENTS_DIR) or has
# already been archived (ARCHIVE_DIR/<yyyy-mm>/<id>.events.jsonl).
# Usage: _find_events_file <id>
_find_events_file() {
    local id="$1"
    find "$MOTHER_ROOT" \( -name "${id}.jsonl" -o -name "${id}.events.jsonl" \) 2>/dev/null | head -n1
}

# Shell snippet that sources the libs needed to call lib/teardown.sh
# functions directly, in the order bin/mother would.
_source_teardown_libs() {
    printf "source '%s/state.sh'; source '%s/worktree.sh'; source '%s/teardown.sh';" \
        "$_LIB_DIR" "$_LIB_DIR" "$_LIB_DIR"
}

# Mock `gh`: records every invocation to $MOTHER_ROOT/mock-gh-calls, then
# echoes $MOCK_GH_STATE for a `pr view ... state` query (default OPEN).
# Honors MOCK_GH_EXIT to simulate command failure.
_install_mock_gh() {
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-gh-calls"
if [ "${MOCK_GH_EXIT:-0}" != "0" ]; then
    exit "${MOCK_GH_EXIT}"
fi
case "$*" in
    *"pr view"*state*)
        printf '%s\n' "${MOCK_GH_STATE:-OPEN}"
        ;;
    *)
        echo ""
        ;;
esac
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
}

# Mock `docker`: records every invocation's full argv to
# $MOTHER_ROOT/mock-docker-args, returns empty lists for ps/volume/network
# (nothing to remove), and fails `docker info` when MOCK_DOCKER_INFO_EXIT is
# set non-zero (default: success).
_install_mock_docker() {
    cat > "$_MOCK_BIN/docker" <<'DOCKER'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${MOTHER_ROOT:?}/mock-docker-args"
case "$1" in
    info)
        exit "${MOCK_DOCKER_INFO_EXIT:-0}"
        ;;
    ps|volume|network)
        echo ""
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
DOCKER
    chmod +x "$_MOCK_BIN/docker"
}

# Back-date a live job's finished_at so the bulk sweep's age gate passes it.
# Usage: _age_job <id> <iso-timestamp>
_age_job() {
    local id="$1" ts="$2" tmp
    tmp=$(mktemp)
    jq --arg ts "$ts" '.finished_at = $ts' "$JOBS_DIR/$id.json" > "$tmp" && mv "$tmp" "$JOBS_DIR/$id.json"
}

# Count `gh pr view` invocations recorded by the gh mock.
_gh_view_count() { grep -c "pr view" "$MOTHER_ROOT/mock-gh-calls" 2>/dev/null || echo 0; }

setup() {
    setup_mother_env
    _install_mock_gh
    _install_mock_docker
}

teardown() {
    teardown_mother_env
}

# ===========================================================================
# Unit tests: mother_compose_project (lib/state.sh)
# ===========================================================================

@test "mother_compose_project: sanitizes a mixed-case job id into a valid compose project name" {
    run bash -c "$(_source_teardown_libs) mother_compose_project '20260730T114600Z-A1B2C3D4'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^mother-[a-z0-9_-]+$ ]]
    [ "$output" = "mother-20260730t114600z-a1b2c3d4" ]
}

@test "mother_compose_project: strips disallowed characters instead of replacing them" {
    run bash -c "$(_source_teardown_libs) mother_compose_project 'abc.def!ghi'"
    [ "$status" -eq 0 ]
    [[ "$output" =~ ^mother-[a-z0-9_-]+$ ]]
    [ "$output" = "mother-abcdefghi" ]
}

# ===========================================================================
# Unit tests: _teardown_pr_disposition
# ===========================================================================

@test "_teardown_pr_disposition: gh MERGED state maps to merged" {
    export MOCK_GH_STATE="MERGED"
    run bash -c "$(_source_teardown_libs) _teardown_pr_disposition 'https://github.com/x/y/pull/1'"
    [ "$status" -eq 0 ]
    [ "$output" = "merged" ]
}

@test "_teardown_pr_disposition: gh CLOSED state maps to closed" {
    export MOCK_GH_STATE="CLOSED"
    run bash -c "$(_source_teardown_libs) _teardown_pr_disposition 'https://github.com/x/y/pull/1'"
    [ "$status" -eq 0 ]
    [ "$output" = "closed" ]
}

@test "_teardown_pr_disposition: gh OPEN state maps to open" {
    export MOCK_GH_STATE="OPEN"
    run bash -c "$(_source_teardown_libs) _teardown_pr_disposition 'https://github.com/x/y/pull/1'"
    [ "$status" -eq 0 ]
    [ "$output" = "open" ]
}

@test "_teardown_pr_disposition: gh command failure maps to inconclusive" {
    export MOCK_GH_EXIT=1
    run bash -c "$(_source_teardown_libs) _teardown_pr_disposition 'https://github.com/x/y/pull/1'"
    [ "$status" -eq 0 ]
    [ "$output" = "inconclusive" ]
}

@test "_teardown_pr_disposition: no gh on PATH maps to inconclusive" {
    # Restrict PATH so no gh binary (real or mocked) can be found. Preserve
    # MOTHER_ROOT explicitly so state.sh's mkdir -p targets the test tmpdir,
    # not the real ~/.mother.
    run env -i HOME="$HOME" MOTHER_ROOT="$MOTHER_ROOT" PATH=/usr/bin:/bin bash -c "
        $(_source_teardown_libs)
        _teardown_pr_disposition 'https://github.com/x/y/pull/1'
    "
    [ "$status" -eq 0 ]
    [ "$output" = "inconclusive" ]
}

# ===========================================================================
# Unit tests: _teardown_gate
# ===========================================================================

@test "_teardown_gate: no pr_url + failed state -> proceed:no_pr_terminal, never calls gh" {
    facts=$(_facts_json "job-g1" "/tmp/r1" "b1" "/tmp/w1" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "proceed:no_pr_terminal" ]
    [ ! -s "$MOTHER_ROOT/mock-gh-calls" ]
}

@test "_teardown_gate: no pr_url + cancelled state -> proceed:no_pr_terminal" {
    facts=$(_facts_json "job-g1b" "/tmp/r1b" "b1b" "/tmp/w1b" "worktree" "" "cancelled" false)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "proceed:no_pr_terminal" ]
}

@test "_teardown_gate: no pr_url + succeeded + no_pr=true -> proceed:no_pr_by_design" {
    facts=$(_facts_json "job-g2" "/tmp/r2" "b2" "/tmp/w2" "worktree" "" "succeeded" true)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "proceed:no_pr_by_design" ]
}

@test "_teardown_gate: no pr_url + succeeded + no_pr=false -> defer:no_pr_url_on_succeeded" {
    facts=$(_facts_json "job-g3" "/tmp/r3" "b3" "/tmp/w3" "worktree" "" "succeeded" false)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "defer:no_pr_url_on_succeeded" ]
}

@test "_teardown_gate: pr_url set + disposition merged -> proceed:pr_merged" {
    export MOCK_GH_STATE="MERGED"
    facts=$(_facts_json "job-g4" "/tmp/r4" "b4" "/tmp/w4" "worktree" "https://github.com/x/y/pull/4" "succeeded" false)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "proceed:pr_merged" ]
}

@test "_teardown_gate: pr_url set + disposition closed -> proceed:pr_closed" {
    export MOCK_GH_STATE="CLOSED"
    facts=$(_facts_json "job-g5" "/tmp/r5" "b5" "/tmp/w5" "worktree" "https://github.com/x/y/pull/5" "succeeded" false)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "proceed:pr_closed" ]
}

@test "_teardown_gate: pr_url set + disposition open -> defer:pr_open" {
    export MOCK_GH_STATE="OPEN"
    facts=$(_facts_json "job-g6" "/tmp/r6" "b6" "/tmp/w6" "worktree" "https://github.com/x/y/pull/6" "succeeded" false)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "defer:pr_open" ]
}

@test "_teardown_gate: pr_url set + disposition inconclusive -> defer:gh_inconclusive" {
    export MOCK_GH_EXIT=1
    facts=$(_facts_json "job-g7" "/tmp/r7" "b7" "/tmp/w7" "worktree" "https://github.com/x/y/pull/7" "succeeded" false)
    run bash -c "$(_source_teardown_libs) _teardown_gate '$facts'"
    [ "$status" -eq 0 ]
    [ "$output" = "defer:gh_inconclusive" ]
}

# ===========================================================================
# Unit tests: _teardown_race_check
# ===========================================================================

@test "_teardown_race_check: conflicts when another non-terminal job shares repo_path+branch" {
    make_job "job-race-other" "running" \
        '.repo_path = "/tmp/shared-repo" | .branch = "feature/shared"'
    facts=$(_facts_json "job-race-self" "/tmp/shared-repo" "feature/shared" "/tmp/w" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_race_check '$facts'"
    [ "$status" -eq 1 ]
    [ "$output" = "job-race-other" ]
}

@test "_teardown_race_check: clear when no other job shares repo_path+branch" {
    make_job "job-race-unrelated" "running" \
        '.repo_path = "/tmp/different-repo" | .branch = "feature/other"'
    facts=$(_facts_json "job-race-self2" "/tmp/shared-repo2" "feature/shared2" "/tmp/w" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_race_check '$facts'"
    [ "$status" -eq 0 ]
}

@test "_teardown_race_check: excludes the facts job's own file from the conflict scan" {
    make_job "job-race-self3" "running" \
        '.repo_path = "/tmp/shared-repo3" | .branch = "feature/shared3"'
    facts=$(_facts_json "job-race-self3" "/tmp/shared-repo3" "feature/shared3" "/tmp/w" "worktree" "" "running" false)
    run bash -c "$(_source_teardown_libs) _teardown_race_check '$facts'"
    [ "$status" -eq 0 ]
}

@test "_teardown_race_check: not a conflict when the matching job is itself terminal" {
    make_job "job-race-terminal" "succeeded" \
        '.repo_path = "/tmp/shared-repo4" | .branch = "feature/shared4"'
    facts=$(_facts_json "job-race-self4" "/tmp/shared-repo4" "feature/shared4" "/tmp/w" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_race_check '$facts'"
    [ "$status" -eq 0 ]
}

# ===========================================================================
# Unit tests: _teardown_docker
# ===========================================================================

@test "_teardown_docker: MOTHER_TEARDOWN_DOCKER_ENABLED=0 skips without calling docker at all" {
    facts=$(_facts_json "job-d1" "/tmp/r" "b" "/tmp/w" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) MOTHER_TEARDOWN_DOCKER_ENABLED=0 _teardown_docker '$facts' 0"
    [ "$status" -eq 1 ]
    [ ! -f "$MOTHER_ROOT/mock-docker-args" ]
}

@test "_teardown_docker: returns 2 (defer) when the docker daemon is unreachable" {
    export MOCK_DOCKER_INFO_EXIT=1
    facts=$(_facts_json "job-d2" "/tmp/r" "b" "/tmp/w" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_docker '$facts' 0"
    [ "$status" -eq 2 ]
}

@test "_teardown_docker: tears down via compose down using the sanitized project name plus a label sweep" {
    facts=$(_facts_json "job-D4" "/tmp/r" "b" "/tmp/w" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_docker '$facts' 0"
    [ "$status" -eq 0 ]

    local down_line
    down_line=$(grep -F "mother-job-d4" "$MOTHER_ROOT/mock-docker-args" | grep -F "down")
    [ -n "$down_line" ]
    [[ "$down_line" == *"--volumes"* ]]
    [[ "$down_line" == *"--remove-orphans"* ]]
    [[ "$down_line" == *"--timeout 30"* ]]

    run grep -F "label=mother.job_id=job-D4" "$MOTHER_ROOT/mock-docker-args"
    [ "$status" -eq 0 ]
    run grep -F "label=com.docker.compose.project=mother-job-d4" "$MOTHER_ROOT/mock-docker-args"
    [ "$status" -eq 0 ]
}

# ===========================================================================
# Unit tests: _teardown_worktree
# ===========================================================================

@test "_teardown_worktree: isolation != worktree returns 1 and never touches repo_path (main-dir guard)" {
    local repo_dir="$MOTHER_ROOT/main-repo-w1"
    mkdir -p "$repo_dir"
    facts=$(_facts_json "job-w1" "$repo_dir" "b" "$repo_dir" "main-dir" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_worktree '$facts' 0"
    [ "$status" -eq 1 ]
    [ -d "$repo_dir" ]
}

@test "_teardown_worktree: removes a real worktree directory when isolation=worktree" {
    local repo_dir="$MOTHER_ROOT/repo-w2"
    local wt_dir="$MOTHER_ROOT/wt-w2"
    _make_teardown_repo "$repo_dir"
    _make_teardown_worktree "$repo_dir" "$wt_dir" "feature/w2"
    facts=$(_facts_json "job-w2" "$repo_dir" "feature/w2" "$wt_dir" "worktree" "" "failed" false)
    run bash -c "$(_source_teardown_libs) _teardown_worktree '$facts' 0"
    [ "$status" -eq 0 ]
    [ ! -d "$wt_dir" ]
}

# ===========================================================================
# End-to-end: `mother archive` / `mother teardowns`
# ===========================================================================

# ---- 1. PR open -> deferred ----

@test "PR open on a succeeded job defers teardown; worktree and archived job both survive" {
    export MOCK_GH_STATE="OPEN"
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-open" "succeeded" '.pr_url = "https://github.com/x/y/pull/1"')

    run mother archive "e2e-open"
    [ "$status" -eq 0 ]

    [ -d "$wt_dir" ]
    [ -f "$TEARDOWN_DIR/e2e-open.json" ]

    local events_file
    events_file=$(_find_events_file "e2e-open")
    run grep -F '"kind":"teardown_deferred"' "$events_file"
    [ "$status" -eq 0 ]
    run grep -F '"reason":"pr_open"' "$events_file"
    [ "$status" -eq 0 ]

    # Archiving is never blocked by a skipped teardown.
    [ ! -f "$JOBS_DIR/e2e-open.json" ]
    run bash -c "find '$ARCHIVE_DIR' -name 'e2e-open.json' | grep -q ."
    [ "$status" -eq 0 ]
}

# ---- 2. PR merged -> torn down ----

@test "PR merged tears down worktree and docker resources, leaving no pending record" {
    export MOCK_GH_STATE="MERGED"
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-merged" "succeeded" '.pr_url = "https://github.com/x/y/pull/2"')

    run mother archive "e2e-merged"
    [ "$status" -eq 0 ]

    [ ! -d "$wt_dir" ]
    [ ! -f "$TEARDOWN_DIR/e2e-merged.json" ]

    local events_file
    events_file=$(_find_events_file "e2e-merged")
    run grep -F '"kind":"teardown_completed"' "$events_file"
    [ "$status" -eq 0 ]

    local down_line
    down_line=$(grep -F "mother-e2e-merged" "$MOTHER_ROOT/mock-docker-args" | grep -F "down")
    [ -n "$down_line" ]
}

# ---- 3. no pr_url + failed -> immediate teardown, gh never invoked ----

@test "no PR URL on a failed job tears down immediately without ever invoking gh" {
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-failed-nopr" "failed" '.pr_url = null')

    run mother archive "e2e-failed-nopr"
    [ "$status" -eq 0 ]

    [ ! -d "$wt_dir" ]
    [ ! -s "$MOTHER_ROOT/mock-gh-calls" ]

    local events_file
    events_file=$(_find_events_file "e2e-failed-nopr")
    run grep -F '"kind":"teardown_completed"' "$events_file"
    [ "$status" -eq 0 ]
}

# ---- 4. gh fails -> deferred gh_inconclusive ----

@test "gh failure defers teardown as gh_inconclusive and leaves the worktree intact" {
    export MOCK_GH_EXIT=1
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-gh-fail" "succeeded" '.pr_url = "https://github.com/x/y/pull/4"')

    run mother archive "e2e-gh-fail"
    [ "$status" -eq 0 ]

    [ -d "$wt_dir" ]
    [ -f "$TEARDOWN_DIR/e2e-gh-fail.json" ]

    local events_file
    events_file=$(_find_events_file "e2e-gh-fail")
    run grep -F '"reason":"gh_inconclusive"' "$events_file"
    [ "$status" -eq 0 ]
}

# ---- 5. race guard ----

@test "a running job sharing repo_path and branch defers teardown as a race, worktree intact" {
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-race-victim" "failed" '.pr_url = null')
    local repo_path branch
    repo_path=$(jq -r '.repo_path' "$JOBS_DIR/e2e-race-victim.json")
    branch=$(jq -r '.branch' "$JOBS_DIR/e2e-race-victim.json")

    make_job "e2e-race-conflict" "running" \
        ".repo_path = \"$repo_path\" | .branch = \"$branch\""

    run mother archive "e2e-race-victim"
    [ "$status" -eq 0 ]

    [ -d "$wt_dir" ]

    local events_file
    events_file=$(_find_events_file "e2e-race-victim")
    run grep -F '"reason":"race"' "$events_file"
    [ "$status" -eq 0 ]
    run grep -F "e2e-race-conflict" "$events_file"
    [ "$status" -eq 0 ]
}

# ---- 6. isolation main-dir -> skipped main_dir ----

@test "isolation=main-dir never removes the checkout and marks teardown skipped" {
    local repo_dir="$MOTHER_ROOT/repo-e2e-maindir"
    _make_teardown_repo "$repo_dir"
    make_job "e2e-maindir" "failed" \
        ".repo_path = \"$repo_dir\" | .branch = \"main\" | .isolation = \"main-dir\" | .pr_url = null | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

    run mother archive "e2e-maindir"
    [ "$status" -eq 0 ]

    [ -d "$repo_dir" ]

    local events_file
    events_file=$(_find_events_file "e2e-maindir")
    run grep -F '"kind":"teardown_skipped"' "$events_file"
    [ "$status" -eq 0 ]
    run grep -F '"reason":"main_dir"' "$events_file"
    [ "$status" -eq 0 ]
}

# ---- 7. --dry-run ----

@test "--dry-run leaves worktree, pending queue, events, and docker state untouched" {
    export MOCK_GH_STATE="MERGED"
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-dryrun" "succeeded" '.pr_url = "https://github.com/x/y/pull/7"')

    run mother archive "e2e-dryrun" --dry-run
    [ "$status" -eq 0 ]

    [ -d "$wt_dir" ]
    [ ! -f "$TEARDOWN_DIR/e2e-dryrun.json" ]
    [ -f "$JOBS_DIR/e2e-dryrun.json" ]

    # No teardown_* events written anywhere (job never archived either, so
    # the events file, if any, is still the live one). Safe against the file
    # not existing at all (that also counts as "no teardown events").
    run bash -c "grep -E '\"kind\":\"teardown_' '$EVENTS_DIR/e2e-dryrun.jsonl' 2>/dev/null; true"
    [ -z "$output" ]

    # No mutating docker call (down/rm) was made. Safe against the args file
    # not existing at all (that also counts as "no mutating call").
    run bash -c "grep -E '(^| )(down|rm)( |$)' '$MOTHER_ROOT/mock-docker-args' 2>/dev/null; true"
    [ -z "$output" ]
}

# ---- 8. drain via bulk archive ----

@test "bulk archive drains a pending teardown record once the PR reports merged" {
    export MOCK_GH_STATE="OPEN"
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-drain" "succeeded" '.pr_url = "https://github.com/x/y/pull/8"')

    run mother archive "e2e-drain"
    [ "$status" -eq 0 ]
    [ -d "$wt_dir" ]
    [ -f "$TEARDOWN_DIR/e2e-drain.json" ]

    # The PR has since merged.
    export MOCK_GH_STATE="MERGED"

    run mother archive --older-than 0
    [ "$status" -eq 0 ]

    [ ! -d "$wt_dir" ]
    [ ! -f "$TEARDOWN_DIR/e2e-drain.json" ]
}

# ---- extra: `mother teardowns` listing + explicit --drain ----

@test "mother teardowns lists pending records and --drain re-attempts them" {
    export MOCK_GH_STATE="OPEN"
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-teardowns-cmd" "succeeded" '.pr_url = "https://github.com/x/y/pull/11"')

    run mother archive "e2e-teardowns-cmd"
    [ "$status" -eq 0 ]
    [ -f "$TEARDOWN_DIR/e2e-teardowns-cmd.json" ]

    run mother teardowns
    [ "$status" -eq 0 ]
    [[ "$output" =~ "e2e-teardowns-cmd" ]]

    export MOCK_GH_STATE="MERGED"
    run mother teardowns --drain
    [ "$status" -eq 0 ]

    [ ! -d "$wt_dir" ]
    [ ! -f "$TEARDOWN_DIR/e2e-teardowns-cmd.json" ]
}

# ---- 9. docker unreachable -> deferred ----

@test "docker daemon unreachable defers teardown so the worktree survives for its compose state" {
    export MOCK_GH_STATE="MERGED"
    export MOCK_DOCKER_INFO_EXIT=1
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-docker-down" "succeeded" '.pr_url = "https://github.com/x/y/pull/9"')

    run mother archive "e2e-docker-down"
    [ "$status" -eq 0 ]

    [ -d "$wt_dir" ]
    [ -f "$TEARDOWN_DIR/e2e-docker-down.json" ]

    local events_file
    events_file=$(_find_events_file "e2e-docker-down")
    run grep -F '"reason":"docker_unreachable"' "$events_file"
    [ "$status" -eq 0 ]
}

# ---- 10. kill switch ----

@test "MOTHER_TEARDOWN_ENABLED=0 skips teardown entirely but still queues a pending record" {
    export MOCK_GH_STATE="MERGED"
    export MOTHER_TEARDOWN_ENABLED=0
    local wt_dir
    wt_dir=$(_make_teardown_job "e2e-disabled" "succeeded" '.pr_url = "https://github.com/x/y/pull/10"')

    run mother archive "e2e-disabled"
    [ "$status" -eq 0 ]

    [ -d "$wt_dir" ]
    [ -f "$TEARDOWN_DIR/e2e-disabled.json" ]

    local events_file
    events_file=$(_find_events_file "e2e-disabled")
    run grep -F '"kind":"teardown_skipped"' "$events_file"
    [ "$status" -eq 0 ]
    run grep -F '"reason":"disabled"' "$events_file"
    [ "$status" -eq 0 ]
}

# ---- 12. back-compat: repo_path no longer exists on disk ----

@test "archiving a job whose repo_path no longer exists on disk still succeeds" {
    make_job "e2e-missing-repo" "failed" \
        ".repo_path = \"/nonexistent/path/does-not-exist\" | .branch = \"gone\" | .isolation = \"worktree\" | .pr_url = null | .finished_at = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\""

    run mother archive "e2e-missing-repo"
    [ "$status" -eq 0 ]

    [ ! -f "$JOBS_DIR/e2e-missing-repo.json" ]
    run bash -c "find '$ARCHIVE_DIR' -name 'e2e-missing-repo.json' | grep -q ."
    [ "$status" -eq 0 ]
}

# ===========================================================================
# Teardown decoupled from the archive age gate
# ===========================================================================

# ---- 1 ----

@test "bulk sweep tears down a young merged job without archiving its record" {
    export MOCK_GH_STATE="MERGED"
    local wt_dir
    wt_dir=$(_make_teardown_job "young-merged" "succeeded" '.pr_url = "https://github.com/x/y/pull/20"')

    run mother archive
    [ "$status" -eq 0 ]

    [ ! -d "$wt_dir" ]
    [ -f "$JOBS_DIR/young-merged.json" ]
    run bash -c "find '$ARCHIVE_DIR' -name 'young-merged.json' | grep -q ."
    [ "$status" -ne 0 ]

    assert_job_field "young-merged" '.teardown_status' "torn_down"

    local events_file
    events_file=$(_find_events_file "young-merged")
    run grep -F '"kind":"teardown_completed"' "$events_file"
    [ "$status" -eq 0 ]
}

@test "bulk sweep summary line reports teardown-only separately from archived" {
    export MOCK_GH_STATE="MERGED"
    _make_teardown_job "young-merged-2" "succeeded" '.pr_url = "https://github.com/x/y/pull/21"'

    run mother archive
    [ "$status" -eq 0 ]
    [[ "$output" =~ "archived: 0" ]]
    [[ "$output" =~ "teardown-only: 1" ]]
}

# ---- 2 ----

@test "a job torn down while young later archives cleanly, teardown a no-op" {
    export MOCK_GH_STATE="MERGED"
    local wt_dir
    wt_dir=$(_make_teardown_job "age-into-archive" "succeeded" '.pr_url = "https://github.com/x/y/pull/22"')

    run mother archive
    [ "$status" -eq 0 ]
    [ ! -d "$wt_dir" ]
    [ -f "$JOBS_DIR/age-into-archive.json" ]

    _age_job "age-into-archive" "2020-01-01T00:00:00Z"

    run mother archive
    [ "$status" -eq 0 ]
    [[ "$output" =~ "archived: 1" ]]

    [ ! -f "$JOBS_DIR/age-into-archive.json" ]
    local archived_file
    archived_file=$(find "$ARCHIVE_DIR" -name 'age-into-archive.json')
    [ -n "$archived_file" ]

    local events_file
    events_file=$(_find_events_file "age-into-archive")
    run grep -F '"kind":"teardown_failed"' "$events_file"
    [ "$status" -ne 0 ]

    run jq -r '.teardown_status' "$archived_file"
    [ "$output" = "torn_down" ]
}

# ---- 3 ----

@test "--older-than 0 archives and moves rather than taking the teardown-only path" {
    export MOCK_GH_STATE="MERGED"
    _make_teardown_job "older-than-zero" "succeeded" '.pr_url = "https://github.com/x/y/pull/23"'

    run mother archive --older-than 0
    [ "$status" -eq 0 ]
    [[ "$output" =~ "archived: 1" ]]
    [[ "$output" =~ "teardown-only: 0" ]]

    [ ! -f "$JOBS_DIR/older-than-zero.json" ]
    run bash -c "find '$ARCHIVE_DIR' -name 'older-than-zero.json' | grep -q ."
    [ "$status" -eq 0 ]
}

# ---- 4 ----

@test "teardown-only accrues exactly one deferral per sweep" {
    export MOCK_GH_STATE="OPEN"
    local wt_dir
    wt_dir=$(_make_teardown_job "one-deferral-per-sweep" "succeeded" '.pr_url = "https://github.com/x/y/pull/24"')

    run mother archive
    [ "$status" -eq 0 ]
    [ "$(jq -r '.deferrals' "$TEARDOWN_DIR/one-deferral-per-sweep.json")" = "1" ]

    run mother archive
    [ "$status" -eq 0 ]
    [ "$(jq -r '.deferrals' "$TEARDOWN_DIR/one-deferral-per-sweep.json")" = "2" ]

    run mother archive
    [ "$status" -eq 0 ]
    [ "$(jq -r '.deferrals' "$TEARDOWN_DIR/one-deferral-per-sweep.json")" = "3" ]
    [ "$(jq -r '.stall_deferrals' "$TEARDOWN_DIR/one-deferral-per-sweep.json")" = "0" ]

    [ -d "$wt_dir" ]
    [ -f "$JOBS_DIR/one-deferral-per-sweep.json" ]
}

# ---- 5 ----

@test "the drain and the teardown-only path never both attempt the same job in one sweep" {
    export MOCK_GH_STATE="OPEN"
    _make_teardown_job "no-double-attempt" "succeeded" '.pr_url = "https://github.com/x/y/pull/25"'

    run mother archive
    [ "$status" -eq 0 ]
    [ -f "$TEARDOWN_DIR/no-double-attempt.json" ]

    : > "$MOTHER_ROOT/mock-gh-calls"

    run mother archive
    [ "$status" -eq 0 ]
    [ "$(_gh_view_count)" = "1" ]
}

# ---- 6 ----

@test "pr_open deferrals never fire teardown_needs_attention" {
    export MOTHER_TEARDOWN_MAX_DEFERRALS=1
    export MOCK_GH_STATE="OPEN"
    _make_teardown_job "pr-open-never-stalls" "succeeded" '.pr_url = "https://github.com/x/y/pull/26"'

    run mother archive
    [ "$status" -eq 0 ]
    run mother archive
    [ "$status" -eq 0 ]
    run mother archive
    [ "$status" -eq 0 ]

    local events_file
    events_file=$(_find_events_file "pr-open-never-stalls")
    run grep -F '"kind":"teardown_needs_attention"' "$events_file"
    [ "$status" -ne 0 ]

    [ "$(jq -r '.deferrals' "$TEARDOWN_DIR/pr-open-never-stalls.json")" = "3" ]
    [ "$(jq -r '.stall_deferrals' "$TEARDOWN_DIR/pr-open-never-stalls.json")" = "0" ]
}

# ---- 7 ----

@test "a genuinely stalled teardown still fires teardown_needs_attention exactly once" {
    export MOTHER_TEARDOWN_MAX_DEFERRALS=1
    export MOCK_GH_EXIT=1
    _make_teardown_job "genuinely-stalled" "succeeded" '.pr_url = "https://github.com/x/y/pull/27"'

    run mother archive
    [ "$status" -eq 0 ]
    run mother archive
    [ "$status" -eq 0 ]
    run mother archive
    [ "$status" -eq 0 ]
    run mother archive
    [ "$status" -eq 0 ]

    local stalls
    stalls=$(jq -r '.stall_deferrals' "$TEARDOWN_DIR/genuinely-stalled.json")
    [ "$stalls" -gt 1 ]

    local events_file
    events_file=$(_find_events_file "genuinely-stalled")
    local count
    count=$(grep -c '"kind":"teardown_needs_attention"' "$events_file")
    [ "$count" -eq 1 ]
}

# ---- 8 ----

@test "MOTHER_TEARDOWN_ENABLED=0 leaves a young job's worktree alone on the teardown-only path" {
    export MOCK_GH_STATE="MERGED"
    export MOTHER_TEARDOWN_ENABLED=0
    local wt_dir
    wt_dir=$(_make_teardown_job "disabled-young" "succeeded" '.pr_url = "https://github.com/x/y/pull/28"')

    run mother archive
    [ "$status" -eq 0 ]

    [ -d "$wt_dir" ]
    [ -f "$TEARDOWN_DIR/disabled-young.json" ]
    [ -f "$JOBS_DIR/disabled-young.json" ]

    local events_file
    events_file=$(_find_events_file "disabled-young")
    run grep -F '"kind":"teardown_skipped"' "$events_file"
    [ "$status" -eq 0 ]
    run grep -F '"reason":"disabled"' "$events_file"
    [ "$status" -eq 0 ]
}

# ---- 9 ----

@test "MOTHER_TEARDOWN_DOCKER_ENABLED=0 on the teardown-only path skips docker but removes the worktree" {
    export MOCK_GH_STATE="MERGED"
    export MOTHER_TEARDOWN_DOCKER_ENABLED=0
    local wt_dir
    wt_dir=$(_make_teardown_job "docker-disabled-young" "succeeded" '.pr_url = "https://github.com/x/y/pull/29"')

    run mother archive
    [ "$status" -eq 0 ]

    [ ! -d "$wt_dir" ]
    run bash -c "[ -s '$MOTHER_ROOT/mock-docker-args' ]"
    [ "$status" -ne 0 ]
}

# ---- 10 ----

@test "_teardown_execute is idempotent across two lifetime calls" {
    export MOCK_GH_STATE="MERGED"
    local repo_dir="$MOTHER_ROOT/repo-idempotent"
    local wt_dir="$MOTHER_ROOT/wt-idempotent"
    _make_teardown_repo "$repo_dir"
    _make_teardown_worktree "$repo_dir" "$wt_dir" "feature/idempotent"
    facts=$(_facts_json "job-idempotent" "$repo_dir" "feature/idempotent" "$wt_dir" "worktree" \
        "https://github.com/x/y/pull/30" "succeeded" false)

    run bash -c "$(_source_teardown_libs)
        _teardown_execute '$facts' 0
        rc1=\$?
        s1=\"\$TEARDOWN_LAST_STATUS\"; r1=\"\$TEARDOWN_LAST_REASON\"
        _teardown_execute '$facts' 0
        rc2=\$?
        s2=\"\$TEARDOWN_LAST_STATUS\"; r2=\"\$TEARDOWN_LAST_REASON\"
        echo \"rc1=\$rc1 s1=\$s1 r1=\$r1 rc2=\$rc2 s2=\$s2 r2=\$r2\"
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc1=0"* ]]
    [[ "$output" == *"s1=torn_down"* ]]
    [[ "$output" == *"r1=pr_merged"* ]]
    [[ "$output" == *"rc2=0"* ]]
    [[ "$output" == *"s2=skipped"* ]]
    [[ "$output" == *"r2=already_absent"* ]]

    [ ! -d "$wt_dir" ]

    local events_file
    events_file=$(_find_events_file "job-idempotent")
    run grep -F '"kind":"teardown_failed"' "$events_file"
    [ "$status" -ne 0 ]
}
