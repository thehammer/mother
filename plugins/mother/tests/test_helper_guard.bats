load 'test_helper'

@test "teardown never deletes an inherited MOTHER_ROOT that setup did not create" {
    real="$(mktemp -d)"; touch "$real/keep"
    export MOTHER_ROOT="$real"; unset _MOTHER_TEST_ROOT
    teardown_mother_env
    [ -f "$real/keep" ]
    rm -rf "$real"
}

@test "setup replaces an inherited MOTHER_ROOT and teardown removes only its own tree" {
    real="$(mktemp -d)"; touch "$real/keep"
    export MOTHER_ROOT="$real"
    setup_mother_env
    [ "$MOTHER_ROOT" != "$real" ]
    mine="$MOTHER_ROOT"
    teardown_mother_env
    [ ! -d "$mine" ]
    [ -f "$real/keep" ]
    rm -rf "$real"
}
