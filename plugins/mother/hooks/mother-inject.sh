#!/usr/bin/env bash
# mother-inject.sh — UserPromptSubmit hook that surfaces queue state changes
# into Claude's context between user messages.
#
# Claude Code passes a JSON payload on stdin with at least `session_id`. We
# use that as a per-session cursor key and ask the queue CLI for events
# newer than the session's last-seen timestamp. The CLI advances the cursor
# as a side effect of returning events.
#
# Non-empty deltas are formatted as a <system-reminder> block and printed
# to stdout. Claude Code adds stdout on exit 0 to the model's context for
# the next turn, so Claude will naturally mention completions, failures,
# and PR URLs at the top of its reply.
#
# Silent (exit 0, no output) when:
#   - no session_id in payload
#   - queue CLI absent or errors
#   - no new events since last cursor advance
#
# Never blocks a prompt (never exits 2). If anything goes wrong, we stay
# out of the way.

set -u

# Read stdin payload. Bail silently if empty or not-JSON.
payload=$(cat 2>/dev/null || true)
[ -z "$payload" ] && exit 0

session_id=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$session_id" ] && exit 0

# Resolve the CLI. When fired as a plugin hook, Claude Code sets
# $CLAUDE_PLUGIN_ROOT. Fall back to $PATH so the hook also works when sourced
# from legacy (pre-plugin) wiring or direct invocation.
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/bin/mother" ]; then
    mother_cli="$CLAUDE_PLUGIN_ROOT/bin/mother"
elif command -v mother >/dev/null 2>&1; then
    mother_cli="$(command -v mother)"
else
    exit 0
fi

# Fetch deltas. The CLI returns a JSON array and advances the cursor.
events=$("$mother_cli" events --since-cursor "$session_id" 2>/dev/null)
[ -z "$events" ] && exit 0

count=$(printf '%s' "$events" | jq 'length' 2>/dev/null || echo 0)
[ -z "$count" ] || [ "$count" = "0" ] && exit 0

# Surface only the events that matter between turns. Queue lifecycles emit
# queued -> ready -> running -> (pr_opened) -> succeeded|failed|cancelled.
# Intra-flight noise (queued/ready/started) is less useful than terminal
# signals, so we filter to the salient kinds.
relevant=$(printf '%s' "$events" | jq -c '
    map(select(.kind == "running" or .kind == "pr_opened"
            or .kind == "succeeded" or .kind == "failed"
            or .kind == "cancelled" or .kind == "cancel_requested"))
')
relevant_count=$(printf '%s' "$relevant" | jq 'length' 2>/dev/null || echo 0)
[ "$relevant_count" = "0" ] && exit 0

# Compact per-line format. Title falls back to job id suffix.
formatted=$(printf '%s' "$relevant" | jq -r '
    .[]
    | . as $e
    | "- [" + .kind + "] "
      + (if (.title // "") != "" then .title else (.job_id | .[-8:]) end)
      + (if (.detail.url // "") != "" then " — " + .detail.url else "" end)
      + (if (.detail.pr_url // "") != "" then " — " + .detail.pr_url else "" end)
      + (if (.detail.reason // "") != "" then " (" + .detail.reason + ")" else "" end)
      + (if (.detail.exit_code // null) != null then " (exit " + (.detail.exit_code | tostring) + ")" else "" end)
')

# Emit the block. Claude will see this as context for its next reply.
cat <<EOF
<system-reminder>
Queue updates since your last message:
$formatted
</system-reminder>
EOF

exit 0
