# teardown.sh — tear down Mother-created worktrees and docker containers.
#
# Sourced by bin/mother (sibling of this lib dir). Does not set shell options;
# inherits `set -u` from mother. Same house style as state.sh/worktree.sh.
#
# Design constraint (load-bearing): every entry point here takes an explicit
# "facts" JSON blob and never reads $JOBS_DIR for the job under teardown. By
# the time a deferred teardown is retried from the pending queue, the job's
# JSON may already be archived (or gone) — the facts blob is the durable,
# self-contained snapshot teardown needs.
#
# Facts blob shape:
#   {"id":"...","repo":"...","repo_path":"...","branch":"...","work_dir":"...",
#    "isolation":"worktree","pr_url":"...","state":"succeeded","no_pr":false,
#    "events_path":"/…/archive/2026-07/<id>.events.jsonl"}
#
# Side-channel result variables (mirrors the _apply_posture_bias /
# POSTURE_BIAS_ACTION pattern already used in state.sh): _teardown_execute
# sets TEARDOWN_LAST_STATUS (torn_down|deferred|skipped|failed) and
# TEARDOWN_LAST_REASON in the caller's scope, in addition to its return code.
# _teardown_worktree sets TEARDOWN_WORKTREE_SKIP_REASON (main_dir|already_absent)
# when it returns 1. These only work because callers invoke the functions
# directly (not via command substitution) — see the comments at each call site.

: "${MOTHER_TEARDOWN_ENABLED:=1}"
: "${MOTHER_TEARDOWN_DOCKER_ENABLED:=1}"
: "${MOTHER_TEARDOWN_MAX_DEFERRALS:=30}"

_teardown_pending_path() { echo "$TEARDOWN_DIR/$1.json"; }

# _facts_get <facts_json> <jq_filter> — the "read one field out of the facts
# blob" idiom used throughout this file. This is the ONLY way functions here
# read job data: never $JOBS_DIR, always the facts blob passed in by the
# caller (see the file-level comment on why that's load-bearing).
_facts_get() {
    printf '%s' "$1" | jq -r "$2"
}

# ---------- events ----------

# Append a teardown event, resolving the right destination file: the live
# per-job events file while the job record still exists in $JOBS_DIR, the
# archived events file (from facts.events_path) once it's been moved, or a
# shared fallback file as a last resort so nothing is silently dropped.
# Usage: _teardown_event <facts_json> <kind> <detail_json>
_teardown_event() {
    local facts="$1" kind="$2" detail="${3:-{\}}"
    local id; id=$(_facts_get "$facts" '.id // empty')
    [ -n "$id" ] || return 1
    local ev
    ev=$(jq -nc --arg ts "$(_iso_now)" --arg kind "$kind" --argjson detail "$detail" \
        '{ts: $ts, kind: $kind, detail: $detail}') || return 1

    local target archived_path
    if [ -f "$JOBS_DIR/$id.json" ] || [ -f "$EVENTS_DIR/$id.jsonl" ]; then
        target="$EVENTS_DIR/$id.jsonl"
    else
        archived_path=$(_facts_get "$facts" '.events_path // ""')
        if [ -n "$archived_path" ] && [ -f "$archived_path" ]; then
            target="$archived_path"
        else
            target="$EVENTS_DIR/teardown.jsonl"
        fi
    fi
    _with_lock "$target" _append_line "$target" "$ev"
}

# ---------- PR disposition ----------

# _teardown_pr_disposition <pr_url> -> echoes merged|closed|open|inconclusive.
# Always exits 0; the disposition is the return value on stdout.
_teardown_pr_disposition() {
    local pr_url="$1"
    if ! command -v gh >/dev/null 2>&1; then
        echo "inconclusive"; return 0
    fi
    local state
    state=$(gh pr view "$pr_url" --json state -q '.state' 2>/dev/null)
    if [ -z "$state" ]; then
        echo "inconclusive"; return 0
    fi
    case "$state" in
        MERGED) echo "merged" ;;
        CLOSED) echo "closed" ;;
        OPEN)   echo "open" ;;
        *)      echo "inconclusive" ;;
    esac
    return 0
}

# ---------- gate ----------

# _teardown_gate <facts_json> -> echoes "proceed:<reason>" or "defer:<reason>".
_teardown_gate() {
    local facts="$1"
    local pr_url state no_pr
    pr_url=$(_facts_get "$facts" '.pr_url // empty')
    state=$(_facts_get "$facts" '.state // ""')
    no_pr=$(_facts_get "$facts" '.no_pr // false')

    if [ -z "$pr_url" ]; then
        case "$state" in
            failed|cancelled)
                echo "proceed:no_pr_terminal"
                return 0
                ;;
            succeeded)
                if [ "$no_pr" = "true" ]; then
                    echo "proceed:no_pr_by_design"
                else
                    echo "defer:no_pr_url_on_succeeded"
                fi
                return 0
                ;;
            *)
                # Unexpected: no PR, not (yet) terminal, not succeeded. Never
                # guess — defer so a human sweep can look at it later.
                echo "defer:no_pr_url_on_succeeded"
                return 0
                ;;
        esac
    fi

    local disposition
    disposition=$(_teardown_pr_disposition "$pr_url")
    case "$disposition" in
        merged) echo "proceed:pr_merged" ;;
        closed) echo "proceed:pr_closed" ;;
        open)   echo "defer:pr_open" ;;
        *)      echo "defer:gh_inconclusive" ;;
    esac
    return 0
}

# ---------- race guard ----------

# _teardown_race_check <facts_json> -> 0 clear, 1 conflict (echoes the
# conflicting job id). A conflict is any OTHER job in $JOBS_DIR sharing the
# same repo_path + branch whose state is not terminal (succeeded/failed/
# cancelled) — covers escalation re-queues, adherence rework, and a distinct
# job queued against the same branch.
_teardown_race_check() {
    local facts="$1"
    local self_id repo_path branch
    self_id=$(_facts_get "$facts" '.id')
    repo_path=$(_facts_get "$facts" '.repo_path // ""')
    branch=$(_facts_get "$facts" '.branch // ""')

    local f other_id other_repo other_branch other_state
    for f in "$JOBS_DIR"/*.json; do
        [ -f "$f" ] || continue
        other_id=$(jq -r '.id // ""' "$f" 2>/dev/null) || continue
        [ "$other_id" = "$self_id" ] && continue
        other_repo=$(jq -r '.repo_path // ""' "$f" 2>/dev/null)
        [ "$other_repo" = "$repo_path" ] || continue
        other_branch=$(jq -r '.branch // ""' "$f" 2>/dev/null)
        [ "$other_branch" = "$branch" ] || continue
        other_state=$(jq -r '.state // ""' "$f" 2>/dev/null)
        case "$other_state" in
            succeeded|failed|cancelled) continue ;;
        esac
        echo "$other_id"
        return 1
    done
    return 0
}

# ---------- docker ----------

# _teardown_docker <facts_json> <dry_run> -> 0 clean, 1 skipped, 2 defer.
# Every docker mutation carries either the job-scoped `-p <project>` compose
# flag or a `label=mother.job_id=…` / `label=com.docker.compose.project=…`
# filter — never an unfiltered removal. Runs before worktree removal because
# a compose file it may need can live inside the worktree.
_teardown_docker() {
    local facts="$1" dry_run="${2:-0}"

    if [ "${MOTHER_TEARDOWN_DOCKER_ENABLED:-1}" = "0" ]; then
        return 1
    fi
    command -v docker >/dev/null 2>&1 || return 1

    if ! docker info --format '{{.ServerVersion}}' >/dev/null 2>&1; then
        return 2
    fi

    local id work_dir project
    id=$(_facts_get "$facts" '.id')
    work_dir=$(_facts_get "$facts" '.work_dir // ""')
    project=$(mother_compose_project "$id")

    if [ "$dry_run" -eq 1 ]; then
        echo "[dry-run] would tear down docker resources for project $project (job $id)"
        return 0
    fi

    local wd_or_fallback
    if [ -n "$work_dir" ] && [ -d "$work_dir" ]; then
        wd_or_fallback="$work_dir"
    else
        wd_or_fallback="$MOTHER_ROOT"
    fi

    ( cd "$wd_or_fallback" && docker compose -p "$project" down --volumes --remove-orphans --timeout 30 ) >/dev/null 2>&1 || true

    local containers=0 volumes=0 networks=0
    local selector cid vid nid
    for selector in "label=mother.job_id=$id" "label=com.docker.compose.project=$project"; do
        for cid in $(docker ps -aq --filter "$selector" 2>/dev/null); do
            [ -n "$cid" ] || continue
            docker rm -f "$cid" >/dev/null 2>&1 || true
            containers=$((containers + 1))
        done
        for vid in $(docker volume ls -q --filter "$selector" 2>/dev/null); do
            [ -n "$vid" ] || continue
            docker volume rm -f "$vid" >/dev/null 2>&1 || true
            volumes=$((volumes + 1))
        done
        for nid in $(docker network ls -q --filter "$selector" 2>/dev/null); do
            [ -n "$nid" ] || continue
            docker network rm "$nid" >/dev/null 2>&1 || true
            networks=$((networks + 1))
        done
    done

    jq -nc --arg cp "$project" --argjson c "$containers" --argjson v "$volumes" --argjson n "$networks" \
        '{compose_project: $cp, containers: $c, volumes: $v, networks: $n}'
    return 0
}

# ---------- worktree ----------

# _teardown_worktree <facts_json> <dry_run> -> 0 removed, 1 skipped, 2 error.
# Sets TEARDOWN_WORKTREE_SKIP_REASON (main_dir|already_absent) whenever it
# returns 1, so the caller can emit an accurate teardown_skipped event.
_teardown_worktree() {
    local facts="$1" dry_run="${2:-0}"
    local isolation repo_path branch work_dir target

    isolation=$(_facts_get "$facts" '.isolation // ""')
    if [ "$isolation" != "worktree" ]; then
        # main-dir jobs run in the operator's own checkout. Removing it would
        # be catastrophic — this is the single most important guard here.
        TEARDOWN_WORKTREE_SKIP_REASON="main_dir"
        return 1
    fi

    repo_path=$(_facts_get "$facts" '.repo_path // ""')
    branch=$(_facts_get "$facts" '.branch // ""')
    work_dir=$(_facts_get "$facts" '.work_dir // ""')

    if [ -n "$work_dir" ]; then
        target="$work_dir"
    elif [ -n "$repo_path" ] && [ -d "$repo_path" ] && [ -n "$branch" ]; then
        target=$(cd "$repo_path" && worktree_get_path "$branch")
    else
        target=""
    fi

    if [ -z "$target" ] || [ "$target" = "/" ] || [ "$target" = "$HOME" ] || [ "$target" = "$repo_path" ]; then
        return 2
    fi

    # The repo may have been moved or deleted since the job ran. Never error
    # the archive sweep over it.
    if [ ! -d "$repo_path" ]; then
        TEARDOWN_WORKTREE_SKIP_REASON="already_absent"
        return 1
    fi

    # Compare against git's registered-worktree list using the resolved real
    # path on both sides: `git worktree list --porcelain` always reports
    # canonicalized paths, and on macOS $target (built from $TMPDIR/mktemp
    # paths) commonly differs from its canonical form only by a /tmp ->
    # /private/tmp (or /var -> /private/var) symlink hop. A literal string
    # compare against the raw $target would false-negative on every such box.
    local real_target
    real_target=$(cd "$target" 2>/dev/null && pwd -P)
    if [ -z "$real_target" ] \
        || ! (cd "$repo_path" && git worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $real_target"); then
        ( cd "$repo_path" && worktree_prune ) >/dev/null 2>&1 || true
        TEARDOWN_WORKTREE_SKIP_REASON="already_absent"
        return 1
    fi

    if [ "$dry_run" -eq 1 ]; then
        echo "[dry-run] would remove worktree $target"
        return 0
    fi

    # Both calls run inside a subshell: worktree_remove/worktree_prune `cd` to
    # the main repo internally, and invoking them bare would silently change
    # the caller's cwd for the rest of the sweep.
    ( cd "$repo_path" && worktree_remove "$target" true ) >/dev/null 2>&1
    ( cd "$repo_path" && worktree_prune )               >/dev/null 2>&1 || true

    [ -d "$target" ] && return 2
    return 0
}

# ---------- pending queue ----------

# _teardown_defer_record <facts_json> <reason> — upsert the pending record,
# incrementing its deferral count. Crossing MOTHER_TEARDOWN_MAX_DEFERRALS
# emits teardown_needs_attention exactly once (on the crossing, not on every
# subsequent pass) — it never triggers destruction, only makes the stall loud.
_teardown_defer_record() {
    local facts="$1" reason="$2"
    local id; id=$(_facts_get "$facts" '.id')
    local path; path=$(_teardown_pending_path "$id")

    local prev_deferrals=0
    if [ -f "$path" ]; then
        prev_deferrals=$(jq -r '.deferrals // 0' "$path" 2>/dev/null) || prev_deferrals=0
    fi
    case "$prev_deferrals" in ''|*[!0-9]*) prev_deferrals=0 ;; esac
    local deferrals=$((prev_deferrals + 1))

    local record
    record=$(printf '%s' "$facts" | jq \
        --arg reason "$reason" \
        --arg deferred_at "$(_iso_now)" \
        --argjson deferrals "$deferrals" \
        '. + {last_reason: $reason, deferred_at: $deferred_at, deferrals: $deferrals}')
    mkdir -p "$TEARDOWN_DIR"
    _atomic_write "$path" "$record"

    local cap="${MOTHER_TEARDOWN_MAX_DEFERRALS:-30}"
    if [ "$deferrals" -gt "$cap" ] && [ "$prev_deferrals" -le "$cap" ]; then
        _teardown_event "$facts" "teardown_needs_attention" \
            "$(jq -nc --argjson d "$deferrals" --arg r "$reason" '{deferrals: $d, reason: $r}')"
    fi
}

_teardown_clear_pending() {
    local id="$1"
    rm -f "$(_teardown_pending_path "$id")"
}

# _teardown_park <facts_json> <status> <reason> <event_kind> [<detail_json>]
# Shared tail for every non-dry-run "this job needs another pass" outcome in
# _teardown_execute — deferred (waiting on something external: PR, gh,
# docker, a racing job) or failed (worktree_error, worth retrying). Sets
# TEARDOWN_LAST_STATUS/REASON, emits the event, and upserts the pending
# record. Always returns 1; callers still `return 1` themselves for clarity
# at the call site rather than relying on this function's exit code.
_teardown_park() {
    local facts="$1" status="$2" reason="$3" kind="$4" detail="${5:-{\}}"
    TEARDOWN_LAST_STATUS="$status"; TEARDOWN_LAST_REASON="$reason"
    _teardown_event "$facts" "$kind" "$detail"
    _teardown_defer_record "$facts" "$reason"
    return 1
}

# ---------- orchestrator ----------

# _teardown_execute <facts_json> <dry_run> -> 0 completed, 1 deferred/skipped.
# Sequence: enabled check -> gate -> race check -> docker -> worktree.
# Dry run passes through every check but emits no events, writes no pending
# record, and mutates nothing.
_teardown_execute() {
    local facts="$1" dry_run="${2:-0}"
    local id pr_url
    id=$(_facts_get "$facts" '.id')
    pr_url=$(_facts_get "$facts" '.pr_url // ""')

    TEARDOWN_LAST_STATUS=""
    TEARDOWN_LAST_REASON=""

    if [ "${MOTHER_TEARDOWN_ENABLED:-1}" = "0" ]; then
        if [ "$dry_run" -eq 1 ]; then
            TEARDOWN_LAST_STATUS="skipped"; TEARDOWN_LAST_REASON="disabled"
            echo "[dry-run] would skip teardown for $id (disabled)"
            return 1
        fi
        _teardown_park "$facts" "skipped" "disabled" "teardown_skipped" '{"reason":"disabled"}'
        return 1
    fi

    local gate reason
    gate=$(_teardown_gate "$facts")
    reason="${gate#*:}"

    if [ "${gate%%:*}" = "defer" ]; then
        if [ "$dry_run" -eq 1 ]; then
            TEARDOWN_LAST_STATUS="deferred"; TEARDOWN_LAST_REASON="$reason"
            echo "[dry-run] would defer teardown for $id ($reason)"
            return 1
        fi
        local gate_detail
        gate_detail=$(jq -nc --arg r "$reason" --arg pr "$pr_url" '{reason: $r, pr_url: $pr}')
        _teardown_park "$facts" "deferred" "$reason" "teardown_deferred" "$gate_detail"
        return 1
    fi

    local conflict race_status
    conflict=$(_teardown_race_check "$facts")
    race_status=$?
    if [ "$race_status" -eq 1 ]; then
        if [ "$dry_run" -eq 1 ]; then
            TEARDOWN_LAST_STATUS="deferred"; TEARDOWN_LAST_REASON="race"
            echo "[dry-run] would defer teardown for $id (race with $conflict)"
            return 1
        fi
        local race_detail
        race_detail=$(jq -nc --arg cid "$conflict" '{reason:"race", conflicting_job_id: $cid}')
        _teardown_park "$facts" "deferred" "race" "teardown_deferred" "$race_detail"
        return 1
    fi

    if [ "$dry_run" -eq 1 ]; then
        echo "[dry-run] gate passed ($reason) for $id; would tear down docker + worktree"
        _teardown_docker "$facts" 1 >/dev/null 2>&1
        _teardown_worktree "$facts" 1 >/dev/null 2>&1
        TEARDOWN_LAST_STATUS="torn_down"; TEARDOWN_LAST_REASON="$reason"
        return 1
    fi

    _teardown_event "$facts" "teardown_started" \
        "$(jq -nc --arg r "$reason" --arg pr "$pr_url" '{gate_reason: $r, pr_url: $pr}')"

    local docker_summary docker_status
    docker_summary=$(_teardown_docker "$facts" 0)
    docker_status=$?
    if [ "$docker_status" -eq 2 ]; then
        _teardown_park "$facts" "deferred" "docker_unreachable" "teardown_deferred" '{"reason":"docker_unreachable"}'
        return 1
    fi

    TEARDOWN_WORKTREE_SKIP_REASON=""
    local wt_status
    _teardown_worktree "$facts" 0
    wt_status=$?

    if [ "$wt_status" -eq 2 ]; then
        _teardown_park "$facts" "failed" "worktree_error" "teardown_failed" '{"stage":"worktree"}'
        return 1
    fi

    if [ "$wt_status" -eq 1 ]; then
        local skip_reason="${TEARDOWN_WORKTREE_SKIP_REASON:-already_absent}"
        TEARDOWN_LAST_STATUS="skipped"; TEARDOWN_LAST_REASON="$skip_reason"
        _teardown_event "$facts" "teardown_skipped" "$(jq -nc --arg r "$skip_reason" '{reason: $r}')"
        _teardown_clear_pending "$id"
        return 0
    fi

    # wt_status == 0: worktree removed.
    local project work_dir containers volumes networks
    project=$(mother_compose_project "$id")
    work_dir=$(_facts_get "$facts" '.work_dir // ""')
    if [ -n "${docker_summary:-}" ]; then
        containers=$(printf '%s' "$docker_summary" | jq -r '.containers // 0' 2>/dev/null) || containers=0
        volumes=$(printf '%s' "$docker_summary" | jq -r '.volumes // 0' 2>/dev/null) || volumes=0
        networks=$(printf '%s' "$docker_summary" | jq -r '.networks // 0' 2>/dev/null) || networks=0
    else
        containers=0; volumes=0; networks=0
    fi

    TEARDOWN_LAST_STATUS="torn_down"; TEARDOWN_LAST_REASON="$reason"
    _teardown_event "$facts" "teardown_completed" \
        "$(jq -nc --arg wp "$work_dir" --argjson wr true \
            --arg cp "$project" --argjson c "${containers:-0}" --argjson v "${volumes:-0}" --argjson n "${networks:-0}" \
            '{worktree_path: $wp, worktree_removed: $wr, compose_project: $cp, containers: $c, volumes: $v, networks: $n}')"
    _teardown_clear_pending "$id"
    return 0
}

# _teardown_drain <dry_run> — sweep $TEARDOWN_DIR, re-running _teardown_execute
# on each stored facts blob. Removes the record on success (handled by
# _teardown_execute itself via _teardown_clear_pending). Echoes a one-line
# summary for callers to fold into their own output.
_teardown_drain() {
    local dry_run="${1:-0}"
    local completed=0 deferred=0
    local f facts
    for f in "$TEARDOWN_DIR"/*.json; do
        [ -f "$f" ] || continue
        facts=$(jq -c '.' "$f" 2>/dev/null) || continue
        if _teardown_execute "$facts" "$dry_run"; then
            completed=$((completed + 1))
        else
            deferred=$((deferred + 1))
        fi
    done
    echo "teardowns: $completed completed, $deferred deferred"
}
