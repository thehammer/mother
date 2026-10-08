# attention.sh — the single "needs the operator's attention" list.
#
# Sourced by bin/mother (and, through it, mother-runner's refresh tick). Does
# not set shell options; inherits `set -u` from the caller.
#
# One producer (mother_attention_items), three renderers: `mother status`
# (no id), the `mother list` footer, and the statusline's ATTENTION count
# (via $MOTHER_ROOT/attention.json, written by mother_attention_write).
#
# HARD RULE: this library reads only local state — $JOBS_DIR, $TEARDOWN_DIR
# and local `git`. It NEVER calls `gh`, because it runs on the status /
# statusline hot path. Anything needing GitHub data (a PR's creation date, a
# dependency PR's merge state) is computed by the hourly teardown sweep or the
# dependency poller and stored in the state files this reads.
#
# Item shape: {kind, job_id, repo, branch, reason, since, detail, hint}.
#
# `needs_attention` job-field contract (producer-agnostic): any job JSON in
# $JOBS_DIR carrying `needs_attention: {reason, note, since}` is rendered as a
# `job_flagged` item. Whoever holds a job for the operator (a failure
# classifier, a future producer) sets the field; this library only renders it.

: "${MOTHER_TEARDOWN_MAX_DEFERRALS:=30}"
: "${MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS:=2}"
: "${MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS:=7}"

_ATTENTION_PLUGIN_UPDATE_CMD='claude plugin update mother@thehammer-mother'

# --- sources (each prints zero or more compact JSON objects, one per line) ---

_attention_teardown_items() {
    local f
    for f in "$TEARDOWN_DIR"/*.json; do
        [ -f "$f" ] || continue
        jq -c \
            --argjson cap "${MOTHER_TEARDOWN_MAX_DEFERRALS:-30}" \
            --argjson probe_cap "${MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS:-2}" \
            --argjson stale_days "${MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS:-7}" \
            --argjson now "$(date +%s)" '
            def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
            (.last_reason // "") as $reason
            | ($reason == "pr_open" or $reason == "pr_open_live") as $healthy
            | (if $reason == "worktree_probe_failed" then $probe_cap else $cap end) as $limit
            | if (($healthy | not) and ((.stall_deferrals // 0) > $limit)) then
                {kind: "teardown_stalled", job_id: .id, repo: (.repo // ""), branch: (.branch // ""),
                 reason: $reason, since: (.deferred_at // ""),
                 detail: {stall_deferrals: (.stall_deferrals // 0), deferrals: (.deferrals // 0),
                          cap: $limit, work_dir: (.work_dir // ""), pr_url: (.pr_url // ""),
                          docker_pending: (.docker_pending // false),
                          worktree_removed: (.worktree_removed // false)},
                 hint: ("mother teardowns  (pending teardown is stalled: " + $reason + ")"
                        + (if $reason == "unsafe_worktree" and (.work_dir // "") != ""
                           then " — inspect " + .work_dir + " for unpushed/uncommitted work" else "" end)
                        + (if (.docker_pending // false) == true
                           then (if (.worktree_removed // false) == true then " — worktree already removed; " else " — " end)
                                + "Docker resources are still pending (is Docker running?)"
                           else "" end))}
              elif $healthy then
                ((.open_pr.created_at // .open_pr.first_seen_open_at // "") as $since
                 | if $since != "" then
                     ((($now - ($since | try epoch catch $now)) / 86400) | floor) as $age
                     | if $age > $stale_days then
                         {kind: "pr_open_stale", job_id: .id, repo: (.repo // ""), branch: (.branch // ""),
                          reason: $reason, since: $since,
                          detail: {pr_url: (.open_pr.url // .pr_url // ""), age_days: $age},
                          hint: ("PR open " + ($age | tostring) + " days — merge or close "
                                 + (.open_pr.url // .pr_url // "it") + " so its worktree can be torn down")}
                       else empty end
                   else empty end)
              else empty end' "$f" 2>/dev/null
    done
}

# Residue directories a teardown could not remove (root-owned files left by a
# container, say). One item per record whose directory still exists; the hint
# carries the suggested manual command. Mother never runs it (and never sudo).
_attention_residue_items() {
    local f
    for f in "$RESIDUE_DIR"/*.json; do
        [ -f "$f" ] || continue
        local path; path=$(jq -r '.path // ""' "$f" 2>/dev/null)
        [ -n "$path" ] && [ -d "$path" ] || continue
        jq -c '{kind: "teardown_residue", job_id: .id, repo: (.repo // ""), branch: (.branch // ""),
                reason: "residue_not_removable", since: (.since // ""),
                detail: {path: .path, sub: (.sub // "")},
                hint: ("could not remove " + .path + " — run: " + .command)}' "$f" 2>/dev/null
    done
}

# Dispatch is paused while the volume holding the next job's repo is below
# MOTHER_MIN_FREE_GB; mother-runner writes $RUNNER_DIR/low-disk.json while that
# holds and removes it when space recovers.
_attention_low_disk_items() {
    local f="$RUNNER_DIR/low-disk.json"
    [ -f "$f" ] || return 0
    jq -c '{kind: "low_disk", job_id: "", repo: "", branch: "",
            reason: ("Low disk: " + (.free_gb | tostring) + " GB free, dispatch paused"),
            since: (.since // ""),
            detail: {free_gb: .free_gb, threshold_gb: .threshold_gb, path: (.path // ""), repo_path: (.repo_path // "")},
            hint: ("free space (mother gc, empty caches); dispatch resumes automatically above "
                   + (.threshold_gb | tostring) + " GB — running jobs are not affected")}' "$f" 2>/dev/null
}

_attention_job_items() {
    local f
    for f in "$JOBS_DIR"/*.json; do
        [ -f "$f" ] || continue
        jq -c '
            (select(.state == "queued" and (.dep_wait.status // "") == "blocked")
             | {kind: "dependency_blocked", job_id: .id, repo: (.repo // ""), branch: (.branch // ""),
                reason: (.dep_wait.reason // ""), since: (.dep_wait.checked_at // ""),
                detail: {dep_id: (.dep_wait.dep_id // ""), pr_url: (.dep_wait.pr_url // "")},
                hint: ("mother force-start " + .id + "  (release it anyway)  or  mother cancel " + .id)}),
            (select(.needs_attention != null and (.needs_attention | type) == "object")
             | {kind: "job_flagged", job_id: .id, repo: (.repo // ""), branch: (.branch // ""),
                reason: (.needs_attention.reason // ""), since: (.needs_attention.since // ""),
                detail: {note: (.needs_attention.note // "")},
                hint: ("mother status " + .id)})' "$f" 2>/dev/null
    done
}

# A job whose adherence review has been spawned more than
# MOTHER_ADHERENCE_LOOP_THRESHOLD (default 5) times in the last hour is almost
# certainly looping (see the 1532-review incident) — whatever the cause. Reads
# only the job's local events file; the cheap grep pre-filter keeps the common
# no-adherence-events case to one grep per job.
_attention_adherence_loop_items() {
    local f id events_file
    for f in "$JOBS_DIR"/*.json; do
        [ -f "$f" ] || continue
        id=$(basename "$f" .json)
        events_file=$(_events_path "$id")
        [ -f "$events_file" ] || continue
        grep -F '"adherence_review_spawned"' "$events_file" 2>/dev/null \
            | jq -cs --arg id "$id" \
                --arg repo "$(jq -r '.repo // ""' "$f" 2>/dev/null)" \
                --arg branch "$(jq -r '.branch // ""' "$f" 2>/dev/null)" \
                --argjson threshold "${MOTHER_ADHERENCE_LOOP_THRESHOLD:-5}" \
                --argjson now "$(date +%s)" '
                def epoch: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
                [ .[] | select(.kind == "adherence_review_spawned")
                      | select((try (.ts | epoch) catch 0) > ($now - 3600)) ] as $recent
                | if ($recent | length) > $threshold then
                    {kind: "adherence_loop", job_id: $id, repo: $repo, branch: $branch,
                     reason: ("adherence review ran " + ($recent | length | tostring) + " times in the last hour"),
                     since: $recent[0].ts,
                     detail: {runs_last_hour: ($recent | length)},
                     hint: ("mother status " + $id + "  (the review is likely looping; MOTHER_ADHERENCE_ENABLED=0 stops all reviews)")}
                  else empty end' 2>/dev/null
    done
}

# Auto-stash entries (`mother:auto-stash:<id>`, written by mother-run-job when
# it stashes an operator's dirty main-dir tree) whose owning job is no longer
# active. Display only — never pops or drops anything.
_attention_stash_items() {
    local f repo repos
    repos=$(for f in "$JOBS_DIR"/*.json; do
                [ -f "$f" ] || continue
                jq -r 'select(.isolation == "main-dir") | .repo_path // empty' "$f" 2>/dev/null
            done | sort -u)
    [ -n "$repos" ] || return 0

    while IFS= read -r repo; do
        [ -n "$repo" ] && [ -d "$repo" ] || continue
        git -C "$repo" stash list --format='%gd%x09%gs' 2>/dev/null \
            | while IFS=$'\t' read -r ref subject; do
                case "$subject" in *mother:auto-stash:*) ;; *) continue ;; esac
                local sid="${subject##*mother:auto-stash:}"
                sid="${sid%% *}"
                [ -n "$sid" ] || continue
                local sstate=""
                [ -f "$(_job_path "$sid")" ] && sstate=$(jq -r '.state // ""' "$(_job_path "$sid")" 2>/dev/null)
                case "$sstate" in running|ready|awaiting) continue ;; esac
                jq -nc --arg id "$sid" --arg repo "$repo" --arg ref "$ref" --arg st "${sstate:-unknown}" '
                    {kind: "auto_stash_unrestored", job_id: $id, repo: ($repo | split("/") | last),
                     branch: "", reason: "auto_stash_unrestored", since: "",
                     detail: {repo_path: $repo, stash: $ref, job_state: $st},
                     hint: ("git -C " + $repo + " stash list   then   git -C " + $repo
                            + " stash show -p " + $ref + "   (Mother never pops it for you)")}'
            done
    done <<EOF
$repos
EOF
}

# The plugin cache can lag the repo by months (a 0.1.0 cache installed in
# April kept serving a stale hook). Compare the one cached file whose
# staleness still matters — the UserPromptSubmit hook script.
_attention_plugin_cache_items() {
    local manifest="${HOME:-}/.claude/plugins/installed_plugins.json"
    [ -f "$manifest" ] || return 0
    local install_path
    install_path=$(jq -r '(.plugins // {}) | to_entries | map(select(.key | startswith("mother@"))) | .[0].value[0].installPath // empty' "$manifest" 2>/dev/null)
    [ -n "$install_path" ] || return 0
    local cached="$install_path/hooks/mother-inject.sh"
    local own="${MOTHER_LIB_DIR:-}/../hooks/mother-inject.sh"
    [ -f "$cached" ] && [ -f "$own" ] || return 0
    if [ "$(cksum < "$cached")" != "$(cksum < "$own")" ]; then
        jq -nc --arg p "$install_path" --arg cmd "$_ATTENTION_PLUGIN_UPDATE_CMD" '
            {kind: "plugin_cache_stale", job_id: "", repo: "", branch: "",
             reason: "hook_script_differs_from_repo", since: "",
             detail: {install_path: $p}, hint: ("run: " + $cmd)}'
    fi
}

# ---------- public ----------

# mother_attention_items — print the needs-attention list as a JSON array.
mother_attention_items() {
    { _attention_teardown_items
      _attention_residue_items
      _attention_low_disk_items
      _attention_job_items
      _attention_adherence_loop_items
      _attention_stash_items
      _attention_plugin_cache_items
    } | jq -cs '.' 2>/dev/null || echo '[]'
}

# mother_attention_write — atomically publish the list to
# $MOTHER_ROOT/attention.json (always valid JSON; `[]` when nothing to report).
mother_attention_write() {
    local items
    items=$(mother_attention_items)
    printf '%s' "$items" | jq -e 'type == "array"' >/dev/null 2>&1 || items='[]'
    _atomic_write "$MOTHER_ROOT/attention.json" "$items"
}

# mother_attention_render_text <items_json> — human rendering used by `mother status`.
mother_attention_render_text() {
    local items="$1" n
    n=$(printf '%s' "$items" | jq 'length')
    echo "=== needs attention ($n) ==="
    if [ "$n" = "0" ]; then
        echo "  (nothing needs attention)"
        return 0
    fi
    printf '%s' "$items" | jq -r '.[] |
        "  [" + .kind + "] " + (if .job_id != "" then .job_id else "-" end)
        + (if .reason != "" then " — " + .reason else "" end)
        + "\n      " + .hint'
}
