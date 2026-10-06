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
        elif rm -rf "$dir" 2>/dev/null; then
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
    local f n=0
    for f in "$JOBS_DIR"/*.json; do
        [ -f "$f" ] || continue
        # Fail closed: an unreadable record counts as running.
        local st act
        st=$(jq -r '.state // ""' "$f" 2>/dev/null) || st="running"
        act=$(jq -r '.activity // ""' "$f" 2>/dev/null) || act=""
        if [ "$st" = "running" ] || [ "$act" = "pipeline_review" ]; then
            n=$((n + 1))
        fi
    done
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

# _gc_cargo_targets — informational only; nothing here is ever removed.
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
        elif rm -rf "$d" 2>/dev/null; then
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
    _gc_derived_data "$dry_run"
    _gc_gocache "$dry_run"
    _gc_job_tmp "$dry_run"
    _gc_residue_records "$dry_run"
    _gc_cargo_targets
    return 0
}
