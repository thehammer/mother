#!/bin/bash
# Resource Locking for Claude Code IDE
# Prevents concurrent access to shared resources (tests, database, build)
#
# Lock files stored in ~/.claude/ide/locks/{lock_name}.lock
# Each lock is a JSON file with holder info for debugging and stale detection

IDE_LOCKS_DIR="$HOME/.claude/ide/locks"

# Ensure directory exists
mkdir -p "$IDE_LOCKS_DIR" 2>/dev/null

# Sanitize lock name for filesystem
# Args: $1 = lock name (e.g., "project:tests")
# Returns: sanitized name safe for filenames
_lock_sanitize_name() {
    echo "$1" | tr '/:' '__' | tr -cd 'a-zA-Z0-9_-'
}

# Get the lock file path for a lock name
# Args: $1 = lock name
# Returns: full path to lock file
lock_get_file() {
    local lock_name="$1"
    local safe_name=$(_lock_sanitize_name "$lock_name")
    echo "$IDE_LOCKS_DIR/${safe_name}.lock"
}

# Check if a lock is currently held
# Args: $1 = lock name
# Returns: 0 if locked, 1 if not locked
lock_is_held() {
    local lock_name="$1"
    local lock_file=$(lock_get_file "$lock_name")

    if [[ ! -f "$lock_file" ]]; then
        return 1
    fi

    # Check if the holding session still exists
    local holder_session=$(jq -r '.session_id // ""' "$lock_file" 2>/dev/null)
    local holder_pane=$(jq -r '.tmux_pane // ""' "$lock_file" 2>/dev/null)

    if [[ -n "$holder_pane" && "$holder_pane" != "null" ]]; then
        # Verify the tmux pane still exists
        if ! tmux list-panes -a -F '#{pane_id}' 2>/dev/null | grep -q "^${holder_pane}$"; then
            # Stale lock - holder is gone
            return 1
        fi
    fi

    return 0
}

# Get information about who holds a lock
# Args: $1 = lock name
# Returns: JSON object with lock holder info, or empty if not locked
lock_holder() {
    local lock_name="$1"
    local lock_file=$(lock_get_file "$lock_name")

    if lock_is_held "$lock_name"; then
        cat "$lock_file"
    else
        # Clean up stale lock if it exists
        [[ -f "$lock_file" ]] && rm -f "$lock_file"
        echo ""
        return 1
    fi
}

# Acquire a lock
# Args: $1 = lock name
#       $2 = timeout in seconds (0 = no wait, default; -1 = wait forever)
#       $3 = description (optional)
# Returns: 0 on success, 1 on failure (lock held by another)
lock_acquire() {
    local lock_name="$1"
    local timeout="${2:-0}"
    local description="${3:-}"
    local lock_file=$(lock_get_file "$lock_name")

    local start_time=$(date +%s)

    while true; do
        # Check if already locked
        if ! lock_is_held "$lock_name"; then
            # Lock is available - acquire it
            local session_id="${CLAUDE_SESSION_ID:-unknown}"
            local tmux_pane=""
            local tmux_window=""
            [[ -n "$TMUX" ]] && {
                tmux_pane=$(tmux display-message -p '#{pane_id}')
                tmux_window=$(tmux display-message -p '#{window_index}')
            }

            local now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

            # Create lock file atomically
            cat > "${lock_file}.tmp" << EOF
{
  "lock_name": "$lock_name",
  "session_id": "$session_id",
  "tmux_pane": "$tmux_pane",
  "tmux_window": "$tmux_window",
  "description": "$description",
  "acquired_at": "$now",
  "pid": $$
}
EOF
            # Atomic move
            mv "${lock_file}.tmp" "$lock_file"
            return 0
        fi

        # Lock is held by another
        if [[ "$timeout" -eq 0 ]]; then
            # No waiting - fail immediately
            return 1
        fi

        if [[ "$timeout" -gt 0 ]]; then
            local elapsed=$(($(date +%s) - start_time))
            if [[ $elapsed -ge $timeout ]]; then
                # Timeout exceeded
                return 1
            fi
        fi

        # Wait and retry (timeout=-1 waits forever, timeout>0 waits up to timeout)
        sleep 1
    done
}

# Release a lock
# Args: $1 = lock name
#       $2 = force release even if not owner (optional, default false)
# Returns: 0 on success, 1 on error
lock_release() {
    local lock_name="$1"
    local force="${2:-false}"
    local lock_file=$(lock_get_file "$lock_name")

    if [[ ! -f "$lock_file" ]]; then
        # Lock doesn't exist - that's fine
        return 0
    fi

    # Check if we own the lock (unless forcing)
    if [[ "$force" != "true" ]]; then
        local holder_session=$(jq -r '.session_id // ""' "$lock_file" 2>/dev/null)
        local current_session="${CLAUDE_SESSION_ID:-unknown}"

        if [[ "$holder_session" != "$current_session" ]]; then
            echo "Error: Lock '$lock_name' held by session $holder_session, not $current_session" >&2
            return 1
        fi
    fi

    rm -f "$lock_file"
    return 0
}

# List all current locks
# Args: $1 = format (json, table) - defaults to table
# Returns: list of locks in requested format
lock_list() {
    local format="${1:-table}"
    local locks=()

    for lock_file in "$IDE_LOCKS_DIR"/*.lock; do
        [[ -f "$lock_file" ]] || continue

        local lock_name=$(jq -r '.lock_name' "$lock_file" 2>/dev/null)

        # Skip stale locks
        if lock_is_held "$lock_name"; then
            locks+=("$(cat "$lock_file")")
        else
            # Clean up stale lock
            rm -f "$lock_file"
        fi
    done

    if [[ ${#locks[@]} -eq 0 ]]; then
        case "$format" in
            json) echo "[]" ;;
            table) echo "No active locks" ;;
        esac
        return 0
    fi

    case "$format" in
        json)
            printf '%s\n' "${locks[@]}" | jq -s '.'
            ;;
        table)
            echo "Lock Name              │ Session     │ Window │ Acquired            │ Description"
            echo "───────────────────────┼─────────────┼────────┼─────────────────────┼────────────────────"
            printf '%s\n' "${locks[@]}" | jq -r '
                [
                    .lock_name[0:22],
                    .session_id[0:11],
                    (.tmux_window // "-"),
                    (.acquired_at | split("T") | .[1] | split("Z") | .[0])[0:8],
                    (.description // "-")[0:20]
                ] | @tsv' | while IFS=$'\t' read -r name session window time desc; do
                printf "%-22s │ %-11s │ %-6s │ %-19s │ %s\n" \
                    "$name" "$session" "$window" "$time" "$desc"
            done
            ;;
    esac
}

# Cleanup all stale locks
# Returns: number of locks cleaned up
lock_cleanup_stale() {
    local cleaned=0

    for lock_file in "$IDE_LOCKS_DIR"/*.lock; do
        [[ -f "$lock_file" ]] || continue

        local lock_name=$(jq -r '.lock_name' "$lock_file" 2>/dev/null)

        if ! lock_is_held "$lock_name"; then
            echo "Removing stale lock: $lock_name"
            rm -f "$lock_file"
            ((cleaned++))
        fi
    done

    echo "$cleaned"
}

# Execute a command while holding a lock
# Args: $1 = lock name
#       $2... = command to execute
# Returns: exit code of command, or 1 if lock acquisition failed
lock_exec() {
    local lock_name="$1"
    shift

    if ! lock_acquire "$lock_name" 0 "Running: $1"; then
        local holder=$(lock_holder "$lock_name")
        local holder_session=$(echo "$holder" | jq -r '.session_id // "unknown"')
        local holder_window=$(echo "$holder" | jq -r '.tmux_window // "?"')
        echo "Error: Cannot acquire lock '$lock_name'" >&2
        echo "  Held by: session $holder_session (window $holder_window)" >&2
        return 1
    fi

    # Run command
    local exit_code=0
    "$@" || exit_code=$?

    # Always release lock
    lock_release "$lock_name"

    return $exit_code
}

# Standard lock names helper
# Returns canonical lock name for common resources
lock_name_for() {
    local resource="$1"
    local project="${2:-$(basename "$(pwd)")}"

    case "$resource" in
        tests|test)
            echo "${project}:tests"
            ;;
        db|database)
            echo "${project}:db"
            ;;
        build)
            echo "${project}:build"
            ;;
        deploy|deployment)
            echo "${project}:deploy"
            ;;
        *)
            echo "${project}:${resource}"
            ;;
    esac
}

# Export functions
export -f lock_get_file
export -f lock_is_held
export -f lock_holder
export -f lock_acquire
export -f lock_release
export -f lock_list
export -f lock_cleanup_stale
export -f lock_exec
export -f lock_name_for
