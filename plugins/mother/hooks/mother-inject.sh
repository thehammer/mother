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

# Resolve the CLI. Order:
#   1. $MOTHER_CLI, if executable (explicit override).
#   2. The path the daemon publishes to $MOTHER_ROOT/runner/cli-path at
#      startup (mother-runner's _publish_cli_path), if it names an executable.
#   3. $CLAUDE_PLUGIN_ROOT/bin/mother (the plugin cache).
#   4. `mother` on $PATH (legacy / direct invocation).
# The daemon's copy wins over the plugin cache on purpose: the events on disk
# are written by the daemon's code, so the reader has to be the same code. The
# plugin cache can be months stale — on 2026-09-29 a cache installed in April
# (before both cursor fixes) replayed every archived job's events as live
# failures into unrelated sessions.
mother_cli=""
if [ -n "${MOTHER_CLI:-}" ] && [ -x "${MOTHER_CLI}" ]; then
    mother_cli="$MOTHER_CLI"
fi
if [ -z "$mother_cli" ]; then
    cli_path_file="${MOTHER_ROOT:-$HOME/.mother}/runner/cli-path"
    if [ -f "$cli_path_file" ]; then
        published=$(cat "$cli_path_file" 2>/dev/null | tr -d '\r\n')
        [ -n "$published" ] && [ -x "$published" ] && mother_cli="$published"
    fi
fi
if [ -z "$mother_cli" ] && [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -x "$CLAUDE_PLUGIN_ROOT/bin/mother" ]; then
    mother_cli="$CLAUDE_PLUGIN_ROOT/bin/mother"
fi
if [ -z "$mother_cli" ] && command -v mother >/dev/null 2>&1; then
    mother_cli="$(command -v mother)"
fi
[ -z "$mother_cli" ] && exit 0

# Fetch deltas. The CLI returns a JSON array and advances the cursor.
events=$("$mother_cli" events --since-cursor "$session_id" 2>/dev/null)
[ -z "$events" ] && exit 0

# Hook-side age floor (defence in depth). Even if resolution above falls
# through to a stale CLI without the cursor fixes, a banner must never announce
# a months-old event as news: drop anything older than
# MOTHER_EVENTS_MAX_AGE_HOURS (default 6; 0 disables) before the kind filter.
# Timestamps on disk come in several precisions (…:18Z, …:12.219777Z,
# …:35.573Z), so fractional seconds are stripped before parsing. Anything
# unparseable is dropped, never shown.
max_age_hours="${MOTHER_EVENTS_MAX_AGE_HOURS:-6}"
case "$max_age_hours" in ''|*[!0-9]*) max_age_hours=6 ;; esac
if [ "$max_age_hours" -gt 0 ]; then
    events=$(printf '%s' "$events" | jq -c --argjson max "$max_age_hours" '
        map(select(
            (try (.ts | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) catch null) as $t
            | $t != null and ($t >= (now - ($max * 3600)))
        ))' 2>/dev/null)
    [ -z "$events" ] && exit 0
fi

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
