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

# --- notification click target (macOS only; advisory) ---
if [ "$(uname -s)" = "Darwin" ] && ! command -v terminal-notifier >/dev/null 2>&1; then
    echo "notifications:"
    printf '  ✗ %-12s not found — clicks will open Script Editor.\n' "terminal-notifier"
    printf '               Fix: brew install terminal-notifier\n'
    echo ""
fi

# --- effective concurrency (advisory) ---
if command -v mother >/dev/null 2>&1; then
    _conc=$(mother status --format json 2>/dev/null | jq -r '.concurrency | "\(.value) (source: \(.source))"' 2>/dev/null)
    [ -z "$_conc" ] || { echo "concurrency:"; printf '  • %s\n' "$_conc"; echo ""; }
fi

# --- dispatch mode, coordinator and local worker (cluster P1-5; advisory — never affects exit status) ---
# `legacy` (default) forks a supervisor per job. `worker` leases jobs through the coordinator to the local
# worker. Shows the mode and where it came from, whether the coordinator and the worker are alive, and the
# coordinator socket's permissions (it must be owner-only, in an owner-only directory).
_droot="${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}"
_drunner="$_droot/runner"
_pidfile_alive() {
    local p
    p=$(tr -dc '0-9' < "$1" 2>/dev/null)
    [ -n "$p" ] && kill -0 "$p" 2>/dev/null && echo "pid $p"
}
if command -v mother >/dev/null 2>&1; then
    _dm=$(mother status --format json 2>/dev/null | jq -r '.dispatch_mode | "\(.value) (source: \(.source))"' 2>/dev/null)
    _dmv=$(mother status --format json 2>/dev/null | jq -r '.dispatch_mode.value // empty' 2>/dev/null)
    # Legacy (the default) prints nothing: doctor output is unchanged until the mode or a worker is in play.
    [ -z "$_dm" ] || { [ "$_dmv" = "legacy" ] && [ ! -d "$_drunner/leases" ] && [ ! -d "$_drunner/dispatch" ]; } || {
        echo "dispatch:"
        printf '  • %-12s %s\n' "mode" "$_dm"
        _coord=$(_pidfile_alive "$_drunner/coord.pid") || _coord=""
        _wrk=$(_pidfile_alive "$_drunner/worker-local.pid") || _wrk=""
        if [ -n "$_coord" ]; then printf '  ✓ %-12s running (%s)\n' "coordinator" "$_coord"
        elif [ "$_dmv" = "worker" ]; then printf '  ✗ %-12s not running (the daemon starts it in worker mode)\n' "coordinator"
        else printf '  – %-12s not running (legacy mode starts none)\n' "coordinator"; fi
        if [ -n "$_wrk" ]; then printf '  ✓ %-12s running (%s)\n' "local worker" "$_wrk"
        elif [ "$_dmv" = "worker" ]; then printf '  ✗ %-12s not running (the daemon starts it in worker mode)\n' "local worker"
        else printf '  – %-12s not running (legacy mode starts none)\n' "local worker"; fi
        _sock="$_drunner/coord/worker.sock"
        if [ -S "$_sock" ]; then
            _sp=$(stat -f %Lp "$_sock" 2>/dev/null || stat -c %a "$_sock" 2>/dev/null)
            _dp=$(stat -f %Lp "$_drunner/coord" 2>/dev/null || stat -c %a "$_drunner/coord" 2>/dev/null)
            if [ "$_sp" = "600" ] && [ "$_dp" = "700" ]; then
                printf '  ✓ %-12s socket 0%s in a 0%s directory\n' "permissions" "$_sp" "$_dp"
            else
                printf '  ✗ %-12s socket 0%s in a 0%s directory (want 0600 in 0700)\n' "permissions" "${_sp:-?}" "${_dp:-?}"
            fi
        elif [ -n "$_coord" ]; then
            printf '  ✗ %-12s coordinator is running but %s is missing\n' "socket" "$_sock"
        fi
        echo ""
    }
fi

# --- state backups: size budget (advisory — never affects exit status) ---
# Backups live outside the tree and are pruned by retention; this shows what they
# cost (count, size, newest age, bytes written in the last 24h) and warns when
# they exceed MOTHER_BACKUP_WARN_GB.
if command -v mother >/dev/null 2>&1; then
    _bk=$(mother backup list --summary 2>/dev/null)
    if [ -n "$_bk" ]; then
        echo "backups:"
        printf '%s\n' "$_bk" | while IFS= read -r _line; do
            case "$_line" in
                warn:*) printf '  ✗ %s\n' "$_line" ;;
                *)      printf '  • %s\n' "$_line" ;;
            esac
        done
        echo ""
    fi
fi

# --- looping adherence reviews (advisory — never affects exit status) ---
# More than 5 adherence reviews on one job in the last hour means the review is
# looping (see CHANGELOG 0.3.3); the same list feeds the statusline's ⚑ count.
if command -v mother >/dev/null 2>&1; then
    _loops=$(mother status --format json 2>/dev/null \
        | jq -r '(.needs_attention // [])[] | select(.kind == "adherence_loop") | "  ✗ adherence    \(.job_id): \(.reason)"' 2>/dev/null)
    if [ -n "$_loops" ]; then
        echo "adherence reviews:"
        printf '%s\n' "$_loops"
        echo "               Fix: investigate the job (mother status <id>); MOTHER_ADHERENCE_ENABLED=0 stops reviews"
        echo ""
    fi
fi

# --- plugin cache freshness (advisory — never affects exit status) ---
# The UserPromptSubmit hook and CLI the plugin manager serves come from a
# cached copy of this repo. If that copy is older than the checkout the daemon
# runs from, the hook reads events with stale code (see CHANGELOG 0.2.0).
_doctor_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
_plugin_dir="$(cd "$_doctor_dir/.." && pwd -P)"
installed_json="$HOME/.claude/plugins/installed_plugins.json"
if [ -f "$installed_json" ] && command -v jq >/dev/null 2>&1; then
    echo "plugin cache:"
    cache_path=$(jq -r '(.plugins // {}) | to_entries | map(select(.key | startswith("mother@"))) | .[0].value[0].installPath // empty' "$installed_json" 2>/dev/null)
    cache_date=$(jq -r '(.plugins // {}) | to_entries | map(select(.key | startswith("mother@"))) | .[0].value[0].installedAt // "unknown"' "$installed_json" 2>/dev/null)
    if [ -z "$cache_path" ]; then
        printf '  – %-12s mother plugin not installed via the plugin manager\n' "cache"
    else
        stale=0
        for rel in hooks/mother-inject.sh bin/mother; do
            if [ ! -f "$cache_path/$rel" ] || [ "$(cksum < "$cache_path/$rel")" != "$(cksum < "$_plugin_dir/$rel")" ]; then
                stale=1
            fi
        done
        if [ "$stale" -eq 0 ]; then
            printf '  ✓ %-12s cached hook + CLI match this checkout\n' "cache"
        else
            printf '  ✗ %-12s cached copy (installed %s) differs from this checkout\n' "cache" "$cache_date"
            printf '               Fix: claude plugin update mother@thehammer-mother\n'
        fi
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
