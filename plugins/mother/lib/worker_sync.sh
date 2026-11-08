#!/usr/bin/env bash
# worker_sync.sh — merge coordinator-sent job keys into a worker's mirror job document (cluster P1-4).
#
#   worker_sync.sh <worker-root> <job> < '{"key": value, ...}'
#
# Used by mother-worker for `cancel` and `sync.job`: these values come FROM the coordinator, so they are
# written under the job lock (the supervisor polls and rewrites the same file) but are NOT emitted to the
# outbox: echoing them back up would turn the coordinator's own write into a worker op. Sourcing state.sh in
# worker mode is what gives us the real lock (`_with_lock`) and atomic write; no outbox function is called.
# Exit 0 merged, 1 failed, 2 usage.

set -u
[ $# -eq 2 ] || { echo "usage: worker_sync.sh <worker-root> <job> < patch.json" >&2; exit 2; }
root="$1"; job="$2"
[ -d "$root" ] || { echo "worker_sync: no such root: $root" >&2; exit 2; }
case "$job" in ''|.|..|*[!A-Za-z0-9._:-]*|*..*) echo "worker_sync: bad job id" >&2; exit 2 ;; esac
patch="$(cat)"
printf '%s' "$patch" | jq -e 'type == "object"' >/dev/null 2>&1 || { echo "worker_sync: patch is not a JSON object" >&2; exit 2; }

unset MOTHER_LIVE_ROOT JOBS_DIR EVENTS_DIR LOGS_DIR DRAFTS_DIR CURSORS_DIR RUNNER_DIR ARCHIVE_DIR TEARDOWN_DIR RESIDUE_DIR
MOTHER_ROOT="$(cd "$root" && pwd -P)"; export MOTHER_ROOT
MOTHER_WORKER_MODE=1; export MOTHER_WORKER_MODE
MOTHER_WORKER_OUTBOX_DIR="$MOTHER_ROOT/outbox"; export MOTHER_WORKER_OUTBOX_DIR
MOTHER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"; export MOTHER_LIB_DIR
# shellcheck source=/dev/null
source "$MOTHER_LIB_DIR/state.sh"

_ws_file="$MOTHER_ROOT/jobs/$job.json"
[ -f "$_ws_file" ] || { echo "worker_sync: no mirror job $job" >&2; exit 1; }

_ws_merge() {
    local merged
    merged="$(jq --argjson p "$patch" '. + $p' "$_ws_file")" && _atomic_write "$_ws_file" "$merged"
}
_with_lock "$_ws_file" _ws_merge
