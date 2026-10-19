#!/usr/bin/env bash
# run-tests.sh — the one entry point for the Mother test suite (Go broker + bats), locally and in CI.
#
# Usage:
#   run-tests.sh                      broker build, Go half, then bats over ALL files. Both halves always run;
#                                     prints `go: PASS|FAIL` and `bats: PASS|FAIL`; non-zero if either failed.
#   run-tests.sh --go-only            Go half only: gofmt -l (any file listed fails), go vet (native and
#                                     GOOS=darwin), go build, go test -count=1 (quarantined tests run separately).
#   run-tests.sh --shard N/M          what a CI shard runs: rebuild the broker (a failed build fails the shard),
#                                     then bats over `test-shards.sh pick N M`, one bats process per file.
#   run-tests.sh a.bats [b.bats ...]  targeted run: rebuild the broker, run just those files (no Go half).
#                                     Other args in this mode are passed to every bats invocation.
#   run-tests.sh [bats options]       anything else: Go half, then `bats <tests dir> [options]` as before.
#
# Per-file loop (--shard, targeted, no-args): files run sequentially, a failing file doesn't stop the rest. Each
# file's TAP goes to $MOTHER_TEST_OUT/tap/<file>.tap and its wall seconds to $MOTHER_TEST_OUT/timings.tsv
# (MOTHER_TEST_OUT defaults to a mktemp dir). A markdown summary table is appended to $GITHUB_STEP_SUMMARY.
#   - Quarantine (tests/quarantine.tsv): a failing quarantined test is re-run once, alone. Pass on retry = green
#     plus a ::warning:: and a summary line; fail twice = red. Any other failing test is red, no retry.
#   - MOTHER_TEST_STRICT_SKIPS=1: a TAP `# skip` fails the file unless listed in tests/ci-allowed-skips.tsv.
#   - MOTHER_TEST_LANES=K (default 1): split the file list into K LPT lanes run concurrently.
#
# Env: MOTHER_TESTS_DIR, MOTHER_BROKER_DIR (fixture overrides, see tests/ci_shards.bats), MOTHER_TEST_OUT.
# Requires bats and Go (version in broker/.tool-versions). Bash-3.2-safe; deliberately exec-free so the
# summary prints.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TESTS_DIR="${MOTHER_TESTS_DIR:-$PLUGIN_DIR/tests}"
BROKER_DIR="${MOTHER_BROKER_DIR:-$PLUGIN_DIR/broker}"
export MOTHER_TESTS_DIR="$TESTS_DIR" MOTHER_BROKER_DIR="$BROKER_DIR"
QUARANTINE="$TESTS_DIR/quarantine.tsv"
ALLOWED_SKIPS="$TESTS_DIR/ci-allowed-skips.tsv"
SHARDS_SH="$SCRIPT_DIR/test-shards.sh"
STRICT_SKIPS="${MOTHER_TEST_STRICT_SKIPS:-0}"
LANES="${MOTHER_TEST_LANES:-1}"

if [ -z "${MOTHER_TEST_OUT:-}" ]; then
    MOTHER_TEST_OUT="$(mktemp -d)"
fi
OUT="$MOTHER_TEST_OUT"

BATS_EXTRA=()

die() { echo "run-tests: $*" >&2; exit 2; }

# --- helpers ----------------------------------------------------------------------------------------

_summary() { # append a line to the GitHub step summary, when there is one
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] && printf '%s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
    return 0
}

_re_escape() { printf '%s' "$1" | sed 's/[][\.^$*+?(){}|]/\\&/g'; }

# <target> <name> -> prints the quarantine issue URL, status 0 when quarantined.
_quarantine_url() {
    [ -f "$QUARANTINE" ] || return 1
    awk -F'\t' -v t="$1" -v n="$2" '
        /^#/ { next }
        $1 == t && $2 == n { print $3; found = 1; exit }
        END { exit found ? 0 : 1 }' "$QUARANTINE"
}

_skip_allowed() { # <file> <name>
    [ -f "$ALLOWED_SKIPS" ] || return 1
    awk -F'\t' -v f="$1" -v n="$2" '
        /^#/ { next }
        $1 == f && $2 == n { found = 1; exit }
        END { exit found ? 0 : 1 }' "$ALLOWED_SKIPS"
}

_tap_failed() { # names of failing tests
    awk '/^not ok [0-9]+ /{ sub(/^not ok [0-9]+ /, ""); sub(/ # timeout after .*$/, ""); print }' "$1"
}

_tap_skipped() {
    awk '/^ok [0-9]+ .* # skip/{ sub(/^ok [0-9]+ /, ""); sub(/ # skip.*$/, ""); print }' "$1"
}

_tap_count() { grep -cE '^(not )?ok [0-9]+ ' "$1"; }

_bats() { # <tap out> <args...> : bats --tap, never reading our stdin
    local tap="$1"
    shift
    bats --tap --print-output-on-failure ${BATS_EXTRA[@]+"${BATS_EXTRA[@]}"} "$@" < /dev/null > "$tap" 2>&1
}

_build_broker() {
    echo "== building broker =="
    "$SCRIPT_DIR/build-broker.sh"
}

# --- Go half ----------------------------------------------------------------------------------------

_go_steps() { # runs in $BROKER_DIR; returns 1 if any step failed (later steps still run)
    local rc=0 out fmt_rc names skip_re name url
    echo "== gofmt =="
    out="$(gofmt -l . 2>&1)"; fmt_rc=$?
    if [ -n "$out" ] || [ "$fmt_rc" -ne 0 ]; then
        echo "gofmt: these files need formatting (gofmt -w):"
        echo "$out"
        rc=1
    fi
    echo "== go vet =="
    go vet ./... || rc=1
    echo "== go vet (GOOS=darwin) =="
    GOOS=darwin go vet ./... || rc=1
    echo "== go build =="
    go build ./... || rc=1

    names=""
    if [ -f "$QUARANTINE" ]; then
        names="$(awk -F'\t' '/^#/{next} $1=="go"{print $2}' "$QUARANTINE")"
    fi
    skip_re=""
    for name in $names; do skip_re="$skip_re${skip_re:+|}$name"; done

    echo "== go test ./... =="
    if [ -n "$skip_re" ]; then
        go test -count=1 -skip "^($skip_re)\$" ./... || rc=1
    else
        go test -count=1 ./... || rc=1
    fi

    for name in $names; do
        url="$(_quarantine_url go "$name")"
        echo "== go test (quarantined) $name =="
        if go test -count=1 -run "^$name\$" ./...; then
            continue
        fi
        echo "quarantined go test $name failed; retrying once ($url)"
        if go test -count=1 -run "^$name\$" ./...; then
            echo "::warning title=Quarantined test retried::go $name passed only on retry ($url)"
            _summary "- :warning: go \`$name\` passed only on retry — $url"
        else
            echo "quarantined go test $name failed twice ($url)"
            rc=1
        fi
    done
    return "$rc"
}

_go_half() {
    if ! command -v go >/dev/null 2>&1; then
        echo "run-tests: go not found on PATH (the Go half never skips)" >&2
        return 1
    fi
    ( cd "$BROKER_DIR" && _go_steps )
}

# --- bats per-file loop -----------------------------------------------------------------------------

# Re-run one quarantined test alone. Prints message lines; returns 1 when it still fails (or breaks strict skips).
_retry_quarantined() { # <file> <name> <url> <retry tap>
    local file="$1" name="$2" url="$3" rtap="$4" base skipmsg rc
    base="$(basename "$file")"
    _bats "$rtap" --filter "^$(_re_escape "$name")\$" "$file"; rc=$?
    if [ "$rc" -ne 0 ] || [ "$(_tap_count "$rtap")" -lt 1 ] || [ -n "$(_tap_failed "$rtap")" ]; then
        echo "  quarantined test failed twice: \"$name\" ($url)"
        return 1
    fi
    echo "::warning title=Quarantined test retried::$base: \"$name\" passed only on retry ($url)"
    _summary "- :warning: \`$base\` \"$name\" passed only on retry — $url"
    skipmsg="$(_strict_skips "$base" "$rtap")"
    [ -z "$skipmsg" ] || { echo "$skipmsg"; return 1; }
}

# Run one bats file with quarantine retry and strict skips; write $OUT/results/<file>.tsv and print the outcome.
_run_one_file() { # <path>
    local file="$1" base tap start secs result=PASS retries=0 failed name url msg="" out tests rc
    base="$(basename "$file")"
    tap="$OUT/tap/$base.tap"
    start="$(date +%s)"

    _bats "$tap" "$file"; rc=$?
    failed="$(_tap_failed "$tap")"
    if [ -z "$failed" ] && [ "$rc" -ne 0 ]; then
        result=FAIL
        msg="${msg}  bats exited $rc without a failing test (load/syntax error?)
"
    fi
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        if url="$(_quarantine_url "$base" "$name")"; then
            retries=$((retries + 1))
            out="$(_retry_quarantined "$file" "$name" "$url" "$OUT/tap/$base.retry$retries.tap")" || result=FAIL
            msg="${msg}${out}
"
        else
            result=FAIL
            msg="${msg}  FAILED: $base: \"$name\"
"
        fi
    done <<EOF2
$failed
EOF2

    out="$(_strict_skips "$base" "$tap")"
    if [ -n "$out" ]; then
        result=FAIL
        msg="${msg}${out}
"
    fi

    secs=$(( $(date +%s) - start ))
    tests="$(_tap_count "$tap")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$base" "$tests" "$secs" "$result" "$retries" > "$OUT/results/$base.tsv"

    {
        printf '%s %s (%s tests, %ss, %s retries)\n' "$result" "$base" "$tests" "$secs" "$retries"
        [ -z "$msg" ] || printf '%s' "$msg"
        if [ "$result" = FAIL ]; then
            echo "  --- TAP (failures and diagnostics) for $base ---"
            grep -v '^ok ' "$tap" | sed 's/^/  /'
        fi
    } > "$OUT/results/$base.out"
    cat "$OUT/results/$base.out"
}

# Strict-skip violations in <tap> as message lines (empty when none or when strict mode is off).
_strict_skips() { # <file> <tap>
    [ "$STRICT_SKIPS" = 1 ] || return 0
    local name
    while IFS= read -r name; do
        [ -n "$name" ] || continue
        _skip_allowed "$1" "$name" || printf '  UNEXPECTED SKIP (MOTHER_TEST_STRICT_SKIPS=1): %s: "%s" — fix the cause or list it in ci-allowed-skips.tsv\n' "$1" "$name"
    done <<EOF2
$(_tap_skipped "$2")
EOF2
}

_run_lane() { # <file>... (sequential)
    local f
    for f in "$@"; do _run_one_file "$f"; done
}

# Run the files (full paths) in K concurrent LPT lanes (test-shards.sh lanes), waiting for all of them.
_run_in_lanes() {
    local f base lane lane_files pid pids="" names=""
    for f in "$@"; do names="$names $(basename "$f")"; done
    lane=1
    while [ "$lane" -le "$LANES" ]; do
        lane_files=""
        # shellcheck disable=SC2086
        for base in $("$SHARDS_SH" lanes "$LANES" $names | awk -F'\t' -v l="$lane" '$1 == l { print $2 }'); do
            for f in "$@"; do
                [ "$(basename "$f")" = "$base" ] && lane_files="$lane_files $f"
            done
        done
        # shellcheck disable=SC2086
        [ -z "$lane_files" ] || { _run_lane $lane_files & pids="$pids $!"; }
        lane=$((lane + 1))
    done
    for pid in $pids; do wait "$pid"; done
}

# Every file we were asked to run must have a result, and nothing else.
_verify_all_ran() { # <path>...
    local f expected="" ran
    for f in "$@"; do expected="$expected$(basename "$f")
"; done
    ran="$(for f in "$OUT"/results/*.tsv; do [ -f "$f" ] && basename "$f" .tsv; done | LC_ALL=C sort)"
    expected="$(printf '%s' "$expected" | LC_ALL=C sort)"
    [ "$ran" != "$expected" ] || return 0
    echo "run-tests: files run differ from files assigned" >&2
    echo "  assigned: $(echo "$expected" | tr '\n' ' ')" >&2
    echo "  ran:      $(echo "$ran" | tr '\n' ' ')" >&2
    return 1
}

# Run the given files (full paths), honouring MOTHER_TEST_LANES; verify and summarise. Returns 0 if all passed.
_run_files() {
    local rc=0
    rm -rf "$OUT/results" "$OUT/tap" "$OUT/timings.tsv"
    mkdir -p "$OUT/results" "$OUT/tap"

    case "$LANES" in ''|*[!0-9]*|0) die "MOTHER_TEST_LANES must be a positive integer" ;; esac
    if [ "$LANES" -le 1 ] || [ "$#" -le 1 ]; then
        _run_lane "$@"
    else
        _run_in_lanes "$@"
    fi

    _verify_all_ran "$@" || rc=1
    _write_reports || rc=1
    return "$rc"
}

_write_reports() {
    local nfail
    cat "$OUT"/results/*.tsv 2>/dev/null | LC_ALL=C sort > "$OUT/results.tsv"
    awk -F'\t' '{ print $1 "\t" $3 }' "$OUT/results.tsv" > "$OUT/timings.tsv"
    nfail="$(awk -F'\t' '$4 != "PASS" { n++ } END { print n + 0 }' "$OUT/results.tsv")"
    if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        {
            echo ""
            echo "| file | tests | seconds | result | retries |"
            echo "|---|---|---|---|---|"
            awk -F'\t' '{ printf "| %s | %s | %s | %s | %s |\n", $1, $2, $3, $4, $5 }' "$OUT/results.tsv"
        } >> "$GITHUB_STEP_SUMMARY"
    fi
    echo "bats: $(wc -l < "$OUT/results.tsv" | tr -d ' ') files run, $nfail failed (TAP and timings in $OUT)"
    [ "$nfail" -eq 0 ]
}

# --- modes ------------------------------------------------------------------------------------------

_summary_halves() { # <go rc> <bats rc>
    local g=PASS b=PASS
    [ "$1" -eq 0 ] || g=FAIL
    [ "$2" -eq 0 ] || b=FAIL
    echo "go: $g"
    echo "bats: $b"
    [ "$1" -eq 0 ] && [ "$2" -eq 0 ]
}

_need_bats() {
    command -v bats >/dev/null 2>&1 || { echo "error: bats not found. Install with: brew install bats-core" >&2; return 1; }
}

mode_go_only() {
    _go_half
}

mode_shard() { # <N/M>
    local spec="$1" n m files f paths=()
    case "$spec" in
        [0-9]*/[0-9]*) ;;
        *) die "--shard wants N/M (e.g. 2/5), got '$spec'" ;;
    esac
    n="${spec%%/*}"; m="${spec#*/}"
    case "$n$m" in *[!0-9]*) die "--shard wants N/M (e.g. 2/5), got '$spec'" ;; esac
    { [ "$n" -ge 1 ] && [ "$n" -le "$m" ]; } || die "--shard $spec is out of range (need 1 <= N <= M)"
    _need_bats || exit 1
    files="$("$SHARDS_SH" pick "$n" "$m")" || exit 2
    if ! _build_broker; then
        echo "run-tests: broker build failed; failing shard $spec (never skipping)" >&2
        exit 1
    fi
    for f in $files; do paths+=("$TESTS_DIR/$f"); done
    echo "== bats shard $spec: ${#paths[@]} files =="
    if _run_files "${paths[@]}"; then
        echo "shard $spec: PASS"
    else
        echo "shard $spec: FAIL"
        exit 1
    fi
}

mode_targeted() { # <files...> (BATS_EXTRA already filled)
    _need_bats || exit 1
    if ! _build_broker; then
        echo "run-tests: broker build failed" >&2
        exit 1
    fi
    echo "== bats =="
    _run_files "$@"
}

_run_all_files() {
    local f paths=()
    for f in $("$SHARDS_SH" list); do paths+=("$TESTS_DIR/$f"); done
    _run_files "${paths[@]}"
}

# Broker build, Go half, then the given bats command; reports both halves.
_both_halves() { # <bats command...>
    local grc=0 brc=0
    _build_broker || grc=1
    _go_half || grc=1
    if _need_bats; then
        echo "== bats =="
        "$@" || brc=1
    else
        brc=1
    fi
    _summary_halves "$grc" "$brc"
}

mode_all() {
    _both_halves _run_all_files
}

mode_passthrough() {
    _both_halves bats "$TESTS_DIR" "$@"
}

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
    local a files=() others=()
    case "${1:-}" in
        -h|--help) usage; return 0 ;;
        --go-only) mode_go_only; return $? ;;
        --shard) [ "$#" -ge 2 ] || die "--shard wants N/M"; mode_shard "$2"; return $? ;;
        --shard=*) mode_shard "${1#--shard=}"; return $? ;;
        "") mode_all; return $? ;;
    esac
    for a in "$@"; do
        case "$a" in
            *.bats) files+=("$a") ;;
            *) others+=("$a") ;;
        esac
    done
    if [ "${#files[@]}" -gt 0 ]; then
        BATS_EXTRA=(${others[@]+"${others[@]}"})
        mode_targeted "${files[@]}"
        return $?
    fi
    mode_passthrough "$@"
}

main "$@"
