#!/usr/bin/env bash
# gates.sh — run a repo's declared quality gates (`.mother/crew.yml`) against a
# work tree and report one compact JSON object.
#
# Pure helpers: no job-state writes, no events (the callers own those).
# Sourced under `set -u`, bash 3.2.
#
# Contract that matters most: a gate that did not actually run is NEVER
# reported `passed`. A missing/disabled rwx, a failed reset, a watchdog expiry
# or an unpushed HEAD (for sandbox gates) all yield `unavailable`, and any
# unavailable check makes the overall status `incomplete`.
#
# Output text never enters the JSON: full output goes to <out_dir>/<name>.log,
# the last 60 lines (max 4 KB) to <out_dir>/<name>.excerpt.

_mother_gates_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=rwx.sh
source "$_mother_gates_lib_dir/rwx.sh" || { echo "gates.sh: cannot load $_mother_gates_lib_dir/rwx.sh" >&2; return 1 2>/dev/null || exit 1; }
MOTHER_CREW_CONFIG_PY="$_mother_gates_lib_dir/crew_config.py"
unset _mother_gates_lib_dir

_GATES_CHANGED_FILES_CAP=65536

# mother_gates_red_json <job-file> — the failing blocking gates of the job's
# last attempt, as a JSON array of names.
mother_gates_red_json() {
    jq -c '[.gates.results[]? | select(.result == "failed" and .blocking != false) | .name]' "$1" 2>/dev/null \
        || echo '[]'
}

# _gates_exec_any <log> <run> — runs inside the watchdog subshell (cwd =
# work_dir). The gate env is set here, scoped to this subshell.
_gates_exec_any() {
    local log="$1" run="$2"
    MOTHER_GATE_BASE="$_GATES_BASE" MOTHER_GATE_CHANGED_FILES="$_GATES_CHANGED" \
        bash -c "$run" >"$log" 2>&1 </dev/null
}

# _gates_write_excerpt <log> <excerpt> — last 60 lines, at most 4096 bytes.
_gates_write_excerpt() {
    local log="$1" excerpt="$2"
    tr -d '\r' <"$log" 2>/dev/null | tail -n 60 | tail -c 4096 >"$excerpt" 2>/dev/null
    [ -f "$excerpt" ] || : >"$excerpt"
}

# _gates_result <name> <result> <blocking> <duration> <exit_code|""> <unavailable_reason> <skip_reason>
# Appends one compact JSON result line to $_GATES_RESULTS.
_gates_result() {
    local line
    line=$(jq -nc --arg name "$1" --arg result "$2" --argjson blocking "$3" \
        --argjson duration "$4" --arg exit_code "$5" --arg ur "$6" --arg sr "$7" \
        '{name: $name, result: $result, blocking: $blocking, duration_s: $duration,
          exit_code: (if $exit_code == "" then null else ($exit_code | tonumber) end),
          unavailable_reason: (if $ur == "" then null else $ur end),
          skip_reason: (if $sr == "" then null else $sr end)}')
    _GATES_RESULTS="${_GATES_RESULTS}${line}"$'\n'
}

# _gates_cap_changed <changed_files> — newline-separated, capped at 64 KB on a
# line boundary.
_gates_cap_changed() {
    local files="$1"
    if [ "${#files}" -gt "$_GATES_CHANGED_FILES_CAP" ]; then
        files=$(printf '%s' "$files" | head -c "$_GATES_CHANGED_FILES_CAP" | sed '$d')
    fi
    printf '%s' "$files"
}

# _gates_precheck_failed <out_dir> <name> — the failing built-in check's log
# (already written to <out_dir>/<name>.log) becomes its excerpt and result.
_gates_precheck_failed() {
    local out_dir="$1" name="$2"
    _gates_write_excerpt "$out_dir/$name.log" "$out_dir/$name.excerpt"
    _gates_result "$name" failed true 0 1 "" ""
}

# _gates_precheck_clean_tree <work_dir> <out_dir>
_gates_precheck_clean_tree() {
    local work_dir="$1" out_dir="$2" porcelain
    if porcelain=$(git -C "$work_dir" status --porcelain 2>&1) && [ -z "$porcelain" ]; then
        _gates_result clean_tree passed true 0 "" "" ""
    else
        printf '%s\n' "${porcelain:-git status failed}" >"$out_dir/clean_tree.log"
        _gates_precheck_failed "$out_dir" clean_tree
    fi
}

# _gates_precheck_pushed <work_dir> <out_dir> <head_sha> <branch>
# Sets _GATES_PUSHED_OK (1 when origin's branch tip equals HEAD).
_gates_precheck_pushed() {
    local work_dir="$1" out_dir="$2" head_sha="$3" branch="$4" remote_sha=""
    if [ -n "$branch" ] && [ "$branch" != "HEAD" ]; then
        remote_sha=$(git -C "$work_dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk 'NR==1 {print $1}')
    fi
    if [ -n "$head_sha" ] && [ "$remote_sha" = "$head_sha" ]; then
        _gates_result pushed passed true 0 "" "" ""
    else
        _GATES_PUSHED_OK=0
        printf 'HEAD %s\norigin/%s %s\n' "${head_sha:-?}" "${branch:-?}" "${remote_sha:-<not found>}" \
            >"$out_dir/pushed.log"
        _gates_precheck_failed "$out_dir" pushed
    fi
}

# _gates_prepare_env <work_dir> <base_ref> <crew_file>
# Uses --no-renames so both sides of a rename are matched against path scopes.
# Sets _GATES_BASE / _GATES_CHANGED (the gate env) and _GATES_APPLICABLE (JSON
# array of applicable check names). Call it directly, not via $(...). If the diff can't be computed it fails closed: every
# check applies (a path-scoped gate must not silently drop out).
_gates_prepare_env() {
    local work_dir="$1" base_ref="$2" crew_file="$3" changed applicable=""
    if changed=$(git -C "$work_dir" diff --name-only --no-renames "$base_ref...HEAD" 2>/dev/null); then
        applicable=$(printf '%s\n' "$changed" | python3 "$MOTHER_CREW_CONFIG_PY" applicable "$crew_file" - 2>/dev/null) || applicable=""
    fi
    _GATES_BASE=$(git -C "$work_dir" merge-base "$base_ref" HEAD 2>/dev/null) \
        || _GATES_BASE=$(git -C "$work_dir" rev-parse "$base_ref" 2>/dev/null) || _GATES_BASE=""
    _GATES_CHANGED=$(_gates_cap_changed "${changed:-}")
    [ -n "$applicable" ] || applicable=$(jq -c '[.gates.checks[].name]' "$crew_file")
    _GATES_APPLICABLE="$applicable"
}

# _gates_resolve_sandbox <work_dir>
# Resolves sandbox availability once per run into _GATES_SANDBOX_STATE (`ok` or
# the unavailable reason): rwx gate first, then HEAD pushed, then the single
# reset. The reason sticks for every sandbox check in the run.
_gates_resolve_sandbox() {
    local work_dir="$1" rwx_gate reset_json reset_outcome
    rwx_gate=$(mother_rwx_gate "$work_dir") || true
    if [ "$rwx_gate" != "ok" ]; then
        _GATES_SANDBOX_STATE="$rwx_gate"
    elif [ "$_GATES_PUSHED_OK" -eq 0 ]; then
        _GATES_SANDBOX_STATE=head_not_pushed
    else
        _GATES_SANDBOX_TOUCHED=1
        reset_json=$(mother_rwx_sandbox reset "$work_dir" 2>/dev/null) || reset_json=""
        reset_outcome=$(printf '%s' "$reset_json" | jq -r '.outcome // "error"' 2>/dev/null) || reset_outcome=error
        case "$reset_outcome" in
            ok)      _GATES_SANDBOX_STATE=ok ;;
            timeout) _GATES_SANDBOX_STATE=rwx_timeout ;;
            *)       _GATES_SANDBOX_STATE=rwx_error ;;
        esac
    fi
}

# _gates_run_sandbox_check <name> <blocking> <run> <timeout_s> <work_dir> <out_dir> <tmp_prefix>
# A sandbox check that could not run (timeout, rwx error) is `unavailable`,
# never `failed` or `passed`.
_gates_run_sandbox_check() {
    local name="$1" blocking="$2" run="$3" timeout_s="$4" work_dir="$5" out_dir="$6" tmp_prefix="$7"
    local log="$out_dir/$name.log" script started dur
    script="export MOTHER_GATE_BASE=$(printf '%q' "$_GATES_BASE"); export MOTHER_GATE_CHANGED_FILES=$(printf '%q' "$_GATES_CHANGED"); $run"
    started=$SECONDS
    mother_watchdog_run "$timeout_s" "$tmp_prefix" "$work_dir" _rwx_run_action exec "$log" "$script"
    dur=$((SECONDS - started))
    _gates_write_excerpt "$log" "$out_dir/$name.excerpt"
    case "$MOTHER_WD_OUTCOME" in
        timeout) _gates_result "$name" unavailable "$blocking" "$dur" "" rwx_timeout "" ;;
        done)
            if [ "$MOTHER_WD_RC" = "0" ]; then
                _gates_result "$name" passed "$blocking" "$dur" 0 "" ""
            else
                _gates_result "$name" failed "$blocking" "$dur" "$MOTHER_WD_RC" "" ""
            fi
            ;;
        *) _gates_result "$name" unavailable "$blocking" "$dur" "" rwx_error "" ;;
    esac
}

# _gates_run_local_check <name> <blocking> <run> <timeout_s> <work_dir> <out_dir> <tmp_prefix>
_gates_run_local_check() {
    local name="$1" blocking="$2" run="$3" timeout_s="$4" work_dir="$5" out_dir="$6" tmp_prefix="$7"
    local log="$out_dir/$name.log" started dur
    started=$SECONDS
    mother_watchdog_run "$timeout_s" "$tmp_prefix" "$work_dir" _gates_exec_any "$log" "$run"
    dur=$((SECONDS - started))
    [ -f "$log" ] || : >"$log"
    _gates_write_excerpt "$log" "$out_dir/$name.excerpt"
    if [ "$MOTHER_WD_OUTCOME" = "done" ] && [ "$MOTHER_WD_RC" = "0" ]; then
        _gates_result "$name" passed "$blocking" "$dur" 0 "" ""
    else
        # timeout (124) and "could not run at all" are failures, not passes.
        _gates_result "$name" failed "$blocking" "$dur" "$MOTHER_WD_RC" "" ""
    fi
}

# _gates_run_check <check-json> <posture> <work_dir> <out_dir> <tmp_prefix>
# Records exactly one result for the check: skipped, unavailable, passed or failed.
_gates_run_check() {
    local check="$1" posture="$2" work_dir="$3" out_dir="$4" tmp_prefix="$5"
    local name blocking where timeout_s run
    # Fields are 0x1f-separated (names are charset-validated; `run` is multi-line
    # free text, so it is read separately).
    IFS=$'\037' read -r name blocking where timeout_s < <(printf '%s' "$check" | jq -r \
        '[.name, (if .blocking == false then "false" else "true" end), (.where // "any"), (.timeout_s // 900 | tostring)] | join("\u001f")')
    run=$(printf '%s' "$check" | jq -r '.run')

    if ! printf '%s' "$_GATES_APPLICABLE" | jq -e --arg n "$name" 'index($n) != null' >/dev/null 2>&1; then
        _gates_result "$name" skipped "$blocking" 0 "" "" not_applicable
    elif [ "$posture" = "conservative" ] && [ "$blocking" = "false" ]; then
        _gates_result "$name" skipped "$blocking" 0 "" "" posture
    elif [ "$where" = "sandbox" ]; then
        [ -n "$_GATES_SANDBOX_STATE" ] || _gates_resolve_sandbox "$work_dir"
        if [ "$_GATES_SANDBOX_STATE" = "ok" ]; then
            _gates_run_sandbox_check "$name" "$blocking" "$run" "$timeout_s" "$work_dir" "$out_dir" "$tmp_prefix"
        else
            _gates_result "$name" unavailable "$blocking" 0 "" "$_GATES_SANDBOX_STATE" ""
        fi
    else
        _gates_run_local_check "$name" "$blocking" "$run" "$timeout_s" "$work_dir" "$out_dir" "$tmp_prefix"
    fi
}

# mother_gates_run <work_dir> <resolved-crew-json-file> <base_ref> <out_dir>
#                  [--posture P] [--attempt N] [--allow-unpushed]
# Echoes the result object; returns 0 whenever it produced one (the verdict is
# in .status). <out_dir> must be outside the work tree or `clean_tree` trips.
mother_gates_run() {
    local work_dir="${1:-}" crew_file="${2:-}" base_ref="${3:-}" out_dir="${4:-}"
    shift 4 2>/dev/null || { echo "mother_gates_run: usage: <work_dir> <crew.json> <base_ref> <out_dir> [opts]" >&2; return 2; }
    local posture="normal" attempt="" allow_unpushed=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --posture)        posture="${2:-normal}"; shift 2 ;;
            --attempt)        attempt="${2:-}"; shift 2 ;;
            --allow-unpushed) allow_unpushed=1; shift ;;
            *) echo "mother_gates_run: unknown option: $1" >&2; return 2 ;;
        esac
    done
    mkdir -p "$out_dir" || return 2

    _GATES_RESULTS=""
    _GATES_PUSHED_OK=1
    _GATES_SANDBOX_STATE=""
    _GATES_SANDBOX_TOUCHED=0
    local head_sha branch
    head_sha=$(git -C "$work_dir" rev-parse HEAD 2>/dev/null) || head_sha=""
    branch=$(git -C "$work_dir" rev-parse --abbrev-ref HEAD 2>/dev/null) || branch=""

    # Built-in pre-checks (always blocking).
    _gates_precheck_clean_tree "$work_dir" "$out_dir"
    [ "$allow_unpushed" -eq 1 ] || _gates_precheck_pushed "$work_dir" "$out_dir" "$head_sha" "$branch"

    local tmp_prefix="$out_dir/.wd.$$" checks_file="$out_dir/.checks.$$" check
    _gates_prepare_env "$work_dir" "$base_ref" "$crew_file"
    jq -c '.gates.checks[]' "$crew_file" >"$checks_file"
    while IFS= read -r check; do
        [ -n "$check" ] || continue
        _gates_run_check "$check" "$posture" "$work_dir" "$out_dir" "$tmp_prefix"
    done <"$checks_file"
    rm -f "$checks_file" "$tmp_prefix".*

    if [ "$_GATES_SANDBOX_TOUCHED" -eq 1 ]; then
        mother_rwx_sandbox stop "$work_dir" >/dev/null 2>&1 || true
    fi

    printf '%s' "$_GATES_RESULTS" | jq -sc \
        --arg head_sha "$head_sha" --arg posture "$posture" --arg attempt "$attempt" '
        . as $r
        | {
            status: (if any($r[]; .blocking and .result == "failed") then "failed"
                     elif any($r[]; .result == "unavailable") then "incomplete"
                     else "passed" end),
            head_sha: $head_sha,
            posture: $posture,
            results: $r,
            not_run: [$r[] | select(.result == "unavailable") | .name]
          }
        | if $attempt != "" then . + {attempt: ($attempt | tonumber? // null)} else . end'
}

# mother_gates_render_text <result-json> <out_dir> <crew-json-file>
# Per-gate lines, then the excerpt and hint of each failing gate.
mother_gates_render_text() {
    local json="$1" out_dir="$2" crew_file="${3:-}"
    local row name result dur exit_code reason skip
    printf '%s' "$json" | jq -r '.results[] | [.name, .result, (.duration_s|tostring), ((.exit_code // "")|tostring), (.unavailable_reason // ""), (.skip_reason // "")] | join("|")' \
        | while IFS='|' read -r name result dur exit_code reason skip; do
            case "$result" in
                passed)      printf '✓ %s %ss\n' "$name" "$dur" ;;
                failed)      printf '✗ %s %ss — see %s/%s.log\n' "$name" "$dur" "$out_dir" "$name" ;;
                skipped)
                    case "$skip" in
                        not_applicable) printf '– %s (not applicable)\n' "$name" ;;
                        *)              printf '– %s (skipped: %s)\n' "$name" "$skip" ;;
                    esac ;;
                unavailable) printf '? %s (unavailable: %s)\n' "$name" "$reason" ;;
            esac
        done

    local failing hint
    failing=$(printf '%s' "$json" | jq -r '.results[] | select(.result == "failed") | .name')
    for name in $failing; do
        printf '\n--- %s (exit %s) ---\n' "$name" "$(printf '%s' "$json" | jq -r --arg n "$name" '.results[] | select(.name == $n) | .exit_code // "?"')"
        [ -f "$out_dir/$name.excerpt" ] && cat "$out_dir/$name.excerpt"
        case "$name" in
            clean_tree) hint="commit or discard your changes" ;;
            pushed)     hint="push your branch" ;;
            *)          hint=$(jq -r --arg n "$name" '.gates.checks[] | select(.name == $n) | .hint // empty' "$crew_file" 2>/dev/null) ;;
        esac
        [ -n "$hint" ] && printf 'hint: %s\n' "$hint"
    done
    return 0
}
