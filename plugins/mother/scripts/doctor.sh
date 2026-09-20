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
_check "bats"    bats    || echo "             (required for test suite; install with 'brew install bats-core')"
_check "yq"      yq      || echo "             (used for suggested_config parsing; install with 'brew install yq')"
_check "python3" python3 || echo "             (fallback YAML parser for suggested_config; usually pre-installed)"
echo ""

# --- launchd agent (macOS only; advisory — never affects exit status) ---
if [ "$(uname -s)" = "Darwin" ] && command -v plutil >/dev/null 2>&1; then
    installed_plist="$HOME/Library/LaunchAgents/com.thehammer.mother.plist"
    echo "launchd agent:"
    if [ ! -f "$installed_plist" ]; then
        printf '  – %-12s not installed (run: mother daemon install)\n' "plist"
    elif [ "$(plutil -extract AbandonProcessGroup raw "$installed_plist" 2>/dev/null)" = "true" ]; then
        printf '  ✓ %-12s AbandonProcessGroup=true\n' "plist"
    else
        printf '  ✗ %-12s AbandonProcessGroup missing or false — a daemon\n' "plist"
        printf '               restart will kill live job workers.\n'
        printf '               Fix: mother daemon install (re-deploys the template)\n'
    fi
    echo ""
fi

if [ "$missing" -eq 0 ]; then
    echo "All required deps present."
    exit 0
else
    echo "Missing required deps. See links in README.md for install instructions."
    exit 1
fi
