#!/usr/bin/env bats
# review_phase.bats — tests for `mother review-phase` and `_merge_reviewer_findings`.

load 'test_helper'

setup() {
    setup_mother_env

    # Install a minimal mock `gh` that returns canned output.
    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
echo "(mock gh output)"
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"

    # Install a mock `bishop` that returns normal posture by default.
    cat > "$_MOCK_BIN/bishop" <<'BISHOP'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ] && [ "${2:-}" = "posture" ]; then
    echo "${MOCK_BISHOP_POSTURE:-normal}"
fi
exit 0
BISHOP
    chmod +x "$_MOCK_BIN/bishop"

    export MOCK_CLAUDE_ARGS_FILE="$MOTHER_ROOT/mock-claude-args"

    # Create a real git repo for diff rendering (phase_render_input needs one).
    export TEST_REPO_DIR="$MOTHER_ROOT/testrepo"
    git init -q "$TEST_REPO_DIR"
    git -C "$TEST_REPO_DIR" config user.email "test@test.com"
    git -C "$TEST_REPO_DIR" config user.name "Test"
    touch "$TEST_REPO_DIR/README.md"
    git -C "$TEST_REPO_DIR" add -A
    git -C "$TEST_REPO_DIR" commit -q -m "init"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers

_valid_findings_stdout() {
    cat <<'EOF'
I have reviewed the implementation.

```findings
[
  {
    "id": "f1",
    "target": "cody",
    "severity": "blocking",
    "summary": "Missing error handling",
    "detail": "processJob() doesn't handle nil input.",
    "location": "job.go:42"
  }
]
```
EOF
}

_empty_findings_stdout() {
    cat <<'EOF'
Looks great, nothing to flag.

```findings
[]
```
EOF
}

_invalid_findings_stdout() {
    cat <<'EOF'
Here is my review.

```findings
[
  {
    "id": "f1",
    "target": "INVALID_TARGET",
    "severity": "blocking",
    "summary": "Bad target"
  }
]
```
EOF
}

_make_pipeline_succeeded_job() {
    local id="$1"
    make_pipeline_job "$id" "cody"
    # Transition to succeeded state.
    local merged
    merged=$(jq '.state = "succeeded"' "$JOBS_DIR/$id.json")
    printf '%s' "$merged" > "$JOBS_DIR/$id.json"
}

# ---------------------------------------------------------------------------
# Well-formed findings block

@test "review-phase: well-formed findings block is persisted under reviewer_findings" {
    _make_pipeline_succeeded_job "job-rf1"
    export MOCK_CLAUDE_STDOUT="$(_valid_findings_stdout)"

    run mother review-phase "job-rf1" --reviewer archie
    [ "$status" -eq 0 ]

    # Findings persisted under .pipeline.reviewer_findings.archie
    run jq -r '.pipeline.reviewer_findings.archie | length' "$JOBS_DIR/job-rf1.json"
    [ "$output" = "1" ]
}

@test "review-phase: each persisted finding is tagged with reviewer" {
    _make_pipeline_succeeded_job "job-rf2"
    export MOCK_CLAUDE_STDOUT="$(_valid_findings_stdout)"

    run mother review-phase "job-rf2" --reviewer perri
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.reviewer_findings.perri[0].reviewer' "$JOBS_DIR/job-rf2.json"
    [ "$output" = "perri" ]
}

@test "review-phase: emits a reviewed event" {
    _make_pipeline_succeeded_job "job-rf3"
    export MOCK_CLAUDE_STDOUT="$(_valid_findings_stdout)"

    run mother review-phase "job-rf3" --reviewer ada
    [ "$status" -eq 0 ]

    assert_event_kind "job-rf3" "reviewed"
}

@test "review-phase: reviewed event contains reviewer and finding_count" {
    _make_pipeline_succeeded_job "job-rf4"
    export MOCK_CLAUDE_STDOUT="$(_valid_findings_stdout)"

    run mother review-phase "job-rf4" --reviewer archie
    [ "$status" -eq 0 ]

    local events_file="$EVENTS_DIR/job-rf4.jsonl"
    run grep '"reviewed"' "$events_file"
    [[ "$output" =~ '"reviewer":"archie"' ]]
    [[ "$output" =~ '"finding_count":1' ]]
}

# ---------------------------------------------------------------------------
# Empty findings block

@test "review-phase: empty findings block persisted, decision=ship" {
    _make_pipeline_succeeded_job "job-empty1"
    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"

    run mother review-phase "job-empty1" --reviewer archie
    [ "$status" -eq 0 ]

    run jq -r '.pipeline.reviewer_findings.archie | length' "$JOBS_DIR/job-empty1.json"
    [ "$output" = "0" ]

    # Event should show ship decision.
    local events_file="$EVENTS_DIR/job-empty1.jsonl"
    run grep '"reviewed"' "$events_file"
    [[ "$output" =~ '"decision":"ship"' ]]
}

# ---------------------------------------------------------------------------
# No findings block at all

@test "review-phase: no findings block inferred as empty, review_no_findings_block event emitted" {
    _make_pipeline_succeeded_job "job-nofb1"
    export MOCK_CLAUDE_STDOUT="I reviewed the code. Everything looks fine."

    run mother review-phase "job-nofb1" --reviewer perri
    [ "$status" -eq 0 ]

    # Empty array persisted.
    run jq -r '.pipeline.reviewer_findings.perri | length' "$JOBS_DIR/job-nofb1.json"
    [ "$output" = "0" ]

    # review_no_findings_block event emitted.
    assert_event_kind "job-nofb1" "review_no_findings_block"
}

@test "review-phase: no block still returns 0" {
    _make_pipeline_succeeded_job "job-nofb2"
    export MOCK_CLAUDE_STDOUT="LGTM."

    run mother review-phase "job-nofb2" --reviewer ada
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Invalid findings block

@test "review-phase: invalid findings block returns 2 and does not mutate reviewer_findings" {
    _make_pipeline_succeeded_job "job-inv1"
    export MOCK_CLAUDE_STDOUT="$(_invalid_findings_stdout)"

    run mother review-phase "job-inv1" --reviewer archie
    [ "$status" -eq 2 ]

    # reviewer_findings should be absent or null for archie.
    run jq -r '.pipeline.reviewer_findings.archie // "null"' "$JOBS_DIR/job-inv1.json"
    [ "$output" = "null" ]
}

@test "review-phase: invalid findings block emits review_parse_error event" {
    _make_pipeline_succeeded_job "job-inv2"
    export MOCK_CLAUDE_STDOUT="$(_invalid_findings_stdout)"

    run mother review-phase "job-inv2" --reviewer perri
    [ "$status" -eq 2 ]

    assert_event_kind "job-inv2" "review_parse_error"
}

# ---------------------------------------------------------------------------
# claude invoked with --agent <reviewer>

@test "review-phase: claude invoked with --agent archie" {
    _make_pipeline_succeeded_job "job-agent1"
    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"

    mother review-phase "job-agent1" --reviewer archie

    local agent_val
    agent_val=$(mock_claude_flag_value "--agent")
    [ "$agent_val" = "archie" ]
}

@test "review-phase: claude invoked with --agent perri for perri reviewer" {
    _make_pipeline_succeeded_job "job-agent2"
    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"

    mother review-phase "job-agent2" --reviewer perri

    local agent_val
    agent_val=$(mock_claude_flag_value "--agent")
    [ "$agent_val" = "perri" ]
}

@test "review-phase: model resolved from suggested_config" {
    _make_pipeline_succeeded_job "job-model1"
    # Override archie's model in suggested_config.
    local merged
    merged=$(jq '.suggested_config.archie = {"model":"opus","effort":"high","rationale":"test"}' \
        "$JOBS_DIR/job-model1.json")
    printf '%s' "$merged" > "$JOBS_DIR/job-model1.json"

    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"
    mother review-phase "job-model1" --reviewer archie

    # The --model flag should be opus.
    local model_val
    model_val=$(mock_claude_flag_value "--model")
    [ "$model_val" = "opus" ]
}

# ---------------------------------------------------------------------------
# Posture clamp

@test "review-phase: conservative posture clamps model to sonnet" {
    _make_pipeline_succeeded_job "job-posture1"
    # Set archie's suggested model to opus.
    local merged
    merged=$(jq '.suggested_config.archie = {"model":"opus","effort":"high","rationale":"test"}' \
        "$JOBS_DIR/job-posture1.json")
    printf '%s' "$merged" > "$JOBS_DIR/job-posture1.json"

    export MOCK_BISHOP_POSTURE="conservative"
    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"
    mother review-phase "job-posture1" --reviewer archie

    local model_val
    model_val=$(mock_claude_flag_value "--model")
    [ "$model_val" = "sonnet" ]
}

@test "review-phase: MOTHER_POSTURE_ENABLED=0 disables posture bias" {
    _make_pipeline_succeeded_job "job-posture2"
    local merged
    merged=$(jq '.suggested_config.archie = {"model":"opus","effort":"high","rationale":"test"}' \
        "$JOBS_DIR/job-posture2.json")
    printf '%s' "$merged" > "$JOBS_DIR/job-posture2.json"

    export MOCK_BISHOP_POSTURE="conservative"
    export MOTHER_POSTURE_ENABLED=0
    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"
    mother review-phase "job-posture2" --reviewer archie

    # Posture disabled: model should remain opus (not clamped).
    local model_val
    model_val=$(mock_claude_flag_value "--model")
    [ "$model_val" = "opus" ]
}

# ---------------------------------------------------------------------------
# _merge_reviewer_findings

@test "_merge_reviewer_findings: concatenates two reviewers' arrays" {
    _make_pipeline_succeeded_job "job-merge1"

    # Pre-populate reviewer_findings with two reviewers.
    local merged_job
    merged_job=$(jq '
        .pipeline.reviewer_findings = {
            "ada": [{"id":"f1","target":"cody","severity":"blocking","summary":"A","reviewer":"ada"}],
            "archie": [{"id":"f1","target":"redd","severity":"advisory","summary":"B","reviewer":"archie"}]
        }
    ' "$JOBS_DIR/job-merge1.json")
    printf '%s' "$merged_job" > "$JOBS_DIR/job-merge1.json"

    run mother merge-findings "job-merge1"
    [ "$status" -eq 0 ]

    # Should produce a 2-element array.
    local count
    count=$(printf '%s' "$output" | jq 'length')
    [ "$count" = "2" ]
}

@test "_merge_reviewer_findings: re-ids findings f1..fN across merged set" {
    _make_pipeline_succeeded_job "job-merge2"

    local merged_job
    merged_job=$(jq '
        .pipeline.reviewer_findings = {
            "ada":    [{"id":"f1","target":"cody","severity":"blocking","summary":"A","reviewer":"ada"}],
            "archie": [{"id":"f1","target":"cody","severity":"advisory","summary":"B","reviewer":"archie"},
                       {"id":"f2","target":"redd","severity":"advisory","summary":"C","reviewer":"archie"}]
        }
    ' "$JOBS_DIR/job-merge2.json")
    printf '%s' "$merged_job" > "$JOBS_DIR/job-merge2.json"

    run mother merge-findings "job-merge2"
    [ "$status" -eq 0 ]

    # 3 findings total, ids should be f1, f2, f3.
    local ids
    ids=$(printf '%s' "$output" | jq -r '.[].id' | sort | tr '\n' ',')
    [ "$ids" = "f1,f2,f3," ]
}

@test "_merge_reviewer_findings: contradictory findings from two reviewers both survive" {
    _make_pipeline_succeeded_job "job-merge3"

    local merged_job
    merged_job=$(jq '
        .pipeline.reviewer_findings = {
            "ada":    [{"id":"f1","target":"cody","severity":"blocking","summary":"Must fix","reviewer":"ada"}],
            "archie": [{"id":"f1","target":"cody","severity":"advisory","summary":"Maybe fix","reviewer":"archie"}]
        }
    ' "$JOBS_DIR/job-merge3.json")
    printf '%s' "$merged_job" > "$JOBS_DIR/job-merge3.json"

    run mother merge-findings "job-merge3"
    [ "$status" -eq 0 ]

    # Both survive: 2 findings.
    local count
    count=$(printf '%s' "$output" | jq 'length')
    [ "$count" = "2" ]
}

@test "_merge_reviewer_findings: empty reviewer_findings returns empty array" {
    _make_pipeline_succeeded_job "job-merge4"

    run mother merge-findings "job-merge4"
    [ "$status" -eq 0 ]

    local count
    count=$(printf '%s' "$output" | jq 'length')
    [ "$count" = "0" ]
}

# ---------------------------------------------------------------------------
# review_spawned event

@test "review-phase: review_spawned event emitted with reviewer and model" {
    _make_pipeline_succeeded_job "job-spawned1"
    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"

    mother review-phase "job-spawned1" --reviewer ada

    assert_event_kind "job-spawned1" "review_spawned"

    local events_file="$EVENTS_DIR/job-spawned1.jsonl"
    run grep '"review_spawned"' "$events_file"
    [[ "$output" =~ '"reviewer":"ada"' ]]
    [[ "$output" =~ '"model"' ]]
}

# ---------------------------------------------------------------------------
# Error handling

@test "review-phase: missing job id fails with error" {
    run mother review-phase --reviewer archie
    [ "$status" -ne 0 ]
}

@test "review-phase: invalid reviewer name fails with error" {
    _make_pipeline_succeeded_job "job-bad-rev"
    export MOCK_CLAUDE_STDOUT="$(_empty_findings_stdout)"
    run mother review-phase "job-bad-rev" --reviewer cody
    [ "$status" -ne 0 ]
}

# ---------------------------------------------------------------------------
# phase_render_input: base_ref freshness
#
# Regression test for a real bug found 2026-08-14: base_ref (e.g.
# origin/main) is a remote-tracking ref, which is only as current as the
# last fetch run *in that specific worktree*. Worktrees are reused as-is
# across chained jobs on the same branch (see worktree_create — an
# existing worktree directory is returned unchanged, no refresh). If
# nothing fetches in between, origin/main can sit arbitrarily stale while
# the real remote branch moves on — and diffing against it doesn't error,
# it just silently includes unrelated commits that landed on the real
# branch after the worktree's cached ref was last updated. This is exactly
# what happened to a real PR review: the rendered "Work already on this
# branch" section included ~200 commits and several files' worth of
# changes from a completely unrelated PR.

@test "phase_render_input diff: refreshes a stale origin/main before diffing" {
    local remote_dir="$MOTHER_ROOT/fake-remote"
    git init -q -b main "$remote_dir"
    git -C "$remote_dir" config user.email "test@test.com"
    git -C "$remote_dir" config user.name "Test"
    echo "v1" > "$remote_dir/README.md"
    git -C "$remote_dir" add -A
    git -C "$remote_dir" commit -q -m "ancient commit"

    # work_dir clones the remote long ago, at the ancient commit. Its
    # cached origin/main is pinned there and nothing will touch it again —
    # matching a worktree that's reused as-is across chained jobs
    # (worktree_create returns an existing directory unchanged).
    local work_dir="$MOTHER_ROOT/fake-worktree"
    git clone -q "$remote_dir" "$work_dir"
    git -C "$work_dir" config user.email "test@test.com"
    git -C "$work_dir" config user.name "Test"

    # Time passes. The real remote main advances with commits that have
    # nothing to do with the PR this test is about.
    echo "unrelated change" > "$remote_dir/unrelated.txt"
    git -C "$remote_dir" add -A
    git -C "$remote_dir" commit -q -m "UNRELATED_COMMIT_landed_on_real_main"

    # A brand-new feature branch is created off the *current* real main
    # (as GitHub/a fresh checkout would do) and fetched into the same old
    # work_dir by branch name only — exactly how a job's own commits get
    # in, without ever touching origin/main. The feature branch's own
    # history therefore already contains the unrelated commit; it's real
    # upstream history, not this PR's work.
    git -C "$remote_dir" checkout -q -b feature
    echo "feature work" > "$remote_dir/feature.txt"
    git -C "$remote_dir" add -A
    git -C "$remote_dir" commit -q -m "add feature work"
    git -C "$work_dir" fetch -q origin feature:feature
    git -C "$work_dir" checkout -q feature

    # Sanity check: work_dir's cached origin/main really is stale here —
    # it never saw the unrelated commit — before phase_render_input runs.
    run git -C "$work_dir" log --oneline origin/main
    [[ ! "$output" =~ "UNRELATED_COMMIT" ]]

    source "$MOTHER_LIB_DIR/phase-prompt.sh"
    run phase_render_input diff "$work_dir" "" "" "origin/main" "" ""

    [ "$status" -eq 0 ]
    # Must NOT attribute the unrelated commit to "work already on this
    # branch" — it's real main history, not this PR's own work. Showing
    # it is exactly the phantom-diff bug.
    [[ ! "$output" =~ "UNRELATED_COMMIT" ]]
    # Must still show the branch's own real commit.
    [[ "$output" =~ "add feature work" ]]
}
