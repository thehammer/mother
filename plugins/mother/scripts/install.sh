#!/usr/bin/env bash
# install.sh — one-shot bootstrap for the Mother plugin.
#
# Actions:
#   - symlink bin/mother (and friends) into $MOTHER_INSTALL_BIN (default: ~/.local/bin)
#   - verify external deps (jq, tmux, fzf, git, claude)
#   - print next-step instructions for the daemon (manual launchd/systemd step)
#
# Run from the plugin dir, or from anywhere with --plugin-dir=<path>.

set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_BIN="${MOTHER_INSTALL_BIN:-$HOME/.local/bin}"

echo "Mother plugin install"
echo "  plugin dir: $PLUGIN_DIR"
echo "  target:     $INSTALL_BIN"
echo ""

mkdir -p "$INSTALL_BIN"

# TODO: port real install logic. Intended behavior:
#   - symlink each bin/* into $INSTALL_BIN (skip on collision, prompt to overwrite)
#   - verify $INSTALL_BIN is on $PATH; warn if not
#   - call doctor.sh to verify deps
#   - print instructions for:
#       mother daemon install   # launchd on macOS, systemd on linux
#       mother daemon start
#   - note tmux binding: `bind Space display-popup -w 80% -h 80% -E "$(command -v mother-switcher)"`

echo "install.sh: not yet implemented (skeleton)" >&2
exit 2
