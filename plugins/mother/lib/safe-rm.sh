# safe-rm.sh — the single guard in front of every recursive directory delete,
# plus the live-tree marker it keys on.
#
# Sourced by lib/state.sh (so every `mother` command and the runner get it) and
# by tests/test_helper.bash. Safe to source repeatedly. Must not `set` shell
# options and must not depend on any other Mother lib.
#
# Why this exists: on 2026-10-17 a stray `rm -rf "$MOTHER_ROOT"` in a test
# teardown deleted the live state tree (~/.mother). Nothing between the `rm`
# and the filesystem asked "is this the real tree?". Now something does:
#
#   - `$MOTHER_ROOT/.mother-live` marks the real tree (created by
#     mother_ensure_live_marker; never in tests, which set MOTHER_TEST_ROOT=1).
#   - safe_rm_tree refuses to delete a directory that is, or contains, a
#     marker, and refuses "", /, $HOME and any ancestor of $HOME.

# mother_ensure_live_marker — create $MOTHER_ROOT/.mother-live if it is absent.
# No-op when MOTHER_TEST_ROOT=1 (test setup) or the root doesn't exist yet.
# Idempotent: an existing marker is never rewritten.
mother_ensure_live_marker() {
    [ "${MOTHER_TEST_ROOT:-0}" = "1" ] && return 0
    local root="${MOTHER_ROOT:-}"
    [ -n "$root" ] && [ -d "$root" ] || return 0
    local marker="$root/.mother-live"
    [ -e "$marker" ] && return 0
    {
        printf 'This directory is Mother'"'"'s LIVE state tree (jobs, events, archive).\n'
        printf 'Mother refuses to recursively delete any directory that contains this file.\n'
        printf 'Do not remove it. Backups: `mother backup list`.\n'
        printf 'created: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } > "$marker" 2>/dev/null || true
    return 0
}

# _safe_rm_physical <path> — echo the symlink-resolved absolute path of an
# existing directory, or the input unchanged when it can't be resolved.
_safe_rm_physical() {
    local p="$1" r
    if [ -d "$p" ] && r=$(cd -P "$p" 2>/dev/null && pwd -P) && [ -n "$r" ]; then
        printf '%s' "$r"
    else
        printf '%s' "$p"
    fi
}

# safe_rm_tree <path> — `rm -rf <path>`, unless the path is dangerous.
#
# Returns 0 when the path was removed or did not exist (rm's own status if it
# failed, e.g. permissions). Returns 1, prints
# `safe_rm_tree: refusing ...` on stderr and deletes nothing when <path> is:
#   - empty, `/`, $HOME, or an ancestor of $HOME;
#   - a directory that is, or contains (up to 3 levels down), a .mother-live
#     marker, or is an ancestor of a known live root ($MOTHER_ROOT,
#     $MOTHER_LIVE_ROOT, $HOME/.mother) that carries one.
safe_rm_tree() {
    local path="${1:-}"
    if [ -z "$path" ]; then
        echo "safe_rm_tree: refusing to delete an empty path" >&2
        return 1
    fi
    while [ "${#path}" -gt 1 ] && [ "${path%/}" != "$path" ]; do path="${path%/}"; done
    if [ "$path" = "/" ]; then
        echo "safe_rm_tree: refusing to delete /" >&2
        return 1
    fi
    [ -e "$path" ] || [ -L "$path" ] || return 0

    local real
    real=$(_safe_rm_physical "$path")
    if [ "$real" = "/" ]; then
        echo "safe_rm_tree: refusing to delete / (via $path)" >&2
        return 1
    fi

    if [ -n "${HOME:-}" ]; then
        local home_real
        home_real=$(_safe_rm_physical "$HOME")
        # $real is $HOME or one of its ancestors.
        case "$home_real/" in
            "$real"/*) echo "safe_rm_tree: refusing to delete $path (is or contains \$HOME)" >&2; return 1 ;;
        esac
    fi

    if [ -d "$real" ]; then
        local hit
        if [ -e "$real/.mother-live" ]; then
            hit="$real/.mother-live"
        else
            hit=$(find "$real" -maxdepth 4 \( -name node_modules -o -name .git \) -prune -o \
                -name .mother-live -print -quit 2>/dev/null)
        fi
        if [ -n "$hit" ]; then
            echo "safe_rm_tree: refusing to delete $path (contains live-tree marker $hit)" >&2
            return 1
        fi
        # Deeper ancestors of a live root: marker too far down for find.
        local root rreal
        for root in "${MOTHER_ROOT:-}" "${MOTHER_LIVE_ROOT:-}" "${HOME:-}/.mother"; do
            [ -n "$root" ] && [ -e "$root/.mother-live" ] || continue
            rreal=$(_safe_rm_physical "$root")
            case "$rreal/" in
                "$real"/*)
                    echo "safe_rm_tree: refusing to delete $path (contains live tree $rreal)" >&2
                    return 1 ;;
            esac
        done
    fi

    rm -rf -- "$path" 2>/dev/null
}
