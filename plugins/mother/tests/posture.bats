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
    [ "$(_norm 'Ease up' 2>&1)" = "normal" ]
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
    [ "$(_norm $'\tEase up\n\n' 2>&1)" = "normal" ]
}

@test "normalize: runs of inner whitespace are squashed" {
    [ "$(_norm 'Pump  the   brakes' 2>&1)" = "conservative" ]
    [ "$(_norm $'Put the\thammer  down' 2>&1)" = "flush" ]
}

@test "normalize: empty or whitespace-only input -> normal, silently" {
    out=$(bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2"' _ "$_LIB_DIR" "" 2>"$BATS_TEST_TMPDIR/err")
    [ "$out" = "normal" ]
    [ ! -s "$BATS_TEST_TMPDIR/err" ]
    out=$(bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2"' _ "$_LIB_DIR" $'  \n\t ' 2>"$BATS_TEST_TMPDIR/err")
    [ "$out" = "normal" ]
    [ ! -s "$BATS_TEST_TMPDIR/err" ]
}

@test "normalize: unrecognized value is truncated to 40 characters in the log line" {
    long=$(printf 'x%.0s' $(seq 1 100))
    bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2"' _ "$_LIB_DIR" "$long" 2>"$BATS_TEST_TMPDIR/err" >/dev/null
    [ "$(cat "$BATS_TEST_TMPDIR/err")" = "mother: unrecognized bishop posture \"$(printf 'x%.0s' $(seq 1 40))\"; treating as normal" ]
}

@test "normalize: multi-line and ANSI-coloured values log as one clean line" {
    raw=$'\033[31mTraceback\033[0m (most recent)\nline two\nline three'
    bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2"' _ "$_LIB_DIR" "$raw" 2>"$BATS_TEST_TMPDIR/err" >/dev/null
    [ "$(wc -l < "$BATS_TEST_TMPDIR/err" | tr -d ' ')" = "1" ]
    ! grep -q $'\033' "$BATS_TEST_TMPDIR/err"
    grep -q 'unrecognized bishop posture "Traceback (most recent)line two' "$BATS_TEST_TMPDIR/err"
    [ "$(sed -e 's/^[^"]*"//' -e 's/";.*$//' "$BATS_TEST_TMPDIR/err" | tr -d '\n' | wc -c | tr -d ' ')" -le 40 ]
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

@test "_resolve_posture: bishop failing or printing nothing -> normal with no stderr noise" {
    export MOCK_BISHOP_POSTURE=""
    run bash -c 'set -u; source "$1/state.sh"; _resolve_posture 2>&1' _ "$_LIB_DIR"
    [ "$output" = "normal" ]
    cat > "$_MOCK_BIN/bishop" <<'BISHOP'
#!/usr/bin/env bash
exit 1
BISHOP
    run bash -c 'set -u; source "$1/state.sh"; _resolve_posture 2>&1' _ "$_LIB_DIR"
    [ "$output" = "normal" ]
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

@test "vocabulary canary: every label in the vendored Bishop fixture maps to its expected class" {
    fixture="$BATS_TEST_DIRNAME/fixtures/bishop-posture-labels.txt"
    [ "$(grep -c . "$fixture")" -eq 5 ]
    while IFS= read -r label; do
        [ -n "$label" ] || continue
        case "$label" in
            "Pump the brakes")     want=conservative ;;
            "Ease up"|"Cruise")    want=normal ;;
            "Push")                want=elevated ;;
            "Put the hammer down") want=flush ;;
            *) echo "fixture label has no expected class in this test: $label" >&2; false ;;
        esac
        err=$(bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2" 2>&1 >/dev/null' _ "$_LIB_DIR" "$label")
        [ -z "$err" ] || { echo "unmapped Bishop label: $label" >&2; false; }
        got=$(bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2" 2>/dev/null' _ "$_LIB_DIR" "$label")
        [ "$got" = "$want" ] || { echo "label '$label' maps to '$got', expected '$want'" >&2; false; }
    done < "$fixture"
}

# Finds the real bishop: drops $_MOCK_BIN wherever it sits on PATH, then refuses a result under it.
_real_bishop() {
    local clean="" dir old_ifs="$IFS"
    IFS=:
    for dir in $PATH; do
        [ "$dir" = "$_MOCK_BIN" ] && continue
        clean="${clean:+$clean:}$dir"
    done
    IFS="$old_ifs"
    local found
    found=$(PATH="$clean" command -v bishop || true)
    case "$found" in "$_MOCK_BIN"/*) return 1 ;; esac
    printf '%s' "$found"
}

@test "local drift canary: real bishop posture is a label Mother recognizes" {
    # Use the real bishop, not the stub. Listed in ci-allowed-skips.tsv.
    real=$(_real_bishop)
    [ -n "$real" ] || skip "bishop not installed"
    raw=$("$real" get posture 2>/dev/null) || skip "bishop get posture failed"
    [ -n "$raw" ] || { echo "bishop printed an empty posture" >&2; false; }
    run bash -c 'set -u; source "$1/state.sh"; _normalize_posture "$2" 2>&1 >/dev/null' _ "$_LIB_DIR" "$raw"
    [ -z "$output" ] || { echo "bishop now prints an unmapped posture: $raw" >&2; false; }
    # Every level Bishop documents must be in the vendored fixture, and vice versa, so a rename or an
    # added level fails here instead of rotting the CI canary.
    if help=$("$real" --help 2>/dev/null) && grep -q "POSTURE LEVELS" <<<"$help"; then
        live=$(sed -n '/POSTURE LEVELS/,/^$/p' <<<"$help" \
            | grep -o -E '^[[:space:]]+(Pump the brakes|Ease up|Cruise|Push|Put the hammer down)' \
            | sed -E 's/^[[:space:]]+//' | sort)
        fixture_sorted=$(grep . "$BATS_TEST_DIRNAME/fixtures/bishop-posture-labels.txt" | sort)
        [ "$live" = "$fixture_sorted" ] || { printf 'bishop --help levels differ from the fixture\nlive:\n%s\nfixture:\n%s\n' "$live" "$fixture_sorted" >&2; false; }
    fi
}
