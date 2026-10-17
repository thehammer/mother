# gc.sh — `mother gc`: the disk hygiene sweep.
#
# Sourced by bin/mother. Does not set shell options; inherits `set -u` and
# bash 3.2 compatibility from the caller (no `declare -A`, no `mapfile`).
#
# Removes only things Mother can prove are garbage and that are not covered by
# worktree teardown:
#   * Xcode DerivedData folders whose recorded WorkspacePath no longer exists
#     (each checkout path gets its own folder; nothing else ever removes it)
#   * the Go build cache, via `go clean -cache`, when it exceeds a cap and no
#     Mother job is running
#   * Mother's own job-scoped worker temp dirs ($MOTHER_ROOT/tmp/<job-id>) for
#     jobs whose record is no longer live
#   * teardown-residue records whose directory has since been removed
#   * the `target/` of a Mother job worktree (Cargo project) once no live job
#     uses it — see _gc_cargo_job_targets for the fail-closed guards
# and REPORTS (never touches) oversized `target/` dirs in main Cargo checkouts.
#
# Every destructive step honours --dry-run. Every step is best-effort: a
# failure is printed and the sweep carries on, so `mother gc` always exits 0.
# Never uses sudo; never touches /private/tmp.
#
# Test/operator seams (all optional):
#   MOTHER_GC_DERIVED_DATA_DIR   default ~/Library/Developer/Xcode/DerivedData
#   MOTHER_GO_BIN                if SET (even empty) the only go binary considered
#   MOTHER_GOCACHE_MAX_GB        default 10
#   MOTHER_GC_CODE_DIR           default ~/Code (scanned for */target next to Cargo.toml)
#   MOTHER_GC_TARGET_REPORT_GB   default 10
#   MOTHER_CARGO_TARGET_PURGE    default 1; 0/false/no/off (any case) or an unrecognised value = only report
#   MOTHER_CARGO_TARGET_IDLE_MINUTES  default 10; a target/ touched more recently is kept
#   MOTHER_CARGO_TARGET_PURGE_EXCLUDE job `repo` names (space/comma separated) never purged

# Every recursive delete here goes through safe_rm_tree (lib/safe-rm.sh), which
# refuses a directory that is or contains the live-tree marker.
# shellcheck source=/dev/null
type safe_rm_tree >/dev/null 2>&1 || source "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/safe-rm.sh"

# _gc_dir_kb <dir> — size in KB (0 when it can't be measured).
_gc_dir_kb() {
    local kb
    kb=$(du -sk "$1" 2>/dev/null | awk '{print $1}')
    case "${kb:-}" in ''|*[!0-9]*) kb=0 ;; esac
    echo "$kb"
}

# _gc_human_kb <kb> — "812 MB" / "14.2 GB".
_gc_human_kb() {
    awk -v kb="$1" 'BEGIN {
        if (kb >= 1048576)      printf "%.1f GB", kb / 1048576;
        else if (kb >= 1024)    printf "%.0f MB", kb / 1024;
        else                    printf "%d KB", kb;
    }'
}

# _gc_plist_workspace <info.plist> — echoes WorkspacePath ("" when unreadable).
_gc_plist_workspace() {
    local plist="$1" out=""
    if [ -x /usr/libexec/PlistBuddy ]; then
        out=$(/usr/libexec/PlistBuddy -c 'Print :WorkspacePath' "$plist" 2>/dev/null) || out=""
    fi
    if [ -z "$out" ] && command -v plutil >/dev/null 2>&1; then
        out=$(plutil -extract WorkspacePath raw -o - "$plist" 2>/dev/null) || out=""
    fi
    printf '%s' "$out"
}

# _gc_derived_data <dry_run>
_gc_derived_data() {
    local dry_run="$1"
    local base="${MOTHER_GC_DERIVED_DATA_DIR:-${HOME:-}/Library/Developer/Xcode/DerivedData}"
    [ -d "$base" ] || { echo "DerivedData: none ($base not found)"; return 0; }

    local plist dir name ws kb removed=0 total_kb=0
    for plist in "$base"/*/info.plist; do
        [ -f "$plist" ] || continue
        dir="${plist%/info.plist}"
        name="${dir##*/}"
        case "$name" in ModuleCache.noindex|'') continue ;; esac
        [ -L "$dir" ] && continue
        ws=$(_gc_plist_workspace "$plist")
        [ -n "$ws" ] || continue            # unreadable plist: never guess
        [ -e "$ws" ] && continue            # workspace still exists: keep
        # Absence we cannot trust: an unmounted external volume, or a
        # TCC-protected folder the daemon may not be allowed to look inside.
        case "$ws" in
            /Volumes/*)
                local vol="${ws#/Volumes/}"; vol="/Volumes/${vol%%/*}"
                [ -d "$vol" ] || continue ;;
            "${HOME:-/nonexistent}"/Documents/*|"${HOME:-/nonexistent}"/Desktop/*|"${HOME:-/nonexistent}"/Downloads/*| \
            "${HOME:-/nonexistent}"/Pictures/*|"${HOME:-/nonexistent}"/Movies/*|"${HOME:-/nonexistent}"/Music/*)
                continue ;;
        esac
        kb=$(_gc_dir_kb "$dir")
        if [ "$dry_run" -eq 1 ]; then
            echo "[dry-run] would remove DerivedData/$name ($(_gc_human_kb "$kb")) — workspace gone: $ws"
        elif safe_rm_tree "$dir"; then
            echo "removed DerivedData/$name ($(_gc_human_kb "$kb")) — workspace gone: $ws"
        else
            echo "DerivedData/$name: could not remove (left in place)"
            continue
        fi
        removed=$((removed + 1)); total_kb=$((total_kb + kb))
    done
    if [ "$removed" -eq 0 ]; then
        echo "DerivedData: nothing orphaned"
    elif [ "$dry_run" -eq 1 ]; then
        echo "DerivedData: would remove $removed folder(s), $(_gc_human_kb "$total_kb")"
    else
        echo "DerivedData: removed $removed folder(s), $(_gc_human_kb "$total_kb")"
    fi
}

# _gc_find_go — echoes a usable go binary, or nothing. The user's `go` is
# commonly an asdf shim that errors without a matching .tool-versions entry, so
# a PATH `go` is only accepted when `go env GOCACHE` actually works; otherwise
# fall back to an explicitly installed version.
_gc_find_go() {
    if [ "${MOTHER_GO_BIN+set}" = "set" ]; then
        [ -n "$MOTHER_GO_BIN" ] && [ -x "$MOTHER_GO_BIN" ] && echo "$MOTHER_GO_BIN"
        return 0
    fi
    local cand
    cand=$(command -v go 2>/dev/null) || cand=""
    if [ -n "$cand" ] && "$cand" env GOCACHE >/dev/null 2>&1; then
        echo "$cand"; return 0
    fi
    local asdf="${ASDF_DATA_DIR:-${HOME:-}/.asdf}/installs/golang"
    if [ -d "$asdf" ]; then
        cand=$(ls -1 "$asdf" 2>/dev/null | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
        if [ -n "$cand" ] && [ -x "$asdf/$cand/go/bin/go" ]; then
            echo "$asdf/$cand/go/bin/go"; return 0
        fi
    fi
    for cand in /opt/homebrew/bin/go /usr/local/go/bin/go /usr/local/bin/go; do
        if [ -x "$cand" ] && "$cand" env GOCACHE >/dev/null 2>&1; then
            echo "$cand"; return 0
        fi
    done
    return 0
}

# _gc_running_jobs — number of jobs currently running (state `running`, or a
# pipeline job in `pipeline_review`).
_gc_running_jobs() {
    _gc_ensure_jobs
    # Fail closed: an unreadable record counts as running.
    [ "$_GC_JOBS_OK" -eq 1 ] || { echo 1; return 0; }
    local line n=0 id st act rest
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS="$_GC_US" read -r id st act rest <<< "$line"
        if [ "$st" = "running" ] || [ "$act" = "pipeline_review" ]; then
            n=$((n + 1))
        fi
    done <<< "$_GC_JOBS"
    echo "$n"
}

# _gc_gocache <dry_run>
_gc_gocache() {
    local dry_run="$1"
    local go_bin cache max_gb max_kb kb
    go_bin=$(_gc_find_go)
    if [ -z "$go_bin" ]; then
        echo "go cache: skipped — go not available (no usable go binary; asdf shim without a version set?)"
        return 0
    fi
    cache=$("$go_bin" env GOCACHE 2>/dev/null) || cache=""
    if [ -z "$cache" ] || [ "$cache" = "off" ]; then
        echo "go cache: skipped — \`go env GOCACHE\` gave no usable path"
        return 0
    fi
    [ -d "$cache" ] || { echo "go cache: none ($cache not found)"; return 0; }

    max_gb="${MOTHER_GOCACHE_MAX_GB:-10}"
    case "$max_gb" in ''|*[!0-9]*) max_gb=10 ;; esac
    max_kb=$((max_gb * 1024 * 1024))
    kb=$(_gc_dir_kb "$cache")
    if [ "$kb" -le "$max_kb" ]; then
        echo "go cache: $(_gc_human_kb "$kb") at $cache — under the ${max_gb} GB cap"
        return 0
    fi

    local running; running=$(_gc_running_jobs)
    if [ "$running" -gt 0 ]; then
        echo "go cache: $(_gc_human_kb "$kb") is over the ${max_gb} GB cap but skipped — $running job(s) running"
        return 0
    fi
    if [ "$dry_run" -eq 1 ]; then
        echo "[dry-run] would run go clean -cache ($(_gc_human_kb "$kb") at $cache, cap ${max_gb} GB)"
        return 0
    fi
    if "$go_bin" clean -cache >/dev/null 2>&1; then
        echo "go cache: ran go clean -cache (freed ~$(_gc_human_kb "$kb") at $cache)"
    else
        echo "go cache: go clean -cache failed — left as is"
    fi
}

# _gc_canon <dir> — physical path, or nothing when it can't be resolved.
_gc_canon() {
    ( cd "$1" 2>/dev/null && pwd -P )
}

# Job-record cache. `jq`-per-file and a subshell per comparison made every gc
# pass quadratic in the job count, so the job list is read once per pass
# (_gc_load_jobs, a single jq over every record) into _GC_JOBS: one record per
# line, fields separated by US (\x1f, which can't appear in a path we accept):
#   id st act adh iso repo repo_path branch work_dir canon_work_dir derived_path
# canon_work_dir is the physical work_dir ("" when it can't be resolved);
# derived_path is where a not-yet-placed job's worktree will be created.
# _GC_JOBS_OK=0 means some record was unreadable: callers fail closed.
_GC_US=$'\x1f'
_GC_JOBS=""
_GC_JOBS_OK=1
_GC_JOBS_LOADED=0

# _gc_job_may_use_cache <state> <activity> <adherence_pending> — 0 unless the job
# is finished for good (succeeded|failed|cancelled, no adherence review pending,
# not in pipeline review).
_gc_job_may_use_cache() {
    case "$1" in succeeded|failed|cancelled) ;; *) return 0 ;; esac
    [ "$2" = "pipeline_review" ] && return 0
    [ "$3" = "true" ]
}

# _gc_derived_worktree <repo_path> <branch> — the path mother-run-job will give
# this job's worktree, or nothing when it can't be derived (the caller then
# treats every worktree of that repo name as in use: fail closed).
# Derived by the very function the runner uses (worktree_path_for_repo, from
# inside repo_path), never re-implemented, so the two cannot drift. Also
# nothing unless repo_path is itself the top level of its git repo: a symlink,
# subdirectory or other non-root repo_path is not something we dare predict.
_gc_derived_worktree() {
    local rp="$1" br="$2" out rpc top parent
    [ -n "$rp" ] && [ -n "$br" ] || return 0
    rpc=$(_gc_canon "$rp") || rpc=""
    [ -n "$rpc" ] || return 0
    top=$(cd "$rp" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || top=""
    [ -n "$top" ] || return 0
    top=$(_gc_canon "$top") || top=""
    [ "$top" = "$rpc" ] || return 0
    # shellcheck disable=SC1091
    out=$( ( type worktree_path_for_repo >/dev/null 2>&1 || source "${MOTHER_LIB_DIR:-}/worktree.sh" >/dev/null 2>&1
             worktree_path_for_repo "$rp" "$br" ) 2>/dev/null ) || out=""
    [ -n "$out" ] || return 0
    # Physical form of the parent so a symlinked checkout location compares equal.
    parent=$(_gc_canon "${out%/*}") || parent=""
    if [ -n "$parent" ]; then printf '%s/%s' "$parent" "${out##*/}"; else printf '%s' "$out"; fi
}

# _gc_is_linked_worktree <work_dir> — 0 only when <work_dir>/.git is a regular
# file (not a symlink) whose first line is `gitdir: <path>`, where <path> (made
# absolute against work_dir when relative) is an existing directory named
# <something>/worktrees/<name>. An empty or garbage file, a submodule-style
# pointer (.git/modules/x) or a pointer to a missing directory all fail.
_gc_is_linked_worktree() {
    local g="$1/.git" line p
    [ -f "$g" ] && [ ! -L "$g" ] || return 1
    line=$(head -n 1 "$g" 2>/dev/null) || return 1
    case "$line" in "gitdir: "?*) p="${line#gitdir: }" ;; *) return 1 ;; esac
    case "$p" in /*) ;; *) p="$1/$p" ;; esac
    while [ "${p%/}" != "$p" ]; do p="${p%/}"; done
    [ -d "$p" ] || return 1
    [ "$(basename "$(dirname "$p")")" = "worktrees" ]
}

# _gc_load_jobs — (re)read every job record into the cache.
_gc_load_jobs() {
    local raw f n=0 line id st act adh iso repo rp br wd canon derived out=""
    _GC_JOBS=""; _GC_JOBS_OK=1; _GC_JOBS_LOADED=1
    for f in "$JOBS_DIR"/*.json; do [ -f "$f" ] && n=$((n + 1)); done
    [ "$n" -gt 0 ] || return 0
    # Fail closed on anything we can't trust: a jq failure, a record jq can't
    # evaluate (non-object JSON), a field holding a newline/US or a non-string,
    # and a record that yields no line at all (a zero-byte file; jq exits 0 on
    # it, and on a mid-list evaluation error it only reports the last file).
    raw=$(jq -r '
        try (
          [.id // "", .state // "", .activity // "", ((.adherence_pending // false) | tostring),
           .isolation // "", .repo // "", .repo_path // "", .branch // "", .work_dir // ""] as $f
          | if ($f | map(type != "string" or test("[\n\u001f]")) | any) then "UNREADABLE"
            else $f | join("\u001f") end
        ) catch "UNREADABLE"' "$JOBS_DIR"/*.json 2>/dev/null) || { _GC_JOBS_OK=0; return 0; }
    [ "$(printf '%s\n' "$raw" | grep -c .)" -eq "$n" ] || { _GC_JOBS_OK=0; return 0; }
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        if [ "$line" = "UNREADABLE" ]; then _GC_JOBS_OK=0; return 0; fi
        IFS="$_GC_US" read -r id st act adh iso repo rp br wd <<< "$line"
        canon=""; derived=""
        [ -z "$wd" ] || canon=$(_gc_canon "$wd") || canon=""
        if [ -z "$wd" ] && [ "$iso" != "main-dir" ] && _gc_job_may_use_cache "$st" "$act" "$adh"; then
            derived=$(_gc_derived_worktree "$rp" "$br")
        fi
        out="${out}${id}${_GC_US}${st}${_GC_US}${act}${_GC_US}${adh}${_GC_US}${iso}${_GC_US}${repo}${_GC_US}${rp}${_GC_US}${br}${_GC_US}${wd}${_GC_US}${canon}${_GC_US}${derived}
"
    done <<< "$raw"
    _GC_JOBS="$out"
}

_gc_ensure_jobs() { [ "$_GC_JOBS_LOADED" -eq 1 ] || _gc_load_jobs; }

# _gc_worktree_rows — one "canon|id|repo|work_dir" row per job that runs in its
# own git worktree (isolation=worktree, work_dir set and not the main checkout).
_gc_worktree_rows() {
    _gc_ensure_jobs
    local line id st act adh iso repo rp br wd canon der rpc
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS="$_GC_US" read -r id st act adh iso repo rp br wd canon der <<< "$line"
        [ "$iso" = "worktree" ] && [ -n "$wd" ] || continue
        [ -d "$wd" ] && [ -n "$canon" ] || continue
        if [ -n "$rp" ]; then
            rpc=$(_gc_canon "$rp") || rpc=""
            { [ "$wd" = "$rp" ] || { [ -n "$rpc" ] && [ "$rpc" = "$canon" ]; }; } && continue
        fi
        printf '%s|%s|%s|%s\n' "$canon" "$id" "$repo" "$wd"
    done <<< "$_GC_JOBS"
}

# _gc_worktree_in_use <work_dir> <repo> — 0 when any job could still use this
# worktree's build cache. Fails closed: only records that are all
# succeeded|failed|cancelled, not adherence-pending and not in pipeline review
# make it idle. Also in use: any unreadable record; and any non-terminal
# worktree job with no work_dir yet (queued, or dispatched but the worker has
# not recorded one) whose derived worktree path is this one — or, when that
# path can't be derived, any such job of the same repo. A job in another repo
# never blocks this one.
_gc_worktree_in_use() {
    local want="$1" want_repo="${2:-}" wcanon
    _gc_ensure_jobs
    [ "$_GC_JOBS_OK" -eq 1 ] || return 0
    wcanon=$(_gc_canon "$want") || wcanon=""
    local line id st act adh iso repo rp br wd canon der
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        IFS="$_GC_US" read -r id st act adh iso repo rp br wd canon der <<< "$line"
        if [ -n "$wd" ]; then
            [ "$wd" = "$want" ] || { [ -n "$canon" ] && [ -n "$wcanon" ] && [ "$canon" = "$wcanon" ]; } || continue
        else
            # No work_dir recorded.
            _gc_job_may_use_cache "$st" "$act" "$adh" || continue
            [ "$iso" = "main-dir" ] && continue
            if [ -n "$der" ]; then
                [ "$der" = "$want" ] || { [ -n "$wcanon" ] && [ "$der" = "$wcanon" ]; } || continue
            else
                # Can't tell which worktree it will use: block the whole repo
                # (by name; an unnamed repo on either side blocks everything).
                [ -z "$repo" ] || [ -z "$want_repo" ] || [ "$repo" = "$want_repo" ] || continue
            fi
            return 0
        fi
        _gc_job_may_use_cache "$st" "$act" "$adh" && return 0
    done <<< "$_GC_JOBS"
    return 1
}

# _gc_is_job_worktree <dir> — 0 when <dir> is the worktree of a Mother job.
_gc_is_job_worktree() {
    local canon row
    canon=$(_gc_canon "$1") || return 1
    while IFS= read -r row; do
        [ "${row%%|*}" = "$canon" ] && return 0
    done <<< "$(_gc_worktree_rows)"
    return 1
}

# _gc_purge_mode — echoes "on", "off" or "invalid" for MOTHER_CARGO_TARGET_PURGE.
# Unset or empty means on; 1/true/yes/on enable; 0/false/no/off disable (any
# case); anything else is unrecognised ("invalid": the caller treats it as off).
_gc_purge_mode() {
    local v
    v=$(printf '%s' "${MOTHER_CARGO_TARGET_PURGE:-1}" | tr '[:upper:]' '[:lower:]')
    case "$v" in
        1|true|yes|on) echo on ;;
        0|false|no|off) echo off ;;
        *) echo invalid ;;
    esac
}

# _gc_mtime <path> — mtime in epoch seconds of the path itself (BSD, then GNU
# stat); nothing when it can't be read.
_gc_mtime() {
    local m
    m=$(stat -f %m "$1" 2>/dev/null) || m=$(stat -c %Y "$1" 2>/dev/null) || m=""
    case "$m" in ''|*[!0-9]*) return 0 ;; esac
    echo "$m"
}

# _gc_keep_reason <busy> <target> <repo> <purge> <idle_min> <exclude> — echoes
# why this target/ must be kept, or nothing when it is safe to remove. Checked
# in order: in use, purge disabled, repo excluded, recently touched.
_gc_keep_reason() {
    local busy="$1" t="$2" repo="$3" purge="$4" idle_min="$5" exclude="$6" recent=""
    if [ "$busy" -eq 1 ]; then
        echo "job still active or awaiting review"
    elif [ "$purge" != "on" ]; then
        echo "MOTHER_CARGO_TARGET_PURGE is off"
    elif case "$exclude" in *" $repo "*) true ;; *) false ;; esac; then
        echo "repo $repo is excluded"
    else
        # Fail closed: a find error counts as recent activity. (`-mmin -0`
        # is not "never" on BSD find, so 0 skips the guard explicitly.) The
        # whole tree is searched — a long single-crate compile writes deep —
        # but the search stops at the first hit.
        if [ "$idle_min" -gt 0 ]; then
            recent=$(find "$t" -mmin -"$idle_min" -print -quit 2>/dev/null) || recent="unreadable"
        fi
        [ -z "$recent" ] || echo "touched in the last ${idle_min} min (or unreadable)"
    fi
}

# _gc_cargo_job_targets <dry_run> — reclaim the target/ of Cargo job worktrees
# nobody is using, and write the inventory cache ($RUNNER_DIR/cargo-targets.json,
# read by `mother status` and the low-disk message). Only ever removes
# <worktree>/target, and only when every guard below holds:
#   * Cargo.toml beside it; the worktree is a LINKED worktree (its .git is a
#     `gitdir: <dir>/worktrees/<name>` file naming an existing directory, never
#     a directory: a main checkout is never touched); target is a
#     real directory (not a symlink) holding cargo's CACHEDIR.TAG; its physical
#     path is <physical worktree>/target
#   * repo not in MOTHER_CARGO_TARGET_PURGE_EXCLUDE; purge not disabled
#   * no job on that worktree is queued/ready/running/awaiting, adherence-pending
#     or in pipeline review, and no unplaced (no work_dir yet) job could land
#     there (_gc_worktree_in_use)
#   * nothing anywhere in it modified within MOTHER_CARGO_TARGET_IDLE_MINUTES
# Immediately before the rm the job list is re-read and the in-use and activity
# checks repeated, and the dir's mtime must be unchanged (second look).
_gc_cargo_job_targets() {
    local dry_run="$1"
    local purge; purge=$(_gc_purge_mode)
    if [ "$purge" = "invalid" ]; then
        echo "cargo targets: unrecognised MOTHER_CARGO_TARGET_PURGE='${MOTHER_CARGO_TARGET_PURGE:-}' — treating as disabled (use 1/true/yes/on or 0/false/no/off)"
        purge=off
    fi
    local idle_min="${MOTHER_CARGO_TARGET_IDLE_MINUTES:-10}"
    case "$idle_min" in ''|*[!0-9]*) idle_min=10 ;; esac
    local exclude
    exclude=" $(printf '%s' "${MOTHER_CARGO_TARGET_PURGE_EXCLUDE:-}" | tr ',' ' ') "

    local rows canon_list canon first work_dir repo ids t kb reason busy mtime1 mtime2
    local seen=0 reclaimed=0 would=0 reclaimed_kb=0 entries=""
    _gc_load_jobs
    rows=$(_gc_worktree_rows)
    canon_list=$(printf '%s\n' "$rows" | cut -d'|' -f1 | sort -u)
    while IFS= read -r canon; do
        [ -n "$canon" ] || continue
        first=$(printf '%s\n' "$rows" | awk -F'|' -v c="$canon" '$1 == c { print; exit }')
        work_dir="${first#*|*|*|}"
        repo=$(printf '%s' "$first" | cut -d'|' -f3)
        ids=$(printf '%s\n' "$rows" | awk -F'|' -v c="$canon" '$1 == c { print $2 }' | tr '\n' ',' | sed 's/,$//')
        t="$work_dir/target"

        [ -f "$work_dir/Cargo.toml" ] || continue
        _gc_is_linked_worktree "$work_dir" || continue
        [ -d "$t" ] && [ ! -L "$t" ] && [ -f "$t/CACHEDIR.TAG" ] || continue
        [ "$(_gc_canon "$t")" = "$canon/target" ] || continue

        seen=$((seen + 1))
        kb=$(_gc_dir_kb "$t")
        busy=0
        if _gc_worktree_in_use "$work_dir" "$repo"; then busy=1; fi
        mtime1=$(_gc_mtime "$t")
        reason=$(_gc_keep_reason "$busy" "$t" "$repo" "$purge" "$idle_min" "$exclude")

        if [ -z "$reason" ] && [ "$dry_run" -eq 0 ]; then
            # Second look: a job may have been queued or dispatched since the
            # first one. Re-read the records and repeat the checks.
            _gc_load_jobs
            busy=0
            if _gc_worktree_in_use "$work_dir" "$repo"; then busy=1; fi
            mtime2=$(_gc_mtime "$t")
            reason=$(_gc_keep_reason "$busy" "$t" "$repo" "$purge" "$idle_min" "$exclude")
            if [ -z "$reason" ] && { [ -z "$mtime1" ] || [ "$mtime1" != "$mtime2" ]; }; then
                reason="changed while being examined"
            fi
        fi

        if [ -n "$reason" ]; then
            echo "cargo targets: kept $repo worktree target $t ($(_gc_human_kb "$kb")) — $reason"
        elif [ "$dry_run" -eq 1 ]; then
            echo "[dry-run] would remove $repo worktree target $t ($(_gc_human_kb "$kb"))"
            would=$((would + 1))
        elif safe_rm_tree "$t" && [ ! -e "$t" ]; then
            echo "removed $repo worktree target $t ($(_gc_human_kb "$kb")) — job(s) $ids finished"
            reclaimed=$((reclaimed + 1)); reclaimed_kb=$((reclaimed_kb + kb))
            continue
        else
            echo "$repo worktree target $t: could not remove (left in place)"
        fi
        entries="${entries}$(jq -nc --arg path "$t" --arg repo "$repo" --argjson kb "$kb" --argjson in_use "$([ "$busy" -eq 1 ] && echo true || echo false)" \
            '{path: $path, repo: $repo, kb: $kb, in_use: $in_use}')
"
    done <<< "$canon_list"

    # No Cargo job worktree at all (the usual case for non-Rust repos): no output.
    if [ "$dry_run" -eq 1 ] && [ "$would" -gt 0 ]; then
        echo "cargo targets: would reclaim $would dir(s)"
    elif [ "$seen" -eq 0 ]; then
        :
    elif [ "$reclaimed" -eq 0 ]; then
        echo "cargo targets: nothing idle"
    else
        echo "cargo targets: reclaimed $reclaimed dir(s), $(_gc_human_kb "$reclaimed_kb")"
    fi
    _gc_write_cargo_cache "$entries" "$reclaimed_kb"
}

# _gc_write_cargo_cache <entry-json-lines> <reclaimed_kb> — publish the
# inventory of job-worktree target/ dirs that still exist after the pass.
_gc_write_cargo_cache() {
    local entries="$1" reclaimed_kb="$2" out now json
    local dir="${RUNNER_DIR:-$MOTHER_ROOT/runner}"
    mkdir -p "$dir" 2>/dev/null || return 0
    now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    json=$(printf '%s' "$entries" | jq -cs --arg now "$now" --argjson rec "$reclaimed_kb" '
        {checked_at: $now, dirs: length,
         total_kb: (map(.kb) | add // 0),
         in_use_kb: (map(select(.in_use) | .kb) | add // 0),
         idle_kb: (map(select(.in_use | not) | .kb) | add // 0),
         reclaimed_kb: $rec, entries: .}' 2>/dev/null) || return 0
    out="$dir/cargo-targets.json"
    if type _atomic_write >/dev/null 2>&1; then
        _atomic_write "$out" "$json" 2>/dev/null || true
    else
        printf '%s' "$json" > "$out.tmp.$$" && mv "$out.tmp.$$" "$out" 2>/dev/null || true
    fi
    return 0
}

# _gc_cargo_targets — informational only; nothing here is ever removed.
# Job worktrees are skipped: _gc_cargo_job_targets owns those.
_gc_cargo_targets() {
    local code="${MOTHER_GC_CODE_DIR:-${HOME:-}/Code}"
    local report_gb="${MOTHER_GC_TARGET_REPORT_GB:-10}"
    case "$report_gb" in ''|*[!0-9]*) report_gb=10 ;; esac
    [ -d "$code" ] || return 0
    local t proj kb
    for t in "$code"/*/target; do
        [ -d "$t" ] || continue
        proj="${t%/target}"
        [ -f "$proj/Cargo.toml" ] || continue
        _gc_is_job_worktree "$proj" && continue
        kb=$(_gc_dir_kb "$t")
        if [ "$kb" -gt $((report_gb * 1024 * 1024)) ]; then
            echo "info: ${proj##*/}/target is $(_gc_human_kb "$kb") ($t) — main checkout, not touched; \`cargo clean\` there if you want it back"
        fi
    done
}

# _gc_job_tmp <dry_run> — $MOTHER_ROOT/tmp/<job-id> dirs of jobs with no live
# record (archived or gone). Only direct children of $MOTHER_ROOT/tmp.
_gc_job_tmp() {
    local dry_run="$1"
    local base="$MOTHER_ROOT/tmp"
    [ -d "$base" ] || return 0
    local d id kb removed=0 total_kb=0
    for d in "$base"/*; do
        [ -d "$d" ] && [ ! -L "$d" ] || continue
        id="${d##*/}"
        [ -f "$JOBS_DIR/$id.json" ] && continue
        kb=$(_gc_dir_kb "$d")
        if [ "$dry_run" -eq 1 ]; then
            echo "[dry-run] would remove job temp dir tmp/$id ($(_gc_human_kb "$kb"))"
        elif safe_rm_tree "$d"; then
            echo "removed job temp dir tmp/$id ($(_gc_human_kb "$kb"))"
        else
            echo "tmp/$id: could not remove (left in place)"
            continue
        fi
        removed=$((removed + 1)); total_kb=$((total_kb + kb))
    done
    [ "$removed" -eq 0 ] && echo "job temp: nothing to remove" || true
}

# _gc_residue_records <dry_run> — drop residue records whose directory is gone.
_gc_residue_records() {
    local dry_run="$1" f path
    for f in "$RESIDUE_DIR"/*.json; do
        [ -f "$f" ] || continue
        path=$(jq -r '.path // ""' "$f" 2>/dev/null)
        if [ -z "$path" ] || [ ! -e "$path" ]; then
            if [ "$dry_run" -eq 1 ]; then
                echo "[dry-run] would remove resolved residue record ${f##*/}"
            else
                rm -f "$f"
                echo "removed resolved residue record ${f##*/}"
            fi
        fi
    done
}

# mother_gc <dry_run> — the whole sweep.
mother_gc() {
    local dry_run="${1:-0}"
    _gc_load_jobs
    _gc_derived_data "$dry_run"
    _gc_gocache "$dry_run"
    _gc_job_tmp "$dry_run"
    _gc_residue_records "$dry_run"
    _gc_cargo_job_targets "$dry_run"
    _gc_cargo_targets
    return 0
}
