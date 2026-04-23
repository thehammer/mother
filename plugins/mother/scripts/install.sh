#!/usr/bin/env bash
# install.sh — one-shot bootstrap for the Mother plugin.
#
# Actions:
#   - symlink bin/* into --target-bin (default: ~/.local/bin)
#   - warn on pre-existing collisions unless --force
#   - verify external deps via doctor.sh
#   - print next-step instructions for the daemon, tmux binding, and statusline
#
# Usage:
#   scripts/install.sh [--target-bin PATH] [--force]

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_BIN="$HOME/.local/bin"
FORCE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --target-bin)
            [ $# -ge 2 ] || { echo "install.sh: --target-bin requires a path" >&2; exit 2; }
            TARGET_BIN="$2"
            shift 2
            ;;
        --target-bin=*)
            TARGET_BIN="${1#--target-bin=}"
            shift
            ;;
        --force)
            FORCE=1
            shift
            ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "install.sh: unknown arg: $1" >&2
            exit 2
            ;;
    esac
done

echo "Mother plugin install"
echo "  plugin dir: $PLUGIN_DIR"
echo "  target:     $TARGET_BIN"
echo ""

mkdir -p "$TARGET_BIN"

# Symlink every file in bin/ into $TARGET_BIN.
linked=0
skipped=0
relinked=0
for src in "$PLUGIN_DIR/bin/"*; do
    [ -e "$src" ] || continue
    name="$(basename "$src")"
    target="$TARGET_BIN/$name"

    if [ -L "$target" ]; then
        current="$(readlink "$target")"
        if [ "$current" = "$src" ]; then
            printf '  = %s (already linked)\n' "$name"
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$FORCE" -eq 1 ]; then
            ln -sf "$src" "$target"
            printf '  ↻ %s (relinked, was → %s)\n' "$name" "$current"
            relinked=$((relinked + 1))
            continue
        fi
        printf '  ! %s exists (symlink → %s); re-run with --force to overwrite\n' "$name" "$current" >&2
        skipped=$((skipped + 1))
        continue
    fi

    if [ -e "$target" ]; then
        if [ "$FORCE" -eq 1 ]; then
            rm -f "$target"
            ln -s "$src" "$target"
            printf '  ↻ %s (replaced regular file)\n' "$name"
            relinked=$((relinked + 1))
            continue
        fi
        printf '  ! %s exists and is not a symlink; re-run with --force to overwrite\n' "$name" >&2
        skipped=$((skipped + 1))
        continue
    fi

    ln -s "$src" "$target"
    printf '  + %s\n' "$name"
    linked=$((linked + 1))
done

echo ""
echo "symlinks: $linked new, $relinked replaced, $skipped skipped"
echo ""

# PATH sanity check.
case ":$PATH:" in
    *":$TARGET_BIN:"*)
        :
        ;;
    *)
        echo "warning: $TARGET_BIN is not on your \$PATH" >&2
        echo "         add to your shell rc:  export PATH=\"$TARGET_BIN:\$PATH\"" >&2
        echo "" >&2
        ;;
esac

# Run doctor. Don't abort on non-zero — let the caller see the report.
doctor_status=0
"$PLUGIN_DIR/scripts/doctor.sh" || doctor_status=$?

echo ""
echo "Next steps:"
echo "  1. mother daemon install       # install launchd agent (macOS)"
echo "  2. mother daemon start         # start the background runner"
echo "  3. tmux binding (optional):    # add to ~/.tmux.conf"
echo "       bind Space display-popup -w 80% -h 80% -E \"\$(command -v mother-switcher)\""
echo "  4. statusline (optional):      # source in your statusline script"
echo "       source \"$PLUGIN_DIR/statusline/segment.sh\" && mother_segment"
echo ""

exit "$doctor_status"
