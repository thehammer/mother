# teardown.sh — tear down Mother-created worktrees and docker containers.
#
# Sourced by bin/mother (sibling of this lib dir). Does not set shell options;
# inherits `set -u` from mother. Same house style as state.sh/worktree.sh.
#
# Design constraint (load-bearing): every entry point here takes an explicit
# "facts" JSON blob and never reads $JOBS_DIR for the job under teardown. By
# the time a deferred teardown is retried from the pending queue, the job's
# JSON may already be archived (or gone) — the facts blob is the durable,
# self-contained snapshot teardown needs. The one deliberate exception is
# _teardown_record_fields: it WRITES the live job record (via _job_update) when
# one still exists, and is a documented no-op when it doesn't. It never reads
# job data to make a teardown decision, so it doesn't undermine the
# facts-blob-only rule above.
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
# when it returns 1, and TEARDOWN_RESIDUE_PATH/_SUB when a leftover non-git
# directory could not be removed (see _teardown_remove_residue).
# _teardown_drain sets TEARDOWN_DRAIN_IDS (space-delimited job ids it
# attempted this pass) so cmd_archive's bulk loop can avoid a
# second _teardown_execute for a job the drain already handled this sweep —
# consulted by BOTH of that loop's branches: the teardown-only branch skips the
# job entirely, and the archive branch still moves the record but tells
# _archive_one not to re-run teardown. These only work because callers invoke
# the functions directly (not via command substitution) — see the comments at
# each call site. _teardown_attempt is the single choke point that pairs every
# _teardown_execute call with exactly one _teardown_record_fields write, so no
# caller can produce two recorded outcomes (or two gh/docker calls) for one
# attempt.

: "${MOTHER_TEARDOWN_ENABLED:=1}"
: "${MOTHER_TEARDOWN_DOCKER_ENABLED:=1}"
: "${MOTHER_TEARDOWN_MAX_DEFERRALS:=30}"
# A probe failure (worktree_probe_failed) should be loud in ~2 hourly sweeps,
# not ~30 — it means we can't tell whether removing the worktree is safe.
: "${MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS:=2}"
# A healthy PR wait only becomes an attention item once the PR has been open
# this many days.
: "${MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS:=7}"
: "${MOTHER_DOCKER_PROBE_TIMEOUT:=5}"  # seconds before a wedged `docker info` probe is killed
: "${MOTHER_TEARDOWN_ALLOW_UNSAFE:=0}" # 1 restores unconditional force-removal, bypassing the unsafe-worktree probe

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
# For the two healthy-wait reasons (pr_open_live, pr_open) the verdict is
# followed by a TAB and the open PR's URL: "defer:pr_open<TAB><url>". The gate
# is called via command substitution, so a global couldn't carry the URL back;
# callers split on the TAB. The reason itself is unchanged.
_teardown_gate() {
    local facts="$1"
    local pr_url state no_pr
    pr_url=$(_facts_get "$facts" '.pr_url // empty')
    state=$(_facts_get "$facts" '.state // ""')
    no_pr=$(_facts_get "$facts" '.no_pr // false')

    # Live-branch probe: regardless of what the STORED pr_url says, check
    # whether the job's branch currently has ITS OWN open PR. A branch can
    # be reused for a fresh PR after the one Mother recorded was
    # merged/closed out from under it — stored #59 merged doesn't mean the
    # branch is idle if #60 (never captured) is now open on it. See
    # .claude/bugs/*/2026-08-14-review-phase-silently-reviews-wrong-repo-when-worktree-is-torn-down.md.
    # Skipped (falls through to the stored-pr_url logic below) whenever it
    # can't run confidently: no repo_path/branch on the facts blob, or
    # prdetect.sh isn't sourced. This is belt-and-braces on top of the
    # stored-URL check below, never a replacement for it.
    if type prd_pr_for_branch >/dev/null 2>&1 && type prd_owner_repo_from_dir >/dev/null 2>&1; then
        local live_repo_path live_branch live_owner_repo live_url
        live_repo_path=$(_facts_get "$facts" '.repo_path // ""')
        live_branch=$(_facts_get "$facts" '.branch // ""')
        if [ -n "$live_repo_path" ] && [ -d "$live_repo_path" ] && [ -n "$live_branch" ]; then
            live_owner_repo=$(prd_owner_repo_from_dir "$live_repo_path")
            if [ -n "$live_owner_repo" ]; then
                live_url=$(prd_pr_for_branch "$live_owner_repo" "$live_branch")
                if [ -n "$live_url" ]; then
                    printf 'defer:pr_open_live\t%s\n' "$live_url"
                    return 0
                fi
            fi
        fi
    fi

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
                    # A work_dir that is SET but absent from disk is not
                    # ambiguous: no local worktree content is at risk, and
                    # teardown never touches the remote branch. Job-scoped
                    # docker resources and the git worktree admin entry are
                    # still cleaned up downstream. An empty/unset work_dir
                    # stays deferred (never guess).
                    local absent_work_dir
                    absent_work_dir=$(_facts_get "$facts" '.work_dir // ""')
                    if [ -n "$absent_work_dir" ] && [ ! -d "$absent_work_dir" ]; then
                        echo "proceed:work_dir_absent"
                    else
                        echo "defer:no_pr_url_on_succeeded"
                    fi
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
        open)   printf 'defer:pr_open\t%s\n' "$pr_url" ;;
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

# _docker_reachable -> 0 reachable, 1 not reachable (failed OR timed out).
#
# `docker info` is normally fast whether Docker is up or down — but when
# Docker Desktop's backend is running yet wedged (socket alive, daemon
# unresponsive), the call can block forever instead of failing fast. Bound
# it with the same background-race watchdog pattern `_maybe_archive` uses
# in mother-runner for its hourly sweep: race the probe against a
# `sleep N; kill` watchdog and `wait` on whichever settles first.
#
# Caveat (same tradeoff `_maybe_archive` documents, at ~60x smaller blast
# radius — 5s default here vs. 300s at the sweep level): killing the probe
# frees this caller, but cannot reach a stuck `docker info` grandchild the
# probe itself spawned. Reaping that grandchild is out of scope here.
_docker_reachable() {
    ( docker info --format '{{.ServerVersion}}' >/dev/null 2>&1 ) &
    local probe_pid=$!
    ( sleep "${MOTHER_DOCKER_PROBE_TIMEOUT:-5}"; kill -9 "$probe_pid" 2>/dev/null ) &
    local watchdog_pid=$!
    local result=1
    if wait "$probe_pid" 2>/dev/null; then
        result=0
    fi
    # Probe settled (finished or was killed) — the race is over, so reap the
    # watchdog too instead of leaving it to fire uselessly later.
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
    return "$result"
}

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

    if ! _docker_reachable; then
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
        # Not a registered worktree. If a directory Mother recorded as this
        # job's work_dir is still on disk with no .git (ignored/generated
        # files left behind by an earlier removal), it is residue: clear it.
        # Only a RECORDED work_dir qualifies — a path derived from the branch
        # name is a guess, and a dir with a .git entry is never touched.
        if [ -n "$work_dir" ] && [ -n "$real_target" ] && [ ! -e "$target/.git" ]; then
            if [ "$dry_run" -eq 1 ]; then
                echo "[dry-run] would remove residue directory $target"
                return 0
            fi
            _teardown_remove_residue "$target" "$repo_path"
            return 0
        fi
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

    if [ -d "$target" ]; then
        # Still registered, or still a git checkout: the removal genuinely
        # failed. Anything else is non-git residue (ignored/generated files).
        if [ -e "$target/.git" ] \
            || (cd "$repo_path" && git worktree list --porcelain 2>/dev/null | grep -Fxq "worktree $real_target"); then
            return 2
        fi
        _teardown_remove_residue "$target" "$repo_path"
    fi
    return 0
}

# _teardown_remove_residue <dir> <repo_path> — rm -rf the non-git directory a
# removed worktree left behind. Sets TEARDOWN_RESIDUE_PATH / TEARDOWN_RESIDUE_SUB
# (both empty when the directory was fully removed). Never fails the caller: a
# directory that cannot be removed (root-owned files from a container) is
# reported through those variables so _teardown_execute can emit the residue
# event and attention record. Never uses sudo.
#
# Refuses to remove (and reports the directory as residue instead) a path that
# is not absolute, has `.`/`..`/empty components, is a symlink, or is / $HOME /
# the repo / $MOTHER_ROOT or an ancestor of them: those are never directories
# Mother created for a job.
_teardown_remove_residue() {
    local dir="$1" repo_path="$2"
    TEARDOWN_RESIDUE_PATH=""; TEARDOWN_RESIDUE_SUB=""
    while [ "${#dir}" -gt 1 ] && [ "${dir%/}" != "$dir" ]; do dir="${dir%/}"; done
    local refuse=0 guard
    case "$dir" in
        /*) ;;
        *) refuse=1 ;;
    esac
    case "$dir" in
        */../*|*/./*|*/..|*/.|*//*) refuse=1 ;;
    esac
    for guard in "/" "${HOME:-/}" "$repo_path" "$MOTHER_ROOT"; do
        [ -n "$guard" ] || continue
        case "$guard/" in "$dir"/*) refuse=1 ;; esac
    done
    [ -L "$dir" ] && refuse=1
    # A refused path is never removed, but it is not claimed as removed either:
    # it is reported as residue so the operator sees it.
    [ "$refuse" -eq 1 ] || rm -rf "$dir" >/dev/null 2>&1
    if [ -d "$dir" ]; then
        TEARDOWN_RESIDUE_PATH="$dir"
        TEARDOWN_RESIDUE_SUB=$(ls -A "$dir" 2>/dev/null | head -1)
    fi
    return 0
}

# _teardown_residue_command <dir> <sub> — the suggested manual cleanup for a
# residue directory Mother could not remove. Text only; Mother never runs it.
# Names are shell-quoted (printf %q): <sub> is a file name from inside the
# directory and is pasted by the operator.
_teardown_residue_command() {
    local dir="$1" sub="$2"
    local qdir qsub
    qdir=$(printf '%q' "$dir"); qsub=$(printf '%q' "$sub")
    printf 'docker run --rm -v %s:/x alpine rm -rf /x/%s   (fallback: sudo rm -rf %s/%s)' \
        "$qdir" "$qsub" "$qdir" "$qsub"
}

# _teardown_note_residue <facts_json> — if the last _teardown_worktree left
# unremovable residue, emit a teardown_residue event and write the durable
# record lib/attention.sh renders. No-op otherwise.
_teardown_note_residue() {
    local facts="$1"
    [ -n "${TEARDOWN_RESIDUE_PATH:-}" ] || return 0
    local id dir sub cmd
    id=$(_facts_get "$facts" '.id')
    dir="$TEARDOWN_RESIDUE_PATH"; sub="${TEARDOWN_RESIDUE_SUB:-}"
    cmd=$(_teardown_residue_command "$dir" "$sub")
    _teardown_event "$facts" "teardown_residue" \
        "$(jq -nc --arg p "$dir" --arg s "$sub" --arg c "$cmd" '{path: $p, sub: $s, command: $c}')"
    mkdir -p "$RESIDUE_DIR"
    _atomic_write "$RESIDUE_DIR/$id.json" "$(printf '%s' "$facts" | jq -c \
        --arg p "$dir" --arg s "$sub" --arg c "$cmd" --arg now "$(_iso_now)" \
        '{id: .id, repo: (.repo // ""), branch: (.branch // ""), path: $p, sub: $s, since: $now, command: $c}')"
}

# _teardown_remove_job_tmp <facts_json> <dry_run> — remove the job-scoped
# worker TMPDIR ($MOTHER_ROOT/tmp/<id>, created by mother-run-job). Only ever
# that one directory: the id must be a plain name.
_teardown_remove_job_tmp() {
    local facts="$1" dry_run="${2:-0}" id
    id=$(_facts_get "$facts" '.id // empty')
    case "$id" in ''|*/*|.|..) return 0 ;; esac
    local dir="$MOTHER_ROOT/tmp/$id"
    [ -d "$dir" ] && [ ! -L "$dir" ] || return 0
    if [ "$dry_run" -eq 1 ]; then
        echo "[dry-run] would remove job temp dir $dir"
    else
        rm -rf "$dir" 2>/dev/null || true
    fi
    return 0
}

# _teardown_worktree_unsafe <facts_json> -> 0 safe / 1 unsafe / 2 indeterminate.
# On unsafe (1), echoes a one-line detail object:
#   {"uncommitted_files": N, "unpushed_commits": N}
#
# Unsafe means the worktree holds work that would be genuinely unrecoverable
# if force-removed: uncommitted/untracked changes (`git status --porcelain`
# non-empty), or commits reachable from HEAD but from no remote-tracking ref
# at all (`git rev-list HEAD --not --remotes` non-empty) — i.e. never pushed
# anywhere. Indeterminate (2) covers an empty/unset work_dir field (we don't
# know which directory the job used, so we can't say anything about what's in
# it), a work_dir that exists but isn't a git repo, or any unexpected git
# error: never guess "safe" when the answer is unclear. A work_dir that is SET
# but simply absent from disk is NOT indeterminate — there is categorically
# nothing left in it to lose, so that case returns safe (0) and falls through
# to the caller's _teardown_worktree, whose own already_absent handling treats
# it as a clean skip.
#
# See .claude/bugs/*/2026-06-13-merged-job-worktrees-never-gc-d-target-dirs-exhaust-disk.md:
# "Whatever GC lands MUST NOT remove a worktree that is ahead-of-base or has
# uncommitted changes; those represent unrecovered work."
_teardown_worktree_unsafe() {
    local facts="$1"
    local work_dir; work_dir=$(_facts_get "$facts" '.work_dir // ""')
    if [ -z "$work_dir" ]; then
        # No recorded work_dir: the job either never created a worktree (it was
        # cancelled before it started — every such job used to be re-probed
        # hourly forever) or we lost track of it. Disambiguate with git's own
        # registry: if NO worktree is registered for the job's branch, Mother
        # never created anything for this job and there is nothing to lose
        # (safe; the caller's _teardown_worktree then takes its already_absent
        # skip). If one IS registered we can't prove THIS job owns it (two jobs
        # can share a branch), so it stays indeterminate — the low
        # MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS cap makes it loud fast.
        local u_repo u_branch registered
        u_repo=$(_facts_get "$facts" '.repo_path // ""')
        u_branch=$(_facts_get "$facts" '.branch // ""')
        [ -n "$u_repo" ] && [ -d "$u_repo" ] && [ -n "$u_branch" ] || return 2
        registered=$(git -C "$u_repo" worktree list --porcelain 2>/dev/null) || return 2
        if printf '%s\n' "$registered" | grep -Fxq "branch refs/heads/$u_branch"; then
            return 2
        fi
        return 0
    fi
    # A work_dir that is SET but absent from disk is NOT ambiguous. There is
    # categorically nothing left in it to lose — "the directory is gone" and
    # "there's unrecovered work at risk" are mutually exclusive. Returning 2
    # here parked such jobs in the pending queue forever (782 deferrals
    # observed). Return safe and let _teardown_worktree's own already_absent
    # skip handle it.
    [ -d "$work_dir" ] || return 0
    (cd "$work_dir" && git rev-parse --is-inside-work-tree >/dev/null 2>&1) || return 2

    local uncommitted unpushed
    uncommitted=$(cd "$work_dir" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
    case "${uncommitted:-}" in ''|*[!0-9]*) return 2 ;; esac

    unpushed=$(cd "$work_dir" && git rev-list --count HEAD --not --remotes 2>/dev/null)
    case "${unpushed:-}" in ''|*[!0-9]*) return 2 ;; esac

    if [ "$uncommitted" -gt 0 ] || [ "$unpushed" -gt 0 ]; then
        jq -nc --argjson u "$uncommitted" --argjson p "$unpushed" \
            '{uncommitted_files: $u, unpushed_commits: $p}'
        return 1
    fi
    return 0
}

# ---------- pending queue ----------

# _teardown_is_healthy_wait <reason> — pr_open / pr_open_live: the job's PR
# really is still open. A wait, not a stall: PRs legitimately stay open for
# days, and counting them would cry wolf.
_teardown_is_healthy_wait() {
    case "$1" in pr_open|pr_open_live) return 0 ;; *) return 1 ;; esac
}

# _teardown_healthy_wait_is_new <id> <reason> <pr_url> — 0 when this pass is
# the FIRST of a healthy wait (no pending record yet, the previous
# last_reason wasn't a healthy wait, or the open PR changed). Only that pass
# emits a teardown_deferred event; later passes are silent no-ops so a PR that
# stays open for weeks doesn't write ~600 identical events into the job's
# events file.
_teardown_healthy_wait_is_new() {
    local id="$1" pr_url="$3"
    local path; path=$(_teardown_pending_path "$id")
    [ -f "$path" ] || return 0
    local prev_reason prev_url
    prev_reason=$(jq -r '.last_reason // ""' "$path" 2>/dev/null) || return 0
    _teardown_is_healthy_wait "$prev_reason" || return 0
    prev_url=$(jq -r '.open_pr.url // ""' "$path" 2>/dev/null) || return 0
    [ "$prev_url" = "$pr_url" ] || return 0
    return 1
}

# _teardown_open_pr_json <prev_open_pr_json_or_empty> <pr_url> — the record's
# `open_pr` object {url, created_at, first_seen_open_at}. `gh pr view` runs
# only when the URL changed or created_at is still unknown: one call per PR per
# lifetime, not per sweep. If gh fails created_at stays null and
# first_seen_open_at is the fallback age source.
_teardown_open_pr_json() {
    local prev="$1" url="$2"
    local prev_url="" created="" first_seen=""
    if [ -n "$prev" ]; then
        prev_url=$(printf '%s' "$prev" | jq -r '.url // ""' 2>/dev/null)
        if [ "$prev_url" = "$url" ]; then
            created=$(printf '%s' "$prev" | jq -r '.created_at // ""' 2>/dev/null)
            first_seen=$(printf '%s' "$prev" | jq -r '.first_seen_open_at // ""' 2>/dev/null)
        fi
    fi
    [ -n "$first_seen" ] || first_seen=$(_iso_now)
    if [ -z "$created" ] && [ -n "$url" ]; then
        local out; out=$(mktemp "${TMPDIR:-/tmp}/mother-prcreated.XXXXXX") || out=""
        if [ -n "$out" ]; then
            if _bounded_run "${MOTHER_GH_TIMEOUT:-10}" "$out" gh pr view "$url" --json createdAt -q .createdAt; then
                created=$(tr -d '[:space:]' < "$out")
            fi
            rm -f "$out"
        fi
    fi
    jq -nc --arg url "$url" --arg created "$created" --arg first "$first_seen" \
        '{url: $url, created_at: (if $created == "" then null else $created end), first_seen_open_at: $first}'
}

# _teardown_defer_record <facts_json> <reason> [<open_pr_url>] — upsert the
# pending record.
#
# Healthy waits (pr_open, pr_open_live) are re-checked every sweep as quiet
# no-ops: `deferrals` and `stall_deferrals` do NOT move (historical values on
# older records are left as they are), and the record just refreshes
# last_reason / last_checked_at / open_pr. The operator hears about a PR wait
# only once it has been open more than MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS
# (see lib/attention.sh).
#
# Every other reason increments both `deferrals` and `stall_deferrals`.
# Crossing the reason's cap of `stall_deferrals` emits teardown_needs_attention
# exactly once (on the crossing, not on every subsequent pass): the cap is
# MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS (default 2) for
# worktree_probe_failed, MOTHER_TEARDOWN_MAX_DEFERRALS (default 30) otherwise.
# It never triggers destruction, only makes the stall loud.
_teardown_defer_record() {
    local facts="$1" reason="$2" open_pr_url="${3:-}"
    local id; id=$(_facts_get "$facts" '.id')
    local path; path=$(_teardown_pending_path "$id")

    local prev_deferrals=0 prev_stalls=0 prev_open_pr=""
    if [ -f "$path" ]; then
        prev_deferrals=$(jq -r '.deferrals // 0' "$path" 2>/dev/null) || prev_deferrals=0
        prev_stalls=$(jq -r '.stall_deferrals // 0' "$path" 2>/dev/null) || prev_stalls=0
        prev_open_pr=$(jq -c '.open_pr // empty' "$path" 2>/dev/null) || prev_open_pr=""
    fi
    case "$prev_deferrals" in ''|*[!0-9]*) prev_deferrals=0 ;; esac
    case "$prev_stalls"    in ''|*[!0-9]*) prev_stalls=0 ;; esac

    local now; now=$(_iso_now)
    local record
    mkdir -p "$TEARDOWN_DIR"

    if _teardown_is_healthy_wait "$reason"; then
        local open_pr
        open_pr=$(_teardown_open_pr_json "$prev_open_pr" "$open_pr_url")
        record=$(printf '%s' "$facts" | jq \
            --arg reason "$reason" --arg now "$now" \
            --argjson deferrals "$prev_deferrals" --argjson stalls "$prev_stalls" \
            --argjson open_pr "$open_pr" \
            '. + {last_reason: $reason, deferred_at: $now, last_checked_at: $now,
                  deferrals: $deferrals, stall_deferrals: $stalls, open_pr: $open_pr}')
        _atomic_write "$path" "$record"
        return 0
    fi

    local deferrals=$((prev_deferrals + 1))
    local stalls=$((prev_stalls + 1))
    record=$(printf '%s' "$facts" | jq \
        --arg reason "$reason" \
        --arg deferred_at "$now" \
        --argjson deferrals "$deferrals" \
        --argjson stalls "$stalls" \
        '. + {last_reason: $reason, deferred_at: $deferred_at, deferrals: $deferrals, stall_deferrals: $stalls}
         | del(.open_pr)')
    _atomic_write "$path" "$record"

    local cap="${MOTHER_TEARDOWN_MAX_DEFERRALS:-30}"
    [ "$reason" = "worktree_probe_failed" ] && cap="${MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS:-2}"
    if [ "$stalls" -gt "$cap" ] && [ "$prev_stalls" -le "$cap" ]; then
        _teardown_event "$facts" "teardown_needs_attention" \
            "$(jq -nc --argjson s "$stalls" --argjson d "$deferrals" --arg r "$reason" \
                '{deferrals: $d, stall_deferrals: $s, reason: $r}')"
    fi
}

_teardown_clear_pending() {
    local id="$1"
    rm -f "$(_teardown_pending_path "$id")"
}

# Record the outcome of a teardown attempt on a still-live job record. No-op
# when the job's record is gone (e.g. a drain pass re-attempting a job that
# was archived earlier in the same sweep) — there's nothing to write and
# _job_update would otherwise print "no such job" to stderr on every such
# pass. `teardown_at` always advances (it means "last attempt"), but a
# recorded `torn_down` is never downgraded: a job torn down by the
# teardown-only path while young gets a second, no-op attempt when it finally
# crosses the archive cutoff, and that pass legitimately reports
# skipped/already_absent. Letting it overwrite would make the field claim
# Mother never removed a worktree it did.
_teardown_record_fields() {
    local id="$1" status="$2" reason="$3"
    [ -n "$id" ] || return 0
    [ -f "$JOBS_DIR/$id.json" ] || return 0
    _job_update "$id" \
        "(if (.teardown_status == \"torn_down\" and \"$status\" != \"torn_down\")
          then . else (.teardown_status = \"$status\" | .teardown_reason = \"$reason\") end)
         | .teardown_at = \"$(_iso_now)\""
}

# _teardown_repoint_pending <id> <events_path> — after a job's record has moved
# into archive/YYYY-MM/, re-point any SURVIVING pending-teardown record at the
# archived events file, so later drain passes keep appending to the same audit
# trail instead of falling back to the shared $EVENTS_DIR/teardown.jsonl. No-op
# when the record is gone (the common case: teardown resolved and cleared it).
_teardown_repoint_pending() {
    local id="$1" events_path="$2"
    local path; path=$(_teardown_pending_path "$id")
    [ -f "$path" ] || return 0
    local updated
    updated=$(jq -c --arg ep "$events_path" '.events_path = $ep' "$path" 2>/dev/null) || return 0
    _atomic_write "$path" "$updated"
}

# _teardown_park <facts_json> <status> <reason> <event_kind> [<detail_json>]
#              [<open_pr_url>] [<emit_event=1>]
# Shared tail for every non-dry-run "this job needs another pass" outcome in
# _teardown_execute — deferred (waiting on something external: PR, gh,
# docker, a racing job) or failed (worktree_error, worth retrying). Sets
# TEARDOWN_LAST_STATUS/REASON, upserts the pending record (passing
# <open_pr_url> through to _teardown_defer_record when given), and emits the
# event — unless <emit_event> is explicitly "0", for the healthy-wait re-check
# case in _teardown_execute, which wants the status/pending-record bookkeeping
# on every pass but the event only on the first (see
# _teardown_healthy_wait_is_new). Always returns 1; callers still `return 1`
# themselves for clarity at the call site rather than relying on this
# function's exit code.
_teardown_park() {
    local facts="$1" status="$2" reason="$3" kind="$4" detail="${5:-{\}}"
    local open_pr_url="${6:-}" emit_event="${7:-1}"
    TEARDOWN_LAST_STATUS="$status"; TEARDOWN_LAST_REASON="$reason"
    [ "$emit_event" = "0" ] || _teardown_event "$facts" "$kind" "$detail"
    _teardown_defer_record "$facts" "$reason" "$open_pr_url"
    return 1
}

# ---------- orchestrator ----------

# _teardown_docker_counts <docker_summary_json> — echo "containers volumes
# networks" from a _teardown_docker summary ("0 0 0" when it is empty or
# unparseable). Read with: read -r c v n <<< "$(_teardown_docker_counts "$s")".
_teardown_docker_counts() {
    local summary="${1:-}" c=0 v=0 n=0
    if [ -n "$summary" ]; then
        c=$(printf '%s' "$summary" | jq -r '.containers // 0' 2>/dev/null) || c=0
        v=$(printf '%s' "$summary" | jq -r '.volumes // 0' 2>/dev/null) || v=0
        n=$(printf '%s' "$summary" | jq -r '.networks // 0' 2>/dev/null) || n=0
    fi
    echo "${c:-0} ${v:-0} ${n:-0}"
}

# _teardown_execute_docker_only <facts_json> <dry_run> -> 0 completed, 1 deferred.
# Retry for a pending record with docker_pending=true (the worktree step was
# finished or skipped on an earlier pass). Runs only _teardown_docker.
#   docker reachable   -> teardown_completed event, pending record cleared
#   still unreachable  -> stays parked, with NO new event (the first park
#                         already reported it; a daemon retrying hourly for
#                         days must not write thousands of identical events)
#   docker skipped     -> (disabled / no docker CLI) nothing left to do: completed
_teardown_execute_docker_only() {
    local facts="$1" dry_run="${2:-0}"
    local id; id=$(_facts_get "$facts" '.id')
    if [ "$dry_run" -eq 1 ]; then
        echo "[dry-run] would retry docker teardown for $id (worktree already removed)"
        _teardown_docker "$facts" 1 >/dev/null 2>&1
        TEARDOWN_LAST_STATUS="torn_down"; TEARDOWN_LAST_REASON="docker_pending_drained"
        return 1
    fi

    # A retry/escalation re-uses the job id (and so the compose project): if
    # the job is live again, its containers are not ours to remove. Wait until
    # it is terminal again. (Quiet, like any other docker-pending re-park.)
    local live_state=""
    [ -f "$JOBS_DIR/$id.json" ] && live_state=$(jq -r '.state // ""' "$JOBS_DIR/$id.json" 2>/dev/null)
    case "$live_state" in
        ''|succeeded|failed|cancelled) ;;
        *)
            _teardown_park "$facts" "deferred" "job_active" "teardown_deferred" '{}' "" 0
            return 1
            ;;
    esac

    local docker_summary docker_status
    docker_summary=$(_teardown_docker "$facts" 0)
    docker_status=$?
    if [ "$docker_status" -eq 2 ]; then
        local reason="docker_unreachable"
        [ "$(_facts_get "$facts" '.worktree_removed // false')" = "true" ] \
            && reason="docker_unreachable_worktree_done"
        _teardown_park "$facts" "deferred" "$reason" "teardown_deferred" '{}' "" 0
        return 1
    fi

    local project work_dir wr containers volumes networks
    project=$(mother_compose_project "$id")
    work_dir=$(_facts_get "$facts" '.work_dir // ""')
    wr=$(_facts_get "$facts" '.worktree_removed // false')
    read -r containers volumes networks <<< "$(_teardown_docker_counts "${docker_summary:-}")"
    TEARDOWN_LAST_STATUS="torn_down"; TEARDOWN_LAST_REASON="docker_pending_drained"
    _teardown_event "$facts" "teardown_completed" \
        "$(jq -nc --arg wp "$work_dir" --argjson wr "$wr" \
            --arg cp "$project" --argjson c "${containers:-0}" --argjson v "${volumes:-0}" --argjson n "${networks:-0}" \
            '{worktree_path: $wp, worktree_removed: $wr, docker_completed: true,
              compose_project: $cp, containers: $c, volumes: $v, networks: $n}')"
    _teardown_clear_pending "$id"
    return 0
}

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

    # The worktree was already removed on an earlier pass and only the Docker
    # part is outstanding: retry just that. No gate / race / unsafe probe —
    # nothing in the worktree is at risk any more and the compose project is
    # job-scoped, so a branch reused by another job cannot be affected.
    if [ "$(_facts_get "$facts" '.docker_pending // false')" = "true" ]; then
        _teardown_execute_docker_only "$facts" "$dry_run"
        return $?
    fi

    local gate reason gate_url=""
    gate=$(_teardown_gate "$facts")
    # Healthy-wait verdicts carry the open PR's URL after a TAB (see the gate).
    case "$gate" in *$'\t'*) gate_url="${gate#*$'\t'}"; gate="${gate%%$'\t'*}" ;; esac
    reason="${gate#*:}"

    if [ "${gate%%:*}" = "defer" ]; then
        if [ "$dry_run" -eq 1 ]; then
            TEARDOWN_LAST_STATUS="deferred"; TEARDOWN_LAST_REASON="$reason"
            echo "[dry-run] would defer teardown for $id ($reason)"
            return 1
        fi
        local gate_detail
        gate_detail=$(jq -nc --arg r "$reason" --arg pr "${gate_url:-$pr_url}" '{reason: $r, pr_url: $pr}')
        if _teardown_is_healthy_wait "$reason"; then
            # Quiet no-op re-check: event only on the first pass of the wait
            # (_teardown_park's status/pending-record bookkeeping still runs
            # every pass; only the event emission is suppressed on repeats).
            local healthy_emit=1
            _teardown_healthy_wait_is_new "$id" "$reason" "$gate_url" || healthy_emit=0
            _teardown_park "$facts" "deferred" "$reason" "teardown_deferred" "$gate_detail" \
                "$gate_url" "$healthy_emit"
            return 1
        fi
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

    # Unrecovered-work guard: a terminal job's worktree may hold uncommitted
    # changes or commits that exist on no remote — tearing it down would
    # destroy work nobody can get back (see
    # .claude/bugs/*/2026-06-13-merged-job-worktrees-never-gc-d-target-dirs-exhaust-disk.md,
    # "MUST NOT remove a worktree that is ahead-of-base or has uncommitted
    # changes"). Skipped when the gate reason is pr_merged (content
    # demonstrably reached upstream already) or when the operator has
    # explicitly opted out via MOTHER_TEARDOWN_ALLOW_UNSAFE=1, and scoped to
    # isolation=worktree only — a main-dir job has no separate worktree to
    # protect and no .work_dir field at all, so it always hits
    # _teardown_worktree's own main_dir skip untouched.
    local isolation; isolation=$(_facts_get "$facts" '.isolation // ""')
    if [ "$isolation" = "worktree" ] \
        && [ "$reason" != "pr_merged" ] \
        && [ "${MOTHER_TEARDOWN_ALLOW_UNSAFE:-0}" != "1" ]; then
        local unsafe_detail unsafe_status
        unsafe_detail=$(_teardown_worktree_unsafe "$facts")
        unsafe_status=$?
        if [ "$unsafe_status" -ne 0 ]; then
            local probe_reason probe_detail
            if [ "$unsafe_status" -eq 1 ]; then
                probe_reason="unsafe_worktree"
                probe_detail="$unsafe_detail"
            else
                probe_reason="worktree_probe_failed"
                probe_detail='{}'
            fi
            if [ "$dry_run" -eq 1 ]; then
                TEARDOWN_LAST_STATUS="deferred"; TEARDOWN_LAST_REASON="$probe_reason"
                echo "[dry-run] would defer teardown for $id ($probe_reason)"
                return 1
            fi
            _teardown_park "$facts" "deferred" "$probe_reason" "teardown_deferred" "$probe_detail"
            return 1
        fi
    fi

    if [ "$dry_run" -eq 1 ]; then
        echo "[dry-run] gate passed ($reason) for $id; would tear down docker + worktree"
        _teardown_docker "$facts" 1 >/dev/null 2>&1
        _teardown_worktree "$facts" 1 >/dev/null 2>&1
        _teardown_remove_job_tmp "$facts" 1
        TEARDOWN_LAST_STATUS="torn_down"; TEARDOWN_LAST_REASON="$reason"
        return 1
    fi

    _teardown_event "$facts" "teardown_started" \
        "$(jq -nc --arg r "$reason" --arg pr "$pr_url" '{gate_reason: $r, pr_url: $pr}')"

    # Docker first (a compose file it needs may live in the worktree), but an
    # unreachable daemon no longer holds the worktree hostage: worktree removal
    # does not need Docker, and a wedged Docker is exactly when disk is scarce.
    local docker_summary docker_status
    docker_summary=$(_teardown_docker "$facts" 0)
    docker_status=$?

    TEARDOWN_WORKTREE_SKIP_REASON=""
    TEARDOWN_RESIDUE_PATH=""; TEARDOWN_RESIDUE_SUB=""
    local wt_status
    _teardown_worktree "$facts" 0
    wt_status=$?

    if [ "$wt_status" -eq 2 ]; then
        _teardown_park "$facts" "failed" "worktree_error" "teardown_failed" '{"stage":"worktree"}'
        return 1
    fi

    _teardown_note_residue "$facts"
    _teardown_remove_job_tmp "$facts" 0

    if [ "$docker_status" -eq 2 ]; then
        # Docker unreachable: park so that only the Docker part is retried.
        local wt_removed=false park_reason="docker_unreachable"
        if [ "$wt_status" -eq 0 ]; then
            wt_removed=true; park_reason="docker_unreachable_worktree_done"
        fi
        local work_dir_p; work_dir_p=$(_facts_get "$facts" '.work_dir // ""')
        local pending_facts
        pending_facts=$(printf '%s' "$facts" | jq -c --argjson wr "$wt_removed" \
            '. + {docker_pending: true, worktree_removed: $wr}')
        _teardown_park "$pending_facts" "deferred" "$park_reason" "teardown_deferred" \
            "$(jq -nc --arg r "$park_reason" --argjson wr "$wt_removed" --arg wp "$work_dir_p" \
                '{reason: $r, worktree_removed: $wr, docker_pending: true, worktree_path: $wp}')"
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
    read -r containers volumes networks <<< "$(_teardown_docker_counts "${docker_summary:-}")"

    TEARDOWN_LAST_STATUS="torn_down"; TEARDOWN_LAST_REASON="$reason"
    _teardown_event "$facts" "teardown_completed" \
        "$(jq -nc --arg wp "$work_dir" --argjson wr true \
            --arg cp "$project" --argjson c "${containers:-0}" --argjson v "${volumes:-0}" --argjson n "${networks:-0}" \
            '{worktree_path: $wp, worktree_removed: $wr, compose_project: $cp, containers: $c, volumes: $v, networks: $n}')"
    _teardown_clear_pending "$id"
    return 0
}

# _teardown_attempt <facts_json> <dry_run> -> same return code as
# _teardown_execute. The ONLY way callers should invoke teardown: it runs the
# orchestrator and then mirrors the outcome onto the job's live record, so one
# _teardown_execute always produces exactly one recorded outcome no matter which
# path (drain, teardown-only, archive) drove it. Dry runs record nothing.
#
# Like _teardown_execute, must be called bare — never in a command
# substitution — because the outcome travels through the TEARDOWN_LAST_*
# globals.
_teardown_attempt() {
    local facts="$1" dry_run="${2:-0}"
    local rc=0
    _teardown_execute "$facts" "$dry_run" || rc=$?
    if [ "$dry_run" -ne 1 ]; then
        local id; id=$(_facts_get "$facts" '.id // empty')
        _teardown_record_fields "$id" "${TEARDOWN_LAST_STATUS:-unknown}" \
            "${TEARDOWN_LAST_REASON:-}"
    fi
    return "$rc"
}

# _teardown_drain <dry_run> — sweep $TEARDOWN_DIR, re-running teardown (via
# _teardown_attempt, so a live job's teardown_* fields stay current too) on
# each stored facts blob. Removes the record on success (handled by
# _teardown_execute itself via _teardown_clear_pending). Echoes a one-line
# summary for callers to fold into their own output.
_teardown_drain() {
    local dry_run="${1:-0}"
    local completed=0 deferred=0
    local f facts drain_id
    # Side-channel out-param: space-delimited ids attempted this pass, so
    # cmd_archive's bulk loop can skip jobs the drain just handled. Without it
    # a job with a pending record gets TWO teardown attempts per sweep,
    # doubling the deferral accrual rate the attention cap is calibrated
    # against (and doubling `gh pr view` calls).
    TEARDOWN_DRAIN_IDS=""
    for f in "$TEARDOWN_DIR"/*.json; do
        [ -f "$f" ] || continue
        facts=$(jq -c '.' "$f" 2>/dev/null) || continue
        drain_id=$(_facts_get "$facts" '.id // empty')
        [ -n "$drain_id" ] && TEARDOWN_DRAIN_IDS="$TEARDOWN_DRAIN_IDS $drain_id"
        if _teardown_attempt "$facts" "$dry_run"; then
            completed=$((completed + 1))
        else
            deferred=$((deferred + 1))
        fi
    done
    echo "teardowns: $completed completed, $deferred deferred"
}
