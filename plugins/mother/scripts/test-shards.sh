#!/usr/bin/env bash
# test-shards.sh — deterministic sharding of the bats suite, plus the guards CI relies on.
#
# Usage:
#   test-shards.sh list                 top-level tests/*.bats basenames, sorted
#   test-shards.sh assign M             `shard<TAB>file<TAB>weight` for every file (greedy LPT, 1-based shards)
#   test-shards.sh pick N M             shard N's files (of M), heaviest first
#   test-shards.sh check M              coverage guard + quarantine/allowed-skip validation; prints the matrix
#                                       JSON ([1,..,M]) on stdout and a per-shard weight table on stderr
#   test-shards.sh weights <dir>...     merge `timings.tsv` files under the dirs into tests/shard-weights.tsv
#   test-shards.sh lanes K <file>...    split a file list into K LPT lanes: `lane<TAB>file`
#
# Assignment: files sorted by weight desc (ties by name), each to the currently lightest shard (ties: lowest
# index). Weights come from tests/shard-weights.tsv (`file<TAB>seconds`); a file without one gets the median.
# Everything is a pure function of the files + weights, so every shard computes the same plan.
#
# Env overrides (used by tests/ci_shards.bats): MOTHER_TESTS_DIR (default plugins/mother/tests) and
# MOTHER_BROKER_DIR (default plugins/mother/broker, only read to validate `go` quarantine rows).
#
# Bash-3.2-safe (no declare -A / mapfile); awk and POSIX tools only.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGIN_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
TESTS_DIR="${MOTHER_TESTS_DIR:-$PLUGIN_DIR/tests}"
BROKER_DIR="${MOTHER_BROKER_DIR:-$PLUGIN_DIR/broker}"
WEIGHTS="$TESTS_DIR/shard-weights.tsv"
QUARANTINE="$TESTS_DIR/quarantine.tsv"
ALLOWED_SKIPS="$TESTS_DIR/ci-allowed-skips.tsv"
ISSUE_RE='^https://github\.com/thehammer/mother/issues/[0-9]+$'

die() { echo "test-shards: $*" >&2; exit 1; }

_need_pos_int() { # <what> <value>
    case "$2" in
        ''|*[!0-9]*) die "$1 must be a positive integer, got '$2'" ;;
    esac
    [ "$2" -ge 1 ] || die "$1 must be >= 1, got '$2'"
}

# --- list / weights -----------------------------------------------------------------------------

cmd_list() {
    local f
    for f in "$TESTS_DIR"/*.bats; do
        [ -f "$f" ] && basename "$f"
    done | LC_ALL=C sort
}

# stdin: file names. stdout: `file<TAB>weight`, unweighted files at the median of the known weights.
_with_weights() {
    local wf="$WEIGHTS"
    [ -f "$wf" ] || wf=/dev/null
    awk -F'\t' -v wf="$wf" '
        BEGIN {
            while ((getline line < wf) > 0) {
                if (line ~ /^#/ || line ~ /^[ \t]*$/) continue
                split(line, p, "\t")
                if (p[2] != "" && p[2] ~ /^[0-9]+(\.[0-9]+)?$/) w[p[1]] = p[2] + 0
            }
        }
        { names[++n] = $1 }
        END {
            k = 0
            for (i = 1; i <= n; i++) if (names[i] in w) known[++k] = w[names[i]]
            med = 1
            if (k > 0) {
                for (i = 2; i <= k; i++) {        # insertion sort
                    v = known[i]; j = i - 1
                    while (j >= 1 && known[j] > v) { known[j + 1] = known[j]; j-- }
                    known[j + 1] = v
                }
                med = (k % 2) ? known[(k + 1) / 2] : (known[k / 2] + known[k / 2 + 1]) / 2
            }
            for (i = 1; i <= n; i++)
                printf "%s\t%g\n", names[i], (names[i] in w) ? w[names[i]] : med
        }'
}

# stdin: `file<TAB>weight`. stdout: `slot<TAB>file<TAB>weight` (greedy LPT over K slots, heaviest first).
_lpt() { # <K>
    awk -F'\t' -v K="$1" '
        { f[++n] = $1; w[n] = $2 + 0 }
        END {
            for (i = 1; i <= n; i++) idx[i] = i
            for (i = 2; i <= n; i++) {            # insertion sort: weight desc, name asc
                v = idx[i]; j = i - 1
                while (j >= 1 && (w[idx[j]] < w[v] || (w[idx[j]] == w[v] && f[idx[j]] > f[v]))) {
                    idx[j + 1] = idx[j]; j--
                }
                idx[j + 1] = v
            }
            for (s = 1; s <= K; s++) load[s] = 0
            for (i = 1; i <= n; i++) {
                x = idx[i]; best = 1
                for (s = 2; s <= K; s++) if (load[s] < load[best]) best = s
                load[best] += w[x]
                printf "%d\t%s\t%g\n", best, f[x], w[x]
            }
        }'
}

cmd_assign() {
    _need_pos_int "M" "${1:-}"
    cmd_list | _with_weights | _lpt "$1"
}

cmd_pick() {
    _need_pos_int "N" "${1:-}"
    _need_pos_int "M" "${2:-}"
    [ "$1" -le "$2" ] || die "shard $1 is out of range for $2 shards"
    cmd_assign "$2" | awk -F'\t' -v n="$1" '$1 == n { print $2 }'
}

cmd_lanes() {
    _need_pos_int "K" "${1:-}"
    local k="$1"
    shift
    [ "$#" -gt 0 ] || return 0
    printf '%s\n' "$@" | _with_weights | _lpt "$k" | awk -F'\t' '{ print $1 "\t" $2 }'
}

cmd_weights() {
    [ "$#" -gt 0 ] || die "weights: give at least one directory holding timings.tsv files"
    local d t tmp
    tmp="$(mktemp)"
    {
        cmd_list | sed 's/^/L\t/'
        [ -f "$WEIGHTS" ] && sed 's/^/W\t/' "$WEIGHTS"
        for d in "$@"; do
            [ -d "$d" ] || die "weights: not a directory: $d"
            find "$d" -name timings.tsv | LC_ALL=C sort | while IFS= read -r t; do
                sed 's/^/T\t/' "$t"
            done
        done
    } | awk -F'\t' '
        $1 == "L" { exists[$2] = 1; next }
        $1 == "W" { if ($2 !~ /^#/ && $3 != "") old[$2] = $3 + 0; next }
        $1 == "T" { if ($2 != "" && $3 != "") cur[$2] = $3 + 0; next }
        END {
            for (f in exists) {
                if (f in cur) v = cur[f]; else if (f in old) v = old[f]; else continue
                v = int(v + 0.5); if (v < 1) v = 1
                printf "%s\t%d\n", f, v
            }
        }' | LC_ALL=C sort > "$tmp"
    {
        echo "# shard-weights.tsv — per-file seconds used by scripts/test-shards.sh to balance shards (greedy LPT)."
        echo "# Format: file<TAB>seconds. A file with no row gets the median weight, so new test files are always scheduled."
        echo "# Refresh from a CI run's timing artifacts:"
        echo "#   gh run download <run-id> -p 'bats-timings-*' -D /tmp/bats-timings"
        echo "#   plugins/mother/scripts/test-shards.sh weights /tmp/bats-timings"
        cat "$tmp"
    } > "$WEIGHTS"
    rm -f "$tmp"
    echo "test-shards: updated $WEIGHTS"
}

# --- check ----------------------------------------------------------------------------------------

_field() { printf '%s\n' "$2" | awk -F'\t' -v n="$1" '{ print $n }'; }

# <file> <test name> : does `@test "<name>"` appear in the bats file?
_bats_test_exists() {
    grep -qF -- "@test \"$2\"" "$TESTS_DIR/$1" 2>/dev/null
}

_go_test_exists() {
    local f
    for f in "$BROKER_DIR"/*_test.go; do
        [ -f "$f" ] && grep -qF -- "func $1(" "$f" && return 0
    done
    return 1
}

# Echo one error line per problem in quarantine.tsv. A missing file is an empty quarantine.
_check_quarantine() {
    [ -f "$QUARANTINE" ] || return 0
    local line target name url seen="" n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in ''|'#'*) continue ;; esac
        target="$(_field 1 "$line")"; name="$(_field 2 "$line")"; url="$(_field 3 "$line")"
        if [ -z "$target" ] || [ -z "$name" ]; then
            echo "quarantine.tsv:$n: row needs target and test name: '$line'"; continue
        fi
        if ! printf '%s\n' "$url" | grep -Eq "$ISSUE_RE"; then
            echo "quarantine.tsv:$n: $target \"$name\": missing or invalid issue URL '$url' (want https://github.com/thehammer/mother/issues/<n>)"
        fi
        if [ "$target" = go ]; then
            _go_test_exists "$name" || echo "quarantine.tsv:$n: go test '$name' not found in $BROKER_DIR/*_test.go"
        elif [ ! -f "$TESTS_DIR/$target" ]; then
            echo "quarantine.tsv:$n: bats file '$target' does not exist"
        elif ! _bats_test_exists "$target" "$name"; then
            echo "quarantine.tsv:$n: test '$name' not found in $target"
        fi
        if printf '%s' "$seen" | grep -qxF -- "$target	$name"; then
            echo "quarantine.tsv:$n: duplicate row for $target \"$name\""
        fi
        seen="$seen$target	$name
"
    done < "$QUARANTINE"
}

_check_allowed_skips() {
    [ -f "$ALLOWED_SKIPS" ] || return 0
    local line file name reason n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        case "$line" in ''|'#'*) continue ;; esac
        file="$(_field 1 "$line")"; name="$(_field 2 "$line")"; reason="$(_field 3 "$line")"
        if [ -z "$file" ] || [ -z "$name" ] || [ -z "$reason" ]; then
            echo "ci-allowed-skips.tsv:$n: row needs file, test name and reason: '$line'"; continue
        fi
        if [ ! -f "$TESTS_DIR/$file" ]; then
            echo "ci-allowed-skips.tsv:$n: bats file '$file' does not exist"
        elif ! _bats_test_exists "$file" "$name"; then
            echo "ci-allowed-skips.tsv:$n: test '$name' not found in $file"
        fi
    done < "$ALLOWED_SKIPS"
}

_check_no_subdir_tests() {
    local sub
    sub="$(find "$TESTS_DIR" -mindepth 2 -name '*.bats' | LC_ALL=C sort)"
    [ -z "$sub" ] || printf 'bats files in a subdirectory (bats and the shard lister would silently skip them):\n%s\n' "$sub"
}

_check_each_file_assigned_once() { # <assigned plan> <files>
    local f c
    for f in $2; do
        c="$(printf '%s\n' "$1" | awk -F'\t' -v f="$f" '$2 == f { n++ } END { print n + 0 }')"
        [ "$c" -eq 1 ] || echo "$f is assigned to $c shards (want exactly 1)"
    done
}

cmd_check() {
    _need_pos_int "M" "${1:-}"
    local m="$1" errors files assigned i matrix=""
    files="$(cmd_list)"
    [ -n "$files" ] || die "no top-level *.bats files in $TESTS_DIR"

    assigned="$(cmd_assign "$m")"
    errors="$(_check_no_subdir_tests; _check_each_file_assigned_once "$assigned" "$files"; _check_quarantine; _check_allowed_skips)"
    if [ -n "$errors" ]; then
        printf 'test-shards: check failed:\n%s\n' "$errors" >&2
        exit 1
    fi

    printf '%s\n' "$assigned" | awk -F'\t' -v m="$m" '
        { n[$1]++; w[$1] += $3 }
        END { for (s = 1; s <= m; s++) printf "shard %d/%d: %d files, weight %g\n", s, m, n[s], w[s] }' >&2
    for i in $(seq 1 "$m"); do
        matrix="$matrix${matrix:+,}$i"
    done
    echo "[$matrix]"
}

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
    list)    shift; cmd_list "$@" ;;
    assign)  shift; cmd_assign "$@" ;;
    pick)    shift; cmd_pick "$@" ;;
    check)   shift; cmd_check "$@" ;;
    weights) shift; cmd_weights "$@" ;;
    lanes)   shift; cmd_lanes "$@" ;;
    -h|--help|help) usage ;;
    *) usage >&2; exit 2 ;;
esac
