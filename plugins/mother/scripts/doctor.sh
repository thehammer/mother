#!/usr/bin/env bash
# doctor.sh — verify Mother's runtime dependencies.
#
# Exits 0 if everything required is present, non-zero otherwise. Prints a
# green ✓ or red ✗ for each check so you can see at a glance what's missing.

set -u

_check() {
    local name="$1" cmd="$2"
    if command -v "$cmd" >/dev/null 2>&1; then
        printf '  ✓ %-12s %s\n' "$name" "$(command -v "$cmd")"
        return 0
    else
        printf '  ✗ %-12s (not found)\n' "$name"
        return 1
    fi
}

echo "Mother doctor"
echo ""
echo "Required:"
missing=0
_check "bash"    bash    || missing=1
_check "jq"      jq      || missing=1
_check "git"     git     || missing=1
_check "tmux"    tmux    || missing=1
_check "claude"  claude  || missing=1
echo ""
echo "Optional:"
_check "fzf"     fzf     || echo "             (required for mother-switcher; install with 'brew install fzf')"
_check "gh"      gh      || echo "             (nice-to-have for agents that open PRs)"
echo ""

if [ "$missing" -eq 0 ]; then
    echo "All required deps present."
    exit 0
else
    echo "Missing required deps. See links in README.md for install instructions."
    exit 1
fi
