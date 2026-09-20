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
