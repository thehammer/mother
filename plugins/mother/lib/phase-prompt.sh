# phase-prompt.sh — input resolvers for pipeline phase spawn prompts.
#
# Sourced by mother-run-job when running a pipeline phase (W2).
# Do not invoke directly.
#
# Bash 3.2-safe: no declare -A, no mapfile, no export -f across bash -c.
# Does not call set -u — inherits shell options from the sourcing script.
# Every external env var reference uses ${VAR:-default}.

# phase_render_input <key> <work_dir> <plan_path> <prd_path> <base_ref> <job_file> <target_agent>
# Renders one titled markdown section for the given input key to stdout.
# Best-effort: never exits non-zero; emits an explanatory placeholder when
# content is unavailable. All parameters after <key> may be empty strings.
phase_render_input() {
    local key="$1"
    local work_dir="${2:-}"
    local plan_path="${3:-}"
    local prd_path="${4:-}"
    local base_ref="${5:-}"
    local job_file="${6:-}"
    local target_agent="${7:-}"

    case "$key" in

        plan)
            printf '## Plan\n\n'
            if [ -r "$plan_path" ]; then
                cat "$plan_path"
            else
                printf '_(plan file not found: %s)_\n' "${plan_path:-<unknown>}"
            fi
            printf '\n'
            ;;

        prd)
            printf '## PRD\n\n'
            local _prd_file=""
            # 1. Explicit prd_path from the job, if readable.
            if [ -n "$prd_path" ] && [ -r "$prd_path" ]; then
                _prd_file="$prd_path"
            elif [ -n "$plan_path" ]; then
                # 2. Derive from plan path: docs/prds/<plan-basename>.md
                #    Plans live at e.g. docs/plans/foo.md → prds at docs/prds/foo.md
                local _plan_name _plan_dir _prd_candidate
                _plan_name=$(basename "$plan_path" .md)
                _plan_dir=$(dirname "$plan_path")
                _prd_candidate="${_plan_dir}/../prds/${_plan_name}.md"
                if [ -r "$_prd_candidate" ]; then
                    _prd_file="$_prd_candidate"
                fi
            fi
            if [ -n "$_prd_file" ]; then
                cat "$_prd_file"
            else
                printf '_(no PRD file found; proceeding from the plan.)_\n'
            fi
            printf '\n'
            ;;

        tests)
            printf '## Tests on this branch\n\n'
            local _test_stat=""
            if [ -n "$work_dir" ] && [ -d "$work_dir" ] && [ -n "$base_ref" ]; then
                # base_ref is a remote-tracking ref (e.g. origin/main). It's
                # whatever this worktree last fetched — which can be
                # arbitrarily stale if nothing has fetched here since the
                # worktree was created (worktrees are reused as-is across
                # chained jobs on the same branch, see worktree_create).
                # A stale base_ref doesn't error — it silently diffs
                # against the wrong point in history, inflating this
                # section with unrelated commits that landed on the real
                # remote branch since. Best-effort refresh before reading
                # it; never hard-fail (offline, no remote, etc. all fall
                # through to the existing stale-but-present value).
                (cd "$work_dir" && git fetch --quiet origin 2>/dev/null || true)
                _test_stat=$(cd "$work_dir" \
                    && git diff --stat "${base_ref}..HEAD" -- '*test*' '*spec*' 'tests/*' \
                    2>/dev/null || true)
            fi
            if [ -n "$_test_stat" ]; then
                printf '%s\n' "$_test_stat"
            else
                printf '_(no test files on this branch yet)_\n'
            fi
            printf '\n'
            ;;

        diff)
            printf '## Work already on this branch\n\n'
            local _diff_log="" _diff_stat=""
            if [ -n "$work_dir" ] && [ -d "$work_dir" ] && [ -n "$base_ref" ]; then
                # See the matching comment in the 'tests' case above: refresh
                # the possibly-stale remote-tracking ref before diffing
                # against it. Best-effort, never hard-fail.
                (cd "$work_dir" && git fetch --quiet origin 2>/dev/null || true)
                _diff_log=$(cd "$work_dir" \
                    && git log --oneline "${base_ref}..HEAD" 2>/dev/null || true)
            fi
            if [ -n "$_diff_log" ]; then
                printf '%s\n\n' "$_diff_log"
                if [ -n "$work_dir" ] && [ -d "$work_dir" ] && [ -n "$base_ref" ]; then
                    _diff_stat=$(cd "$work_dir" \
                        && git diff --stat "${base_ref}..HEAD" 2>/dev/null || true)
                fi
                [ -n "$_diff_stat" ] && printf '%s\n' "$_diff_stat"
            else
                printf '_(branch has no commits yet)_\n'
            fi
            printf '\n'
            ;;

        findings)
            # Only rendered when rt_inputs declares 'findings' for the phase.
            # Filter .pipeline.findings by target == target_agent; omit section if none.
            local _findings_raw="" _targeted="" _count
            if [ -n "$job_file" ] && [ -r "$job_file" ]; then
                _findings_raw=$(jq -r '.pipeline.findings // empty' "$job_file" 2>/dev/null \
                    || true)
            fi
            # If absent, null, or empty array — nothing to render.
            if [ -z "$_findings_raw" ] || [ "$_findings_raw" = "null" ]; then
                return 0
            fi
            # Use findings_by_target if available (sourced by W3+), else inline jq.
            if type findings_by_target >/dev/null 2>&1; then
                _targeted=$(findings_by_target "$_findings_raw" "$target_agent" 2>/dev/null \
                    || echo "[]")
            else
                _targeted=$(printf '%s' "$_findings_raw" \
                    | jq --arg t "$target_agent" 'map(select(.target == $t))' 2>/dev/null \
                    || echo "[]")
            fi
            _count=$(printf '%s' "$_targeted" | jq 'length' 2>/dev/null || echo 0)
            [ "${_count:-0}" -le 0 ] && return 0
            printf '## Findings addressed to you\n\n'
            printf '%s' "$_targeted" \
                | jq -r '.[] | "- [\(.severity)] \(.summary) — \(.detail // "(no detail)") (\(.location // "?"))"' \
                2>/dev/null || true
            printf '\n'
            ;;

        *)
            printf '## %s\n\n_(no resolver for input key: %s)_\n\n' "$key" "$key"
            ;;
    esac
}
