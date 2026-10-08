#!/usr/bin/env bats
# preview.bats — `mother preview`: per-job preview stacks.
#
# Contract under test (behaviour only; see the interface notes at the bottom of
# the hand-off for the names Cody must satisfy):
#   - `mother preview up|wait|info|verify|call|fake|down` for the job named by
#     MOTHER_JOB_ID or --job. Stack id = "job-" + job id, lowercased, runs of
#     non-[a-z0-9] collapsed to "-", at most 36 chars.
#   - `up` validates locally first (exit 2, nothing launched), checks the job
#     branch is pushed, drives the preview-stack CLI, records `.preview` on the
#     job + a `preview_up` event, and (unless --no-wait) waits for readiness.
#   - Owner secrets from the CLI go to $RUNNER_DIR/<job_id>.preview-secrets.json
#     (mode 0600) and nowhere else: not the job JSON, events, stdout/stderr, or
#     any argv. They reach curl only on STDIN (-K -).
#   - `mother-run-job` stops a non-stopped stack after EVERY worker exit
#     (reason worker_exit), before a fresh attempt spawns (attempt_start), and
#     mother-runner's orphan sweep stops a dead supervisor's stack (orphan).
#     Stop is best-effort: it never changes the job's terminal state.
#
# Harness: three fakes live in the per-test mock dir (created by heredoc):
#   fake-preview-stack  the CLI. Logs "<cwd>|<argv>" to $MOTHER_ROOT/preview-cli.log.
#   fake-http           the curl seam. Logs argv + stdin per call under
#                       $MOTHER_ROOT/http/calls/NNN/ and answers from canned
#                       files ($MOTHER_ROOT/http/canned/<url-key>).
#   rwx                 only `rwx results <run>` is answered (run-failed check).
# No network, no real addresses: every URL is https://*.example.invalid.

load 'test_helper'
bats_require_minimum_version 1.5.0

SENTINEL="MOTHER-PREVIEW-SECRET-SENTINEL-9c1e"
FAKE_LAUNCHED_AT="2026-10-04T17:25:28Z"
FAKE_SHA="1111111111111111111111111111111111111111"

setup() {
    setup_mother_env
    unset MOTHER_JOB_ID MOTHER_PREVIEW_ENABLED MOTHER_PREVIEW_BACKEND MOTHER_PREVIEW_STACK_REF
    unset FAKE_PS_EXIT_UP FAKE_PS_EXIT_DOWN FAKE_PS_EXIT_VERIFY FAKE_PS_SLEEP_UP FAKE_PS_SLEEP_DOWN FAKE_PS_SLEEP_VERIFY MOTHER_PREVIEW_VERIFY_TIMEOUT \
          FAKE_PS_STDERR_UP FAKE_PS_TEXT_DOWN FAKE_RWX_RUN_STATUS

    export MOTHER_PREVIEW_STACK_BIN="$_MOCK_BIN/fake-preview-stack"
    export MOTHER_PREVIEW_CURL="$_MOCK_BIN/fake-http"
    export MOTHER_PREVIEW_POLL_INTERVAL=1
    export MOTHER_PREVIEW_WAIT_TIMEOUT=4
    export MOTHER_PREVIEW_STOP_TIMEOUT=10
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120

    PV_LOG="$MOTHER_ROOT/preview-cli.log"
    RWX_LOG="$MOTHER_ROOT/rwx-calls.log"

    # ---- fake preview-stack CLI ------------------------------------------
    # Knobs (per subcommand, suffix _UP / _DOWN / _VERIFY):
    #   FAKE_PS_EXIT_*    exit code (default 0)
    #   FAKE_PS_SLEEP_*   hang this many seconds instead of finishing
    #   FAKE_PS_STDERR_UP stderr text on a failed up
    #   FAKE_PS_TEXT_DOWN text printed (stdout AND stderr) by down; printf %b
    #   FAKE_PS_LAUNCHED_AT / FAKE_PS_SHA / FAKE_PS_SENTINEL  canned values
    # `up` JSON includes owner_secrets whenever the component list has rm.
    cat > "$_MOCK_BIN/fake-preview-stack" <<'FAKEPS'
#!/usr/bin/env bash
sub="${1:-}"
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$MOTHER_ROOT/preview-cli.log"
upper=$(printf '%s' "$sub" | tr 'a-z' 'A-Z')
_knob() { local v="FAKE_PS_${1}_${upper}"; printf '%s' "${!v:-$2}"; }
sl=$(_knob SLEEP 0)
ec=$(_knob EXIT 0)
case "$sub" in
  up)
    shift
    id=""; comps=""; refs='{}'
    while [ $# -gt 0 ]; do
      case "$1" in
        --id) id="$2"; shift 2 ;;
        --components) comps="$2"; shift 2 ;;
        --ap|--fp|--payments|--rm)
          refs=$(printf '%s' "$refs" | jq -c --arg c "${1#--}" --arg r "$2" '.[$c] = $r'); shift 2 ;;
        *) shift ;;
      esac
    done
    echo "preview-stack: launching $id ($comps)" >&2
    [ "$sl" != "0" ] && exec sleep "$sl"
    if [ "$ec" != "0" ]; then
      echo "$(_knob STDERR 'up failed: canned failure')" >&2
      exit "$ec"
    fi
    combo=$(printf '%s' "$comps" | tr ',' '-')
    url="https://stk-${id}-${combo}.example.invalid"
    jq -nc --arg id "$id" --arg comps "$comps" --arg combo "$combo" --arg url "$url" \
       --arg launched "${FAKE_PS_LAUNCHED_AT:-2026-10-04T17:25:28Z}" \
       --arg sha "${FAKE_PS_SHA:-1111111111111111111111111111111111111111}" \
       --arg sentinel "${FAKE_PS_SENTINEL:-MOTHER-PREVIEW-SECRET-SENTINEL-9c1e}" \
       --argjson refs "$refs" '
      ($comps | split(",")) as $cs
      | {
          stack_id: $id, combo: $combo,
          run_id: "run-test-1",
          run_url: "https://cloud.example.invalid/runs/run-test-1",
          url: $url, health_url: ($url + "/__stack/health"), info_url: ($url + "/__stack/info"),
          launched_at: $launched,
          components: ([ $cs[] | {key: ., value: ({ref: ($refs[.] // "main"), sha: $sha}
                          + (if . == "ap" then {url: $url}
                             elif . == "fp" then {url: ("https://stk-" + $id + "-fp.example.invalid")}
                             elif . == "rm" then {url: $url}
                             else {url: null} end))} ] | from_entries)
        }
        + (if ($cs | index("ap")) then
             {urls: {"admin-portal": $url},
              logins: {"admin-portal": {user: "preview-admin@example.invalid", password: "preview-login-pass"}}}
           else {} end)
        + (if ($cs | index("rm")) then
             {owner_secrets: {
                seed: ($sentinel + "-seed"),
                tokens: ([ "CREDENTIAL_API_TOKEN","REFERRAL_ACTION_API_TOKEN","MESSAGING_API_TOKEN",
                           "ADMIN_API_TOKEN","OPERATIONS_API_TOKEN","FAKEPARTNERS_CONTROL_TOKEN" ]
                         | map({key: ., value: ($sentinel + "-" + .)}) | from_entries)}}
           else {} end)'
    exit 0
    ;;
  down)
    shift
    if [ -n "${FAKE_PS_TEXT_DOWN:-}" ]; then
      printf '%b\n' "$FAKE_PS_TEXT_DOWN"
      printf '%b\n' "$FAKE_PS_TEXT_DOWN" >&2
    elif [ "$ec" = "0" ]; then
      printf '{"stack_id":"%s","status":"down"}\n' "${1:-}"
    else
      echo "down failed: canned failure" >&2
    fi
    [ "$sl" != "0" ] && exec sleep "$sl"
    exit "$ec"
    ;;
  verify)
    [ "$sl" != "0" ] && exec sleep "$sl"
    echo "verify-output-marker ${2:-}"
    exit "$ec"
    ;;
  *)
    echo "fake-preview-stack: unexpected subcommand '$sub'" >&2
    exit 64
    ;;
esac
FAKEPS
    chmod +x "$_MOCK_BIN/fake-preview-stack"

    # ---- fake curl --------------------------------------------------------
    # Understands the curl flags Mother might use (-o -w -X -d -D -i -f -K -);
    # logs argv and stdin per call; answers from canned files keyed by URL.
    cat > "$_MOCK_BIN/fake-http" <<'FAKEHTTP'
#!/usr/bin/env bash
base="$MOTHER_ROOT/http"
mkdir -p "$base/calls"
n=$(ls "$base/calls" | wc -l | tr -d ' ')
dir="$base/calls/$(printf '%03d' $((n + 1)))"
mkdir -p "$dir"
printf '%s\n' "$@" > "$dir/argv"

url=""; method=""; data=""; out=""; wfmt=""; include=0; fail=0; cfg=0; dump=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) out="${2:-}"; shift 2 ;;
    -w|--write-out) wfmt="${2:-}"; shift 2 ;;
    -X|--request) method="${2:-}"; shift 2 ;;
    -d|--data|--data-raw|--data-binary|--data-ascii) data="${2:-}"; shift 2 ;;
    -D|--dump-header) dump="${2:-}"; shift 2 ;;
    -K|--config) { [ "${2:-}" = "-" ] || [ "${2:-}" = "/dev/stdin" ]; } && cfg=1; shift 2 ;;
    -H|--header|-m|--max-time|--connect-timeout|--retry|-A|--user-agent|-u|--user) shift 2 ;;
    -i|--include) include=1; shift ;;
    --fail|--fail-with-body) fail=1; shift ;;
    --*) shift ;;
    https://*) url="$1"; shift ;;
    -*f*) fail=1; shift ;;
    *) shift ;;
  esac
done

if [ "$cfg" = "1" ]; then cat > "$dir/stdin"; else : > "$dir/stdin"; fi
if [ -s "$dir/stdin" ]; then
  while IFS= read -r l || [ -n "$l" ]; do
    k=$(printf '%s' "$l" | sed -n 's/^[[:space:]]*\([a-z-]*\)[[:space:]]*=.*/\1/p')
    v=$(printf '%s' "$l" | sed -n 's/^[^=]*=[[:space:]]*"\(.*\)"[[:space:]]*$/\1/p' | sed -e 's/\\"/"/g' -e 's/\\\\/\\/g')
    case "$k" in
      url) [ -n "$url" ] || url="$v" ;;
      request) method="$v" ;;
      data|data-raw|data-binary) data="$v" ;;
    esac
  done < "$dir/stdin"
fi
case "$data" in @*) data=$(cat "${data#@}" 2>/dev/null) ;; esac
[ -n "$method" ] || { [ -n "$data" ] && method=POST || method=GET; }
printf '%s' "$url" > "$dir/url"
printf '%s' "$method" > "$dir/method"
printf '%s' "$data" > "$dir/data"

key=$(printf '%s' "${url#https://}" | tr -c 'A-Za-z0-9' '_')
f="$base/canned/$key"
if [ -f "$f" ]; then
  code=$(head -n 1 "$f"); body=$(tail -n +2 "$f")
else
  code=404; body=""
fi
hdr="HTTP/1.1 $code Canned"
payload="$body"
[ "$include" = "1" ] && payload=$(printf '%s\r\n\r\n%s' "$hdr" "$body")
if [ -n "$dump" ]; then
  if [ "$dump" = "-" ]; then printf '%s\r\n\r\n' "$hdr"; else printf '%s\r\n\r\n' "$hdr" > "$dump"; fi
fi
if [ -n "$out" ]; then printf '%s' "$payload" > "$out"; else printf '%s' "$payload"; fi
if [ -n "$wfmt" ]; then printf '%b' "${wfmt//%\{http_code\}/$code}"; fi
if [ "$fail" = "1" ] && [ "$code" -ge 400 ] 2>/dev/null; then exit 22; fi
exit 0
FAKEHTTP
    chmod +x "$_MOCK_BIN/fake-http"

    # ---- fake rwx (only `results` is meaningful) --------------------------
    cat > "$_MOCK_BIN/rwx" <<'FAKERWX'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$MOTHER_ROOT/rwx-calls.log"
case "${1:-}" in
  results)
    st="${FAKE_RWX_RUN_STATUS:-in_progress}"
    jq -nc --arg s "$st" --arg id "${2:-}" \
      '{RunID: $id, run_id: $id, ResultStatus: $s, result_status: $s, status: $s,
        Status: {Result: $s}, Completed: ($s != "in_progress"), completed: ($s != "in_progress")}'
    exit 0 ;;
  *) echo "fake rwx: unexpected call: $*" >&2; exit 97 ;;
esac
FAKERWX
    chmod +x "$_MOCK_BIN/rwx"

    # ---- git: a real local bare repo as `origin` --------------------------
    ORIGIN="$MOTHER_ROOT/origin.git"
    WORK="$MOTHER_ROOT/work"
    export TEST_REPO_DIR="$WORK"
    git init -q --bare "$ORIGIN"
    git init -q -b main "$WORK"
    git -C "$WORK" config user.email "test@example.com"
    git -C "$WORK" config user.name "Test"
    echo "# repo" > "$WORK/README.md"
    git -C "$WORK" add README.md
    git -C "$WORK" commit -q -m "init"
    git -C "$WORK" remote add origin "$ORIGIN"
    git -C "$WORK" push -q origin main

    cat > "$_MOCK_BIN/gh" <<'GH'
#!/usr/bin/env bash
exit 0
GH
    chmod +x "$_MOCK_BIN/gh"
}

teardown() {
    # Reap any hung stand-ins a timeout test left behind.
    [ -f "$MOTHER_ROOT/claude.pid" ] && kill "$(cat "$MOTHER_ROOT/claude.pid")" 2>/dev/null || true
    pkill -f "sleep 30" 2>/dev/null || true
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Helpers: ids, git, jobs

_slug() { printf '%s' "$1" | tr 'A-Z' 'a-z' | sed -e 's/[^a-z0-9][^a-z0-9]*/-/g'; }
_stack_id() { printf 'job-%s' "$(_slug "$1")"; }
# The friendly URL the fake CLI reports for a job + combo ("ap", "ap-fp", "rm").
_url() { printf 'https://stk-%s-%s.example.invalid' "$(_stack_id "$1")" "$2"; }
_sha7() { printf '%s' "$1" | cut -c1-7; }
_head() { git -C "$WORK" rev-parse HEAD; }
_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }
_real() { (cd "$1" && pwd -P); }

# Cut <branch> from main with one commit; HEAD stays on it. Not pushed.
_mk_branch() {
    git -C "$WORK" checkout -q -B "$1" main
    git -C "$WORK" commit -q --allow-empty -m "work on $1"
}
_push_branch() { git -C "$WORK" push -q origin "$1"; }

# _make_pv_job <id> <repo> [branch] [extra-jq]  — a running job whose work_dir
# is the test repo (origin = the local bare repo).
_make_pv_job() {
    local id="$1" repo="$2" branch="${3:-feature/$1}" extra="${4:-.}"
    make_job "$id" running \
        ".repo = \"$repo\" | .repo_path = \"$WORK\" | .work_dir = \"$WORK\" | .branch = \"$branch\" | .isolation = \"main-dir\" | $extra"
}

# Pushed branch + job + MOTHER_JOB_ID exported.
_pv_job() {
    local id="$1" repo="$2" branch="${3:-feature/$1}"
    _mk_branch "$branch"
    _push_branch "$branch"
    _make_pv_job "$id" "$repo" "$branch"
    export MOTHER_JOB_ID="$id"
}

_up_nowait() {
    run mother preview up "$@" --no-wait
    [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Helpers: logs and calls

_count_in() { # <fixed-string> <file>
    local n
    n=$(grep -cF -- "$1" "$2" 2>/dev/null) || true
    echo "${n:-0}"
}
_cli_calls() { cat "$PV_LOG" 2>/dev/null | wc -l | tr -d ' '; }
_down_calls() { _count_in "|down $1" "$PV_LOG"; }   # <stack_id>
_http_calls() { ls "$MOTHER_ROOT/http/calls" 2>/dev/null | wc -l | tr -d ' '; }
_assert_nothing_launched() {
    [ "$(_cli_calls)" = "0" ]
    [ "$(_http_calls)" = "0" ]
}
_http_key() { printf '%s' "${1#https://}" | tr -c 'A-Za-z0-9' '_'; }
_http_set() { # <url> <code> <body>
    mkdir -p "$MOTHER_ROOT/http/canned"
    printf '%s\n%s' "$2" "$3" > "$MOTHER_ROOT/http/canned/$(_http_key "$1")"
}
# Last fake-http call dir whose URL is <url>.
_http_find() {
    local d last=""
    for d in "$MOTHER_ROOT"/http/calls/*/; do
        [ -f "${d}url" ] || continue
        [ "$(cat "${d}url")" = "$1" ] && last="${d%/}"
    done
    printf '%s' "$last"
}
_http_count_url() { # <url> [method]
    local d n=0
    for d in "$MOTHER_ROOT"/http/calls/*/; do
        [ -f "${d}url" ] || continue
        [ "$(cat "${d}url")" = "$1" ] || continue
        if [ -n "${2:-}" ] && [ "$(cat "${d}method")" != "$2" ]; then continue; fi
        n=$((n + 1))
    done
    echo "$n"
}
# Canned readiness answers for <job_id> with combo <combo>; info reports <sha>
# for component <comp>.
_set_ready_http() { # <job_id> <combo> <comp> <sha>
    local u; u=$(_url "$1" "$2")
    _http_set "$u/__stack/health" 200 "{\"status\":\"ok\",\"launched_at\":\"$FAKE_LAUNCHED_AT\"}"
    _http_set "$u/__stack/info" 200 "{\"components\":{\"$3\":{\"sha\":\"$4\"}}}"
}

# ---------------------------------------------------------------------------
# Helpers: events

_event_count() {
    jq -c --arg k "$2" 'select(.kind == $k)' "$EVENTS_DIR/$1.jsonl" 2>/dev/null \
        | wc -l | tr -d ' '
}
# _event_field <id> <kind> <nth|last> <field>
_event_field() {
    local id="$1" kind="$2" nth="$3" field="$4" line
    if [ "$nth" = "last" ]; then
        line=$(jq -c --arg k "$kind" 'select(.kind == $k) | .detail' "$EVENTS_DIR/$id.jsonl" | tail -1)
    else
        line=$(jq -c --arg k "$kind" 'select(.kind == $k) | .detail' "$EVENTS_DIR/$id.jsonl" | sed -n "${nth}p")
    fi
    printf '%s' "$line" | jq -r ".$field"
}

# No owner secret may be anywhere under MOTHER_ROOT except the 0600 secrets
# file and fake-http's recorded stdin (the mock dir holds the fake's own text).
_assert_secrets_contained() {
    local hits
    hits=$(grep -rlF --exclude-dir=mock-bin -- "$SENTINEL" "$MOTHER_ROOT" 2>/dev/null \
        | grep -v -e 'preview-secrets.json$' -e '/http/calls/[0-9]*/stdin$' || true)
    if [ -n "$hits" ]; then
        echo "owner secret leaked into: $hits" >&2
        return 1
    fi
}
_assert_no_secret_in_argv() {
    ! grep -qF -- "$SENTINEL" "$PV_LOG" 2>/dev/null
    local f
    for f in "$MOTHER_ROOT"/http/calls/*/argv; do
        [ -f "$f" ] || continue
        ! grep -qF -- "$SENTINEL" "$f"
    done
}

# ===========================================================================
# Identity and validation (all exit 2 and launch nothing)

@test "preview up with no job id (no MOTHER_JOB_ID, no --job) exits 2 and launches nothing" {
    _mk_branch feature/noid; _push_branch feature/noid
    _make_pv_job pvnoid admin-portal feature/noid
    run mother preview up --no-wait
    [ "$status" -eq 2 ]
    _assert_nothing_launched
}

@test "preview up --job <id> works without MOTHER_JOB_ID" {
    _mk_branch feature/viajob; _push_branch feature/viajob
    _make_pv_job pvviajob admin-portal feature/viajob
    run mother preview up --job pvviajob --no-wait
    [ "$status" -eq 0 ]
    assert_job_field pvviajob '.preview.stack_id' "$(_stack_id pvviajob)"
}

@test "stack id is job- + the lowercased job id with runs of non-alphanumerics collapsed to a dash" {
    local id="Feat__X.Y-AB"
    _pv_job "$id" admin-portal feature/norm
    _up_nowait
    assert_job_field "$id" '.preview.stack_id' 'job-feat-x-y-ab'
    grep -qF -- '--id job-feat-x-y-ab' "$PV_LOG"
}

@test "a 36-character stack id is accepted" {
    local id="abcdefghijklmnopqrstuvwxyz012345"   # 32 chars -> job- + 32 = 36
    [ "${#id}" -eq 32 ]
    _pv_job "$id" admin-portal feature/len36
    _up_nowait
    assert_job_field "$id" '.preview.stack_id' "job-$id"
}

@test "a stack id longer than 36 characters exits 2 and launches nothing" {
    local id="abcdefghijklmnopqrstuvwxyz0123456"   # 33 chars -> 37
    [ "${#id}" -eq 33 ]
    _pv_job "$id" admin-portal feature/len37
    run mother preview up --no-wait
    [ "$status" -eq 2 ]
    _assert_nothing_launched
}

@test "up --components fp (without ap) exits 2 with 'fp requires ap' and launches nothing" {
    _pv_job pvval1 admin-portal
    run mother preview up --components fp --no-wait
    [ "$status" -eq 2 ]
    [[ "$output" == *"fp requires ap"* ]]
    _assert_nothing_launched
}

@test "up --components payments (without ap) exits 2 with 'payments requires ap' and launches nothing" {
    _pv_job pvval2 admin-portal
    run mother preview up --components payments --no-wait
    [ "$status" -eq 2 ]
    [[ "$output" == *"payments requires ap"* ]]
    _assert_nothing_launched
}

@test "up with an unknown component exits 2 and launches nothing" {
    _pv_job pvval3 admin-portal
    run mother preview up --components ap,zz --no-wait
    [ "$status" -eq 2 ]
    _assert_nothing_launched
}

@test "up with a ref for a component that is not selected (--rm without rm) exits 2 and launches nothing" {
    _pv_job pvval4 admin-portal
    run mother preview up --rm main --no-wait
    [ "$status" -eq 2 ]
    _assert_nothing_launched
}

@test "up on a repo with no default components (mother) and no --components exits 2 and launches nothing" {
    _pv_job pvval5 mother
    run mother preview up --no-wait
    [ "$status" -eq 2 ]
    _assert_nothing_launched
}

@test "up on an unpushed branch exits 2 with 'push first' (origin has nothing) and launches nothing" {
    _mk_branch feature/unpushed
    _make_pv_job pvpush1 admin-portal feature/unpushed
    export MOTHER_JOB_ID=pvpush1
    run mother preview up --no-wait
    [ "$status" -eq 2 ]
    [[ "$output" == *"push first"* ]]
    [[ "$output" == *"nothing"* ]]
    [[ "$output" == *"$(_sha7 "$(_head)")"* ]]
    _assert_nothing_launched
}

@test "up when HEAD has moved past what origin has exits 2 with 'push first' naming both shas" {
    _mk_branch feature/diverged
    _push_branch feature/diverged
    local pushed; pushed=$(_head)
    git -C "$WORK" commit -q --allow-empty -m "local only"
    local local_head; local_head=$(_head)
    [ "$pushed" != "$local_head" ]
    _make_pv_job pvpush2 admin-portal feature/diverged
    export MOTHER_JOB_ID=pvpush2
    run mother preview up --no-wait
    [ "$status" -eq 2 ]
    [[ "$output" == *"push first"* ]]
    [[ "$output" == *"$(_sha7 "$pushed")"* ]]
    [[ "$output" == *"$(_sha7 "$local_head")"* ]]
    _assert_nothing_launched
}

@test "a repo with no own component (mother --components ap) has no pushed-branch check" {
    _mk_branch feature/ownless          # deliberately not pushed
    _make_pv_job pvown mother feature/ownless
    export MOTHER_JOB_ID=pvown
    _up_nowait --components ap
    grep -qF -- 'up --via dispatch --stack main --purpose job' "$PV_LOG"
    grep -qF -- '--components ap --ap main' "$PV_LOG"
    assert_job_field pvown '.preview.expected_sha | length' '0'
}

# ===========================================================================
# Backend seam and kill switch

@test "MOTHER_PREVIEW_BACKEND=operations: up exits 3 'not available' and makes no calls" {
    _pv_job pvbk1 admin-portal
    export MOTHER_PREVIEW_BACKEND=operations
    run mother preview up --no-wait
    [ "$status" -eq 3 ]
    [[ "$output" == *"is not available"* ]]
    [[ "$output" == *"operations"* ]]
    _assert_nothing_launched
    assert_job_field pvbk1 '.preview // "none"' 'none'
}

@test "MOTHER_PREVIEW_ENABLED=0: up exits 3 and makes no calls" {
    _pv_job pvkill admin-portal
    export MOTHER_PREVIEW_ENABLED=0
    run mother preview up --no-wait
    [ "$status" -eq 3 ]
    _assert_nothing_launched
}

@test "lib/preview.sh mentions 'operations' only in the seam comment and the not-available message" {
    local f="$_LIB_DIR/preview.sh" hits="$MOTHER_ROOT/ops-hits" line body bad=0
    [ -f "$f" ]
    grep -n 'operations' "$f" > "$hits" || true
    grep -q 'is not available' "$hits"
    while IFS= read -r line; do
        body="${line#*:}"
        case "$body" in
            *"is not available"*) ;;
            *)
                body=$(printf '%s' "$body" | sed 's/^[[:space:]]*//')
                [ "${body%"${body#?}"}" = "#" ] || { echo "stray 'operations' reference: $line" >&2; bad=1; }
                ;;
        esac
    done < "$hits"
    [ "$bad" = "0" ]
}

# ===========================================================================
# up: launch arguments and the recorded .preview

@test "up on an admin-portal job runs the CLI with the exact dispatch args from the job's work_dir" {
    _pv_job pvup1 admin-portal feature/pvup1
    _up_nowait
    local want="$(_real "$WORK")|up --via dispatch --stack main --purpose job --id $(_stack_id pvup1) --components ap --ap feature/pvup1"
    [ "$(_count_in "$want" "$PV_LOG")" = "1" ]
    [ "$(_cli_calls)" = "1" ]
    # Pure local operation: no HTTP at all with --no-wait.
    [ "$(_http_calls)" = "0" ]
}

@test "up --stack <ref> passes the ref through to the CLI's --stack" {
    _pv_job pvstk1 admin-portal feature/pvstk1
    _up_nowait --stack feature/ps-fix
    grep -qF -- 'up --via dispatch --stack feature/ps-fix --purpose job' "$PV_LOG"
}

@test "up without --stack still uses MOTHER_PREVIEW_STACK_REF/main" {
    _pv_job pvstk2 admin-portal feature/pvstk2
    _up_nowait
    grep -qF -- '--stack main --purpose job' "$PV_LOG"
}

@test "up --stack @worktree on a preview-stack job uses the pushed job branch" {
    _pv_job pvstk3 preview-stack feature/pvstk3
    _up_nowait --components ap --stack @worktree
    grep -qF -- 'up --via dispatch --stack feature/pvstk3 --purpose job' "$PV_LOG"
}

@test "up --stack @worktree on an unpushed preview-stack branch exits 2 with 'push first'" {
    _mk_branch feature/pvstk4
    _make_pv_job pvstk4 preview-stack feature/pvstk4
    export MOTHER_JOB_ID=pvstk4
    run mother preview up --components ap --stack @worktree --no-wait
    [ "$status" -eq 2 ]
    [[ "$output" == *"push first"* ]]
    _assert_nothing_launched
}

@test "up --stack @worktree on a non-preview-stack repo exits 2 and launches nothing" {
    _pv_job pvstk5 admin-portal feature/pvstk5
    run mother preview up --stack @worktree --no-wait
    [ "$status" -eq 2 ]
    [[ "$output" == *"preview-stack"* ]]
    _assert_nothing_launched
}

@test "up --stack rejects unsafe refs (exit 2, nothing launched)" {
    _pv_job pvstk6 admin-portal feature/pvstk6
    local bad
    for bad in '--evil' 'a b' 'a;touch x' '$(id)' 'a`id`' 'a..b' 'x/' 'x.lock' '/abs' 'a//b' ''; do
        run mother preview up --stack "$bad" --no-wait
        [ "$status" -eq 2 ]
        _assert_nothing_launched
    done
    [ ! -e x ]
}

@test "up --stack with no value exits 2" {
    _pv_job pvstk7 admin-portal feature/pvstk7
    run mother preview up --stack
    [ "$status" -eq 2 ]
    _assert_nothing_launched
}

@test "up records .preview on the job and appends an identical preview_up event" {
    _pv_job pvup2 admin-portal feature/pvup2
    local sha; sha=$(_head)
    _up_nowait
    local sid; sid=$(_stack_id pvup2)
    assert_job_field pvup2 '.preview.backend' 'cli'
    assert_job_field pvup2 '.preview.stack_id' "$sid"
    assert_job_field pvup2 '.preview.status' 'launching'
    assert_job_field pvup2 '.preview.launches' '1'
    assert_job_field pvup2 '.preview.stopped_at' 'null'
    assert_job_field pvup2 '.preview.components | join(",")' 'ap'
    assert_job_field pvup2 '.preview.combo' 'ap'
    assert_job_field pvup2 '.preview.run_id' 'run-test-1'
    assert_job_field pvup2 '.preview.run_url' 'https://cloud.example.invalid/runs/run-test-1'
    assert_job_field pvup2 '.preview.launched_at' "$FAKE_LAUNCHED_AT"
    assert_job_field pvup2 '.preview.refs.ap.ref' 'feature/pvup2'
    assert_job_field pvup2 '.preview.refs.ap.sha' "$FAKE_SHA"
    # expected_sha is what is pushed (the job's HEAD), not what the CLI echoes.
    assert_job_field pvup2 '.preview.expected_sha.ap' "$sha"
    # The friendly URL is recorded somewhere in .urls.
    run jq -e --arg u "$(_url pvup2 ap)" '.preview.urls | [.. | strings] | any(. == $u)' "$JOBS_DIR/pvup2.json"
    [ "$status" -eq 0 ]

    [ "$(_event_count pvup2 preview_up)" = "1" ]
    local ev rec
    # (The CLI's published logins may ride along on the job record only; the
    # event carries the same object otherwise.)
    ev=$(jq -S -c 'select(.kind == "preview_up") | .detail | del(.logins)' "$EVENTS_DIR/pvup2.jsonl")
    rec=$(jq -S -c '.preview | del(.logins)' "$JOBS_DIR/pvup2.json")
    [ "$ev" = "$rec" ]
}

@test "up --with fp adds fp from main: --components ap,fp --ap <branch> --fp main" {
    _pv_job pvup3 admin-portal feature/pvup3
    _up_nowait --with fp
    local want="up --via dispatch --stack main --purpose job --id $(_stack_id pvup3) --components ap,fp --ap feature/pvup3 --fp main"
    [ "$(_count_in "|$want" "$PV_LOG")" = "1" ]
    assert_job_field pvup3 '.preview.backend' 'cli'
    assert_job_field pvup3 '.preview.components | join(",")' 'ap,fp'
    assert_job_field pvup3 '.preview.refs.fp.ref' 'main'
    [ "$(_event_count pvup3 preview_up)" = "1" ]
    # Both component URLs are published.
    run jq -e --arg a "$(_url pvup3 ap-fp)" \
              --arg f "https://stk-$(_stack_id pvup3)-fp.example.invalid" \
        '.preview.urls | [.. | strings] | (any(. == $a)) and (any(. == $f))' "$JOBS_DIR/pvup3.json"
    [ "$status" -eq 0 ]
}

@test "up with an explicit ref for a non-own component passes it through" {
    _pv_job pvup4 admin-portal feature/pvup4
    _up_nowait --with fp --fp feature/fp-other
    grep -qF -- '--fp feature/fp-other' "$PV_LOG"
    assert_job_field pvup4 '.preview.refs.fp.ref' 'feature/fp-other'
}

@test "family-portal job defaults to ap,fp with the branch on fp and main on ap" {
    _pv_job pvfp family-portal feature/pvfp
    _up_nowait
    grep -qF -- "--components ap,fp --ap main --fp feature/pvfp" "$PV_LOG"
    assert_job_field pvfp '.preview.expected_sha | keys | join(",")' 'fp'
    assert_job_field pvfp '.preview.expected_sha.fp' "$(_head)"
}

@test "payments job defaults to ap,payments with the branch on payments" {
    _pv_job pvpay payments feature/pvpay
    _up_nowait
    grep -qF -- "--components ap,payments --ap main --payments feature/pvpay" "$PV_LOG"
    assert_job_field pvpay '.preview.expected_sha | keys | join(",")' 'payments'
}

@test "referral-monitor job defaults to rm with the branch on rm" {
    _pv_job pvrm referral-monitor feature/pvrm
    _up_nowait
    grep -qF -- "--components rm --rm feature/pvrm" "$PV_LOG"
    assert_job_field pvrm '.preview.expected_sha | keys | join(",")' 'rm'
}

@test "a second up relaunches the same stack id and increments launches" {
    _pv_job pvre admin-portal feature/pvre
    _up_nowait
    _up_nowait
    local sid; sid=$(_stack_id pvre)
    [ "$(_count_in "--id $sid " "$PV_LOG")" = "2" ]
    assert_job_field pvre '.preview.stack_id' "$sid"
    assert_job_field pvre '.preview.launches' '2'
    [ "$(_event_count pvre preview_up)" = "2" ]
}

@test "up --json prints the recorded .preview object on stdout and nothing else" {
    _pv_job pvjson admin-portal feature/pvjson
    run --separate-stderr mother preview up --no-wait --json
    [ "$status" -eq 0 ]
    local printed rec
    printed=$(printf '%s' "$output" | jq -S -c 'del(.logins)')
    rec=$(jq -S -c '.preview | del(.logins)' "$JOBS_DIR/pvjson.json")
    [ "$printed" = "$rec" ]
}

@test "up (human output) shows the stack URL, the published AP login and how to stop it" {
    _pv_job pvhuman admin-portal feature/pvhuman
    run mother preview up --no-wait
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(_url pvhuman ap)"* ]]
    [[ "$output" == *"preview-admin@example.invalid"* ]]
    [[ "$output" == *"mother preview down"* ]]
}

@test "up maps CLI exit 3 (vault refused) to exit 3" {
    _pv_job pvx3 admin-portal
    export FAKE_PS_EXIT_UP=3
    run mother preview up --no-wait
    [ "$status" -eq 3 ]
}

@test "up maps CLI exit 2 (usage) to exit 2" {
    _pv_job pvx2 admin-portal
    export FAKE_PS_EXIT_UP=2
    run mother preview up --no-wait
    [ "$status" -eq 2 ]
}

@test "up with any other CLI failure exits 1 and shows the CLI's stderr" {
    _pv_job pvx1 admin-portal
    export FAKE_PS_EXIT_UP=1 FAKE_PS_STDERR_UP="dispatch refused: canned-boom"
    run mother preview up --no-wait
    [ "$status" -eq 1 ]
    [[ "$output" == *"canned-boom"* ]]
}

@test "up without --no-wait waits for readiness, then reports ready" {
    _pv_job pvupw admin-portal feature/pvupw
    _set_ready_http pvupw ap ap "$(_head)"
    run mother preview up
    [ "$status" -eq 0 ]
    assert_job_field pvupw '.preview.status' 'ready'
    [ "$(_event_count pvupw preview_ready)" = "1" ]
}

# ===========================================================================
# Owner secrets

_rm_job() { _pv_job "$1" referral-monitor "feature/$1"; }

@test "rm launch: owner secrets are written to a 0600 file under RUNNER_DIR and removed from the record" {
    _rm_job pvs1
    _up_nowait
    local f="$RUNNER_DIR/pvs1.preview-secrets.json"
    [ -f "$f" ]
    [ "$(_mode "$f")" = "600" ]
    [ "$(jq -r '.tokens.FAKEPARTNERS_CONTROL_TOKEN' "$f")" = "${SENTINEL}-FAKEPARTNERS_CONTROL_TOKEN" ]
    [ "$(jq -r '.tokens.CREDENTIAL_API_TOKEN' "$f")" = "${SENTINEL}-CREDENTIAL_API_TOKEN" ]
    [ "$(jq -r '.seed' "$f")" = "${SENTINEL}-seed" ]
    # Not in the job record (neither as a key nor as a value).
    assert_job_field pvs1 '.preview | has("owner_secrets")' 'false'
    ! grep -qF -- "$SENTINEL" "$JOBS_DIR/pvs1.json"
    ! grep -qF -- "$SENTINEL" "$EVENTS_DIR/pvs1.jsonl"
}

@test "rm launch: the secret never reaches up's stdout/stderr (text or --json), info, or any argv" {
    _rm_job pvs2
    run mother preview up --no-wait
    [ "$status" -eq 0 ]
    [[ "$output" != *"$SENTINEL"* ]]
    run mother preview up --no-wait --json
    [ "$status" -eq 0 ]
    [[ "$output" != *"$SENTINEL"* ]]
    run mother preview info
    [ "$status" -eq 0 ]
    [[ "$output" != *"$SENTINEL"* ]]
    _assert_no_secret_in_argv
    _assert_secrets_contained
}

@test "rm launch with readiness wait: secrets still stay in the secrets file only" {
    _rm_job pvs3
    _set_ready_http pvs3 rm rm "$(_head)"
    run mother preview up
    [ "$status" -eq 0 ]
    [[ "$output" != *"$SENTINEL"* ]]
    _assert_no_secret_in_argv
    _assert_secrets_contained
    [ -f "$RUNNER_DIR/pvs3.preview-secrets.json" ]
}

@test "call --token puts the bearer on curl's stdin, never argv, and prints HTTP code to stderr and body to stdout" {
    _rm_job pvc1
    _up_nowait
    local u; u=$(_url pvc1 rm)
    _http_set "$u/api/things" 200 '{"things":[1,2]}'
    run --separate-stderr mother preview call GET /api/things --token CREDENTIAL_API_TOKEN
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -c .)" = '{"things":[1,2]}' ]
    [[ "$stderr" == *"HTTP 200"* ]]
    local d; d=$(_http_find "$u/api/things")
    [ -n "$d" ]
    [ "$(cat "$d/method")" = "GET" ]
    grep -qF -- "Bearer ${SENTINEL}-CREDENTIAL_API_TOKEN" "$d/stdin"
    _assert_no_secret_in_argv
    _assert_secrets_contained
}

@test "call POST --data sends the body to <url><path>" {
    _rm_job pvc2
    _up_nowait
    local u; u=$(_url pvc2 rm)
    _http_set "$u/api/things" 201 '{"created":true}'
    run --separate-stderr mother preview call POST /api/things --token ADMIN_API_TOKEN --data '{"a":1}'
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"HTTP 201"* ]]
    local d; d=$(_http_find "$u/api/things")
    [ "$(cat "$d/method")" = "POST" ]
    [ "$(jq -S -c . "$d/data")" = '{"a":1}' ]
    grep -qF -- "Bearer ${SENTINEL}-ADMIN_API_TOKEN" "$d/stdin"
}

@test "call exits 1 for a non-2xx response (still printing HTTP code and body)" {
    _rm_job pvc3
    _up_nowait
    local u; u=$(_url pvc3 rm)
    _http_set "$u/nope" 404 'not here'
    run --separate-stderr mother preview call GET /nope --token ADMIN_API_TOKEN
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"HTTP 404"* ]]
    [[ "$output" == *"not here"* ]]
}

@test "call without --token sends no bearer" {
    _pv_job pvc4 admin-portal
    _up_nowait
    local u; u=$(_url pvc4 ap)
    _http_set "$u/ping" 200 'pong'
    run --separate-stderr mother preview call GET /ping
    [ "$status" -eq 0 ]
    local d; d=$(_http_find "$u/ping")
    ! grep -qi 'bearer' "$d/stdin"
    ! grep -qi 'bearer' "$d/argv"
}

@test "call --token with an unknown token name exits 2 and makes no request" {
    _rm_job pvc5
    _up_nowait
    run mother preview call GET /x --token NOT_A_TOKEN
    [ "$status" -eq 2 ]
    [ "$(_http_calls)" = "0" ]
}

@test "call --token on a stack without owner secrets (no rm) exits 2 and makes no request" {
    _pv_job pvc6 admin-portal
    _up_nowait
    run mother preview call GET /x --token ADMIN_API_TOKEN
    [ "$status" -eq 2 ]
    [ "$(_http_calls)" = "0" ]
}

@test "fake <scenario> POSTs {} to /__fake/scenarios/<scenario> with the control token on stdin" {
    _rm_job pvf0
    _up_nowait
    local u; u=$(_url pvf0 rm)
    _http_set "$u/__fake/scenarios/reset" 200 '{"ok":true}'
    run --separate-stderr mother preview fake reset
    [ "$status" -eq 0 ]
    local d; d=$(_http_find "$u/__fake/scenarios/reset")
    [ -n "$d" ]
    [ "$(cat "$d/method")" = "POST" ]
    [ "$(jq -S -c . "$d/data")" = '{}' ]
    grep -qF -- "Bearer ${SENTINEL}-FAKEPARTNERS_CONTROL_TOKEN" "$d/stdin"
    _assert_no_secret_in_argv
}

@test "fake new-referral --source aidin --body merges source into the body" {
    _rm_job pvf1
    _up_nowait
    local u; u=$(_url pvf1 rm)
    _http_set "$u/__fake/scenarios/new-referral" 200 '{"ok":true}'
    run --separate-stderr mother preview fake new-referral --source aidin --body '{"count":1}'
    [ "$status" -eq 0 ]
    local d; d=$(_http_find "$u/__fake/scenarios/new-referral")
    [ -n "$d" ]
    [ "$(cat "$d/method")" = "POST" ]
    [ "$(jq -S -c . "$d/data")" = '{"count":1,"source":"aidin"}' ]
    grep -qF -- "Bearer ${SENTINEL}-FAKEPARTNERS_CONTROL_TOKEN" "$d/stdin"
    ! grep -qF -- "$SENTINEL" "$d/argv"
}

@test "fake on a stack without rm exits 2 and makes no request" {
    _pv_job pvf2 admin-portal
    _up_nowait
    run mother preview fake new-referral --source aidin
    [ "$status" -eq 2 ]
    [ "$(_http_calls)" = "0" ]
}

@test "down removes the secrets file (and the sentinel is then nowhere on disk but the mock dir)" {
    _rm_job pvs4
    _up_nowait
    [ -f "$RUNNER_DIR/pvs4.preview-secrets.json" ]
    run mother preview down
    [ "$status" -eq 0 ]
    [ ! -e "$RUNNER_DIR/pvs4.preview-secrets.json" ]
    _assert_secrets_contained
}

# ===========================================================================
# wait

@test "wait: ready only when health is 200 with this launch's launched_at AND info reports the pushed sha" {
    _pv_job pvw1 admin-portal feature/pvw1
    _up_nowait
    _set_ready_http pvw1 ap ap "$(_head)"
    run mother preview wait
    [ "$status" -eq 0 ]
    assert_job_field pvw1 '.preview.status' 'ready'
    [ "$(_event_count pvw1 preview_ready)" = "1" ]
    run jq -e '.detail.wait_s | type == "number"' <(jq -c 'select(.kind == "preview_ready")' "$EVENTS_DIR/pvw1.jsonl")
    [ "$status" -eq 0 ]
    # Exactly one info GET, after readiness.
    [ "$(_http_count_url "$(_url pvw1 ap)/__stack/info" GET)" = "1" ]
    [ "$(_http_count_url "$(_url pvw1 ap)/__stack/health" GET)" -ge "1" ]
}

@test "wait prints the record as JSON on success" {
    _pv_job pvw1b admin-portal feature/pvw1b
    _up_nowait
    _set_ready_http pvw1b ap ap "$(_head)"
    run --separate-stderr mother preview wait
    [ "$status" -eq 0 ]
    [ "$(printf '%s' "$output" | jq -r '.stack_id')" = "$(_stack_id pvw1b)" ]
}

@test "wait: an 'App Starting' page keeps polling until the timeout, then exits 4 and stays launching" {
    _pv_job pvw2 admin-portal feature/pvw2
    _up_nowait
    local u; u=$(_url pvw2 ap)
    _http_set "$u/__stack/health" 200 '<html><body>App Starting</body></html>'
    run mother preview wait --timeout 3
    [ "$status" -eq 4 ]
    [[ "$output" == *"still starting after"* ]]
    [[ "$output" == *"mother preview wait"* ]]
    assert_job_field pvw2 '.preview.status' 'launching'
    [ "$(_event_count pvw2 preview_ready)" = "0" ]
    # It really polled more than once.
    [ "$(_http_count_url "$u/__stack/health")" -ge "2" ]
}

@test "wait: a health answer from a stale launch (different launched_at) is not ready" {
    _pv_job pvw3 admin-portal feature/pvw3
    _up_nowait
    local u; u=$(_url pvw3 ap)
    _http_set "$u/__stack/health" 200 '{"status":"ok","launched_at":"2020-01-01T00:00:00Z"}'
    _http_set "$u/__stack/info" 200 "{\"components\":{\"ap\":{\"sha\":\"$(_head)\"}}}"
    run mother preview wait --timeout 3
    [ "$status" -eq 4 ]
    assert_job_field pvw3 '.preview.status' 'launching'
}

@test "wait: a non-200 health answer is not ready" {
    _pv_job pvw3b admin-portal feature/pvw3b
    _up_nowait
    local u; u=$(_url pvw3b ap)
    _http_set "$u/__stack/health" 503 "{\"launched_at\":\"$FAKE_LAUNCHED_AT\"}"
    run mother preview wait --timeout 3
    [ "$status" -eq 4 ]
}

@test "wait: info reporting a different sha than the pushed one exits 1 naming both shas" {
    _pv_job pvw4 admin-portal feature/pvw4
    _up_nowait
    local want; want=$(_head)
    local other="deadbee0000000000000000000000000000000ff"
    _set_ready_http pvw4 ap ap "$other"
    run mother preview wait
    [ "$status" -eq 1 ]
    [[ "$output" == *"$(_sha7 "$want")"* ]]
    [[ "$output" == *"$(_sha7 "$other")"* ]]
    [ "$(_event_count pvw4 preview_ready)" = "0" ]
}

@test "wait: when the CI run has failed it exits 1 early with the run URL" {
    _pv_job pvw5 admin-portal feature/pvw5
    _up_nowait
    export MOTHER_PREVIEW_WAIT_TIMEOUT=30
    export FAKE_RWX_RUN_STATUS=failed
    local t0 t1
    t0=$(date +%s)
    run mother preview wait
    t1=$(date +%s)
    [ "$status" -eq 1 ]
    [[ "$output" == *"https://cloud.example.invalid/runs/run-test-1"* ]]
    [ $((t1 - t0)) -lt 20 ]
    assert_job_field pvw5 '.preview.status' 'launching'
}

@test "wait --timeout overrides MOTHER_PREVIEW_WAIT_TIMEOUT" {
    _pv_job pvw6 admin-portal feature/pvw6
    _up_nowait
    export MOTHER_PREVIEW_WAIT_TIMEOUT=60
    local t0 t1
    t0=$(date +%s)
    run mother preview wait --timeout 2
    t1=$(date +%s)
    [ "$status" -eq 4 ]
    [ $((t1 - t0)) -lt 20 ]
}

@test "wait: a stack that becomes ready while polling is picked up" {
    _pv_job pvw7 admin-portal feature/pvw7
    _up_nowait
    local u sha
    u=$(_url pvw7 ap)
    sha=$(_head)
    _http_set "$u/__stack/health" 200 '<html><body>App Starting</body></html>'
    export MOTHER_PREVIEW_WAIT_TIMEOUT=20
    (
        sleep 2
        _http_set "$u/__stack/health" 200 "{\"status\":\"ok\",\"launched_at\":\"$FAKE_LAUNCHED_AT\"}"
        _http_set "$u/__stack/info" 200 "{\"components\":{\"ap\":{\"sha\":\"$sha\"}}}"
    ) &
    run mother preview wait
    wait
    [ "$status" -eq 0 ]
    assert_job_field pvw7 '.preview.status' 'ready'
}

# ===========================================================================
# info / verify / down

@test "info prints the record (stack id and URL) without any HTTP call" {
    _pv_job pvi1 admin-portal feature/pvi1
    _up_nowait
    run mother preview info
    [ "$status" -eq 0 ]
    [[ "$output" == *"$(_stack_id pvi1)"* ]]
    [[ "$output" == *"$(_url pvi1 ap)"* ]]
    [ "$(_http_calls)" = "0" ]
}

@test "info --live also fetches and prints the stack's /__stack/info" {
    _pv_job pvi2 admin-portal feature/pvi2
    _up_nowait
    local u; u=$(_url pvi2 ap)
    _http_set "$u/__stack/info" 200 '{"live-marker":"yes-this-is-live"}'
    run mother preview info --live
    [ "$status" -eq 0 ]
    [[ "$output" == *"yes-this-is-live"* ]]
    [ "$(_http_count_url "$u/__stack/info" GET)" -ge "1" ]
}

@test "verify runs the CLI's verify against the stack URL and passes its output and exit code through" {
    _pv_job pvv1 admin-portal feature/pvv1
    _up_nowait
    export FAKE_PS_EXIT_VERIFY=1
    run mother preview verify
    [ "$status" -eq 1 ]
    [[ "$output" == *"verify-output-marker $(_url pvv1 ap)"* ]]
    grep -qF -- "|verify $(_url pvv1 ap)" "$PV_LOG"
}

@test "a failed owner-secrets write warns on stderr and the launch still succeeds" {
    _pv_job pvs9 referral-monitor feature/pvs9
    # A neutral mv shim that refuses to place the secrets file.
    cat > "$_MOCK_BIN/mv" <<'SHIM'
#!/bin/sh
for last; do :; done
case "$last" in *.preview-secrets.json) exit 1 ;; esac
exec /bin/mv "$@"
SHIM
    chmod +x "$_MOCK_BIN/mv"
    run --separate-stderr mother preview up --components rm --no-wait
    [ "$status" -eq 0 ]
    [[ "$stderr" == *"owner-secrets"* ]]
    [ ! -e "$RUNNER_DIR/pvs9.preview-secrets.json" ]
}

@test "_preview_tmp creates the captured-stderr file 0600 even under a permissive umask" {
    umask 022
    run bash -c 'source "$MOTHER_LIB_DIR/preview.sh"; umask 022; t=$(_preview_tmp); stat -f %Lp "$t.err" 2>/dev/null || stat -c %a "$t.err"; stat -f %Lp "$t" 2>/dev/null || stat -c %a "$t"'
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "600" ]
    [ "${lines[1]}" = "600" ]
}

@test "verify that hangs is killed at MOTHER_PREVIEW_VERIFY_TIMEOUT and exits non-zero" {
    _pv_job pvv2 admin-portal feature/pvv2
    _up_nowait
    export FAKE_PS_SLEEP_VERIFY=30 MOTHER_PREVIEW_VERIFY_TIMEOUT=2
    local started=$SECONDS
    run mother preview verify
    [ "$status" -ne 0 ]
    [[ "$output" == *"timed out after 2s"* ]]
    [ $((SECONDS - started)) -lt 15 ]
}

@test "stopped stack: wait, call and verify exit 2 quickly without calling the CLI or HTTP" {
    _pv_job pvx1 admin-portal feature/pvx1
    _up_nowait
    run mother preview down
    [ "$status" -eq 0 ]
    local cli_before; cli_before=$(_cli_calls)
    local http_before; http_before=$(_http_calls)
    local started=$SECONDS
    run mother preview wait
    [ "$status" -eq 2 ]
    [[ "$output" == *"stopped"* ]]
    run mother preview call GET /x
    [ "$status" -eq 2 ]
    run mother preview verify
    [ "$status" -eq 2 ]
    run mother preview info --live
    [ "$status" -eq 2 ]
    [ $((SECONDS - started)) -lt 3 ]
    [ "$(_cli_calls)" = "$cli_before" ]
    [ "$(_http_calls)" = "$http_before" ]
}

@test "down stops the stack now (reason explicit), marks it stopped, and is idempotent" {
    _pv_job pvd1 admin-portal feature/pvd1
    _up_nowait
    local sid; sid=$(_stack_id pvd1)
    run mother preview down
    [ "$status" -eq 0 ]
    [ "$(_down_calls "$sid")" = "1" ]
    assert_job_field pvd1 '.preview.status' 'stopped'
    assert_job_field_truthy pvd1 '.preview.stopped_at'
    [ "$(_event_field pvd1 preview_stop last reason)" = "explicit" ]
    [ "$(_event_field pvd1 preview_stop last outcome)" = "ok" ]
    [ "$(_event_field pvd1 preview_stop last backend)" = "cli" ]
    run mother preview down
    [ "$(_down_calls "$sid")" = "1" ]
}

# ===========================================================================
# Lifecycle hooks (mother-run-job), driven by real supervisors + a claude stand-in.

_seed_branch() {
    git -C "$WORK" checkout -q -B "$1" main
    git -C "$WORK" commit -q --allow-empty -m "seed for $1"
    git -C "$WORK" checkout -q main
}

_lc_filter_common() {
    local id="$1"
    printf '%s' '.repo_path = "'"$WORK"'"
         | .base_ref = "main"
         | .branch = "feature/test-'"$id"'"
         | .no_pr = true
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }'
}

# A hand-written .preview record (JSON object). <status> default launching.
_preview_obj() { # <id> [status] [backend]
    local id="$1" status="${2:-launching}" backend="${3:-cli}" sid
    sid=$(_stack_id "$id")
    printf '%s' '{
        "stack_id": "'"$sid"'", "backend": "'"$backend"'", "combo": "ap", "components": ["ap"],
        "refs": {"ap": {"ref": "feature/x", "sha": "'"$FAKE_SHA"'"}},
        "urls": {"stack": "https://stk-'"$sid"'-ap.example.invalid"},
        "run_id": "run-test-1", "run_url": "https://cloud.example.invalid/runs/run-test-1",
        "launched_at": "'"$FAKE_LAUNCHED_AT"'", "status": "'"$status"'", "expected_sha": {},
        "launches": 1, "stopped_at": null }'
}
# The same record as a jq assignment, for seeding a job BEFORE it runs. Note a
# non-stopped record present at spawn is a leftover from a previous attempt.
_preview_rec() { printf '.preview = %s' "$(_preview_obj "$@")"; }

# Simulate "the worker ran `mother preview up`" without a CLI round trip: the
# claude stand-ins source $MOTHER_ROOT/plant.sh right after they start, which
# writes the record onto the job and a secrets file. (A record that appears
# DURING the run is what the worker_exit hook has to clean up.)
_arm_preview() { # <id> [status] [backend]
    _preview_obj "$@" > "$MOTHER_ROOT/plant-rec.json"
    cat > "$MOTHER_ROOT/plant.sh" <<'PLANT'
jf="$MOTHER_ROOT/jobs/$MOTHER_JOB_ID.json"
tmp=$(jq --slurpfile r "$MOTHER_ROOT/plant-rec.json" '.preview = $r[0]' "$jf") && printf '%s' "$tmp" > "$jf"
printf '{"seed":"planted","tokens":{"ADMIN_API_TOKEN":"planted"}}' > "$MOTHER_ROOT/runner/$MOTHER_JOB_ID.preview-secrets.json"
chmod 600 "$MOTHER_ROOT/runner/$MOTHER_JOB_ID.preview-secrets.json"
PLANT
}

# A main-dir no_pr job (can reach succeeded). $2 = extra jq filter.
_lc_job() {
    local id="$1" extra="${2:-.}"
    _seed_branch "feature/test-$id"
    make_job "$id" ready ".isolation = \"main-dir\" | $(_lc_filter_common "$id") | $extra"
    mkdir -p "$MOTHER_ROOT/plans"
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"
}

_plant_secrets() { # <id>
    printf '{"seed":"planted","tokens":{"ADMIN_API_TOKEN":"planted"}}' > "$RUNNER_DIR/$1.preview-secrets.json"
    chmod 600 "$RUNNER_DIR/$1.preview-secrets.json"
}

# Claude stand-ins. Each marks "claude-start" in the CLI log so ordering shows,
# then plants the armed preview record, if any.
_install_claude_ok() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/preview-cli.log"
[ -f "$MOTHER_ROOT/plant.sh" ] && . "$MOTHER_ROOT/plant.sh"
cat <<'EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}
_install_claude_fail() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/preview-cli.log"
[ -f "$MOTHER_ROOT/plant.sh" ] && . "$MOTHER_ROOT/plant.sh"
exit 1
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}
_install_claude_await() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/preview-cli.log"
[ -f "$MOTHER_ROOT/plant.sh" ] && . "$MOTHER_ROOT/plant.sh"
mother await --question "need clarification before continuing" >/dev/null 2>&1
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}
# Hangs without a result (cancel / idle-timeout / supervisor-kill cases).
_install_claude_hang() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/preview-cli.log"
[ -f "$MOTHER_ROOT/plant.sh" ] && . "$MOTHER_ROOT/plant.sh"
echo "$$" > "$MOTHER_ROOT/claude.pid"
exec sleep 30
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

_set_job() { # <id> <jq filter>
    local merged
    merged=$(jq "$2" "$JOBS_DIR/$1.json") && printf '%s' "$merged" > "$JOBS_DIR/$1.json"
}

# After a worker exit: the stack was stopped exactly once, for <reason>.
_assert_stopped_once() { # <id> <reason>
    local id="$1" sid; sid=$(_stack_id "$1")
    [ "$(_down_calls "$sid")" = "1" ]
    [ "$(_event_count "$id" preview_stop)" = "1" ]
    [ "$(_event_field "$id" preview_stop 1 reason)" = "$2" ]
    [ "$(_event_field "$id" preview_stop 1 outcome)" = "ok" ]
    [ "$(_event_field "$id" preview_stop 1 backend)" = "cli" ]
    assert_job_field "$id" '.preview.status' 'stopped'
    assert_job_field_truthy "$id" '.preview.stopped_at'
    [ ! -e "$RUNNER_DIR/$id.preview-secrets.json" ]
}

@test "worker exits succeeded: the stack is stopped once (worker_exit), the secrets file removed, the job stays succeeded" {
    local id="pv-ok"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_ok
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    _assert_stopped_once "$id" worker_exit
    # The stop came after the worker ran.
    local l_start l_down
    l_start=$(grep -nF 'claude-start' "$PV_LOG" | head -1 | cut -d: -f1)
    l_down=$(grep -nF "|down $(_stack_id "$id")" "$PV_LOG" | head -1 | cut -d: -f1)
    [ "$l_start" -lt "$l_down" ]
}

@test "worker exits failed: the stack is stopped once (worker_exit) and the failure stands" {
    local id="pv-fail"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_fail
    run mother-run-job "$id"
    assert_job_field "$id" '.state' 'failed'
    _assert_stopped_once "$id" worker_exit
}

@test "worker exits cancelled: the stack is stopped once (worker_exit)" {
    local id="pv-cancel"
    _lc_job "$id" '.cancel_requested = true'
    _arm_preview "$id" ready
    _install_claude_hang
    run mother-run-job "$id"
    assert_job_field "$id" '.state' 'cancelled'
    _assert_stopped_once "$id" worker_exit
}

@test "worker exits awaiting (mother await): the stack is stopped once (worker_exit)" {
    local id="pv-await"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_await
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'awaiting'
    _assert_stopped_once "$id" worker_exit
}

@test "worker idles out into a continuation: the stack is stopped once (worker_exit)" {
    local id="pv-cont"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_hang
    export MOTHER_IDLE_REAP_SECONDS=3
    run mother-run-job "$id"
    assert_job_field "$id" '.state' 'ready'
    assert_job_field "$id" '.activity' 'continuation'
    _assert_stopped_once "$id" worker_exit
}

@test "supervisor killed mid-run (EXIT-trap path, runner_died_early): the stack is still stopped once (worker_exit)" {
    local id="pv-trap"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_hang
    mother-run-job "$id" >/dev/null 2>&1 &
    local sup=$! i=0
    while [ ! -f "$MOTHER_ROOT/claude.pid" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i + 1)); done
    [ -f "$MOTHER_ROOT/claude.pid" ]
    sleep 1
    kill -TERM "$sup" 2>/dev/null || true
    wait "$sup" 2>/dev/null || true
    kill "$(cat "$MOTHER_ROOT/claude.pid")" 2>/dev/null || true
    assert_job_field "$id" '.state' 'failed'
    assert_job_field "$id" '.failure_reason' 'runner_died_early'
    _assert_stopped_once "$id" worker_exit
}

@test "stale supervisor (a newer worker owns the job): preview_stop is skipped as newer_worker and nothing is stopped" {
    local id="pv-stale"
    _lc_job "$id"
    _arm_preview "$id" ready
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/preview-cli.log"
[ -f "$MOTHER_ROOT/plant.sh" ] && . "$MOTHER_ROOT/plant.sh"
jf="$MOTHER_ROOT/jobs/$MOTHER_JOB_ID.json"
tmp=$(jq '.worker_pid = 999999' "$jf") && printf '%s' "$tmp" > "$jf"
cat <<'EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    run mother-run-job "$id"
    [ "$(_down_calls "$(_stack_id "$id")")" = "0" ]
    [ "$(_event_count "$id" preview_stop)" = "1" ]
    [ "$(_event_field "$id" preview_stop 1 outcome)" = "skipped" ]
    [ "$(_event_field "$id" preview_stop 1 reason)" = "newer_worker" ]
}

@test "a fresh attempt with a leftover non-stopped stack stops it (attempt_start) BEFORE the worker spawns" {
    local id="pv-attempt"
    _lc_job "$id" "$(_preview_rec "$id" launching)"
    _plant_secrets "$id"
    _install_claude_ok
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    _assert_stopped_once "$id" attempt_start
    local l_down l_start
    l_down=$(grep -nF "|down $(_stack_id "$id")" "$PV_LOG" | head -1 | cut -d: -f1)
    l_start=$(grep -nF 'claude-start' "$PV_LOG" | head -1 | cut -d: -f1)
    [ "$l_down" -lt "$l_start" ]
}

@test "an already-stopped record is left alone: no stop call at spawn or at exit" {
    local id="pv-stopped"
    _lc_job "$id" "$(_preview_rec "$id" stopped)"
    _install_claude_ok
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_down_calls "$(_stack_id "$id")")" = "0" ]
}

@test "a job that never ran 'mother preview up' gets no stop call and no preview_stop event" {
    local id="pv-never"
    _lc_job "$id"
    _install_claude_ok
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    [ "$(_down_calls "$(_stack_id "$id")")" = "0" ]
    [ "$(_count_in '|down ' "$PV_LOG")" = "0" ]
    [ "$(_event_count "$id" preview_stop)" = "0" ]
}

@test "kill switch MOTHER_PREVIEW_ENABLED=0: hooks still stop an existing stack" {
    local id="pv-killsw"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_ok
    export MOTHER_PREVIEW_ENABLED=0
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    _assert_stopped_once "$id" worker_exit
}

@test "end to end: a stack launched by the worker is stopped when the worker exits, secrets file included" {
    local id="pv-e2e"
    _lc_job "$id" '.repo = "mother"'
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
echo "claude-start" >> "$MOTHER_ROOT/preview-cli.log"
mother preview up --components rm --no-wait >/dev/null 2>&1
[ -f "$MOTHER_ROOT/runner/$MOTHER_JOB_ID.preview-secrets.json" ] && echo present > "$MOTHER_ROOT/e2e-secrets"
cat <<'EOF'
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
exit 0
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    [ -f "$MOTHER_ROOT/e2e-secrets" ]
    [ "$(_event_count "$id" preview_up)" = "1" ]
    _assert_stopped_once "$id" worker_exit
    _assert_secrets_contained
}

# ---------------------------------------------------------------------------
# Stop is best-effort and never changes the job's outcome

@test "stop failure (CLI down exits 1): recorded as error/stop_failed, secrets removed, job still succeeded" {
    local id="pv-sfail"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_ok
    export FAKE_PS_EXIT_DOWN=1 FAKE_PS_TEXT_DOWN='\033[31mdown-boom\033[0m'
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    assert_job_field "$id" '.failure_reason // "none"' 'none'
    [ "$(_event_count "$id" preview_stop)" = "1" ]
    [ "$(_event_field "$id" preview_stop 1 outcome)" = "error" ]
    [ "$(_event_field "$id" preview_stop 1 exit_code)" = "1" ]
    [ "$(_event_field "$id" preview_stop 1 reason)" = "worker_exit" ]
    assert_job_field "$id" '.preview.status' 'stop_failed'
    assert_job_field_truthy "$id" '.preview.stopped_at'
    [ ! -e "$RUNNER_DIR/$id.preview-secrets.json" ]
    local tail_text; tail_text=$(_event_field "$id" preview_stop 1 output_tail)
    [[ "$tail_text" == *"down-boom"* ]]
    [[ "$tail_text" != *$'\033'* ]]
}

@test "stop output_tail is capped at 300 characters" {
    local id="pv-stail"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_ok
    export FAKE_PS_EXIT_DOWN=1 FAKE_PS_TEXT_DOWN="$(head -c 1500 /dev/zero | tr '\0' 'x')"
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    local n; n=$(_event_field "$id" preview_stop 1 output_tail | tr -d '\n' | wc -c | tr -d ' ')
    [ "$n" -gt 0 ]
    [ "$n" -le 300 ]
}

@test "stop that hangs past MOTHER_PREVIEW_STOP_TIMEOUT is recorded as timeout/stop_failed and the job still succeeds" {
    local id="pv-shang"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_ok
    export FAKE_PS_SLEEP_DOWN=30 MOTHER_PREVIEW_STOP_TIMEOUT=2
    local t0 t1
    t0=$(date +%s)
    run mother-run-job "$id"
    t1=$(date +%s)
    [ "$status" -eq 0 ]
    [ $((t1 - t0)) -lt 25 ]
    assert_job_field "$id" '.state' 'succeeded'
    assert_job_field "$id" '.failure_reason // "none"' 'none'
    [ "$(_event_field "$id" preview_stop 1 outcome)" = "timeout" ]
    assert_job_field "$id" '.preview.status' 'stop_failed'
    [ ! -e "$RUNNER_DIR/$id.preview-secrets.json" ]
}

@test "CLI down exiting 2 (stack already gone) counts as a successful stop" {
    local id="pv-sgone"
    _lc_job "$id"
    _arm_preview "$id" ready
    _install_claude_ok
    export FAKE_PS_EXIT_DOWN=2
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    [ "$(_event_field "$id" preview_stop 1 outcome)" = "ok" ]
    [ "$(_event_field "$id" preview_stop 1 exit_code)" = "2" ]
    assert_job_field "$id" '.preview.status' 'stopped'
}

@test "a record on the (deferred) operations backend: stop records outcome error without crashing, job outcome unchanged" {
    local id="pv-ops"
    _lc_job "$id"
    _arm_preview "$id" ready operations
    _install_claude_ok
    run mother-run-job "$id"
    [ "$status" -eq 0 ]
    assert_job_field "$id" '.state' 'succeeded'
    assert_job_field "$id" '.failure_reason // "none"' 'none'
    [ "$(_event_count "$id" preview_stop)" = "1" ]
    [ "$(_event_field "$id" preview_stop 1 outcome)" = "error" ]
    [ "$(_event_field "$id" preview_stop 1 backend)" = "operations" ]
    # The CLI backend must not be asked to stop a stack it didn't launch.
    [ "$(_count_in '|down ' "$PV_LOG")" = "0" ]
}
