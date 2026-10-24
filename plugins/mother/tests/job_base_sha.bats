#!/usr/bin/env bats
# job_base_sha.bats — a job's diff base is a fixed commit, not a moving ref.
#
# BUG: `mother add --base origin/<pr-branch> --expect-branch-mismatch` (a fix-up
# job on an existing PR branch) stored base_ref as the string `origin/<pr-branch>`,
# a MOVING remote-tracking ref. Every local-diff consumer evaluates it late, after
# the worker pushed to that same branch (which advances origin/<pr-branch>), so
# merge-base(base_ref, HEAD) == HEAD and the diff is empty:
#   - the lens wave's changed-file list (`mother merge-findings --wave`)
#   - the pre-ready adherence review's diff (`mother adherence-review --pre-ready`)
#   - gate `when: {paths}` applicability (`mother gates run --job`, observe gates)
#   - the no_pr "commits ahead of base" success check in mother-run-job
#
# CONTRACT: `mother add` resolves base_ref once to a commit and stores it as
# `.base_sha` (full 40-hex) next to the unchanged `.base_ref`. Local-diff consumers
# prefer `.base_sha` and fall back to `.base_ref` for jobs that predate it.
# mother-run-job refreshes `.base_sha` to the commit a brand-new branch/worktree is
# created from (after its fetch); a resume/rework run on an existing worktree keeps
# it. PR targeting and worktree creation still use base_ref. `mother status` and
# `mother peek` show the short sha.
#
# Observable surfaces used (never internals):
#   job JSON            .base_sha, .base_ref, .state, .failure_reason, .gates.results[]
#   merged.json         .coverage_gaps[].location == changed files no lens examined
#                       (the lens stub examines nothing, so gaps == the changed list)
#   mother gates run    --format json .results[] {name, result, skip_reason}
#   adherence prompt    the "## PR Diff" section the reviewer receives on stdin
#   status / peek text
#
# Harness: temp repo with a BARE origin (main + a PR branch feature/x one commit
# ahead of main), real `mother add`, hand-made worktrees for the cheap tests, and
# real `mother-run-job` subprocesses (~3s each) for the lifecycle tests. gh and
# claude are stand-ins. No stacks, no ~/.mother.

bats_require_minimum_version 1.5.0
load 'test_helper'

setup() {
    setup_mother_env
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID BS_PUSH_BRANCH
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120

    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    ORIGIN="$MOTHER_ROOT/origin.git"
    REPO="$MOTHER_ROOT/work/baserepo"
    OTHER="$MOTHER_ROOT/work/other-clone"
    mkdir -p "$REPO"
    git init -q --bare "$ORIGIN"
    (
        cd "$REPO"
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        mkdir -p .mother
        cat > .mother/crew.yml <<'CREW'
version: 1
gates:
  mode: observe
  max_attempts: 2
  budget_minutes: 10
  checks:
    - name: src_scoped
      run: "true"
      when:
        paths:
          - "src/**"
    - name: docs_scoped
      run: "true"
      when:
        paths:
          - "docs/**"
CREW
        git add .
        git commit -q -m "init"
        git remote add origin "$ORIGIN"
        git push -q -u origin main

        # The existing PR branch: one commit ahead of main (touching docs/).
        git checkout -q -b feature/x
        mkdir -p docs
        echo "pr notes" > docs/pr-notes.md
        git add docs
        git commit -q -m "PR: first pass"
        git push -q -u origin feature/x
        git checkout -q main
        git branch -q -D feature/x
    ) >/dev/null 2>&1
}

teardown() { teardown_mother_env; }

# ---------------------------------------------------------------------------
# Helpers

_bs_job() { jq -r "$2" "$JOBS_DIR/$1.json"; }
# _bs_eq <actual> <expected> <label> — assert equality; on failure bats' "Last output" names both sides.
_bs_eq() { run printf '%s: expected [%s] got [%s]' "${3:-value}" "$2" "$1"; [ "$1" = "$2" ]; }
_bs_origin_sha() { git -C "$REPO" rev-parse "$1^{commit}"; }

# _bs_plan <path> [no_pr] — a plan with a valid suggested_config (and no_pr: true on request).
_bs_plan() {
    cat > "$1" <<'PLAN'
# Fix-up plan

## Context
Address review comments on an open PR.

## Target
- **Repo:** baserepo

## Acceptance criteria
- It works.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "x"
  redd:
    model: sonnet
    effort: medium
    rationale: "x"
  marty:
    model: sonnet
    effort: medium
    rationale: "x"
  perri:
    model: sonnet
    effort: medium
    rationale: "x"
PLAN
    [ "${2:-}" = "no_pr" ] && printf 'no_pr: true\n' >> "$1"
    printf '```\n' >> "$1"
}

# _bs_add <branch> <base> [no_pr] [extra mother-add flags...] — sets ID.
_bs_add() {
    local branch="$1" base="$2" np="${3:-}"
    shift 3 2>/dev/null || shift $#
    _bs_plan "$MOTHER_ROOT/plan.md" "$np"
    run mother add --plan-file "$MOTHER_ROOT/plan.md" --repo baserepo \
        --repo-path "$REPO" --branch "$branch" --base "$base" "$@"
    [ "$status" -eq 0 ]
    ID=$(printf '%s\n' "$output" | tail -1)
    [ -f "$JOBS_DIR/$ID.json" ]
}

# The standard fix-up job: PR branch feature/x, base = the PR branch's remote ref.
_bs_add_fixup() { _bs_add feature/x origin/feature/x "${1:-}" --expect-branch-mismatch; }

# _bs_worktree <id> — what mother-run-job does for a fresh worktree job: a worktree
# on the job's branch created from its base_ref, recorded as .work_dir.
_bs_worktree() {
    local id="$1" branch base_ref wt
    branch=$(_bs_job "$id" '.branch'); base_ref=$(_bs_job "$id" '.base_ref')
    wt="$MOTHER_ROOT/work/wt-$id"
    git -C "$REPO" worktree add -q -b "$branch" "$wt" "$base_ref" >/dev/null 2>&1
    jq --arg w "$wt" '.work_dir = $w | .state = "running"' "$JOBS_DIR/$id.json" > "$JOBS_DIR/$id.tmp" \
        && mv "$JOBS_DIR/$id.tmp" "$JOBS_DIR/$id.json"
    WT="$wt"
}

# _bs_worker_commit [push-branch] — the worker's fix-up in $WT: a source file and a
# test file; pushed to origin/<push-branch> when given (a real worker pushes).
_bs_worker_commit() {
    (
        cd "$WT"
        mkdir -p src Tests
        echo 'let fixed = true' > src/app.swift
        echo 'import XCTest' > Tests/AppTests.swift
        git add src Tests
        git commit -q -m "worker: fix-up"
        if [ -n "${1:-}" ]; then git push -q origin "HEAD:refs/heads/$1"; fi
    ) >/dev/null 2>&1
}

# _bs_advance_main — someone else lands docs/main-only.md on origin/main, from a
# second clone, so REPO's origin/main only moves when REPO fetches.
_bs_advance_main() {
    (
        rm -rf "$OTHER"
        git clone -q "$ORIGIN" "$OTHER"
        cd "$OTHER"
        git config user.email "other@example.com"
        git config user.name "Other"
        mkdir -p docs
        echo "main only" > docs/main-only.md
        git add docs
        git commit -q -m "main moves on"
        git push -q origin main
    ) >/dev/null 2>&1
}

# _bs_changed <id> — comma-joined changed-file list the lens wave computes for the job.
_bs_changed() {
    local id="$1" wave="$MOTHER_ROOT/crew/$1/wave/c0"
    mkdir -p "$wave"
    printf '{"findings":[],"examined":[],"cost_usd":0,"decision":"continue"}' > "$wave/correctness.json"
    run mother merge-findings "$id" --wave "$id" --cycle 0
    [ "$status" -eq 0 ]
    jq -r '[.coverage_gaps[].location] | sort | join(",")' "$wave/merged.json"
}

# _bs_gates <id> — runs `mother gates run --job` into $MOTHER_ROOT/gates.json.
_bs_gates() {
    mother gates run --job "$1" --format json > "$MOTHER_ROOT/gates.json" 2>/dev/null || true
    jq -e '.results' "$MOTHER_ROOT/gates.json" >/dev/null
}
_bs_gate_field() { jq -r --arg n "$1" '.results[] | select(.name == $n) | .'"$2" "$MOTHER_ROOT/gates.json"; }
# _bs_job_gate <id> <name> <field> — the same, from a finished job's recorded .gates.
_bs_job_gate() { jq -r --arg n "$2" '.gates.results[] | select(.name == $n) | .'"$3" "$JOBS_DIR/$1.json"; }

# _bs_install_worker — a stand-in worker that commits a source and a test file in its
# worktree (a new content each run), and pushes to origin/$BS_PUSH_BRANCH when set.
_bs_install_worker() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
root="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-}}"
n=$(cat "$root/bs-n" 2>/dev/null || echo 0)
n=$((n + 1))
echo "$n" > "$root/bs-n"
mkdir -p src Tests
echo "let fixed = $n" > src/app.swift
echo "import XCTest // $n" > Tests/AppTests.swift
git add src Tests
git commit -q -m "worker change $n"
[ -z "${BS_PUSH_BRANCH:-}" ] || git push -q origin "HEAD:refs/heads/$BS_PUSH_BRANCH"
printf '%s\n' '{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}'
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

# _bs_run_job <id> — promote the queued job (what the daemon does) and run it once.
_bs_run_job() {
    jq '.state = "ready"' "$JOBS_DIR/$1.json" > "$JOBS_DIR/$1.tmp" && mv "$JOBS_DIR/$1.tmp" "$JOBS_DIR/$1.json"
    run mother-run-job "$1"
    [ "$status" -eq 0 ]
}

# ===========================================================================
# 1. `mother add` snapshots the base as a commit  [MB-1]
# ===========================================================================

@test "add stores base_sha: the full commit sha of origin/main at add time, base_ref unchanged" {
    _bs_add feature/y origin/main
    local want; want=$(_bs_origin_sha origin/main)
    [[ "$want" =~ ^[0-9a-f]{40}$ ]]
    _bs_eq "$(_bs_job "$ID" '.base_sha')" "$want" "base_sha"
    [ "$(_bs_job "$ID" '.base_ref')" = "origin/main" ]
}

@test "add stores base_sha for a PR-branch base: the tip of origin/feature/x at add time, base_ref unchanged" {
    _bs_add_fixup
    local want; want=$(_bs_origin_sha origin/feature/x)
    [[ "$want" =~ ^[0-9a-f]{40}$ ]]
    _bs_eq "$(_bs_job "$ID" '.base_sha')" "$want" "base_sha"
    [ "$(_bs_job "$ID" '.base_ref')" = "origin/feature/x" ]
    # the snapshot is of the PR branch, not of main
    [ "$(_bs_job "$ID" '.base_sha')" != "$(_bs_origin_sha origin/main)" ]
}

@test "base_sha is a snapshot: it does not move when origin/main advances after add" {
    _bs_add feature/y origin/main
    local before; before=$(_bs_job "$ID" '.base_sha')
    [[ "$before" =~ ^[0-9a-f]{40}$ ]]
    _bs_advance_main
    git -C "$REPO" fetch -q origin
    [ "$(_bs_origin_sha origin/main)" != "$before" ]
    [ "$(_bs_job "$ID" '.base_sha')" = "$before" ]
}

# ===========================================================================
# 2. status and peek show the short base_sha  [MB-1]
# ===========================================================================

@test "mother status <id> shows the short base_sha" {
    _bs_add_fixup
    local short; short=$(_bs_origin_sha origin/feature/x | cut -c1-7)
    run mother status "$ID"
    [ "$status" -eq 0 ]
    # The `=== job ===` dump is the raw JSON (it carries the sha today via .crew.source_sha
    # and would carry the full .base_sha); the display must show it outside that dump.
    local shown; shown=$(printf '%s\n' "$output" | awk '/^=== job ===/ {skip = 1; next} /^=== events ===/ {skip = 0} !skip')
    [[ "$shown" == *"$short"* ]]
}

@test "mother peek <id> shows the short base_sha" {
    _bs_add_fixup
    _bs_worktree "$ID"
    local short; short=$(_bs_origin_sha origin/feature/x | cut -c1-7)

    # peek reads the worker's transcript from $HOME/.claude/projects/<slug of work_dir>/.
    export HOME="$MOTHER_ROOT/home"
    local slug="${WT//\//-}"; slug="${slug//./-}"
    mkdir -p "$HOME/.claude/projects/$slug"
    printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"text","text":"working"}]}}' \
        > "$HOME/.claude/projects/$slug/sess.jsonl"

    run mother peek "$ID"
    [ "$status" -eq 0 ]
    [[ "$output" == *"$short"* ]]
}

# ===========================================================================
# 3. The fix-up scenario: the worker pushes to the PR branch the base points at
# ===========================================================================

@test "fix-up: merge-findings --wave sees the files the worker pushed to the PR branch" {
    _bs_add_fixup
    _bs_worktree "$ID"
    _bs_worker_commit feature/x
    [ "$(_bs_origin_sha origin/feature/x)" = "$(git -C "$WT" rev-parse HEAD)" ]   # origin/feature/x advanced

    # the worker's files, and not the PR's earlier docs/pr-notes.md (before the job)
    _bs_eq "$(_bs_changed "$ID")" "Tests/AppTests.swift,src/app.swift" "changed files"
}

@test "fix-up: a path-scoped gate for the worker's files is applicable and runs after the worker pushed" {
    _bs_add_fixup
    _bs_worktree "$ID"
    _bs_worker_commit feature/x

    _bs_gates "$ID"
    _bs_eq "$(_bs_gate_field src_scoped result)" "passed" "src_scoped result"
    # a scope the worker did not touch is still skipped, so applicability is not "everything"
    _bs_eq "$(_bs_gate_field docs_scoped result)" "skipped" "docs_scoped result"
    _bs_eq "$(_bs_gate_field docs_scoped skip_reason)" "not_applicable" "docs_scoped skip_reason"
}

@test "fix-up: the pre-ready adherence review is shown the worker's diff, not an empty one" {
    _bs_add_fixup no_pr
    _bs_worktree "$ID"
    _bs_worker_commit feature/x

    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
cat > "$ADH_PROMPT_FILE"
printf '%s\n' 'ADHERENCE: pass' 'NOTES:' 'ok'
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    export ADH_PROMPT_FILE="$MOTHER_ROOT/adherence-prompt.txt"

    run mother adherence-review "$ID" --pre-ready
    [ "$status" -eq 0 ]
    [ -s "$ADH_PROMPT_FILE" ]
    run sed -n '/^## PR Diff/,/^## CI Status/p' "$ADH_PROMPT_FILE"   # what the reviewer was shown as the diff
    [[ "$output" == *"src/app.swift"* ]]
    [[ "$output" == *"let fixed = true"* ]]
    [[ "$output" != *"(diff unavailable)"* ]]
}

@test "fix-up lifecycle: a no_pr job whose worker committed and pushed to the PR branch succeeds (not no_commits_on_branch)" {
    _bs_add_fixup no_pr
    local base_sha; base_sha=$(_bs_job "$ID" '.base_sha')
    _bs_install_worker
    export BS_PUSH_BRANCH=feature/x

    _bs_run_job "$ID"
    run jq -r '.failure_reason // "none"' "$JOBS_DIR/$ID.json"   # "Last output" names the reason on failure
    [ "$output" = "none" ]
    [ "$(_bs_job "$ID" '.state')" = "succeeded" ]
    # the PR branch moved on, the job's base did not
    [ "$(_bs_origin_sha origin/feature/x)" != "$base_sha" ]
    [ "$(_bs_job "$ID" '.base_sha')" = "$base_sha" ]
}

@test "fix-up lifecycle: observe gates scoped to the worker's files run on the pushed PR branch" {
    _bs_add_fixup
    _bs_install_worker
    export BS_PUSH_BRANCH=feature/x

    _bs_run_job "$ID"
    _bs_eq "$(_bs_job_gate "$ID" src_scoped result)" "passed" "src_scoped result"
    _bs_eq "$(_bs_job_gate "$ID" docs_scoped result)" "skipped" "docs_scoped result"
    _bs_eq "$(_bs_job_gate "$ID" docs_scoped skip_reason)" "not_applicable" "docs_scoped skip_reason"
}

# ===========================================================================
# 4. A plain `--base origin/main` job behaves as before, and main moving does
#    not leak into the job's diff
# ===========================================================================

@test "origin/main job: changed files and gate applicability are the worker's files only" {
    _bs_add feature/y origin/main
    _bs_worktree "$ID"
    _bs_worker_commit

    _bs_eq "$(_bs_changed "$ID")" "Tests/AppTests.swift,src/app.swift" "changed files"
    _bs_gates "$ID"
    _bs_eq "$(_bs_gate_field src_scoped result)" "passed" "src_scoped result"
    _bs_eq "$(_bs_gate_field docs_scoped result)" "skipped" "docs_scoped result"
}

@test "origin/main job: a commit landing on main mid-job does not enter the changed files or gate scope" {
    _bs_add feature/y origin/main
    _bs_worktree "$ID"
    _bs_worker_commit
    _bs_advance_main
    git -C "$WT" fetch -q origin
    [ -f "$OTHER/docs/main-only.md" ]
    git -C "$WT" cat-file -e origin/main:docs/main-only.md   # main really moved in the work dir

    local changed; changed=$(_bs_changed "$ID")
    [ "$changed" = "Tests/AppTests.swift,src/app.swift" ]
    [[ "$changed" != *"main-only"* ]]
    _bs_gates "$ID"
    _bs_eq "$(_bs_gate_field src_scoped result)" "passed" "src_scoped result"
    _bs_eq "$(_bs_gate_field docs_scoped result)" "skipped" "docs_scoped result"
    _bs_eq "$(_bs_gate_field docs_scoped skip_reason)" "not_applicable" "docs_scoped skip_reason"
}

@test "origin/main job: a main that advanced between add and start does not skew the diff, and base_sha follows the new branch point" {
    _bs_add feature/y origin/main
    local at_add; at_add=$(_bs_job "$ID" '.base_sha')
    _bs_advance_main
    _bs_install_worker
    export BS_PUSH_BRANCH=feature/y

    _bs_run_job "$ID"
    local now_main; now_main=$(git -C "$ORIGIN" rev-parse refs/heads/main)
    [ "$now_main" != "$at_add" ]

    # the worktree was created from the advanced main; main's own docs change is not "the job's change"
    _bs_eq "$(_bs_job_gate "$ID" src_scoped result)" "passed" "src_scoped result"
    _bs_eq "$(_bs_job_gate "$ID" docs_scoped result)" "skipped" "docs_scoped result"
    _bs_eq "$(_bs_job_gate "$ID" docs_scoped skip_reason)" "not_applicable" "docs_scoped skip_reason"
    # base_sha was refreshed to the commit the branch was created from
    _bs_eq "$(_bs_job "$ID" '.base_sha')" "$now_main" "base_sha after start"
    # base_ref (PR targeting, worktree creation) is untouched
    [ "$(_bs_job "$ID" '.base_ref')" = "origin/main" ]
}

# ===========================================================================
# 5. Jobs that predate base_sha fall back to base_ref
# ===========================================================================

@test "legacy job without base_sha: changed files and gate applicability still come from base_ref" {
    _bs_add feature/y origin/main
    jq 'del(.base_sha)' "$JOBS_DIR/$ID.json" > "$JOBS_DIR/$ID.tmp" && mv "$JOBS_DIR/$ID.tmp" "$JOBS_DIR/$ID.json"
    [ "$(jq 'has("base_sha")' "$JOBS_DIR/$ID.json")" = "false" ]
    _bs_worktree "$ID"
    _bs_worker_commit   # committed, not pushed

    _bs_eq "$(_bs_changed "$ID")" "Tests/AppTests.swift,src/app.swift" "changed files"
    _bs_gates "$ID"
    _bs_eq "$(_bs_gate_field src_scoped result)" "passed" "src_scoped result"
    _bs_eq "$(_bs_gate_field docs_scoped result)" "skipped" "docs_scoped result"
}

@test "legacy job without base_sha: the pre-ready adherence review still gets the local diff" {
    _bs_add feature/y origin/main no_pr
    jq 'del(.base_sha)' "$JOBS_DIR/$ID.json" > "$JOBS_DIR/$ID.tmp" && mv "$JOBS_DIR/$ID.tmp" "$JOBS_DIR/$ID.json"
    _bs_worktree "$ID"
    _bs_worker_commit

    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
cat > "$ADH_PROMPT_FILE"
printf '%s\n' 'ADHERENCE: pass' 'NOTES:' 'ok'
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    export ADH_PROMPT_FILE="$MOTHER_ROOT/adherence-prompt.txt"

    run mother adherence-review "$ID" --pre-ready
    [ "$status" -eq 0 ]
    grep -qF 'let fixed = true' "$ADH_PROMPT_FILE"
}

# ===========================================================================
# 6. An unresolvable base behaves exactly as before, and stores no base_sha
# ===========================================================================

@test "add with an unresolvable base still succeeds as it always did, with no crew snapshot and no base_sha" {
    _bs_add feature/y origin/does-not-exist
    [ "$(_bs_job "$ID" '.base_ref')" = "origin/does-not-exist" ]
    [ "$(_bs_job "$ID" '.base_sha // "absent"')" = "absent" ]
    [ "$(jq 'has("crew")' "$JOBS_DIR/$ID.json")" = "false" ]
    [ "$(_bs_job "$ID" '.state')" = "queued" ]
}

# ===========================================================================
# 7. A resume/rework run keeps the original base_sha
# ===========================================================================

@test "a rework run on the existing worktree keeps base_sha even though main has moved since" {
    _bs_add feature/y origin/main no_pr
    _bs_install_worker

    _bs_run_job "$ID"
    [ "$(_bs_job "$ID" '.state')" = "succeeded" ]
    local first; first=$(_bs_job "$ID" '.base_sha')
    _bs_eq "$first" "$(_bs_origin_sha origin/main)" "base_sha after first run"

    _bs_advance_main
    _bs_run_job "$ID"    # promoted back to ready, same worktree and branch
    [ "$(_bs_job "$ID" '.state')" = "succeeded" ]
    _bs_eq "$(_bs_job "$ID" '.base_sha')" "$first" "base_sha after the rework run"
    [ "$(git -C "$ORIGIN" rev-parse refs/heads/main)" != "$first" ]
    # and the second run's gates did not pick up main's docs change
    _bs_eq "$(_bs_job_gate "$ID" docs_scoped result)" "skipped" "docs_scoped result"
}
