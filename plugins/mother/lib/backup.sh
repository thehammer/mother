# backup.sh — rotating backups of Mother's state tree, and restore.
#
# Sourced by bin/mother (CLI: `mother backup now|list|restore`); the runner
# calls `mother backup now` on a timer (_maybe_backup in bin/mother-runner).
# Does not set shell options; inherits `set -u` and bash 3.2 compatibility
# (no `declare -A`, no `mapfile`) from the caller.
#
# Why: on 2026-10-17 the whole of ~/.mother was deleted and nothing could bring
# it back. The tree is plain files, so a tarball every 15 minutes, kept
# OUTSIDE the tree, makes any single mistake recoverable.
#
# What is backed up (relative to $MOTHER_ROOT): jobs events archive drafts
# cursors metrics attention.json rate-limits.json config.env — and logs/ only
# when MOTHER_BACKUP_LOGS=1 (large). `metrics/` (runs.jsonl: the retro and
# ETA-calibration history) and `config.env` (durable operator settings) are
# small and irreplaceable, so they ride along even though they are not
# state-machine files.
#
# Knobs (all optional):
#   MOTHER_BACKUP_DIR         default: ~/Library/Application Support/Mother/backups
#                             (macOS), ${XDG_STATE_HOME:-~/.local/state}/mother/backups
#                             elsewhere. Never allowed inside $MOTHER_ROOT.
#   MOTHER_BACKUP_KEEP_HOURS  keep every backup newer than this (default 24)
#   MOTHER_BACKUP_KEEP_DAYS   then keep the newest backup of each UTC day for
#                             this many days (default 30); older is pruned
#   MOTHER_BACKUP_LOGS        1 = include logs/
#   MOTHER_BACKUP_NOW_EPOCH   test seam: the "current time" retention uses

# shellcheck source=/dev/null
type safe_rm_tree >/dev/null 2>&1 || source "${MOTHER_LIB_DIR:-$(dirname "${BASH_SOURCE[0]}")}/safe-rm.sh"

# Top-level entries a backup may contain; restore refuses anything else.
_BACKUP_ENTRIES="jobs events archive drafts cursors metrics logs attention.json rate-limits.json config.env"

mother_backup_dir() {
    if [ -n "${MOTHER_BACKUP_DIR:-}" ]; then
        printf '%s' "$MOTHER_BACKUP_DIR"
    elif [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
        printf '%s' "$HOME/Library/Application Support/Mother/backups"
    else
        printf '%s' "${XDG_STATE_HOME:-$HOME/.local/state}/mother/backups"
    fi
}

# _backup_abs <path> — absolute, symlink-resolved path even when the path (or
# some of its trailing components) doesn't exist yet.
_backup_abs() {
    local p="$1" tail="" base
    case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
    while [ ! -d "$p" ] && [ "$p" != "/" ]; do
        base="${p##*/}"; p="${p%/*}"; [ -n "$p" ] || p="/"
        tail="/$base$tail"
    done
    p=$(cd -P "$p" 2>/dev/null && pwd -P) || p="/"
    [ "$p" = "/" ] && p=""
    printf '%s%s' "$p" "$tail"
}

# mother_backup_check_dir <dir> — refuse a backup dir at or inside $MOTHER_ROOT
# (a backup that lives in the tree dies with the tree).
mother_backup_check_dir() {
    local dir root
    dir=$(_backup_abs "$1"); root=$(_backup_abs "$MOTHER_ROOT")
    case "$dir/" in
        "$root"/*)
            echo "backup dir $dir is inside MOTHER_ROOT ($root); refusing — set MOTHER_BACKUP_DIR to a location outside the state tree" >&2
            return 1 ;;
    esac
    return 0
}

# mother_backup_now — write one backup, prune, print the new file's path.
mother_backup_now() {
    local dir; dir=$(mother_backup_dir)
    mother_backup_check_dir "$dir" || return 1
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
    [ -d "$dir" ] || { echo "cannot create backup dir $dir" >&2; return 1; }

    local items=() e
    for e in $_BACKUP_ENTRIES; do
        [ "$e" = "logs" ] && [ "${MOTHER_BACKUP_LOGS:-0}" != "1" ] && continue
        [ -e "$MOTHER_ROOT/$e" ] && items+=("$e")
    done
    if [ "${#items[@]}" -eq 0 ]; then
        echo "nothing to back up under $MOTHER_ROOT" >&2
        return 1
    fi

    local ts final tmp n=0
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    final="$dir/mother-state-$ts.tar.gz"
    while [ -e "$final" ]; do n=$((n + 1)); final="$dir/mother-state-$ts-$n.tar.gz"; done
    # Hidden temp name that never matches mother-state-*.tar.gz: a crash leaves
    # nothing that looks like a valid backup.
    tmp="$dir/.mother-state-$ts.tmp.$$"
    local rc=0
    ( umask 077; tar -czf "$tmp" --exclude='*.tmp.*' --exclude='*.lockdir' \
        -C "$MOTHER_ROOT" "${items[@]}" 2>/dev/null ) || rc=$?
    # Exit 1 is "a file changed/vanished while being read" (live tree, atomic
    # renames); the archive is still good if it lists cleanly.
    if [ "$rc" -gt 1 ] || ! tar -tzf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "backup failed (tar exit $rc)" >&2
        return 1
    fi
    mv -f "$tmp" "$final" || { rm -f "$tmp"; echo "backup failed (could not move into place)" >&2; return 1; }
    printf '%s\n' "$final"
    mother_backup_prune >/dev/null 2>&1 || true
    return 0
}

# _backup_ts_epoch <YYYYmmddTHHMMSSZ> — UTC epoch seconds (pure bash; BSD and
# GNU `date` disagree on parsing). The `10#` prefixes dodge octal parsing.
_backup_ts_epoch() {
    local ts="$1" y m d H M S era yoe doy doe days
    y=$((10#${ts:0:4})); m=$((10#${ts:4:2})); d=$((10#${ts:6:2}))
    H=$((10#${ts:9:2})); M=$((10#${ts:11:2})); S=$((10#${ts:13:2}))
    [ "$m" -le 2 ] && y=$((y - 1))
    era=$((y / 400)); yoe=$((y - era * 400))
    if [ "$m" -gt 2 ]; then doy=$(( (153 * (m - 3) + 2) / 5 + d - 1 )); else doy=$(( (153 * (m + 9) + 2) / 5 + d - 1 )); fi
    doe=$((yoe * 365 + yoe / 4 - yoe / 100 + doy))
    days=$((era * 146097 + doe - 719468))
    echo $((days * 86400 + H * 3600 + M * 60 + S))
}

# _backup_files — backup file names in the dir, newest first. Only names that
# match mother-state-<ts>.tar.gz exactly; nothing else is ever listed or pruned.
_backup_files() {
    local dir; dir=$(mother_backup_dir)
    [ -d "$dir" ] || return 0
    ls -1 "$dir" 2>/dev/null \
        | grep -E '^mother-state-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?\.tar\.gz$' \
        | sort -r
}

# mother_backup_prune — retention: keep everything newer than KEEP_HOURS; of
# the older ones keep the newest backup per UTC day for KEEP_DAYS days; delete
# the rest. Age comes from the timestamp in the file name, never mtime.
mother_backup_prune() {
    local dir keep_h keep_d now f ts epoch age seen="|"
    dir=$(mother_backup_dir)
    keep_h="${MOTHER_BACKUP_KEEP_HOURS:-24}"; keep_d="${MOTHER_BACKUP_KEEP_DAYS:-30}"
    case "$keep_h" in ''|*[!0-9]*) keep_h=24 ;; esac
    case "$keep_d" in ''|*[!0-9]*) keep_d=30 ;; esac
    now="${MOTHER_BACKUP_NOW_EPOCH:-$(date +%s)}"
    for f in $(_backup_files); do
        ts="${f#mother-state-}"; ts="${ts:0:16}"
        epoch=$(_backup_ts_epoch "$ts")
        age=$((now - epoch))
        if [ "$age" -lt $((keep_h * 3600)) ]; then
            continue
        elif [ "$age" -le $((keep_d * 86400)) ] && [ "${seen#*|${ts:0:8}|}" = "$seen" ]; then
            seen="$seen${ts:0:8}|"
            continue
        fi
        rm -f -- "$dir/$f" && echo "pruned $f"
    done
    return 0
}

# _backup_human <bytes>
_backup_human() {
    awk -v b="$1" 'BEGIN {
        if (b >= 1073741824) printf "%.1f GB", b / 1073741824;
        else if (b >= 1048576) printf "%.1f MB", b / 1048576;
        else if (b >= 1024) printf "%.0f KB", b / 1024;
        else printf "%d B", b }'
}

# mother_backup_list — newest first: name, size, job count.
mother_backup_list() {
    local dir f bytes jobs any=0
    dir=$(mother_backup_dir)
    for f in $(_backup_files); do
        any=1
        bytes=$(wc -c < "$dir/$f" 2>/dev/null | tr -d ' ')
        jobs=$(tar -tzf "$dir/$f" 2>/dev/null | grep -cE '^(\./)?jobs/[^/]+\.json$')
        printf '%-42s %9s  jobs=%s\n' "$f" "$(_backup_human "${bytes:-0}")" "${jobs:-0}"
    done
    [ "$any" -eq 1 ] || echo "no backups in $dir"
    return 0
}

# _backup_runner_alive — 0 when $RUNNER_DIR/runner.pid names a live process.
_backup_runner_alive() {
    local pid
    pid=$(cat "${RUNNER_DIR:-$MOTHER_ROOT/runner}/runner.pid" 2>/dev/null) || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# mother_backup_restore <file-or-name> [--yes]
#
# Replaces the restorable parts of the tree with the backup's. The current
# versions are MOVED ASIDE to $MOTHER_ROOT/.pre-restore-<ts>/, never deleted.
mother_backup_restore() {
    local file="" yes=0 a
    for a in "$@"; do
        case "$a" in
            --yes|-y) yes=1 ;;
            -*) echo "unknown flag for backup restore: $a" >&2; return 2 ;;
            *) [ -z "$file" ] && file="$a" || { echo "backup restore takes one file" >&2; return 2; } ;;
        esac
    done
    [ -n "$file" ] || { echo "usage: mother backup restore <file> [--yes]" >&2; return 2; }
    if [ ! -f "$file" ] && [ -f "$(mother_backup_dir)/$file" ]; then
        file="$(mother_backup_dir)/$file"
    fi
    [ -f "$file" ] || { echo "no such backup: $file" >&2; return 1; }

    if _backup_runner_alive; then
        echo "refusing to restore while the runner is running — run \`mother daemon stop\` first, then restore, then \`mother daemon start\`" >&2
        return 1
    fi

    # Validate the archive before touching anything: it must list cleanly, hold
    # only relative paths with no `..`, and only known top-level entries.
    local listing tops="" entry top bad=0
    listing=$(tar -tzf "$file" 2>/dev/null) || { echo "not a readable backup archive: $file" >&2; return 1; }
    [ -n "$listing" ] || { echo "empty backup archive: $file" >&2; return 1; }
    while IFS= read -r entry; do
        entry="${entry#./}"
        case "$entry" in
            ''|/*|..|../*|*/..|*/../*) bad=1; break ;;
        esac
        top="${entry%%/*}"
        case " $_BACKUP_ENTRIES " in *" $top "*) ;; *) bad=1; break ;; esac
        case " $tops " in *" $top "*) ;; *) tops="$tops $top" ;; esac
    done <<EOF
$listing
EOF
    [ "$bad" -eq 0 ] || { echo "backup $file contains unexpected paths; refusing" >&2; return 1; }

    if [ "$yes" -ne 1 ]; then
        if [ -t 0 ]; then
            printf 'Restore %s into %s? Current state is kept in .pre-restore-*/. [y/N] ' "$file" "$MOTHER_ROOT" >&2
            read -r a
            case "$a" in y|Y|yes|YES) ;; *) echo "aborted" >&2; return 1 ;; esac
        else
            echo "refusing to restore without confirmation — pass --yes" >&2
            return 1
        fi
    fi

    local aside="$MOTHER_ROOT/.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)" n=0 moved=""
    while [ -e "$aside" ]; do n=$((n + 1)); aside="$MOTHER_ROOT/.pre-restore-$(date -u +%Y%m%dT%H%M%SZ)-$n"; done
    mkdir -p "$aside" || { echo "cannot create $aside" >&2; return 1; }
    for top in $tops; do
        if [ -e "$MOTHER_ROOT/$top" ]; then
            mv "$MOTHER_ROOT/$top" "$aside/$top" || { _backup_undo_aside "$aside" "$moved"; return 1; }
            moved="$moved $top"
        fi
    done
    if ! tar -xzf "$file" -C "$MOTHER_ROOT" 2>/dev/null; then
        echo "extract failed; putting the previous state back" >&2
        for top in $tops; do safe_rm_tree "$MOTHER_ROOT/$top"; done
        _backup_undo_aside "$aside" "$moved"
        return 1
    fi

    local jobs archived
    jobs=$(ls -1 "$MOTHER_ROOT/jobs" 2>/dev/null | grep -c '\.json$')
    archived=$(find "$MOTHER_ROOT/archive" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "restored from $file:$tops"
    echo "  jobs: $jobs   archive files: $archived"
    [ -n "$moved" ] && echo "previous state kept at $aside"
    return 0
}

# _backup_undo_aside <aside_dir> <moved-names> — put moved-aside entries back.
_backup_undo_aside() {
    local aside="$1" top
    for top in $2; do
        [ -e "$aside/$top" ] && mv "$aside/$top" "$MOTHER_ROOT/$top"
    done
    rmdir "$aside" 2>/dev/null
    return 0
}
