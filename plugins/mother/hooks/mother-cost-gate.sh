#!/usr/bin/env bash
# mother-cost-gate.sh — PreToolUse hook enforcing a job's --max-cost cap.
#
# Wired in only for jobs that have max_cost_usd set (see mother-run-job's
# wrapper generation, which writes a job-scoped Claude `--settings` file
# pointing PreToolUse at this script). Absent for every other job — this
# script isn't even referenced unless a cap is in play.
#
# Contract:
#   - No cost-cap flag file for this job -> allow (exit 0). This is the
#     common case (before breach, or no cap at all).
#   - Flag file present -> only a `Bash` tool call whose command starts
#     (after optional leading whitespace, and an optional path prefix, e.g.
#     `/usr/local/bin/mother await` or `mother await`) with `mother await`
#     is allowed through; everything else is denied (exit 2) with a message
#     on stderr telling the agent to call `mother await` and stop.
#   - Any internal error (missing jq, malformed stdin, unreadable flag file,
#     etc.) fails OPEN (exit 0) — this hook must never wedge a job stuck.
#
# Applies inside subagents too, since Claude Code hooks apply uniformly
# across the whole session tree.

set -u

_fail_open() { exit 0; }

payload=$(cat 2>/dev/null) || _fail_open
[ -n "$payload" ] || _fail_open

job_id="${MOTHER_JOB_ID:-}"
[ -n "$job_id" ] || _fail_open

mother_root="${MOTHER_ROOT:-$HOME/.mother}"
flag_file="$mother_root/runner/$job_id.cost-cap"

[ -f "$flag_file" ] || _fail_open

tool_name=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null) || _fail_open
command=$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null) || _fail_open

if [ "$tool_name" = "Bash" ] && [ -n "$command" ]; then
    trimmed="${command#"${command%%[![:space:]]*}"}"
    case "$trimmed" in
        "mother await"|"mother await "*|*/mother\ await|*/mother\ await\ *)
            exit 0 ;;
    esac
fi

summary=$(cat "$flag_file" 2>/dev/null)
[ -n "$summary" ] || summary="Mother cost cap reached on job $job_id."

cat >&2 <<EOF
$summary

Do not continue working. Run \`mother await --question "<one-line status of
where you are>"\` now, then end your session.
EOF
exit 2
