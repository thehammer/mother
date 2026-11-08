#!/usr/bin/env bats
# state_seam_lint.bats — nothing inside a running job may write job, event or usage state around the
# worker-mode seam (cluster Phase 1, slice P1-2).
#
# In worker mode every state write must also be mirrored into the outbox (lib/outbox.sh). That only holds
# if every write goes through one of the helpers that does the mirroring. This file is the tripwire: it
# scans bin/mother-run-job, bin/mother and lib/*.sh and fails when
#
#   * a job file is written directly (`_atomic_write` of "$job_file" / "$jf" / "$_jobpath" / `_job_path`,
#     `mv <tmp> "$job_file"`, or a `>` redirect onto one), or
#   * a line is appended directly to the events or usage streams (`>> "$EVENTS_DIR/..."`,
#     `>> "$metrics_file"`, ...)
#
# outside an allowlist of function NAMES (never line numbers, so refactors do not churn it). Each hit is
# attributed to its innermost enclosing shell function by an awk scan (indentation-aware, so a nested
# helper definition does not launder the writes that follow it in the outer function).
#
# Keeping the allowlist honest:
#   * Helper definition sites: the functions that ARE the mirrored write path.
#   * Operator-side bin/mother commands: they run in the operator's or the runner's process, never inside
#     a worker, and write the canonical root on purpose. Each one is listed below with the reason.
#   * The in-job commands (cmd_await, cmd_gates, cmd_review_lens, cmd_merge_findings, cmd_adherence_review,
#     cmd_preview, and the helpers they call) MUST NOT be listed: their writes have to go through the
#     helpers. A test below proves the scanner reports them.
#   * An entry for a function that no longer exists fails the file: a stale name would silently exempt
#     whatever function reuses it.
#
# The scanner is a function taking a directory (laid out like the plugin: bin/mother-run-job, bin/mother,
# lib/*.sh), so the tests can point it at fixtures.

load 'test_helper'

# --- the allowlist ---------------------------------------------------------------------------------

# Helper definition sites: the mirrored write path itself (and the canonical-side replay writer).
SEAM_ALLOW_HELPERS="_job_write_doc mother_job_write_doc mother_job_update _job_update _usage_job_write _ca_job_set_locked _ca_stall"

# bin/mother functions that are not reachable from inside a running job:
#   cmd_add            enqueue: creates the job document
#   cmd_force_start    operator override (clears dependency / quota gates)
#   _retry_locked      `mother retry` (operator)
#   cmd_escalate       `mother escalate` (operator, and the runner's escalation pass)
#   cmd_reconcile      `mother reconcile` (operator, and the runner's pre-escalation pass)
#   _rf_hold, _rf_backoff, _rf_retry_once
#                      `mother route-failure`, run by the runner on already-failed jobs
#   _resume_write_locked
#                      `mother resume` (refuses to run when MOTHER_JOB_ID is set)
SEAM_ALLOW_OPERATOR="cmd_add cmd_force_start _retry_locked cmd_escalate cmd_reconcile _rf_hold _rf_backoff _rf_retry_once _resume_write_locked"

# Event / usage append helpers (the lock-and-emit helpers; they mirror into the outbox themselves).
SEAM_ALLOW_APPENDERS="_append_line _append_event mother_event_append _usage_append_line _usage_append_event"

SEAM_ALLOW="$SEAM_ALLOW_HELPERS $SEAM_ALLOW_OPERATOR $SEAM_ALLOW_APPENDERS"

# In-job commands: never allowlisted.
SEAM_IN_JOB_FUNCTIONS="cmd_await cmd_gates cmd_review_lens cmd_merge_findings cmd_adherence_review cmd_preview"

PLUGIN_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd -P)"

# --- the scanner -----------------------------------------------------------------------------------

# _lint_awk_program — prints the awk program. Output rows are tab-separated:
#   <file> <line> <function|(top-level)> <job-write|log-append> <source line>
_lint_awk_program() {
    cat <<'AWK'
BEGIN {
    # Variable names that hold a job document path (JOBNAME), and the same followed by a name boundary (JOBVAR).
    JOBNAME = "[$][{]?(_?jf|[A-Za-z_]*[Jj][Oo][Bb]_?([Ff][Ii][Ll][Ee]|[Pp][Aa][Tt][Hh]))[}]?"
    JOBVAR = JOBNAME "([^A-Za-z0-9_}]|$)"
    JOBWRITE = "_atomic_write[[:space:]]+[\"]?(" JOBNAME "([^A-Za-z0-9_}]|$)|[$][{]?JOBS_DIR|[$][(]_job_path)"
    # mv <something> "$job_file"  (the job file as the destination, i.e. the last argument)
    JOBMV = "(^|[;&|[:space:]])mv[[:space:]]+[^|;&]*[\"]" JOBNAME "[\"][[:space:]]*([0-9]?>[^[:space:]]*)?[[:space:]]*($|[;&|)])"
    JOBREDIR = "[^>0-9]>[[:space:]]*[\"]?" JOBVAR
    APPEND = ">>[[:space:]]*[\"]?([$][{]?(EVENTS_DIR|metrics_file|_eventpath|events_file|MOTHER_ROOT/(events|metrics))|[$][(]_events_path)"
    TEEAPPEND = "tee[[:space:]]+-a[[:space:]]+[\"]?[$][{]?(EVENTS_DIR|metrics_file|_eventpath|events_file)"
}
function indent_of(s) { match(s, /^[[:space:]]*/); return RLENGTH }
function report(kind) {
    printf "%s\t%d\t%s\t%s\t%s\n", FILENAME, FNR, (sp > 0 ? stack[sp] : "(top-level)"), kind, line
}
function scan() {
    if (line ~ JOBWRITE || line ~ JOBMV || line ~ JOBREDIR) report("job-write")
    else if (line ~ APPEND || line ~ TEEAPPEND) report("log-append")
}
FNR == 1 { sp = 0 }
{
    line = $0
    if (line ~ /^[[:space:]]*#/) next
    ind = indent_of(line)
    # A closing brace at the indent of the innermost open function ends it.
    if (sp > 0 && line ~ /^[[:space:]]*[}][[:space:]]*(#.*)?$/ && ind == sind[sp]) { sp--; next }
    if (line ~ /^[[:space:]]*(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_:.-]*[[:space:]]*[(][)][[:space:]]*[{]/) {
        name = line
        sub(/^[[:space:]]*(function[[:space:]]+)?/, "", name)
        sub(/[[:space:]]*[(][)].*$/, "", name)
        rest = line
        sub(/^[^{]*[{]/, "", rest)
        sp++; stack[sp] = name; sind[sp] = ind
        scan()
        # A one-line function (`f() { ...; }`) is closed on its own line.
        if (rest ~ /[}][[:space:]]*(#.*)?$/) sp--
        next
    }
    scan()
}
AWK
}

# _lint_scan <dir> — every raw hit under <dir> (bin/mother-run-job, bin/mother, lib/*.sh), allowlisted or not.
_lint_scan() {
    local dir="$1" prog="$BATS_TEST_TMPDIR/seam-scan.awk"
    _lint_awk_program > "$prog"
    ( cd "$dir" && awk -f "$prog" bin/mother-run-job bin/mother lib/*.sh )
}

# _lint_violations <dir> — the hits whose enclosing function is not on the allowlist.
_lint_violations() {
    _lint_scan "$1" | awk -F'\t' -v allow=" $SEAM_ALLOW " 'index(allow, " " $3 " ") == 0'
}

# _lint_fixture <dest> — a copy of the plugin files the scanner reads, laid out the same way.
_lint_fixture() {
    mkdir -p "$1/bin" "$1/lib"
    cp "$PLUGIN_ROOT/bin/mother-run-job" "$PLUGIN_ROOT/bin/mother" "$1/bin/"
    cp "$PLUGIN_ROOT"/lib/*.sh "$1/lib/"
}

setup() {
    setup_mother_env
}

teardown() {
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# The tripwire itself

@test "no job file, event or usage stream is written directly outside the allowlisted write helpers" {
    run _lint_violations "$PLUGIN_ROOT"
    if [ -n "$output" ]; then
        echo "direct state writes outside the mirrored helpers (file, line, function, kind, source):" >&2
        printf '%s\n' "$output" >&2
        echo "route them through mother_job_update / _job_write_doc / mother_event_append / the usage appenders," >&2
        echo "or, for an operator-only command, add its NAME to the allowlist in this file with the reason." >&2
    fi
    [ -z "$output" ]
}

@test "the in-job commands are not on the allowlist" {
    local fn
    for fn in $SEAM_IN_JOB_FUNCTIONS; do
        case " $SEAM_ALLOW " in
            *" $fn "*) echo "$fn is allowlisted but runs inside a job" >&2; return 1 ;;
        esac
    done
}

@test "every allowlisted function still exists (a stale name would exempt whatever reuses it)" {
    local fn missing=""
    for fn in $SEAM_ALLOW; do
        if ! grep -qE "^[[:space:]]*(function[[:space:]]+)?$fn[[:space:]]*\(\)" \
                "$PLUGIN_ROOT/bin/mother-run-job" "$PLUGIN_ROOT/bin/mother" "$PLUGIN_ROOT"/lib/*.sh; then
            missing="$missing $fn"
        fi
    done
    if [ -n "$missing" ]; then echo "allowlisted but not defined anywhere:$missing" >&2; return 1; fi
}

# ---------------------------------------------------------------------------
# The scanner catches violations (and only violations)

# _has_row <rows> <file> <function> <kind> — succeeds when the rows (tab-separated scanner output) hold a
# hit in <file> attributed to <function> of <kind>.
_has_row() {
    printf '%s\n' "$1" | awk -F'\t' -v f="$2" -v fn="$3" -v k="$4" \
        '$1 == f && $3 == fn && $4 == k { found = 1 } END { exit !found }'
}

@test "scanner: a direct job-file write injected into a non-allowlisted function of a copy of the real tree is reported" {
    local fx="$BATS_TEST_TMPDIR/fixture"
    _lint_fixture "$fx"
    _lint_violations "$fx" > "$BATS_TEST_TMPDIR/before"

    cat >> "$fx/bin/mother-run-job" <<'EOF'

_seam_lint_probe_sneaky_write() {
    local merged
    merged=$(jq '.state = "succeeded"' "$job_file")
    _atomic_write "$job_file" "$merged"
}
EOF
    _lint_violations "$fx" > "$BATS_TEST_TMPDIR/after"

    _has_row "$(cat "$BATS_TEST_TMPDIR/after")" bin/mother-run-job _seam_lint_probe_sneaky_write job-write
    # Exactly one new row: the injected line, nothing else changed.
    [ "$(awk 'NF' "$BATS_TEST_TMPDIR/after" | wc -l | tr -d ' ')" = "$(( $(awk 'NF' "$BATS_TEST_TMPDIR/before" | wc -l | tr -d ' ') + 1 ))" ]
}

@test "scanner: a direct event or usage append injected into a copy of the real tree is reported" {
    local fx="$BATS_TEST_TMPDIR/fixture"
    _lint_fixture "$fx"
    cat >> "$fx/lib/state.sh" <<'EOF'

_seam_lint_probe_sneaky_event() {
    printf '%s\n' "$1" >> "$EVENTS_DIR/$2.jsonl"
}
_seam_lint_probe_sneaky_usage() {
    local metrics_file="$MOTHER_ROOT/metrics/runs.jsonl"
    printf '%s\n' "$1" >> "$metrics_file"
}
EOF
    run _lint_violations "$fx"
    _has_row "$output" lib/state.sh _seam_lint_probe_sneaky_event log-append
    _has_row "$output" lib/state.sh _seam_lint_probe_sneaky_usage log-append
}

@test "scanner: the same writes inside allowlisted helper names add nothing to the report" {
    local fx="$BATS_TEST_TMPDIR/fixture"
    _lint_fixture "$fx"
    _lint_violations "$fx" > "$BATS_TEST_TMPDIR/before"
    cat >> "$fx/lib/state.sh" <<'EOF'

mother_job_update() {
    _atomic_write "$job_file" "$1"
}
_append_line() { printf '%s\n' "$2" >> "$EVENTS_DIR/probe.jsonl"; }
EOF
    _lint_violations "$fx" > "$BATS_TEST_TMPDIR/after"
    diff -u "$BATS_TEST_TMPDIR/before" "$BATS_TEST_TMPDIR/after"
}

@test "scanner: the in-job commands are reported when they write job state directly" {
    local fx="$BATS_TEST_TMPDIR/fixture" fn
    _lint_fixture "$fx"
    # A scratch library defines each in-job function name with a direct write, so the attribution is by
    # name, wherever the real definition lives.
    : > "$fx/lib/zz_probe.sh"
    for fn in $SEAM_IN_JOB_FUNCTIONS; do
        printf '%s() {\n    local merged="{}"\n    _atomic_write "$job_file" "$merged"\n}\n' "$fn" >> "$fx/lib/zz_probe.sh"
    done
    run _lint_violations "$fx"
    for fn in $SEAM_IN_JOB_FUNCTIONS; do
        _has_row "$output" lib/zz_probe.sh "$fn" job-write || { echo "$fn was not reported" >&2; return 1; }
    done
}

# A tiny hand-written tree pins the attribution rules without depending on the real files.
@test "scanner: attributes each write to its innermost function and ignores comments, mv-away and allowlisted helpers" {
    local fx="$BATS_TEST_TMPDIR/tiny"
    mkdir -p "$fx/bin" "$fx/lib"
    : > "$fx/bin/mother"
    : > "$fx/lib/empty.sh"
    cat > "$fx/bin/mother-run-job" <<'EOF'
# _atomic_write "$job_file" "$in_a_comment"
mother_job_update() {
    _atomic_write "$_jobpath" "$merged"
}
bad_plain() {
    _atomic_write "$job_file" "$merged"
}
bad_outer() {
    _job_update() {
        _atomic_write "$job_file" "$inner"
    }
    _atomic_write "$jf" "$after_the_nested_helper"
}
bad_oneliner() { _atomic_write "$job_file" "$c"; }
after_oneliner() {
    printf 'x\n' >> "$EVENTS_DIR/$id.jsonl"
}
bad_mv() {
    printf '%s' "$m" > "$tmp" && mv "$tmp" "$job_file"
}
ok_archive() {
    mv "$job_file" "$dest_dir/$id.json" 2>/dev/null
}
ok_other_file() {
    _atomic_write "$cursor_file" "$payload"
    printf 'x\n' >> "$LOGS_DIR/$id.log"
}
_append_line() { printf '%s\n' "$2" >> "$EVENTS_DIR/$1"; }
bad_after_helpers() {
    _atomic_write "$(_job_path "$id")" "$j"
}
_atomic_write "$job_file" "$top_level"
EOF
    run _lint_violations "$fx"
    [ "$status" -eq 0 ]
    local got want
    got=$(printf '%s\n' "$output" | awk -F'\t' 'NF { print $3 " " $4 }')
    want="bad_plain job-write
bad_outer job-write
bad_oneliner job-write
after_oneliner log-append
bad_mv job-write
bad_after_helpers job-write
(top-level) job-write"
    if [ "$got" != "$want" ]; then
        echo "got:" >&2; printf '%s\n' "$got" >&2
        echo "want:" >&2; printf '%s\n' "$want" >&2
        return 1
    fi
}
