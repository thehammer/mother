#!/usr/bin/env bash
# test_helper.bash — shared setup for Mother bats tests.
#
# Load this at the top of each .bats file:
#   load 'test_helper'

# Resolve this file's location so helpers can reference sibling files.
_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_PLUGIN_DIR="$(cd "$_HELPER_DIR/.." && pwd -P)"
_BIN_DIR="$_PLUGIN_DIR/bin"
_LIB_DIR="$_PLUGIN_DIR/lib"

setup_mother_env() {
    # Isolated MOTHER_ROOT per test — each test gets a fresh state tree.
    export MOTHER_ROOT
    MOTHER_ROOT="$(mktemp -d)"
    export JOBS_DIR="$MOTHER_ROOT/jobs"
    export EVENTS_DIR="$MOTHER_ROOT/events"
    export LOGS_DIR="$MOTHER_ROOT/logs"
    export DRAFTS_DIR="$MOTHER_ROOT/drafts"
    export CURSORS_DIR="$MOTHER_ROOT/cursors"
    export RUNNER_DIR="$MOTHER_ROOT/runner"
    export ARCHIVE_DIR="$MOTHER_ROOT/archive"
    mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" \
             "$CURSORS_DIR" "$RUNNER_DIR" "$ARCHIVE_DIR"

    # Put the mock shims FIRST on PATH so they override real tools.
    _MOCK_BIN="$MOTHER_ROOT/mock-bin"
    mkdir -p "$_MOCK_BIN"
    # Install mock_claude into mock-bin as `claude`
    cp "$_HELPER_DIR/mock_claude" "$_MOCK_BIN/claude"
    chmod +x "$_MOCK_BIN/claude"
    export PATH="$_MOCK_BIN:$_BIN_DIR:$PATH"

    # Point mother at the test MOTHER_ROOT
    export MOTHER_BIN_DIR="$_BIN_DIR"
    export MOTHER_LIB_DIR="$_LIB_DIR"

    # Default: mock_claude exits 0
    export MOCK_CLAUDE_EXIT=0
    # Default: mock_claude records args to this file
    export MOCK_CLAUDE_ARGS_FILE="$MOTHER_ROOT/mock-claude-args"
}

teardown_mother_env() {
    rm -rf "${MOTHER_ROOT:-}"
}

# Create a minimal plan file with a valid suggested_config block.
# Usage: make_plan <path> [extra content]
make_plan() {
    local dest="$1"
    cat > "$dest" <<'PLAN'
# Test plan

## Context
A test plan.

## Target
- **Repo:** testrepo
- **Branch:** feature/test
- **Base:** origin/main

## Files to change
- `foo.sh` — add something

## Approach
1. Do the thing.

## Acceptance criteria
- It works.

## Out of scope
- Nothing.

```yaml
suggested_config:
  cody:
    model: sonnet
    effort: medium
    rationale: "Standard work."
  redd:
    model: sonnet
    effort: medium
    rationale: "Standard tests."
  marty:
    model: sonnet
    effort: medium
    rationale: "Standard refactor."
  perri:
    model: sonnet
    effort: medium
    rationale: "Standard review."
```
PLAN
}

# Create a plan file with a custom suggested_config block.
# Usage: make_plan_with_config <path> <yaml-block>
make_plan_with_config() {
    local dest="$1" config="$2"
    cat > "$dest" <<PLAN
# Test plan

## Context
A test plan.

## Target
- **Repo:** testrepo
- **Branch:** feature/test
- **Base:** origin/main

## Files to change
- \`foo.sh\` — add something

## Approach
1. Do the thing.

## Acceptance criteria
- It works.

## Out of scope
- Nothing.

\`\`\`yaml
${config}
\`\`\`
PLAN
}

# Create a minimal job JSON directly (bypassing mother add).
# Usage: make_job <id> [state] [extra-jq-filter]
make_job() {
    local id="$1" state="${2:-ready}" extra="${3:-.}"
    local job_file="$JOBS_DIR/$id.json"
    jq -n \
        --arg id "$id" \
        --arg state "$state" \
        --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{
            id: $id,
            title: "test job",
            repo: "testrepo",
            repo_path: "/tmp/testrepo",
            branch: "feature/test",
            base_ref: "origin/main",
            isolation: "worktree",
            executor: "local-tmux",
            depends_on: [],
            max_cost_usd: null,
            plan_path: "",
            log_path: "",
            state: $state,
            created_at: $created_at,
            started_at: null,
            finished_at: null,
            pr_url: null,
            tmux_window: null,
            worker_pid: null,
            actual_cost_usd: null,
            retry_count: 0,
            escalation_count: 0,
            adherence_attempts: 0,
            current_tier: "tier_0"
        }' | jq "$extra" > "$job_file"
}

# Assert a jq expression on a job file returns a specific value.
# Usage: assert_job_field <id> <jq-expr> <expected>
assert_job_field() {
    local id="$1" expr="$2" expected="$3"
    local actual
    actual=$(jq -r "$expr" "$JOBS_DIR/$id.json")
    if [ "$actual" != "$expected" ]; then
        echo "FAIL: job $id: $expr expected '$expected' got '$actual'" >&2
        return 1
    fi
}

# Assert a jq expression on a job file returns truthy (non-empty, non-null, non-false).
assert_job_field_truthy() {
    local id="$1" expr="$2"
    local actual
    actual=$(jq -r "$expr" "$JOBS_DIR/$id.json")
    case "$actual" in
        ""| "null"|"false") echo "FAIL: job $id: $expr expected truthy, got '$actual'" >&2; return 1 ;;
    esac
}

# Check if an event of a given kind exists for a job.
# Usage: assert_event_kind <id> <kind>
assert_event_kind() {
    local id="$1" kind="$2"
    local events_file="$EVENTS_DIR/$id.jsonl"
    if ! grep -q "\"kind\":\"$kind\"" "$events_file" 2>/dev/null; then
        echo "FAIL: no event of kind '$kind' found for job $id" >&2
        return 1
    fi
}
