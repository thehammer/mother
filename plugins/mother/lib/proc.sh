#!/usr/bin/env bash
# proc.sh — process helpers shared by lib/rwx.sh and lib/preview.sh.
# Sourced under `set -u`, bash 3.2.

# mother_kill_tree <pid> — SIGKILL a background subshell and all its
# descendants (children first). Never fails.
mother_kill_tree() {
    local pid="$1" kid
    for kid in $(pgrep -P "$pid" 2>/dev/null); do
        mother_kill_tree "$kid"
    done
    kill -9 "$pid" 2>/dev/null
    return 0
}
