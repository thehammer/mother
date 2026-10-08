# notify.sh — operator push-notification shim.
#
# Sourced by bin/mother-runner. Does not set shell options; inherits `set -u`.
#
# One entry point: mother_notify <title> <body> [<job_id> [<pr_url>]]. Call sites never
# know which transport is in use; MOTHER_NOTIFY_TRANSPORT picks it:
#
#   auto (default)     terminal-notifier if on PATH, else osascript on Darwin,
#                      else none
#   terminal-notifier  terminal-notifier -title … -message … -group mother-<id>
#                      plus a click action: -open <pr_url> when the job has an
#                      http(s) PR, else -execute "<click command> <id>" (job ids
#                      only; the body never reaches -execute). The click command
#                      is MOTHER_NOTIFY_CLICK_COMMAND, default: open Terminal
#                      running `mother status <id>`.
#   osascript          display notification, with title/body passed as ARGV to
#                      an `on run argv` handler — NEVER interpolated into the
#                      AppleScript source. The body carries worker-authored
#                      question text, and string interpolation there is an
#                      AppleScript injection vector.
#   command            "$MOTHER_NOTIFY_COMMAND" "$title" "$body" "$job_id".
#                      This is the swap point for later off-box delivery (phone
#                      push, Slack relay): call sites never change.
#   none               do nothing, succeed
#
# Every transport is bounded (_bounded_run, MOTHER_NOTIFY_TIMEOUT, default 5s)
# so a wedged notifier can never stall the daemon's single-threaded loop.
# Returns 0 on success, non-zero on failure. Callers record the outcome but
# never retry in a tight loop. Sets MOTHER_NOTIFY_LAST_TRANSPORT to the
# transport actually used (callers must invoke this bare, not via $(...), to
# read it).

: "${MOTHER_NOTIFY_TRANSPORT:=auto}"
: "${MOTHER_NOTIFY_TIMEOUT:=5}"

_notify_resolve_transport() {
    local t="${MOTHER_NOTIFY_TRANSPORT:-auto}"
    if [ "$t" = "auto" ]; then
        if command -v terminal-notifier >/dev/null 2>&1; then
            t="terminal-notifier"
        elif [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
            t="osascript"
        else
            t="none"
        fi
    fi
    echo "$t"
}

# Fills the global array _NOTIFY_CLICK with terminal-notifier's click-action
# args for a job (built as an array, never serialized, so no value can split
# into extra flags). Only a validated job id and a whitespace-free http(s) URL
# are ever used.
_notify_click_args() {
    local job_id="$1" pr_url="$2"
    _NOTIFY_CLICK=()
    [ -n "$job_id" ] || return 0
    case "$job_id" in *[!A-Za-z0-9_.-]*) return 0 ;; esac
    _NOTIFY_CLICK=(-group "mother-$job_id")
    case "$pr_url" in
        *[[:space:][:cntrl:]]*) pr_url="" ;;
        http://*|https://*) _NOTIFY_CLICK+=(-open "$pr_url"); return 0 ;;
    esac
    local cmd="${MOTHER_NOTIFY_CLICK_COMMAND:-}"
    if [ -n "$cmd" ]; then
        _NOTIFY_CLICK+=(-execute "$cmd $job_id")
    else
        _NOTIFY_CLICK+=(-execute "/usr/bin/osascript -e 'tell application \"Terminal\" to activate' -e 'tell application \"Terminal\" to do script \"mother status $job_id\"'")
    fi
}

mother_notify() {
    local title="$1" body="$2" job_id="${3:-}" pr_url="${4:-}"
    local transport secs="${MOTHER_NOTIFY_TIMEOUT:-5}"
    transport=$(_notify_resolve_transport)
    MOTHER_NOTIFY_LAST_TRANSPORT="$transport"
    case "$transport" in
        terminal-notifier)
            _notify_click_args "$job_id" "$pr_url"
            _bounded_run "$secs" - terminal-notifier -title "$title" -message "$body" ${_NOTIFY_CLICK[@]+"${_NOTIFY_CLICK[@]}"}
            ;;
        osascript)
            _bounded_run "$secs" - osascript \
                -e 'on run argv' \
                -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
                -e 'end run' "$title" "$body"
            ;;
        command)
            local cmd="${MOTHER_NOTIFY_COMMAND:-}"
            [ -n "$cmd" ] || return 1
            _bounded_run "$secs" - "$cmd" "$title" "$body" "$job_id"
            ;;
        none) return 0 ;;
        *) return 1 ;;
    esac
}
