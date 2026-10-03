#!/usr/bin/env bats
# launchd_plist.bats — tests for the launchd agent plist template.
#
# Contract under test: the template at launchd/com.thehammer.mother.plist
# must render (via the same substitutions `_daemon_install` performs) into a
# valid plist that declares AbandonProcessGroup=true. Without that key,
# launchd reaps the whole process group — including live job workers, which
# share the daemon's PGID since `nohup … & disown` does not detach one — on
# every daemon stop/crash/KeepAlive respawn. See CLAUDE.md's "Daemon process
# groups and launchd" section and the resolved bug report
# 2026-08-20-daemon-restart-kills-detached-job-supervisors.md.
#
# macOS-only (plutil-dependent); skips everywhere else.

PLUGIN_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd -P)"
PLIST_SRC="$PLUGIN_DIR/launchd/com.thehammer.mother.plist"

setup() {
    if [ "$(uname -s)" != "Darwin" ] || ! command -v plutil >/dev/null 2>&1; then
        skip "plutil / Darwin only"
    fi

    # Render the template through the same substitutions `_daemon_install`
    # performs (plugins/mother/bin/mother, _daemon_install), using throwaway
    # values so this test doesn't depend on the real environment.
    RENDERED="$BATS_TEST_TMPDIR/com.thehammer.mother.plist"
    sed \
        -e "s|__MOTHER_RUNNER_PATH__|/tmp/fake-runner-path/mother-runner|g" \
        -e "s|__MOTHER_STATE_DIR__|/tmp/fake-mother-state|g" \
        -e "s|__USER_HOME__|/tmp/fake-home|g" \
        "$PLIST_SRC" > "$RENDERED"
}

@test "rendered plist template is valid" {
    run plutil -lint "$RENDERED"
    [ "$status" -eq 0 ]
}

@test "rendered plist declares AbandonProcessGroup=true" {
    run plutil -extract AbandonProcessGroup raw "$RENDERED"
    [ "$status" -eq 0 ]
    [ "$output" = "true" ]
}

@test "rendered plist has no unsubstituted placeholder tokens" {
    run grep -oE '__[A-Z_]*__' "$RENDERED"
    # grep exits 1 when it finds no matches — that's the success case here.
    [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Concurrency survives `mother daemon install` (config.env + plist migration).
# The template deliberately carries no MOTHER_CONCURRENCY, so a reinstall would
# silently reset the daemon to the runner's default of 2 unless the installed
# plist's value is moved into $MOTHER_ROOT/config.env first.

_make_installed_plist() {
    # An "installed" plist that hand-sets MOTHER_CONCURRENCY=$1.
    local out="$BATS_TEST_TMPDIR/installed.plist" conc="$1"
    sed -e "s|<key>PATH</key>|<key>MOTHER_CONCURRENCY</key><string>$conc</string><key>PATH</key>|" \
        "$RENDERED" > "$out"
    echo "$out"
}

_runner_effective() {
    # What a freshly started runner resolves, as "<value>|<source>".
    env -u MOTHER_CONCURRENCY MOTHER_ROOT="$BATS_TEST_TMPDIR/root" \
        "$PLUGIN_DIR/bin/mother-runner" --publish-config-tick >/dev/null 2>&1
    jq -r '"\(.concurrency)|\(.concurrency_source)"' "$BATS_TEST_TMPDIR/root/runner/effective-config.json"
}

@test "shipped template does not hardcode MOTHER_CONCURRENCY" {
    run grep -c MOTHER_CONCURRENCY "$PLIST_SRC"
    [ "$output" = "0" ]
}

@test "a reinstall keeps a non-default concurrency (plist value migrated to config.env)" {
    export MOTHER_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$MOTHER_ROOT"
    local installed; installed=$(_make_installed_plist 3)

    source "$PLUGIN_DIR/lib/config.sh"
    run mother_config_migrate_plist "$installed"
    [ "$output" = "3" ]

    # The reinstalled plist is the bare template: no concurrency in it...
    run grep -c MOTHER_CONCURRENCY "$RENDERED"
    [ "$output" = "0" ]
    # ...yet a fresh runner still resolves 3, from the config file.
    run _runner_effective
    [ "$output" = "3|config file" ]
}

@test "migration never lowers an existing higher config.env value" {
    export MOTHER_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$MOTHER_ROOT"
    echo "MOTHER_CONCURRENCY=5" > "$MOTHER_ROOT/config.env"
    local installed; installed=$(_make_installed_plist 3)

    source "$PLUGIN_DIR/lib/config.sh"
    run mother_config_migrate_plist "$installed"
    [ -z "$output" ]
    run _runner_effective
    [ "$output" = "5|config file" ]
}

@test "migration raises a lower config.env value to the plist's" {
    export MOTHER_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$MOTHER_ROOT"
    echo "MOTHER_CONCURRENCY=2" > "$MOTHER_ROOT/config.env"
    local installed; installed=$(_make_installed_plist 4)

    source "$PLUGIN_DIR/lib/config.sh"
    run mother_config_migrate_plist "$installed"
    [ "$output" = "4" ]
    run _runner_effective
    [ "$output" = "4|config file" ]
}
