# backup.sh — rotating backups of Mother's state tree, and restore.
#
# Sourced by bin/mother (CLI: `mother backup now|list|restore`); the runner
# calls `mother backup now --auto` on a timer (_maybe_backup in bin/mother-runner).
# Does not set shell options; inherits `set -u` and bash 3.2 compatibility
# (no `declare -A`, no `mapfile`) from the caller.
#
# Why: on 2026-10-17 the whole of ~/.mother was deleted and nothing could bring
# it back. The tree is plain files, so a tarball every hour, kept OUTSIDE the
# tree, makes any single mistake recoverable.
#
# Churn control: a full tarball every 15 minutes wrote ~14 GB of disk a day for
# a tree that barely changes. Now (1) `backup now --auto` (the runner) skips the
# state tarball when a cheap change fingerprint is unchanged (forced anyway every
# MOTHER_BACKUP_MAX_AGE), and (2) `archive/` (append-only, the bulk of the tree)
# lives in its own mother-archive-<ts>.tar.gz, written only when it changed.
# The state tarball (mother-state-<ts>.tar.gz) therefore no longer contains
# archive/; restore stitches the two back together, and legacy single-file
# backups (archive/ inside the state tarball) still restore on their own.
#
# What is backed up (relative to $MOTHER_ROOT): jobs events archive drafts
# cursors metrics attention.json rate-limits.json config.env — and logs/ only
# when MOTHER_BACKUP_LOGS=1 (large). `metrics/` (runs.jsonl: the retro and
# ETA-calibration history) and `config.env` (durable operator settings) are
# small and irreplaceable, so they ride along even though they are not
# state-machine files.
#
# Knobs (all optional; explicit values in config.env / the environment win):
#   MOTHER_BACKUP_DIR         default: ~/Library/Application Support/Mother/backups
#                             (macOS), ${XDG_STATE_HOME:-~/.local/state}/mother/backups
#                             elsewhere. Never allowed inside $MOTHER_ROOT.
#   MOTHER_BACKUP_KEEP_HOURS  keep every backup newer than this (default 12)
#   MOTHER_BACKUP_KEEP_DAYS   then keep the newest backup of each UTC day for
#                             this many days (default 14); older is pruned
#   MOTHER_BACKUP_MAX_AGE     --auto takes a backup at least this often even if
#                             nothing changed (default 21600; 0 = never skip)
#   MOTHER_BACKUP_ARCHIVE_INTERVAL  --auto writes a changed archive/ at most this
#                             often (default 86400)
#   MOTHER_BACKUP_WARN_GB     list --summary / doctor warn above this (default 5)
#   MOTHER_BACKUP_LOGS        1 = include logs/
#   MOTHER_BACKUP_NOW_EPOCH   test seam: the "current time" retention and the
#                             skip logic use

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

# _backup_stat_all <path>... — "path|size|mtime" for every regular file under
# the given paths (relative to the cwd), skipping atomic-write temp files and
# lock dirs. GNU and BSD `stat` take different flags; probe once.
_backup_stat_all() {
    local flag fmt
    if stat -c %s / >/dev/null 2>&1; then flag="-c"; fmt='%n|%s|%Y'; else flag="-f"; fmt='%N|%z|%m'; fi
    find "$@" -type f ! -name '*.tmp.*' ! -path '*.lockdir/*' -exec stat "$flag" "$fmt" {} + 2>/dev/null
}

# _backup_state_sig — change fingerprint of what the state tarball holds.
# Path+size+mtime for jobs events drafts metrics config.env; cursors/ by file
# count and total size only (it churns constantly but its content is
# throwaway). attention.json and rate-limits.json are left out on purpose: the
# daemon and statusline rewrite them every minute, which would defeat the
# fingerprint; they are regenerated state and still ride in the tarball.
# archive/ has its own fingerprint.
_backup_state_sig() {
    (
        cd "$MOTHER_ROOT" 2>/dev/null || exit 0
        for e in jobs events drafts metrics config.env; do
            [ -e "$e" ] && _backup_stat_all "$e"
        done | LC_ALL=C sort
        [ -d cursors ] && _backup_stat_all cursors | awk -F'|' '{ n++; s += $2 } END { print "cursors|" n + 0 "|" s + 0 }'
        exit 0
    ) | cksum | awk '{ print $1 "-" $2 }'
}

# _backup_archive_sig — change fingerprint of archive/.
_backup_archive_sig() {
    ( cd "$MOTHER_ROOT" 2>/dev/null && _backup_stat_all archive | LC_ALL=C sort ) | cksum | awk '{ print $1 "-" $2 }'
}

# _backup_read_sig <file> / _backup_write_sig <file> <sig>
_backup_read_sig() { head -n1 "$1" 2>/dev/null; }
_backup_write_sig() {
    local f="$1" tmp="$1.tmp.$$"
    mkdir -p "$(dirname "$f")" 2>/dev/null
    { printf '%s\n' "$2" > "$tmp" && mv -f "$tmp" "$f"; } 2>/dev/null || rm -f "$tmp"
}

_backup_runner_dir() { printf '%s' "${RUNNER_DIR:-$MOTHER_ROOT/runner}"; }
_backup_now_epoch() { printf '%s' "${MOTHER_BACKUP_NOW_EPOCH:-$(date +%s)}"; }

# _backup_name_epoch <file name> — epoch of the UTC stamp in a backup file name.
_backup_name_epoch() {
    local ts="${1#mother-state-}"; ts="${ts#mother-archive-}"
    _backup_ts_epoch "${ts:0:16}"
}

# _backup_write_tar <prefix> <dest-dir> <item>... — tar the items (relative to
# $MOTHER_ROOT) into <dest-dir>/<prefix>-<ts>.tar.gz atomically; print the path.
_backup_write_tar() {
    local prefix="$1" dir="$2"; shift 2
    local ts final tmp n=0 rc=0
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    final="$dir/$prefix-$ts.tar.gz"
    while [ -e "$final" ]; do n=$((n + 1)); final="$dir/$prefix-$ts-$n.tar.gz"; done
    # Hidden temp name that never matches a backup name: a crash leaves
    # nothing that looks like a valid backup.
    tmp="$dir/.$prefix-$ts.tmp.$$"
    ( umask 077; tar -czf "$tmp" --exclude='*.tmp.*' --exclude='*.lockdir' \
        -C "$MOTHER_ROOT" "$@" 2>/dev/null ) || rc=$?
    # Exit 1 is "a file changed/vanished while being read" (live tree, atomic
    # renames); the archive is still good if it lists cleanly.
    if [ "$rc" -gt 1 ] || ! tar -tzf "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "backup failed (tar exit $rc)" >&2
        return 1
    fi
    mv -f "$tmp" "$final" || { rm -f "$tmp"; echo "backup failed (could not move into place)" >&2; return 1; }
    printf '%s\n' "$final"
}

# _backup_archive_step <dir> <auto> <now> — write mother-archive-<ts>.tar.gz
# when archive/ changed since the last one. Under --auto, at most once per
# MOTHER_BACKUP_ARCHIVE_INTERVAL. Prints the new file's path.
_backup_archive_step() {
    local dir="$1" auto="$2" now="$3" sigfile sig last interval path
    # An archive/ with no files (the CLI recreates the empty dir) has nothing to back up.
    [ -n "$(find "$MOTHER_ROOT/archive" -type f -print -quit 2>/dev/null)" ] || return 0
    sigfile="$(_backup_runner_dir)/last-backup-archive.sig"
    sig=$(_backup_archive_sig)
    last=$(_backup_archive_files | head -n1)
    if [ -n "$last" ] && [ "$sig" = "$(_backup_read_sig "$sigfile")" ]; then return 0; fi
    if [ "$auto" -eq 1 ] && [ -n "$last" ]; then
        interval="${MOTHER_BACKUP_ARCHIVE_INTERVAL:-86400}"
        case "$interval" in ''|*[!0-9]*) interval=86400 ;; esac
        [ $((now - $(_backup_name_epoch "$last"))) -ge "$interval" ] || return 0
    fi
    path=$(_backup_write_tar mother-archive "$dir" archive) || return 1
    _backup_write_sig "$sigfile" "$sig"
    printf '%s\n' "$path"
}

# _backup_state_unchanged <sig> <now> — 0 when the state tarball can be skipped:
# same fingerprint as the last backup AND the newest state tarball still exists
# and is younger than MOTHER_BACKUP_MAX_AGE (so a stale tarball is never the
# only copy).
_backup_state_unchanged() {
    local sig="$1" now="$2" prev newest max
    prev=$(_backup_read_sig "$(_backup_runner_dir)/last-backup.sig")
    [ -n "$prev" ] && [ "$prev" = "$sig" ] || return 1
    newest=$(_backup_files | head -n1)
    [ -n "$newest" ] || return 1
    max="${MOTHER_BACKUP_MAX_AGE:-21600}"
    case "$max" in ''|*[!0-9]*) max=21600 ;; esac
    [ "$max" -gt 0 ] || return 1
    [ $((now - $(_backup_name_epoch "$newest"))) -lt "$max" ]
}

# mother_backup_now [--auto] — write a backup, prune, print the new file paths
# (the archive tarball first when one was written, the state tarball last).
# --auto (the runner) skips the state tarball when nothing changed and prints
# "unchanged, skipped"; prune runs either way.
mother_backup_now() {
    local auto=0 a
    for a in "$@"; do
        case "$a" in
            --auto) auto=1 ;;
            *) echo "unknown flag for backup now: $a" >&2; return 2 ;;
        esac
    done
    local dir; dir=$(mother_backup_dir)
    mother_backup_check_dir "$dir" || return 1
    mkdir -p "$dir" 2>/dev/null && chmod 700 "$dir" 2>/dev/null
    [ -d "$dir" ] || { echo "cannot create backup dir $dir" >&2; return 1; }

    local items=() e rc=0 now sig
    for e in $_BACKUP_ENTRIES; do
        [ "$e" = "archive" ] && continue            # has its own tarball
        [ "$e" = "logs" ] && [ "${MOTHER_BACKUP_LOGS:-0}" != "1" ] && continue
        [ -e "$MOTHER_ROOT/$e" ] && items+=("$e")
    done
    if [ "${#items[@]}" -eq 0 ] && [ ! -d "$MOTHER_ROOT/archive" ]; then
        echo "nothing to back up under $MOTHER_ROOT" >&2
        return 1
    fi

    now=$(_backup_now_epoch)
    # Fingerprint BEFORE reading the tree: a change landing mid-tar makes the
    # next run write again instead of being missed.
    sig=$(_backup_state_sig)

    _backup_archive_step "$dir" "$auto" "$now" || rc=1

    if [ "$auto" -eq 1 ] && _backup_state_unchanged "$sig" "$now"; then
        echo "unchanged, skipped"
        mother_backup_prune >/dev/null 2>&1 || true
        return "$rc"
    fi
    if [ "${#items[@]}" -eq 0 ]; then
        mother_backup_prune >/dev/null 2>&1 || true
        return "$rc"
    fi
    _backup_write_tar mother-state "$dir" "${items[@]}" || return 1
    _backup_write_sig "$(_backup_runner_dir)/last-backup.sig" "$sig"
    mother_backup_prune >/dev/null 2>&1 || true
    return "$rc"
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

# _backup_files — state backup file names in the dir, newest first. Only names
# that match mother-state-<ts>.tar.gz exactly; nothing else is ever listed or pruned.
_backup_files() {
    local dir; dir=$(mother_backup_dir)
    [ -d "$dir" ] || return 0
    ls -1 "$dir" 2>/dev/null \
        | grep -E '^mother-state-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?\.tar\.gz$' \
        | sort -r
}

# _backup_archive_files — the same for mother-archive-<ts>.tar.gz.
_backup_archive_files() {
    local dir; dir=$(mother_backup_dir)
    [ -d "$dir" ] || return 0
    ls -1 "$dir" 2>/dev/null \
        | grep -E '^mother-archive-[0-9]{8}T[0-9]{6}Z(-[0-9]+)?\.tar\.gz$' \
        | sort -r
}

# mother_backup_prune — retention: keep everything newer than KEEP_HOURS; of
# the older ones keep the newest backup per UTC day for KEEP_DAYS days; delete
# the rest. Age comes from the timestamp in the file name, never mtime. The
# newest state backup is never pruned, whatever the knobs say.
#
# Archive backups: keep the newest, plus for every RETAINED state backup the
# newest archive backup not newer than it (else the oldest one, which is then
# the nearest newer). Everything else is pruned.
mother_backup_prune() {
    local dir keep_h keep_d now f ts epoch age seen="|" first=1 kept_epochs="" i
    dir=$(mother_backup_dir)
    [ -n "$dir" ] || return 0
    keep_h="${MOTHER_BACKUP_KEEP_HOURS:-12}"; keep_d="${MOTHER_BACKUP_KEEP_DAYS:-14}"
    case "$keep_h" in ''|*[!0-9]*) keep_h=12 ;; esac
    case "$keep_d" in ''|*[!0-9]*) keep_d=14 ;; esac
    now=$(_backup_now_epoch)
    for f in $(_backup_files); do
        ts="${f#mother-state-}"; ts="${ts:0:16}"
        epoch=$(_backup_ts_epoch "$ts")
        age=$((now - epoch))
        if [ "$first" -eq 1 ]; then
            first=0
        elif [ "$age" -lt $((keep_h * 3600)) ]; then
            :
        elif [ "$age" -le $((keep_d * 86400)) ] && [ "${seen#*|${ts:0:8}|}" = "$seen" ]; then
            seen="$seen${ts:0:8}|"
        else
            rm -f -- "${dir:?}/${f:?}" && echo "pruned $f"
            continue
        fi
        kept_epochs="$kept_epochs $epoch"
    done

    local afiles=() aepochs=() keep_idx n best
    for f in $(_backup_archive_files); do
        afiles+=("$f"); aepochs+=("$(_backup_name_epoch "$f")")
    done
    n="${#afiles[@]}"
    [ "$n" -gt 0 ] || return 0
    keep_idx="|0|"                                # the newest archive backup
    for epoch in $kept_epochs; do
        best=$((n - 1))                           # none old enough: the oldest
        for ((i = 0; i < n; i++)); do
            if [ "${aepochs[$i]}" -le "$epoch" ]; then best=$i; break; fi
        done
        keep_idx="$keep_idx$best|"
    done
    for ((i = 0; i < n; i++)); do
        case "$keep_idx" in *"|$i|"*) continue ;; esac
        rm -f -- "${dir:?}/${afiles[$i]:?}" && echo "pruned ${afiles[$i]}"
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

# _backup_age_human <seconds>
_backup_age_human() {
    local s="$1"
    [ "$s" -lt 0 ] && s=0
    if [ "$s" -ge 86400 ]; then echo "$((s / 86400))d"
    elif [ "$s" -ge 3600 ]; then echo "$((s / 3600))h"
    else echo "$((s / 60))m"; fi
}

# mother_backup_summary — the backup budget: count, total size, newest age and
# bytes written in the last 24h, plus a `warn:` line above MOTHER_BACKUP_WARN_GB.
mother_backup_summary() {
    local dir f bytes now epoch count=0 total=0 written=0 newest=0 warn_gb
    dir=$(mother_backup_dir); now=$(_backup_now_epoch)
    for f in $(_backup_files) $(_backup_archive_files); do
        bytes=$(wc -c < "$dir/$f" 2>/dev/null | tr -d ' '); bytes="${bytes:-0}"
        epoch=$(_backup_name_epoch "$f")
        count=$((count + 1)); total=$((total + bytes))
        [ "$epoch" -gt "$newest" ] && newest=$epoch
        [ $((now - epoch)) -lt 86400 ] && written=$((written + bytes))
    done
    if [ "$count" -eq 0 ]; then echo "no backups in $dir"; return 0; fi
    printf 'backups: %d files, %s total, newest %s ago, %s written in the last 24h\n' \
        "$count" "$(_backup_human "$total")" "$(_backup_age_human $((now - newest)))" "$(_backup_human "$written")"
    warn_gb="${MOTHER_BACKUP_WARN_GB:-5}"
    case "$warn_gb" in ''|*[!0-9.]*|*.*.*) warn_gb=5 ;; esac
    if awk -v t="$total" -v g="$warn_gb" 'BEGIN { exit !(t > g * 1073741824) }'; then
        printf 'warn: backups use %s (over %s GB). Lower MOTHER_BACKUP_KEEP_HOURS (now %s) or MOTHER_BACKUP_KEEP_DAYS (now %s), or raise MOTHER_BACKUP_INTERVAL (now %s) in config.env.\n' \
            "$(_backup_human "$total")" "$warn_gb" "${MOTHER_BACKUP_KEEP_HOURS:-12}" "${MOTHER_BACKUP_KEEP_DAYS:-14}" "${MOTHER_BACKUP_INTERVAL:-3600}"
    fi
    return 0
}

# mother_backup_list [--summary] — state backups newest first (name, size, job
# count), then archive backups, then the summary. --summary prints only that.
mother_backup_list() {
    local dir f bytes jobs any=0
    dir=$(mother_backup_dir)
    if [ "${1:-}" = "--summary" ]; then mother_backup_summary; return 0; fi
    for f in $(_backup_files); do
        any=1
        bytes=$(wc -c < "$dir/$f" 2>/dev/null | tr -d ' ')
        jobs=$(tar -tzf "$dir/$f" 2>/dev/null | grep -cE '^(\./)?jobs/[^/]+\.json$')
        printf '%-42s %9s  jobs=%s\n' "$f" "$(_backup_human "${bytes:-0}")" "${jobs:-0}"
    done
    for f in $(_backup_archive_files); do
        any=1
        bytes=$(wc -c < "$dir/$f" 2>/dev/null | tr -d ' ')
        printf '%-42s %9s  kind=archive\n' "$f" "$(_backup_human "${bytes:-0}")"
    done
    [ "$any" -eq 1 ] || { echo "no backups in $dir"; return 0; }
    mother_backup_summary
    return 0
}

# _backup_runner_alive — 0 when $RUNNER_DIR/runner.pid names a live process.
_backup_runner_alive() {
    local pid
    pid=$(cat "${RUNNER_DIR:-$MOTHER_ROOT/runner}/runner.pid" 2>/dev/null) || return 1
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# _backup_validate <file> — check an archive before touching anything: it must
# list cleanly, hold only relative paths with no `..`, and only known top-level
# entries. Prints the top-level names (space-separated); 1 on any problem.
_backup_validate() {
    local file="$1" listing tops="" entry top
    listing=$(tar -tzf "$file" 2>/dev/null) || { echo "not a readable backup archive: $file" >&2; return 1; }
    [ -n "$listing" ] || { echo "empty backup archive: $file" >&2; return 1; }
    while IFS= read -r entry; do
        entry="${entry#./}"
        case "$entry" in
            ''|/*|..|../*|*/..|*/../*) echo "backup $file contains unexpected paths; refusing" >&2; return 1 ;;
        esac
        top="${entry%%/*}"
        case " $_BACKUP_ENTRIES " in *" $top "*) ;; *) echo "backup $file contains unexpected paths; refusing" >&2; return 1 ;; esac
        case " $tops " in *" $top "*) ;; *) tops="$tops $top" ;; esac
    done <<EOF
$listing
EOF
    printf '%s' "$tops"
}

# _backup_pick_archive <state-file-name> — the archive backup that goes with a
# state backup: the newest not newer than it, else the oldest (the nearest
# newer one), else the newest when the name has no stamp. Prints a file name.
_backup_pick_archive() {
    local name="$1" epoch f pick="" oldest=""
    case "$name" in
        mother-state-[0-9]*T[0-9]*Z*.tar.gz) epoch=$(_backup_name_epoch "$name") ;;
        *) _backup_archive_files | head -n1; return 0 ;;
    esac
    for f in $(_backup_archive_files); do
        oldest="$f"
        if [ -z "$pick" ] && [ "$(_backup_name_epoch "$f")" -le "$epoch" ]; then pick="$f"; fi
    done
    printf '%s\n' "${pick:-$oldest}"
}

# mother_backup_restore <file-or-name> [--yes]
#
# Replaces the restorable parts of the tree with the backup's. The current
# versions are MOVED ASIDE to $MOTHER_ROOT/.pre-restore-<ts>/, never deleted.
# A state backup without archive/ in it (the current layout) is restored
# together with its matching mother-archive-* backup; a legacy backup that
# carries archive/ itself restores alone.
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

    # Validate everything before touching anything.
    local tops top archive_file="" archive_note=""
    tops=$(_backup_validate "$file") || return 1
    case "$(basename "$file")" in
        mother-archive-*) ;;                       # an archive backup restores alone
        *)
            case " $tops " in
                *" archive "*) ;;                  # legacy single-file backup
                *)
                    local pick; pick=$(_backup_pick_archive "$(basename "$file")")
                    if [ -n "$pick" ]; then
                        archive_file="$(mother_backup_dir)/$pick"
                        local atops; atops=$(_backup_validate "$archive_file") || return 1
                        [ "$atops" = " archive" ] || { echo "archive backup $archive_file holds more than archive/; refusing" >&2; return 1; }
                        tops="$tops archive"
                    else
                        archive_note="no archive backup found; archive/ left as it is"
                    fi ;;
            esac ;;
    esac

    if [ "$yes" -ne 1 ]; then
        if [ -t 0 ]; then
            printf 'Restore %s%s into %s? Current state is kept in .pre-restore-*/. [y/N] ' "$file" "${archive_file:+ + $archive_file}" "$MOTHER_ROOT" >&2
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
    if ! tar -xzf "$file" -C "$MOTHER_ROOT" 2>/dev/null \
        || { [ -n "$archive_file" ] && ! tar -xzf "$archive_file" -C "$MOTHER_ROOT" 2>/dev/null; }; then
        echo "extract failed; putting the previous state back" >&2
        for top in $tops; do safe_rm_tree "$MOTHER_ROOT/$top"; done
        _backup_undo_aside "$aside" "$moved"
        return 1
    fi

    local jobs archived
    jobs=$(ls -1 "$MOTHER_ROOT/jobs" 2>/dev/null | grep -c '\.json$')
    archived=$(find "$MOTHER_ROOT/archive" -type f 2>/dev/null | wc -l | tr -d ' ')
    echo "restored from $file:$tops"
    [ -n "$archive_file" ] && echo "  archive from $archive_file"
    [ -n "$archive_note" ] && echo "  note: $archive_note"
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
