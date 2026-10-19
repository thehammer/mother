#!/usr/bin/env bats
# ci_shards.bats — behaviour of scripts/test-shards.sh and scripts/run-tests.sh
# (CI sharding, quarantine retry, strict skips, Go half).
#
# Everything runs against fixtures in a per-test temp dir (under MOTHER_ROOT)
# via MOTHER_TESTS_DIR / MOTHER_BROKER_DIR / MOTHER_TEST_OUT and a stub `go` /
# `gofmt` on PATH. Never starts the broker. A few tests read the REAL tests dir
# (list/pick/check only; nothing is run).

load 'test_helper'

setup() {
    setup_mother_env
    # The suite may itself run in GitHub Actions; nested runs must never write
    # into the real step summary.
    unset GITHUB_STEP_SUMMARY GITHUB_ACTIONS
    # A nested bats that inherits BATS_TEST_TIMEOUT hangs until the countdown fires whenever a nested test
    # fails (CI doesn't set it; a developer might), so the fixture runs never get it.
    unset BATS_TEST_TIMEOUT

    SCRIPTS="$_PLUGIN_DIR/scripts"
    TS="$SCRIPTS/test-shards.sh"
    RT="$SCRIPTS/run-tests.sh"

    FX="$MOTHER_ROOT/fx"
    export MOTHER_TESTS_DIR="$FX/tests"
    export MOTHER_BROKER_DIR="$FX/broker"
    export MOTHER_TEST_OUT="$FX/out"
    mkdir -p "$MOTHER_TESTS_DIR" "$MOTHER_BROKER_DIR"
    unset MOTHER_TEST_STRICT_SKIPS MOTHER_TEST_LANES

    export STUB_GO_LOG="$FX/go.log"
    export MARKER_DIR="$FX/markers"
    mkdir -p "$MARKER_DIR"
    unset STUB_GO_FAIL_TEST STUB_GO_FAIL_BUILD STUB_GO_FAIL_VET STUB_GO_RUN_FAIL STUB_GOFMT_OUT
    make_stub_go
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------- helpers

TAB="$(printf '\t')"

# Stub go + gofmt first on PATH. Logs one line per call:
#   go GOOS=<value> <argv...>      /      gofmt <argv...>
make_stub_go() {
    local d="$FX/stubs"
    mkdir -p "$d"
    cat > "$d/go" <<'EOF'
#!/usr/bin/env bash
echo "go GOOS=${GOOS:-} $*" >> "${STUB_GO_LOG:?}"
case "${1:-}" in
    build)
        if [ -n "${STUB_GO_FAIL_BUILD:-}" ]; then echo "stub go: build failed" >&2; exit 1; fi
        prev=""
        for a in "$@"; do
            if [ "$prev" = "-o" ]; then
                mkdir -p "$(dirname "$a")"; : > "$a"; chmod +x "$a"
            fi
            prev="$a"
        done
        exit 0 ;;
    vet)
        if [ -n "${STUB_GO_FAIL_VET:-}" ]; then echo "stub go: vet failed" >&2; exit 1; fi
        exit 0 ;;
    test)
        case " $* " in
            *" -run "*)
                if [ -n "${STUB_GO_RUN_FAIL:-}" ]; then echo "stub go: quarantined test failed" >&2; exit 1; fi
                exit 0 ;;
        esac
        if [ -n "${STUB_GO_FAIL_TEST:-}" ]; then echo "stub go: test failed" >&2; exit 1; fi
        exit 0 ;;
esac
exit 0
EOF
    cat > "$d/gofmt" <<'EOF'
#!/usr/bin/env bash
echo "gofmt $*" >> "${STUB_GO_LOG:?}"
[ -n "${STUB_GOFMT_OUT:-}" ] && echo "$STUB_GOFMT_OUT"
exit 0
EOF
    chmod +x "$d/go" "$d/gofmt"
    export PATH="$d:$PATH"
}

# mk_bats <name.bats> : a one-test passing file in the tests dir.
mk_bats() {
    printf '@test "ok" {\n  true\n}\n' > "$MOTHER_TESTS_DIR/$1"
}

# mk_marker_bats <name.bats> : passing file that records each time it runs.
mk_marker_bats() {
    cat > "$MOTHER_TESTS_DIR/$1" <<'EOF'
@test "mark" {
  echo ran >> "$MARKER_DIR/$(basename "$BATS_TEST_FILENAME")"
}
EOF
}

mk_failing_bats() {
    printf '@test "boom" {\n  false\n}\n' > "$MOTHER_TESTS_DIR/$1"
}

# make_fixture : 12 files with assorted weights.
make_fixture() {
    local i w ws="9 1 14 3 3 27 5 8 2 11 6 40"
    i=0
    : > "$MOTHER_TESTS_DIR/shard-weights.tsv"
    echo "# fixture weights" >> "$MOTHER_TESTS_DIR/shard-weights.tsv"
    for w in $ws; do
        i=$((i + 1))
        mk_bats "$(printf 'f%02d.bats' "$i")"
        printf 'f%02d.bats\t%s\n' "$i" "$w" >> "$MOTHER_TESTS_DIR/shard-weights.tsv"
    done
}

# lines_in <file> : line count, 0 when missing.
lines_in() {
    if [ -f "$1" ]; then wc -l < "$1" | tr -d ' '; else echo 0; fi
}

# union_of_picks <M> : every file from pick 1..M (sorted).
union_of_picks() {
    local m="$1" n
    n=1
    while [ "$n" -le "$m" ]; do
        "$TS" pick "$n" "$m" || return 1
        n=$((n + 1))
    done
}

assert_partition() {
    local m="$1" expected got dups
    expected="$("$TS" list)"
    got="$(union_of_picks "$m" | sort)"
    dups="$(union_of_picks "$m" | sort | uniq -d)"
    [ -z "$dups" ] || { echo "duplicates for M=$m: $dups"; return 1; }
    [ "$got" = "$(echo "$expected" | sort)" ] || { echo "M=$m union != list"; echo "$got"; return 1; }
}

# ---------------------------------------------------- 1. partition

@test "every file lands in exactly one shard for M=1, 5 and 8 (fixture)" {
    make_fixture
    assert_partition 1
    assert_partition 5
    assert_partition 8
}

@test "every real tests-dir file lands in exactly one shard for M=1, 5 and 8" {
    unset MOTHER_TESTS_DIR MOTHER_BROKER_DIR
    assert_partition 1
    assert_partition 5
    assert_partition 8
    # list matches the actual top-level bats files
    expected="$(cd "$_PLUGIN_DIR/tests" && ls -1 ./*.bats | sed 's|^\./||' | LC_ALL=C sort)"
    [ "$("$TS" list)" = "$expected" ]
}

@test "list prints sorted basenames of top-level bats files only" {
    mk_bats b.bats; mk_bats a.bats; mk_bats c.bats
    mkdir -p "$MOTHER_TESTS_DIR/helpers"
    echo hi > "$MOTHER_TESTS_DIR/notes.txt"
    run "$TS" list
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'a.bats\nb.bats\nc.bats')" ]
}

# ------------------------------------------------ 2. determinism / LPT

@test "assign and pick are deterministic across calls" {
    make_fixture
    a1="$("$TS" assign 5)"; a2="$("$TS" assign 5)"
    [ "$a1" = "$a2" ]
    p1="$("$TS" pick 2 5)"; p2="$("$TS" pick 2 5)"
    [ "$p1" = "$p2" ]
}

@test "assign uses greedy LPT: weights 10,9,8,3,3,2 on 3 shards" {
    for f in a b c d e f; do mk_bats "$f.bats"; done
    printf '# w\na.bats\t10\nb.bats\t9\nc.bats\t8\nd.bats\t3\ne.bats\t3\nf.bats\t2\n' \
        > "$MOTHER_TESTS_DIR/shard-weights.tsv"
    run "$TS" assign 3
    [ "$status" -eq 0 ]
    got="$(echo "$output" | cut -f1,2 | sort)"
    want="$(printf '1\ta.bats\n1\tf.bats\n2\tb.bats\n2\te.bats\n3\tc.bats\n3\td.bats' | sort)"
    [ "$got" = "$want" ]
}

@test "pick returns a shard's files heaviest first" {
    for f in a b c d e f; do mk_bats "$f.bats"; done
    printf 'a.bats\t10\nb.bats\t9\nc.bats\t8\nd.bats\t3\ne.bats\t3\nf.bats\t2\n' \
        > "$MOTHER_TESTS_DIR/shard-weights.tsv"
    run "$TS" pick 1 3
    [ "$status" -eq 0 ]
    [ "$output" = "$(printf 'a.bats\nf.bats')" ]
    run "$TS" pick 3 3
    [ "$output" = "$(printf 'c.bats\nd.bats')" ]
}

@test "pick rejects out-of-range or non-integer shard numbers" {
    make_fixture
    run "$TS" pick 0 5; [ "$status" -ne 0 ]
    run "$TS" pick 6 5; [ "$status" -ne 0 ]
    run "$TS" pick x 5; [ "$status" -ne 0 ]
    run "$TS" pick 1 y; [ "$status" -ne 0 ]
}

# ------------------------------------------------ 3. unweighted files

@test "a file with no weight is still assigned exactly once, at the median weight" {
    for f in a b c z; do mk_bats "$f.bats"; done
    printf 'a.bats\t10\nb.bats\t2\nc.bats\t4\n' > "$MOTHER_TESTS_DIR/shard-weights.tsv"
    run "$TS" assign 3
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | cut -f2 | grep -c '^z.bats$')" -eq 1 ]
    [ "$(echo "$output" | awk -F'\t' '$2=="z.bats"{print $3}')" = "4" ]
    assert_partition 3
}

@test "a missing shard-weights.tsv still assigns every file once" {
    mk_bats a.bats; mk_bats b.bats; mk_bats c.bats
    assert_partition 2
}

# ---------------------------------------------------------- 4. check

@test "check passes on a clean fixture and prints the matrix JSON on stdout" {
    make_fixture
    out="$("$TS" check 5 2>/dev/null)"
    [ "$out" = "[1,2,3,4,5]" ]
}

@test "check prints a per-shard weight table on stderr" {
    make_fixture
    err="$("$TS" check 3 2>&1 >/dev/null)"
    [ -n "$err" ]
}

@test "check fails on a bats file in a subdirectory" {
    make_fixture
    mkdir -p "$MOTHER_TESTS_DIR/sub"
    mk_bats_in_sub() { printf '@test "x" {\n  true\n}\n' > "$MOTHER_TESTS_DIR/sub/hidden.bats"; }
    mk_bats_in_sub
    run "$TS" check 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"hidden.bats"* ]]
}

@test "check fails when quarantine.tsv names a test that does not exist" {
    make_fixture
    printf 'f01.bats\tno such test\thttps://github.com/thehammer/mother/issues/12\tflaky\n' \
        > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"no such test"* ]]
}

@test "check fails when quarantine.tsv names a bats file that does not exist" {
    make_fixture
    printf 'ghost.bats\tok\thttps://github.com/thehammer/mother/issues/12\t\n' \
        > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"ghost.bats"* ]]
}

@test "check fails when a quarantine row has no issue URL" {
    make_fixture
    printf 'f01.bats\tok\t\tflaky\n' > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"f01.bats"* ]]
}

@test "check fails when a quarantine issue URL does not match the mother issues pattern" {
    make_fixture
    printf 'f01.bats\tok\thttps://github.com/someone/else/issues/12\tflaky\n' \
        > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    printf 'f01.bats\tok\thttps://github.com/thehammer/mother/issues/abc\tflaky\n' \
        > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
}

@test "check fails on a duplicate quarantine row" {
    make_fixture
    {
        printf 'f01.bats\tok\thttps://github.com/thehammer/mother/issues/12\tfirst\n'
        printf 'f01.bats\tok\thttps://github.com/thehammer/mother/issues/13\tsecond\n'
    } > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"f01.bats"* ]]
}

@test "check accepts a valid quarantine row, comments and blank lines" {
    make_fixture
    {
        printf '# comment\n\n'
        printf 'f01.bats\tok\thttps://github.com/thehammer/mother/issues/12\t\n'
    } > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -eq 0 ]
}

@test "check fails on an allowed-skip row for a missing test" {
    make_fixture
    printf 'f01.bats\tnot a test\tneeds docker\n' > "$MOTHER_TESTS_DIR/ci-allowed-skips.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a test"* ]]
}

@test "check fails on an allowed-skip row for a missing file or with an empty reason" {
    make_fixture
    printf 'ghost.bats\tok\tneeds docker\n' > "$MOTHER_TESTS_DIR/ci-allowed-skips.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    printf 'f01.bats\tok\t\n' > "$MOTHER_TESTS_DIR/ci-allowed-skips.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
}

@test "check accepts a valid allowed-skip row" {
    make_fixture
    printf 'f01.bats\tok\tneeds docker\n' > "$MOTHER_TESTS_DIR/ci-allowed-skips.tsv"
    run "$TS" check 5
    [ "$status" -eq 0 ]
}

@test "check fails when a go quarantine row names a test not in the broker package" {
    make_fixture
    printf 'package main\n\nfunc TestReal(t *testing.T) {}\n' > "$MOTHER_BROKER_DIR/x_test.go"
    printf 'go\tTestMissing\thttps://github.com/thehammer/mother/issues/12\t\n' \
        > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -ne 0 ]
    [[ "$output" == *"TestMissing"* ]]
}

@test "check accepts a go quarantine row for an existing go test" {
    make_fixture
    printf 'package main\n\nfunc TestReal(t *testing.T) {}\n' > "$MOTHER_BROKER_DIR/x_test.go"
    printf 'go\tTestReal\thttps://github.com/thehammer/mother/issues/12\t\n' \
        > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$TS" check 5
    [ "$status" -eq 0 ]
}

@test "check passes on the real repo tests dir with M=5" {
    unset MOTHER_TESTS_DIR MOTHER_BROKER_DIR
    out="$("$TS" check 5 2>/dev/null)"
    [ "$out" = "[1,2,3,4,5]" ]
}

# --------------------------------------------- 5. --shard validation

@test "--shard rejects malformed or out-of-range specs and runs nothing" {
    mk_marker_bats a.bats
    for spec in 0/5 6/5 x/y 3 " "; do
        run "$RT" --shard "$spec"
        [ "$status" -ne 0 ]
    done
    [ ! -s "$STUB_GO_LOG" ]
    [ ! -d "$MOTHER_TEST_OUT/tap" ]
    [ ! -f "$MARKER_DIR/a.bats" ]
}

# --------------------------------------- 6. quarantine retry (D5)

flaky_file() {
    # one quarantined flaky test (regex-special name) + one plain passing test
    cat > "$MOTHER_TESTS_DIR/flaky.bats" <<'EOF'
@test "flaky: a.b (c)" {
  echo run >> "$FLAKY_STATE"
  [ "$(wc -l < "$FLAKY_STATE" | tr -d ' ')" -ge "${FLAKY_PASS_AT:-2}" ]
}

@test "steady" {
  echo run >> "$STEADY_STATE"
}
EOF
    export FLAKY_STATE="$FX/flaky.state" STEADY_STATE="$FX/steady.state"
    : > "$FLAKY_STATE"; : > "$STEADY_STATE"
}

QURL="https://github.com/thehammer/mother/issues/321"

@test "a quarantined test that fails then passes keeps the shard green with a warning" {
    flaky_file
    printf 'flaky.bats\tflaky: a.b (c)\t%s\tflaky on CI\n' "$QURL" > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
    warn="$(echo "$output" | grep -E '^::warning' | head -1)"
    [[ "$warn" == *"flaky: a.b (c)"* ]]
    [[ "$warn" == *"$QURL"* ]]
    # exactly the first run plus one retry of that test alone
    [ "$(lines_in "$FLAKY_STATE")" -eq 2 ]
    # the retry never re-runs the rest of the file
    [ "$(lines_in "$STEADY_STATE")" -eq 1 ]
}

@test "a quarantine retry is recorded in GITHUB_STEP_SUMMARY when set" {
    flaky_file
    printf 'flaky.bats\tflaky: a.b (c)\t%s\t\n' "$QURL" > "$MOTHER_TESTS_DIR/quarantine.tsv"
    export GITHUB_STEP_SUMMARY="$FX/summary.md"
    : > "$GITHUB_STEP_SUMMARY"
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
    grep -F "flaky: a.b (c)" "$GITHUB_STEP_SUMMARY"
    grep -F "$QURL" "$GITHUB_STEP_SUMMARY"
}

@test "the same failing test without a quarantine row is red immediately with no retry" {
    flaky_file
    run "$RT" --shard 1/1
    [ "$status" -ne 0 ]
    [ "$(lines_in "$FLAKY_STATE")" -eq 1 ]
    [[ "$output" != *"::warning"* ]]
}

@test "a quarantined test that fails twice is red" {
    flaky_file
    export FLAKY_PASS_AT=99
    printf 'flaky.bats\tflaky: a.b (c)\t%s\t\n' "$QURL" > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$RT" --shard 1/1
    [ "$status" -ne 0 ]
    [ "$(lines_in "$FLAKY_STATE")" -eq 2 ]
}

@test "a failing non-quarantined test in a file with a quarantined one is not forgiven" {
    cat > "$MOTHER_TESTS_DIR/mixed.bats" <<'EOF'
@test "quarantined flaky" {
  echo run >> "$FLAKY_STATE"
  [ "$(wc -l < "$FLAKY_STATE" | tr -d ' ')" -ge 2 ]
}

@test "real failure" {
  echo run >> "$REAL_STATE"
  false
}
EOF
    export FLAKY_STATE="$FX/flaky.state" REAL_STATE="$FX/real.state"
    : > "$FLAKY_STATE"; : > "$REAL_STATE"
    printf 'mixed.bats\tquarantined flaky\t%s\t\n' "$QURL" > "$MOTHER_TESTS_DIR/quarantine.tsv"
    run "$RT" --shard 1/1
    [ "$status" -ne 0 ]
    [ "$(lines_in "$REAL_STATE")" -eq 1 ]
}

# ----------------------------------------------- 7. strict skips (D6)

skippy_file() {
    cat > "$MOTHER_TESTS_DIR/skippy.bats" <<'EOF'
@test "needs docker" {
  skip "no docker here"
}
EOF
}

@test "strict skips: an unlisted skip fails the shard, naming file and test" {
    skippy_file
    export MOTHER_TEST_STRICT_SKIPS=1
    run "$RT" --shard 1/1
    [ "$status" -ne 0 ]
    [[ "$output" == *"skippy.bats"* ]]
    [[ "$output" == *"needs docker"* ]]
}

@test "strict skips: a skip listed in ci-allowed-skips.tsv passes" {
    skippy_file
    printf 'skippy.bats\tneeds docker\tno docker on runners\n' > "$MOTHER_TESTS_DIR/ci-allowed-skips.tsv"
    export MOTHER_TEST_STRICT_SKIPS=1
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
}

@test "skips are fine when strict mode is off" {
    skippy_file
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
}

# ------------------------------------------- 8. halves and failures

@test "no-arg mode runs bats even when the Go half fails" {
    mk_marker_bats a.bats
    export STUB_GO_FAIL_TEST=1
    run "$RT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"go: FAIL"* ]]
    [[ "$output" == *"bats: PASS"* ]]
    [ -f "$MARKER_DIR/a.bats" ]
}

@test "no-arg mode reports a bats failure with the Go half green" {
    mk_failing_bats a.bats
    run "$RT"
    [ "$status" -ne 0 ]
    [[ "$output" == *"go: PASS"* ]]
    [[ "$output" == *"bats: FAIL"* ]]
}

@test "no-arg mode passes when both halves pass and runs every file" {
    mk_marker_bats a.bats; mk_marker_bats b.bats
    run "$RT"
    [ "$status" -eq 0 ]
    [[ "$output" == *"go: PASS"* ]]
    [[ "$output" == *"bats: PASS"* ]]
    [ -f "$MARKER_DIR/a.bats" ] && [ -f "$MARKER_DIR/b.bats" ]
}

@test "a broker build failure fails the shard" {
    mk_marker_bats a.bats
    export STUB_GO_FAIL_BUILD=1
    run "$RT" --shard 1/1
    [ "$status" -ne 0 ]
}

@test "the broker is rebuilt on every shard run" {
    mk_bats a.bats
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
    [ "$(grep -c ' build ' "$STUB_GO_LOG")" -ge 2 ]
}

@test "--shard does not run the Go half" {
    mk_bats a.bats
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
    ! grep -q ' test ' "$STUB_GO_LOG"
    ! grep -q ' vet ' "$STUB_GO_LOG"
    ! grep -q '^gofmt' "$STUB_GO_LOG"
}

@test "--shard keeps going after a failing file and still runs the rest" {
    mk_failing_bats a.bats
    mk_marker_bats b.bats
    mk_marker_bats c.bats
    run "$RT" --shard 1/1
    [ "$status" -ne 0 ]
    [ -f "$MARKER_DIR/b.bats" ] && [ -f "$MARKER_DIR/c.bats" ]
}

# ------------------------------------------------------ --go-only

@test "--go-only runs fmt, both vets, build and test, and no bats" {
    mk_marker_bats a.bats
    run "$RT" --go-only
    [ "$status" -eq 0 ]
    grep -q '^gofmt -l' "$STUB_GO_LOG"
    grep -q '^go GOOS= vet \./\.\.\.' "$STUB_GO_LOG"
    grep -q '^go GOOS=darwin vet \./\.\.\.' "$STUB_GO_LOG"
    grep -q ' build ' "$STUB_GO_LOG"
    grep -q ' test .*-count=1' "$STUB_GO_LOG"
    [ ! -f "$MARKER_DIR/a.bats" ]
}

@test "--go-only fails on gofmt output but still runs the later steps" {
    export STUB_GOFMT_OUT="broken.go"
    run "$RT" --go-only
    [ "$status" -ne 0 ]
    grep -q ' test ' "$STUB_GO_LOG"
}

@test "--go-only fails on a vet failure but still runs build and test" {
    export STUB_GO_FAIL_VET=1
    run "$RT" --go-only
    [ "$status" -ne 0 ]
    grep -q ' build ' "$STUB_GO_LOG"
    grep -q ' test ' "$STUB_GO_LOG"
}

@test "--go-only fails when go test fails" {
    export STUB_GO_FAIL_TEST=1
    run "$RT" --go-only
    [ "$status" -ne 0 ]
}

go_quarantine_fixture() {
    printf 'package main\n\nfunc TestFlaky(t *testing.T) {}\nfunc TestOther(t *testing.T) {}\n' \
        > "$MOTHER_BROKER_DIR/x_test.go"
    printf 'go\tTestFlaky\t%s\tflaky\n' "$QURL" > "$MOTHER_TESTS_DIR/quarantine.tsv"
}

@test "quarantined go tests are excluded from the main run and run alone once when they pass" {
    go_quarantine_fixture
    run "$RT" --go-only
    [ "$status" -eq 0 ]
    grep -F -- '-skip ^(TestFlaky)$' "$STUB_GO_LOG"
    [ "$(grep -c -F -- '-run ^TestFlaky$' "$STUB_GO_LOG")" -eq 1 ]
}

@test "a quarantined go test that fails is retried once and is red when it fails again" {
    go_quarantine_fixture
    export STUB_GO_RUN_FAIL=1
    run "$RT" --go-only
    [ "$status" -ne 0 ]
    [ "$(grep -c -F -- '-run ^TestFlaky$' "$STUB_GO_LOG")" -eq 2 ]
}

# ------------------------------------- 9. timings and TAP artifacts

@test "a shard run writes one timings line per file and a TAP file per file" {
    mk_bats a.bats; mk_bats b.bats; mk_bats c.bats
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
    [ "$(lines_in "$MOTHER_TEST_OUT/timings.tsv")" -eq 3 ]
    for f in a b c; do
        grep -q "^$f.bats$TAB[0-9]" "$MOTHER_TEST_OUT/timings.tsv"
        [ -s "$MOTHER_TEST_OUT/tap/$f.bats.tap" ]
        grep -q '^ok ' "$MOTHER_TEST_OUT/tap/$f.bats.tap"
        [[ "$output" == *"$f.bats"* ]]
    done
}

@test "shards 1/2 and 2/2 together run every file exactly once" {
    make_fixture
    for f in "$MOTHER_TESTS_DIR"/f*.bats; do mk_marker_bats "$(basename "$f")"; done
    run "$RT" --shard 1/2
    [ "$status" -eq 0 ]
    run "$RT" --shard 2/2
    [ "$status" -eq 0 ]
    for f in "$MOTHER_TESTS_DIR"/f*.bats; do
        [ "$(lines_in "$MARKER_DIR/$(basename "$f")")" -eq 1 ]
    done
}

@test "targeted mode runs only the named files, builds the broker, and skips the Go half" {
    mk_marker_bats a.bats; mk_marker_bats b.bats; mk_marker_bats c.bats
    run "$RT" "$MOTHER_TESTS_DIR/a.bats" "$MOTHER_TESTS_DIR/c.bats"
    [ "$status" -eq 0 ]
    [ -f "$MARKER_DIR/a.bats" ] && [ -f "$MARKER_DIR/c.bats" ]
    [ ! -f "$MARKER_DIR/b.bats" ]
    grep -q ' build ' "$STUB_GO_LOG"
    ! grep -q ' test ' "$STUB_GO_LOG"
    [ "$(lines_in "$MOTHER_TEST_OUT/timings.tsv")" -eq 2 ]
}

# ------------------------------------------------------- 10. lanes

@test "MOTHER_TEST_LANES=2 runs every file exactly once" {
    for f in a b c d e f; do mk_marker_bats "$f.bats"; done
    export MOTHER_TEST_LANES=2
    run "$RT" --shard 1/1
    [ "$status" -eq 0 ]
    for f in a b c d e f; do
        [ "$(lines_in "$MARKER_DIR/$f.bats")" -eq 1 ]
    done
    [ "$(lines_in "$MOTHER_TEST_OUT/timings.tsv")" -eq 6 ]
}

@test "MOTHER_TEST_LANES=2 still fails the shard when a file fails" {
    for f in a b c; do mk_marker_bats "$f.bats"; done
    mk_failing_bats d.bats
    export MOTHER_TEST_LANES=2
    run "$RT" --shard 1/1
    [ "$status" -ne 0 ]
    for f in a b c; do
        [ "$(lines_in "$MARKER_DIR/$f.bats")" -eq 1 ]
    done
}

# ------------------------------------------- 11. weights and lanes

@test "weights merges timings dirs, keeps old values for untouched files, drops vanished files" {
    mk_bats a.bats; mk_bats b.bats; mk_bats c.bats; mk_bats untouched.bats; mk_bats quick.bats
    printf '# old\na.bats\t100\nb.bats\t50\nc.bats\t9\nuntouched.bats\t33\nquick.bats\t8\ngone.bats\t4\n' \
        > "$MOTHER_TESTS_DIR/shard-weights.tsv"
    mkdir -p "$FX/t1/x" "$FX/t2/y"
    printf 'a.bats\t7\nb.bats\t3\n' > "$FX/t1/x/timings.tsv"
    printf 'c.bats\t20\nquick.bats\t0.2\n' > "$FX/t2/y/timings.tsv"
    run "$TS" weights "$FX/t1" "$FX/t2"
    [ "$status" -eq 0 ]
    data="$(grep -v '^#' "$MOTHER_TESTS_DIR/shard-weights.tsv" | grep -v '^$')"
    want="$(printf 'a.bats\t7\nb.bats\t3\nc.bats\t20\nquick.bats\t1\nuntouched.bats\t33')"
    [ "$data" = "$want" ]
    head -1 "$MOTHER_TESTS_DIR/shard-weights.tsv" | grep -q '^#'
}

@test "lanes partitions the given files exactly once using LPT" {
    for f in a b c d; do mk_bats "$f.bats"; done
    printf 'a.bats\t10\nb.bats\t9\nc.bats\t2\nd.bats\t1\n' > "$MOTHER_TESTS_DIR/shard-weights.tsv"
    run "$TS" lanes 2 a.bats b.bats c.bats d.bats
    [ "$status" -eq 0 ]
    got="$(echo "$output" | sort)"
    want="$(printf '1\ta.bats\n1\td.bats\n2\tb.bats\n2\tc.bats' | sort)"
    [ "$got" = "$want" ]
}

@test "lanes covers every file exactly once without weights" {
    for f in a b c d; do mk_bats "$f.bats"; done
    run "$TS" lanes 2 a.bats b.bats c.bats d.bats
    [ "$status" -eq 0 ]
    [ "$(echo "$output" | cut -f2 | sort)" = "$(printf 'a.bats\nb.bats\nc.bats\nd.bats')" ]
    [ -z "$(echo "$output" | cut -f1 | grep -v '^[12]$')" ]
}
