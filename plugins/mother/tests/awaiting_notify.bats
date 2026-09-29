#!/usr/bin/env bats
# awaiting_notify.bats — behavioral contract for awaiting-job push notifications.
#
# A job that pauses to ask the operator a question ("awaiting") is silent
# unless someone happens to run `mother status`. The daemon now nudges the
# operator: one push when the question first appears, then a reminder every
# MOTHER_AWAITING_REMIND_HOURS (24h), open-ended, until the job is answered.
#
# The nudge is strictly informational. It NEVER changes a job's state, answer,
# question, pause reason or auto-resume time; it never cancels or resumes
# anything. The only thing it may write is the job's `awaiting_notify` record
# and `awaiting_notified` events.
#
# Interfaces exercised:
#   lib/notify.sh           mother_notify <title> <body> [<job_id>]
#   mother-runner --notify-tick   one _notify_awaiting pass
#
# The transport under test is always `command` (or a PATH-shimmed fake), so no
# test can ever raise a real desktop notification.

load 'test_helper'

setup() {
    setup_mother_env

    # Never let the real notifier fire: pin the transport to a recording script.
    export MOTHER_NOTIFY_TRANSPORT=command
    export MOTHER_NOTIFY_COMMAND="$MOTHER_ROOT/notify-cmd"
    export MOTHER_NOTIFY_ENABLED=1
    export MOTHER_NOTIFY_SCAN_INTERVAL=0      # every tick fires
    export MOTHER_AWAITING_REMIND_HOURS=24
    export CALLS_DIR="$MOTHER_ROOT/notify-calls"
    mkdir -p "$CALLS_DIR"
    echo 0 > "$MOTHER_ROOT/notify-exit"

    # Recording transport: each call gets its own directory holding the exact
    # argv elements (no shell re-interpretation) and the argument count.
    cat > "$MOTHER_NOTIFY_COMMAND" <<'CMD'
#!/usr/bin/env bash
d="${MOTHER_ROOT:?}/notify-calls"
mkdir -p "$d"
n=$(find "$d" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')
c="$d/$((n + 1))"
mkdir -p "$c"
printf '%s' "$#"       > "$c/argc"
printf '%s' "${1-}"    > "$c/title"
printf '%s' "${2-}"    > "$c/body"
printf '%s' "${3-}"    > "$c/job"
exit "$(cat "${MOTHER_ROOT}/notify-exit" 2>/dev/null || echo 0)"
CMD
    chmod +x "$MOTHER_NOTIFY_COMMAND"
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# helpers

_hours_ago() {
    /usr/bin/perl -MPOSIX=strftime -e '
        my @t = gmtime(time() - ($ARGV[0] * 3600));
        printf "%sT%sZ\n", strftime("%Y-%m-%d", @t), strftime("%H:%M:%S", @t);
    ' "$1"
}

_call_count() {
    find "$CALLS_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '
}

# Create an awaiting job with an operator question.
# Usage: _make_awaiting <id> [question] [extra-jq]
_make_awaiting() {
    local id="$1" q="${2:-Which database should I use?}" extra="${3:-.}"
    local qj tsj
    qj=$(jq -n --arg q "$q" '$q')
    tsj=$(jq -n --arg ts "$(_hours_ago 1)" '$ts')
    make_job "$id" "awaiting" \
        ".title = \"Fix the widget\" | .question = $qj | .paused_at = $tsj | .paused_reason = \"user\" | $extra"
}

# Run one notification pass. Guarded: a runner without the --notify-tick test
# entry point would fall through to starting the real daemon loop, which must
# never happen inside a test.
_tick() {
    _require_notify_tick
    run mother-runner --notify-tick
    [ "$status" -eq 0 ]
}

_require_notify_tick() {
    if ! grep -q -- '--notify-tick' "$_BIN_DIR/mother-runner"; then
        echo "mother-runner has no --notify-tick entry point" >&2
        return 1
    fi
}

# Apply a jq filter to a job file in place.
_edit_job() {
    local id="$1" filter="$2"
    jq "$filter" "$JOBS_DIR/$id.json" > "$JOBS_DIR/$id.json.edit" && mv "$JOBS_DIR/$id.json.edit" "$JOBS_DIR/$id.json"
}

# Pretend the last push for a job happened N hours ago.
_age_last_notified() {
    local id="$1" hours="$2"
    _edit_job "$id" ".awaiting_notify.last_notified_at = \"$(_hours_ago "$hours")\""
}

_events_of() {
    local id="$1" kind="$2"
    [ -f "$EVENTS_DIR/$id.jsonl" ] || return 0
    jq -c "select(.kind == \"$kind\")" "$EVENTS_DIR/$id.jsonl"
}

_event_count() {
    _events_of "$1" "$2" | grep -c . || true
}

# ---------------------------------------------------------------------------
# Initial push

@test "awaiting job gets an initial push naming the job, the question and how to answer" {
    _make_awaiting "job-a" "Which database should I use for the cache layer?"

    _tick

    [ "$(_call_count)" -eq 1 ]
    local body; body=$(cat "$CALLS_DIR/1/body")
    local title; title=$(cat "$CALLS_DIR/1/title")
    [[ "$title$body" == *"Fix the widget"* ]]
    [[ "$body" == *"Which database should I use for the cache layer?"* ]]
    [[ "$body" == *"mother resume job-a"* ]]
    [ "$(cat "$CALLS_DIR/1/job")" = "job-a" ]
}

@test "initial push truncates a very long question" {
    local long; long=$(printf 'Q%.0s' $(seq 1 600))
    _make_awaiting "job-a" "$long"

    _tick

    [ "$(_call_count)" -eq 1 ]
    local body; body=$(cat "$CALLS_DIR/1/body")
    # Whole 600-char question must not be echoed; a leading chunk must be.
    [[ "$body" != *"$long"* ]]
    [[ "$body" == *"QQQQQQQQQQ"* ]]
}

@test "initial push records awaiting_notify and emits an awaiting_notified event" {
    _make_awaiting "job-a"
    local paused_at; paused_at=$(jq -r .paused_at "$JOBS_DIR/job-a.json")

    _tick

    assert_job_field "job-a" '.awaiting_notify.count' "1"
    assert_job_field "job-a" '.awaiting_notify.episode' "$paused_at"
    assert_job_field_truthy "job-a" '.awaiting_notify.first_seen_at'
    assert_job_field_truthy "job-a" '.awaiting_notify.last_notified_at'

    [ "$(_event_count job-a awaiting_notified)" -eq 1 ]
    run bash -c "jq -r 'select(.kind==\"awaiting_notified\") | [.detail.kind, (.detail.count|tostring), .detail.transport, (.detail.ok|tostring)] | join(\",\")' '$EVENTS_DIR/job-a.jsonl'"
    [ "$output" = "initial,1,command,true" ]
}

@test "a second scan within the reminder window sends nothing" {
    _make_awaiting "job-a"
    _tick
    _tick
    _tick
    [ "$(_call_count)" -eq 1 ]
    assert_job_field "job-a" '.awaiting_notify.count' "1"
    [ "$(_event_count job-a awaiting_notified)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Reminders

@test "no reminder is sent before the reminder interval has elapsed" {
    _make_awaiting "job-a"
    _tick
    _age_last_notified "job-a" 23
    _tick
    [ "$(_call_count)" -eq 1 ]
}

@test "a reminder is sent once the reminder interval has elapsed and includes the awaiting age" {
    _make_awaiting "job-a" "Which database should I use?" ".paused_at = \"$(_hours_ago 30)\""
    _tick
    _age_last_notified "job-a" 25

    _tick

    [ "$(_call_count)" -eq 2 ]
    local body; body=$(cat "$CALLS_DIR/2/body")
    [[ "$body" == *"Which database should I use?"* ]]
    [[ "$body" == *"mother resume job-a"* ]]
    # Awaiting for ~30h: rendered as hours or days, however the implementation likes.
    [[ "$body" =~ [0-9]+[[:space:]]*(h|hr|hrs|hour|hours|d|day|days)([^a-z]|$) ]]

    assert_job_field "job-a" '.awaiting_notify.count' "2"
    run bash -c "jq -r 'select(.kind==\"awaiting_notified\") | .detail.kind' '$EVENTS_DIR/job-a.jsonl' | tail -n1"
    [ "$output" = "reminder" ]
}

@test "reminders repeat every interval, open-ended" {
    _make_awaiting "job-a"
    _tick
    _age_last_notified "job-a" 25
    _tick
    _age_last_notified "job-a" 25
    _tick
    _age_last_notified "job-a" 25
    _tick

    [ "$(_call_count)" -eq 4 ]
    assert_job_field "job-a" '.awaiting_notify.count' "4"
}

@test "no second push is sent inside the reminder window even after a reminder" {
    _make_awaiting "job-a"
    _tick
    _age_last_notified "job-a" 25
    _tick
    [ "$(_call_count)" -eq 2 ]
    _tick
    _tick
    [ "$(_call_count)" -eq 2 ]
}

@test "MOTHER_AWAITING_REMIND_HOURS tunes the reminder interval" {
    export MOTHER_AWAITING_REMIND_HOURS=2
    _make_awaiting "job-a"
    _tick
    _age_last_notified "job-a" 3
    _tick
    [ "$(_call_count)" -eq 2 ]
}

# ---------------------------------------------------------------------------
# Episodes and cleanup

@test "a new awaiting episode (fresh paused_at) restarts with an initial push and a reset count" {
    _make_awaiting "job-a" "First question?"
    _tick
    _age_last_notified "job-a" 25
    _tick
    assert_job_field "job-a" '.awaiting_notify.count' "2"

    # Operator answers, the job runs, then asks again: new paused_at + question.
    local new_ts; new_ts=$(_hours_ago 0)
    _edit_job "job-a" ".question = \"Second question?\" | .paused_at = \"$new_ts\""
    _tick

    [ "$(_call_count)" -eq 3 ]
    local body; body=$(cat "$CALLS_DIR/3/body")
    [[ "$body" == *"Second question?"* ]]
    assert_job_field "job-a" '.awaiting_notify.count' "1"
    assert_job_field "job-a" '.awaiting_notify.episode' "$new_ts"
    run bash -c "jq -r 'select(.kind==\"awaiting_notified\") | .detail.kind' '$EVENTS_DIR/job-a.jsonl' | tail -n1"
    [ "$output" = "initial" ]
}

@test "a job that is no longer awaiting has its awaiting_notify cleared, without a push" {
    _make_awaiting "job-a"
    _tick
    [ "$(_call_count)" -eq 1 ]

    _edit_job "job-a" '.state = "running" | .question = null | .paused_at = null | .paused_reason = null'
    _tick

    [ "$(_call_count)" -eq 1 ]
    assert_job_field "job-a" '.awaiting_notify // "null"' "null"
}

@test "quota-paused jobs are never announced (they auto-resume)" {
    _make_awaiting "job-q" "quota pause" '.paused_reason = "quota_5h" | .auto_resume_at = "2099-01-01T00:00:00Z"'
    _tick
    _tick
    [ "$(_call_count)" -eq 0 ]
    assert_job_field "job-q" '.awaiting_notify // "null"' "null"
}

@test "only awaiting jobs trigger pushes: failed, blocked-queued, running and succeeded jobs are silent" {
    make_job "job-failed" "failed" '.reason = "x"'
    make_job "job-blocked" "queued" '.dep_wait = {dep_id:"d", status:"blocked", reason:"dep_failed"}'
    make_job "job-running" "running"
    make_job "job-ok" "succeeded"
    _tick
    [ "$(_call_count)" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Coalescing

@test "three due pushes in one scan are sent individually" {
    _make_awaiting "job-1"
    _make_awaiting "job-2"
    _make_awaiting "job-3"
    _tick
    [ "$(_call_count)" -eq 3 ]
}

@test "more than three due pushes in one scan collapse into a single summary push" {
    _make_awaiting "job-1"
    _make_awaiting "job-2"
    _make_awaiting "job-3"
    _make_awaiting "job-4"
    _make_awaiting "job-5"

    _tick

    [ "$(_call_count)" -eq 1 ]
    local body; body=$(cat "$CALLS_DIR/1/title" "$CALLS_DIR/1/body")
    [[ "$body" == *"5 Mother jobs are waiting for you"* ]]
    [[ "$body" == *"mother status"* ]]

    # Every covered job is marked notified, with its own event.
    local n
    for n in 1 2 3 4 5; do
        assert_job_field "job-$n" '.awaiting_notify.count' "1"
        assert_job_field_truthy "job-$n" '.awaiting_notify.last_notified_at'
        [ "$(_event_count "job-$n" awaiting_notified)" -eq 1 ]
    done

    # ...so the next scan is silent.
    _tick
    [ "$(_call_count)" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Failure handling

@test "a failing transport still records the attempt (no push storm) and the event says ok:false" {
    echo 1 > "$MOTHER_ROOT/notify-exit"
    _make_awaiting "job-a"

    _tick

    [ "$(_call_count)" -eq 1 ]
    assert_job_field_truthy "job-a" '.awaiting_notify.last_notified_at'
    run bash -c "jq -r 'select(.kind==\"awaiting_notified\") | (.detail.ok|tostring)' '$EVENTS_DIR/job-a.jsonl'"
    [ "$output" = "false" ]

    _tick
    _tick
    [ "$(_call_count)" -eq 1 ]
}

@test "MOTHER_NOTIFY_ENABLED=0 sends nothing" {
    export MOTHER_NOTIFY_ENABLED=0
    _make_awaiting "job-a"
    _tick
    _tick
    [ "$(_call_count)" -eq 0 ]
}

@test "the scan interval gates how often a pass actually runs" {
    export MOTHER_NOTIFY_SCAN_INTERVAL=3600
    _make_awaiting "job-a"
    # The first pass runs (no marker yet) and stamps the gate.
    _tick
    local first; first=$(_call_count)

    # A second job appearing inside the interval is not scanned yet.
    _make_awaiting "job-b"
    _tick
    [ "$(_call_count)" -eq "$first" ]
    assert_job_field "job-b" '.awaiting_notify // "null"' "null"
}

# ---------------------------------------------------------------------------
# Hard constraint: the nudge never touches anything but its own record

@test "notifying never modifies a job apart from awaiting_notify, and never appends other events" {
    _make_awaiting "job-a" "Which database?" '.auto_resume_at = null | .pending_answer = null | .activity = null'
    # Baseline event log, as `mother await` would have left it.
    jq -nc '{ts:"2026-09-01T00:00:00.000Z", kind:"awaiting_input", detail:{question:"Which database?", paused_reason:"user"}}' > "$EVENTS_DIR/job-a.jsonl"
    local before_job; before_job=$(jq -S 'del(.awaiting_notify)' "$JOBS_DIR/job-a.json")
    local before_events; before_events=$(cat "$EVENTS_DIR/job-a.jsonl")

    _tick
    _age_last_notified "job-a" 25
    _tick
    _age_last_notified "job-a" 49
    _tick
    _age_last_notified "job-a" 73
    _tick

    local after_job; after_job=$(jq -S 'del(.awaiting_notify)' "$JOBS_DIR/job-a.json")
    [ "$after_job" = "$before_job" ]
    assert_job_field "job-a" '.state' "awaiting"

    # Original events are untouched and everything appended is awaiting_notified.
    [ "$(head -n1 "$EVENTS_DIR/job-a.jsonl")" = "$before_events" ]
    run bash -c "tail -n +2 '$EVENTS_DIR/job-a.jsonl' | jq -r .kind | sort -u"
    [ "$output" = "awaiting_notified" ]
    [ "$(_call_count)" -eq 4 ]
}

@test "notifying leaves a running job's state alone too" {
    make_job "job-run" "running"
    local before; before=$(jq -S . "$JOBS_DIR/job-run.json")
    _tick
    [ "$(jq -S . "$JOBS_DIR/job-run.json")" = "$before" ]
}

# ---------------------------------------------------------------------------
# Injection safety

@test "a hostile question reaches the transport intact as a single argument and is never executed" {
    # Relative marker paths from a cwd of $MOTHER_ROOT keep the question under
    # the ~150-char body truncation (a temp-dir prefix alone would blow it).
    cd "$MOTHER_ROOT"
    local q="\" & ' ; \$(touch pwned) \`touch pwned2\` done"
    _make_awaiting "job-a" "$q"

    _tick

    [ "$(_call_count)" -eq 1 ]
    [ "$(cat "$CALLS_DIR/1/argc")" = "3" ]
    local body; body=$(cat "$CALLS_DIR/1/body")
    [[ "$body" == *"$q"* ]]
    [ ! -e "$MOTHER_ROOT/pwned" ]
    [ ! -e "$MOTHER_ROOT/pwned2" ]
}

# ---------------------------------------------------------------------------
# lib/notify.sh — mother_notify and its transports

_notify() {
    # Usage: _notify <args...>  — runs mother_notify with libs sourced.
    bash -c "set -u; source '$_LIB_DIR/state.sh'; source '$_LIB_DIR/notify.sh'; mother_notify \"\$@\"" _ "$@"
}

_fake_bin() {
    # Usage: _fake_bin <name>  — records argv (one per line) to $MOTHER_ROOT/<name>-argv.
    cat > "$_MOCK_BIN/$1" <<'FAKE'
#!/usr/bin/env bash
me=$(basename "$0")
{ printf 'ARGC=%s\n' "$#"; for a in "$@"; do printf 'ARG=%s\n' "$a"; done; } >> "${MOTHER_ROOT:?}/${me}-argv"
exit 0
FAKE
    chmod +x "$_MOCK_BIN/$1"
}

@test "mother_notify: command transport runs the command with title, body and job id as separate args" {
    run _notify "The title" "The body" "job-z"
    [ "$status" -eq 0 ]
    [ "$(_call_count)" -eq 1 ]
    [ "$(cat "$CALLS_DIR/1/argc")" = "3" ]
    [ "$(cat "$CALLS_DIR/1/title")" = "The title" ]
    [ "$(cat "$CALLS_DIR/1/body")" = "The body" ]
    [ "$(cat "$CALLS_DIR/1/job")" = "job-z" ]
}

@test "mother_notify: returns non-zero when the transport command fails" {
    echo 1 > "$MOTHER_ROOT/notify-exit"
    run _notify "t" "b" "job-z"
    [ "$status" -ne 0 ]
}

@test "mother_notify: transport none is a successful no-op" {
    export MOTHER_NOTIFY_TRANSPORT=none
    run _notify "t" "b" "job-z"
    [ "$status" -eq 0 ]
    [ "$(_call_count)" -eq 0 ]
}

@test "mother_notify: a hung transport is cut off by the watchdog and reported as failure" {
    cat > "$MOTHER_NOTIFY_COMMAND" <<'CMD'
#!/usr/bin/env bash
sleep 30
CMD
    local start end
    start=$(date +%s)
    run _notify "t" "b" "job-z"
    end=$(date +%s)
    [ "$status" -ne 0 ]
    [ $((end - start)) -lt 15 ]
}

@test "mother_notify: osascript transport passes title and body as argv, never interpolated into the script" {
    _fake_bin osascript
    export MOTHER_NOTIFY_TRANSPORT=osascript
    local body="\" & ' ; \$(touch $MOTHER_ROOT/pwned) done"

    run _notify "A title" "$body" "job-z"
    [ "$status" -eq 0 ]

    [ -f "$MOTHER_ROOT/osascript-argv" ]
    grep -qxF "ARG=A title" "$MOTHER_ROOT/osascript-argv"
    grep -qxF "ARG=$body" "$MOTHER_ROOT/osascript-argv"
    # The script text (the -e arguments) must not contain the body.
    grep -qxF "ARG=-e" "$MOTHER_ROOT/osascript-argv"
    local script_lines; script_lines=$(grep -F 'on run' "$MOTHER_ROOT/osascript-argv" || true)
    [ -n "$script_lines" ]
    [[ "$script_lines" != *touch* ]]
    [ ! -e "$MOTHER_ROOT/pwned" ]
}

@test "mother_notify: terminal-notifier transport passes title and body as arguments" {
    _fake_bin terminal-notifier
    export MOTHER_NOTIFY_TRANSPORT=terminal-notifier
    run _notify "A title" "A body" "job-z"
    [ "$status" -eq 0 ]
    grep -qxF "ARG=A title" "$MOTHER_ROOT/terminal-notifier-argv"
    grep -qxF "ARG=A body" "$MOTHER_ROOT/terminal-notifier-argv"
}

@test "mother_notify: auto prefers terminal-notifier when it is installed" {
    _fake_bin terminal-notifier
    _fake_bin osascript
    export MOTHER_NOTIFY_TRANSPORT=auto
    run _notify "A title" "A body" "job-z"
    [ "$status" -eq 0 ]
    [ -f "$MOTHER_ROOT/terminal-notifier-argv" ]
    [ ! -f "$MOTHER_ROOT/osascript-argv" ]
}
