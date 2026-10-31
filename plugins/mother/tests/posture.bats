#!/usr/bin/env bats
# posture.bats — the Bishop -> Mother posture boundary (_normalize_posture).
# Bishop's labels: Pump the brakes | Ease up | Cruise | Push | Put the hammer down.
# Mother's internal vocabulary: conservative | normal | elevated | flush.

load 'test_helper'

setup() {
    setup_mother_env
    # Stub bishop: prints $MOCK_BISHOP_POSTURE verbatim.
    cat > "$_MOCK_BIN/bishop" <<'BISHOP'
#!/usr/bin/env bash
if [ "${1:-}" = "get" ] && [ "${2:-}" = "posture" ]; then
    printf '%s\n' "${MOCK_BISHOP_POSTURE:-Cruise}"
fi
exit 0
BISHOP
    chmod +x "$_MOCK_BIN/bishop"
}

teardown() {
    teardown_mother_env
}

_norm() {
    bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2"' _ "$_LIB_DIR" "$1"
}

@test "normalize: the five current Bishop labels map to Mother's vocabulary" {
    [ "$(_norm 'Pump the brakes' 2>&1)" = "conservative" ]
    [ "$(_norm 'Ease up' 2>&1)" = "conservative" ]
    [ "$(_norm 'Cruise' 2>&1)" = "normal" ]
    [ "$(_norm 'Push' 2>&1)" = "elevated" ]
    [ "$(_norm 'Put the hammer down' 2>&1)" = "flush" ]
}

@test "normalize: legacy labels map to themselves" {
    for l in conservative normal elevated flush; do
        [ "$(_norm "$l" 2>&1)" = "$l" ]
    done
}

@test "normalize: case-insensitive and tolerant of surrounding whitespace/newline" {
    [ "$(_norm 'PUMP THE BRAKES' 2>&1)" = "conservative" ]
    [ "$(_norm 'put the HAMMER down' 2>&1)" = "flush" ]
    [ "$(_norm $'  Push \n' 2>&1)" = "elevated" ]
    [ "$(_norm $'\tEase up\n\n' 2>&1)" = "conservative" ]
}

@test "normalize: inner spaces are not stripped (old squashed form is unknown)" {
    run _norm 'Pumpthebrakes'
    [ "$output" != "conservative" ]
}

@test "normalize: unknown label -> normal on stdout, one stderr line with only the label" {
    out=$(bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2"' _ "$_LIB_DIR" "  Zoom zoom " 2>"$BATS_TEST_TMPDIR/err")
    [ "$out" = "normal" ]
    [ "$(cat "$BATS_TEST_TMPDIR/err")" = 'mother: unrecognized bishop posture "Zoom zoom"; treating as normal' ]
    [ "$(wc -l < "$BATS_TEST_TMPDIR/err" | tr -d ' ')" = "1" ]
}

@test "_resolve_posture: 'Pump the brakes' -> conservative" {
    export MOCK_BISHOP_POSTURE="Pump the brakes"
    run bash -c 'set -u; source "$1/state.sh"; _resolve_posture' _ "$_LIB_DIR"
    [ "$status" -eq 0 ]
    [ "$output" = "conservative" ]
}

@test "_resolve_posture: 'Put the hammer down' -> flush" {
    export MOCK_BISHOP_POSTURE="Put the hammer down"
    run bash -c 'set -u; source "$1/state.sh"; _resolve_posture' _ "$_LIB_DIR"
    [ "$output" = "flush" ]
}

@test "force-start: 'Pump the brakes' is seen as conservative posture" {
    make_job "job-pb" "ready"
    export MOCK_BISHOP_POSTURE="Pump the brakes"
    run mother force-start "job-pb" --yes
    [ "$status" -eq 0 ]
    [[ "$output" =~ "posture=conservative" ]]
    [ "$(jq -r '.detail.posture' < <(grep force_start_requested "$EVENTS_DIR/job-pb.jsonl" | tail -1))" = "conservative" ]
}

@test "drift canary: real bishop's posture is a label Mother recognizes" {
    # Use the real bishop, not the stub.
    real=$(PATH="${PATH#"$_MOCK_BIN":}" command -v bishop || true)
    [ -n "$real" ] || skip "bishop not installed"
    raw=$("$real" get posture 2>/dev/null) || skip "bishop get posture failed"
    run bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2" 2>&1 >/dev/null' _ "$_LIB_DIR" "$raw"
    [ -z "$output" ] || { echo "bishop now prints an unmapped posture: $raw" >&2; false; }
}
