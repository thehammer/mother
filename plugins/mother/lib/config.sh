#!/usr/bin/env bash
# config.sh — operator configuration that survives `mother daemon install`.
#
# The launchd plist is rendered from a shipped template, so any
# EnvironmentVariables an operator hand-added to the installed plist (notably
# MOTHER_CONCURRENCY) vanish on reinstall. Durable settings live in
# ${MOTHER_ROOT}/config.env instead: plain `KEY=VALUE` lines, `#` comments,
# optional single/double quotes around the value. Environment variables always
# take precedence over the file. The file is parsed, never sourced, so it
# cannot execute anything.
#
# Sourced by bin/mother and bin/mother-runner; the caller owns shell options
# (bash 3.2, `set -u` safe).

# Space-padded list of vars that mother_config_load took from the file.
MOTHER_CONFIG_FROM_FILE=" "

mother_config_file() {
    echo "${MOTHER_ROOT:-$HOME/.mother}/config.env"
}

# _config_unquote <val> — strip one pair of surrounding single or double quotes.
_config_unquote() {
    local val="$1"
    case "$val" in
        \"*\") val="${val#\"}"; val="${val%\"}" ;;
        \'*\') val="${val#\'}"; val="${val%\'}" ;;
    esac
    printf '%s' "$val"
}

# mother_config_load — export every MOTHER_* assignment in config.env that is
# not already set in the environment.
mother_config_load() {
    local file line key val
    file=$(mother_config_file)
    [ -r "$file" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            MOTHER_[A-Z0-9_]*=*) ;;
            *) continue ;;
        esac
        key="${line%%=*}"
        case "$key" in *[!A-Z0-9_]*) continue ;; esac
        val="${line#*=}"
        val=$(_config_unquote "$val")
        # Env wins: skip anything already set (even to the empty string).
        if eval "[ \"\${$key+set}\" = set ]"; then
            continue
        fi
        export "$key=$val"
        MOTHER_CONFIG_FROM_FILE="${MOTHER_CONFIG_FROM_FILE}${key} "
    done <"$file"
    return 0
}

# mother_config_source <VAR> — where VAR's current value comes from:
# "env", "config file" or "default". Call after mother_config_load and BEFORE
# applying a `${VAR:-default}` fallback.
mother_config_source() {
    local key="$1"
    case "$MOTHER_CONFIG_FROM_FILE" in
        *" $key "*) echo "config file"; return 0 ;;
    esac
    if eval "[ \"\${$key+set}\" = set ]"; then
        echo env
    else
        echo default
    fi
}

# mother_config_get <VAR> — the value VAR has in config.env ("" if absent).
mother_config_get() {
    local file; file=$(mother_config_file)
    [ -r "$file" ] || return 0
    local line val=""
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in "$1="*) val="${line#*=}" ;; esac
    done <"$file"
    val=$(_config_unquote "$val")
    printf '%s' "$val"
}

# mother_config_set <VAR> <value> — add or replace VAR in config.env atomically.
mother_config_set() {
    local key="$1" val="$2" file tmp
    file=$(mother_config_file)
    mkdir -p "$(dirname "$file")"
    tmp="$file.tmp.$$"
    {
        if [ -r "$file" ]; then
            grep -v "^${key}=" "$file" || true
        fi
        printf '%s=%s\n' "$key" "$val"
    } >"$tmp" && mv "$tmp" "$file"
}

# mother_config_migrate_plist <installed-plist> — before `daemon install`
# overwrites the plist, carry its MOTHER_CONCURRENCY into config.env so a
# reinstall never silently resets (or lowers) the operator's concurrency. An
# existing config.env value is kept unless the plist's is higher. Echoes the
# migrated value (nothing if nothing was migrated). Needs plutil (macOS).
mother_config_migrate_plist() {
    local plist="${1:-}" val cur
    [ -f "$plist" ] || return 0
    command -v plutil >/dev/null 2>&1 || return 0
    val=$(plutil -extract EnvironmentVariables.MOTHER_CONCURRENCY raw "$plist" 2>/dev/null) || return 0
    case "$val" in ''|*[!0-9]*) return 0 ;; esac
    [ "$val" -gt 0 ] || return 0
    cur=$(mother_config_get MOTHER_CONCURRENCY)
    case "$cur" in
        ''|*[!0-9]*) ;;
        *) [ "$val" -gt "$cur" ] || return 0 ;;
    esac
    mother_config_set MOTHER_CONCURRENCY "$val" && echo "$val"
}
