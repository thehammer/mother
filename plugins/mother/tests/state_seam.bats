#!/usr/bin/env bats
# state_seam.bats — the worker-mode state seam (cluster Phase 1, slice P1-2).
#
# In worker mode (MOTHER_WORKER_MODE=1, MOTHER_ROOT=<worker root W>, MOTHER_WORKER_OUTBOX_DIR=$W/outbox)
# `mother-run-job` and everything it calls run against a mirror root W AND append every state write as a
# protocol op to $W/outbox/<job>.ndjson:
#
#     {"seq":N,"t":"job.set|event.append|record.append|artifact.put","ts":...,"data":...}
#
# `lib/coord_apply.sh <canonical-root> <job> < ops.ndjson` replays those ops onto a canonical root C.
#
# Contract under test (docs/worker-protocol.md sections 4, 6, 8 plus the P1-2 plan):
#   * Off is off: without MOTHER_WORKER_MODE=1 nothing outbox-shaped is created.
#   * Equivalence: a job run in worker mode and replayed onto C leaves C's job file, events and usage rows
#     equal to what the same job leaves when run the legacy way (modulo timestamps, ids, pids, paths), and
#     C's actual_cost_usd is the canonical recompute (the mirror never computes one).
#   * Replay is idempotent and resumable: applying an outbox twice, or a prefix and then the whole thing,
#     gives the same files as one clean replay, with no duplicate event or usage line.
#   * Ownership: ops that set coordinator-owned (or unknown) job keys are skipped and audited in
#     <C>/runner/leases/audit.jsonl as {ts, job, code:"ownership", keys}; the other ops still apply.
#   * Artifacts: crew/<job>/ and checkpoints/<job>/ files arrive byte-identical, in chunks; a path that
#     escapes (`..`, absolute, another job's tree) is refused with a non-zero exit and nothing is written.
#   * A worker run never writes the canonical root (it may be read-only).
#   * safe_rm_tree refuses a worker root (.mother-worker-live).
#
# Harness. Every root is a mktemp tree under the test's (or the file's) own MOTHER_ROOT, so teardown cleans
# everything and the real ~/.mother is never reachable (HOME is a throwaway directory too):
#   legacy root  a job run the old way (worker mode off)
#   W            a worker mirror: the same job run with worker mode on
#   C            the canonical root: seeded with W's pre-run job document, then fed W's outbox
# Each world that runs a job gets its own git repo + bare origin + gh_mock state, so a scenario that pushes
# (the gate fix) starts identically in each. Worlds are entered in a subshell (_ss_in_world) so exported
# MOTHER_* variables never leak between them. `claude` is a scriptable stand-in (same shape as
# gates_enforce.bats); scenarios script it with $ROOT/ge-behave.<n> files.
#
# The plain scenario is run once per file (setup_file, legacy and worker side by side in parallel) and shared
# by the tests that only need a finished worker outbox; the others run their own pair.

bats_require_minimum_version 1.5.0
load 'test_helper'
load 'gh_mock'

SS_PR="https://github.com/Carefeed/test/pull/42"
SS_COORD_APPLY="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd -P)/lib/coord_apply.sh"
SS_PLAIN_ID="ss-plain"
SS_GATE_FIXME="[ -f .gate-fixed ] || { printf 'GATE_%s_%s\\n' MARKER c0ffee; exit 1; }"
SS_FIX_SNIPPET='touch .gate-fixed; git add .gate-fixed; git commit -q -m "fix the gates"'

# ---------------------------------------------------------------------------
# Environment

# _ss_common_env — what every test (and setup_file) needs on top of setup_mother_env. Call right after it.
_ss_common_env() {
    unset MOTHER_GATES_ENABLED MOTHER_PHI_REPOS MOTHER_JOB_ID MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR \
          GH_MOCK_FAIL_DRAFT MOTHER_LIVE_ROOT
    export MOTHER_POSTURE_ENABLED=0
    export MOTHER_IDLE_REAP_SECONDS=120
    export MOTHER_RESULT_GRACE_SECONDS=120
    export MOTHER_NOTIFY_ENABLED=0 MOTHER_BACKUP_ENABLED=0
    # Pin identity and dates so commit shas match between worlds.
    export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com" \
           GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com" \
           GIT_AUTHOR_DATE="2026-10-01T00:00:00Z" GIT_COMMITTER_DATE="2026-10-01T00:00:00Z"
    # A hermetic HOME inside the test tree: any code path that falls back to ~/.mother lands in here,
    # never in the developer's live tree. (Keep the real HOME for teardown_mother_env, which resets it
    # before deleting; exporting it makes setup_file's value reach the per-test shells.)
    export _MOTHER_TEST_REAL_HOME="${_MOTHER_TEST_REAL_HOME:-$HOME}"
    SS_HOME="$MOTHER_ROOT/fake-home"
    mkdir -p "$SS_HOME"
    export HOME="$SS_HOME"
    _ss_install_claude
}

setup_file() {
    setup_mother_env
    _ss_common_env
    export SS_F="$MOTHER_ROOT"
    export SS_FL="$SS_F/worlds/legacy" SS_FW="$SS_F/worlds/worker"
    _ss_run_pair plain "$SS_PLAIN_ID" "$SS_FL" "$SS_FW"
}

teardown_file() {
    teardown_mother_env
}

setup() {
    setup_mother_env
    _ss_common_env
    SS_L="$MOTHER_ROOT"
    SS_W="$MOTHER_ROOT/worlds/worker"
    SS_C="$MOTHER_ROOT/worlds/canonical"
    mkdir -p "$SS_W" "$SS_C"
    # Roots whose absolute paths the normaliser maps to <ROOT>/<REPO>/<ORIGIN>.
    SS_NORM_ROOTS="$SS_L $SS_W $SS_C ${SS_FL:-} ${SS_FW:-}"
}

teardown() {
    # A read-only canonical root must be writable again before the tree can be removed.
    chmod -R u+rwx "$MOTHER_ROOT" 2>/dev/null || true
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Worlds

# _ss_export_root <dir> — point every MOTHER_* directory variable at <dir> (mirrors setup_mother_env).
_ss_export_root() {
    local r="$1"
    export MOTHER_ROOT="$r"
    export JOBS_DIR="$r/jobs" EVENTS_DIR="$r/events" LOGS_DIR="$r/logs" DRAFTS_DIR="$r/drafts" \
           CURSORS_DIR="$r/cursors" RUNNER_DIR="$r/runner" ARCHIVE_DIR="$r/archive" \
           TEARDOWN_DIR="$r/teardown-pending"
    mkdir -p "$JOBS_DIR" "$EVENTS_DIR" "$LOGS_DIR" "$DRAFTS_DIR" "$CURSORS_DIR" "$RUNNER_DIR" \
             "$ARCHIVE_DIR" "$TEARDOWN_DIR"
}

# _ss_in_world <root> <worker:0|1|2> <cmd...> — run <cmd> with <root> as MOTHER_ROOT, in a subshell.
#   0  every worker knob unset (legacy)
#   1  worker mode on, outbox at <root>/outbox
#   2  only MOTHER_WORKER_OUTBOX_DIR set (mode off): must behave like 0
_ss_in_world() {
    local root="$1" worker="$2"
    shift 2
    (
        _ss_export_root "$root"
        case "$worker" in
            1) export MOTHER_WORKER_MODE=1 MOTHER_WORKER_OUTBOX_DIR="$root/outbox" ;;
            2) unset MOTHER_WORKER_MODE; export MOTHER_WORKER_OUTBOX_DIR="$root/outbox" ;;
            *) unset MOTHER_WORKER_MODE MOTHER_WORKER_OUTBOX_DIR ;;
        esac
        "$@"
    )
}

# The scriptable worker (same shape as gates_enforce.bats). Counts its invocations in $ROOT/ge-count;
# invocation n sources $ROOT/ge-behave.<n> (cwd = the job's work dir). Defaults: push the branch, print
# the PR url on invocation 1 (unless $ROOT/ge-no-pr-url exists), print a result event, linger 3 s (longer
# than the supervisor's 2 s poll tick, so every run deterministically observes the final result while the
# worker is alive: otherwise final_result_at / live cost / final_result_observed appear or not by timing,
# in legacy and worker mode alike), exit 0.
# ROOT is the worker's view of the root (workers get MOTHER_LIVE_ROOT, not MOTHER_ROOT).
_ss_install_claude() {
    cat > "$_MOCK_BIN/claude" <<'CLAUDE'
#!/usr/bin/env bash
ROOT="${MOTHER_LIVE_ROOT:-${MOTHER_ROOT:-}}"
[ -n "$ROOT" ] || exit 97
n=$(( $(cat "$ROOT/ge-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/ge-count"
cat > "$ROOT/stdin.$n"
PUSH=1; EXIT=0; SLEEP=3; POST=""; OUT_FILE="default"
BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -f "$ROOT/ge-behave.$n" ]; then . "$ROOT/ge-behave.$n"; fi
if [ "$PUSH" = "1" ]; then
    git push -q origin "HEAD:refs/heads/$BR" >/dev/null 2>&1 || true
fi
if [ "$n" = "1" ] && [ ! -f "$ROOT/ge-no-pr-url" ]; then
    echo "opened https://github.com/Carefeed/test/pull/42"
fi
if [ "$OUT_FILE" = "default" ]; then
    cat <<'EOF'
{"type":"assistant","message":{"id":"msg_ss","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":200}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.004,"modelUsage":{"claude-sonnet-5":{"costUSD":0.004,"inputTokens":1000,"outputTokens":200}}}
EOF
elif [ -n "$OUT_FILE" ]; then
    cat "$OUT_FILE"
fi
[ "$SLEEP" = "0" ] || sleep "$SLEEP"
[ -z "$POST" ] || eval "$POST"
exit "$EXIT"
CLAUDE
    chmod +x "$_MOCK_BIN/claude"
}

# _ss_behave <n> <shell-snippet> — script claude invocation <n> in the CURRENT world ($MOTHER_ROOT).
_ss_behave() { printf '%s\n' "$2" > "$MOTHER_ROOT/ge-behave.$1"; }

# _ss_crew — a resolved enforce-mode gate snapshot with one blocking check that is red until the worker
# creates .gate-fixed (same shape as gates_enforce.bats).
_ss_crew() {
    jq -nc --arg run "$SS_GATE_FIXME" '{
        version: 1, source_ref: "origin/main", source_sha: "abc", phi_sensitive: false,
        gates: {mode: "enforce", max_attempts: 3, budget_minutes: 15,
                checks: [{name: "fixme", run: $run, when: null, blocking: true, where: "any",
                          timeout_s: 60, hint: "HINT_apply_the_fixer"}]},
        lenses: null}'
}

# _ss_prepare <scenario> <id> — build the CURRENT world (call through _ss_in_world, worker mode off, so the
# seed is never an outbox op): a git repo with a bare origin, gh state, a plan, a log file, a seeded job
# branch and the job file. Scenarios:
#   plain   a no_pr job; the worker pushes and finishes                      -> succeeded
#   await   a no_pr job whose worker runs `mother await` (in-agent)         -> awaiting
#   gate    an enforce-gates PR job; the first gate run is red, the worker's
#           resumed session fixes it, the second run is green                -> succeeded
#   cancel  a no_pr job with cancel_requested set before the run            -> cancelled
# The pre-run job document is kept as $MOTHER_ROOT/seed-<id>.json.
_ss_prepare() {
    local scn="$1" id="$2"
    local repo="$MOTHER_ROOT/work/gaterepo" origin="$MOTHER_ROOT/origin.git" branch="feature/ss-$id"
    mkdir -p "$repo" "$MOTHER_ROOT/plans"
    git init -q --bare "$origin"
    (
        cd "$repo" || exit 1
        git init -q
        git symbolic-ref HEAD refs/heads/main
        echo "# repo" > README.md
        git add .
        git commit -q -m "init"
        git remote add origin "$origin"
        git push -q -u origin main
        git checkout -q -B "$branch" origin/main
        mkdir -p app
        echo '<?php' > app/Foo.php
        git add app/Foo.php
        git commit -q -m "feature work for $branch"
        git checkout -q main
    ) >/dev/null 2>&1
    gh_mock_install
    make_plan "$MOTHER_ROOT/plans/$id.md"
    touch "$LOGS_DIR/$id.log"

    local extra='.'
    case "$scn" in
        plain|await|cancel) extra='.no_pr = true' ;;
        gate) extra=".crew = $(_ss_crew)" ;;
    esac
    make_job "$id" "ready" \
        '.isolation = "main-dir"
         | .repo = "gaterepo"
         | .repo_path = "'"$repo"'"
         | .base_ref = "origin/main"
         | .branch = "'"$branch"'"
         | .plan_path = "'"$MOTHER_ROOT/plans/$id.md"'"
         | .log_path = "'"$LOGS_DIR/$id.log"'"
         | .suggested_config = {
               "cody":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "redd":  {"model":"sonnet","effort":"medium","rationale":"test"},
               "marty": {"model":"sonnet","effort":"medium","rationale":"test"},
               "perri": {"model":"sonnet","effort":"medium","rationale":"test"}
           }
         | ('"$extra"')'

    case "$scn" in
        plain)
            touch "$MOTHER_ROOT/ge-no-pr-url" ;;
        await)
            touch "$MOTHER_ROOT/ge-no-pr-url"
            _ss_behave 1 'OUT_FILE=""; SLEEP=0; POST='"'"'mother await --question "need clarification before continuing" >/dev/null 2>&1'"'" ;;
        gate)
            gh_mock_set_pr "$SS_PR" OPEN "$branch"
            _ss_behave 2 "$SS_FIX_SNIPPET" ;;
        cancel)
            touch "$MOTHER_ROOT/ge-no-pr-url"
            _ss_behave 1 'OUT_FILE=""; SLEEP=8'
            jq '.cancel_requested = true' "$JOBS_DIR/$id.json" > "$JOBS_DIR/$id.json.new" \
                && mv "$JOBS_DIR/$id.json.new" "$JOBS_DIR/$id.json" ;;
    esac
    cp "$JOBS_DIR/$id.json" "$MOTHER_ROOT/seed-$id.json"
}

# _ss_run_job <id> — one real supervisor run in the CURRENT world; the output is kept for triage.
_ss_run_job() {
    mother-run-job "$1" > "$MOTHER_ROOT/run-job.out" 2>&1
}

# _ss_run_pair <scenario> <id> <legacy-root> <worker-root> — prepare both worlds, then run the same job in
# both at once (they share nothing but the read-only stand-ins on PATH). Exit statuses are not part of the
# contract; the job's state is.
_ss_run_pair() {
    local scn="$1" id="$2" lr="$3" wr="$4" p1 p2
    mkdir -p "$lr" "$wr"
    _ss_in_world "$lr" 0 _ss_prepare "$scn" "$id" || return 1
    _ss_in_world "$wr" 0 _ss_prepare "$scn" "$id" || return 1
    _ss_in_world "$lr" 0 _ss_run_job "$id" 3>&- & p1=$!
    _ss_in_world "$wr" 1 _ss_run_job "$id" 3>&- & p2=$!
    wait "$p1" || true
    wait "$p2" || true
    return 0
}

# ---------------------------------------------------------------------------
# Canonical root and replay

# _ss_seed_canonical <croot> <id> <seed-file> — a canonical root holding the pre-run job document.
_ss_seed_canonical() {
    local croot="$1" id="$2" seed="$3"
    mkdir -p "$croot/jobs" "$croot/events" "$croot/metrics" "$croot/runner"
    cp "$seed" "$croot/jobs/$id.json"
}

# _ss_seed_hand <id> — a canonical root ($SS_C) whose job is a plain running job made by make_job
# (repo_path /tmp/testrepo, branch feature/test), for hand-written outboxes.
_ss_seed_hand() {
    local id="$1"
    _ss_in_world "$SS_C" 0 make_job "$id" running
    mkdir -p "$SS_C/events" "$SS_C/metrics" "$SS_C/runner"
}

# _ss_replay_to <croot> <id> <ops-file> — replay ops onto <croot> the way the coordinator would: a process
# whose MOTHER_ROOT is the canonical root and which is not in worker mode. Sets bats' status/output
# (stdout only; stderr in $stderr).
_ss_replay_to() {
    local croot="$1" id="$2" ops="$3"
    run --separate-stderr _ss_in_world "$croot" 0 bash -c '"$0" "$1" "$2" < "$3"' \
        "$SS_COORD_APPLY" "$croot" "$id" "$ops"
}

# _ss_last_line — the last non-empty line of $output, trimmed (coord_apply prints the last applied seq).
_ss_last_line() { printf '%s\n' "$output" | awk 'NF { l = $0 } END { print l }' | tr -d '[:space:]'; }

# _ss_snapshot <croot> <id> — everything a replay may change that is part of the contract, as text:
# the job document, the events, this job's usage rows, and the artifact tree (names and checksums).
_ss_snapshot() {
    local croot="$1" id="$2"
    echo "--- job"
    jq -S . "$croot/jobs/$id.json"
    echo "--- events"
    cat "$croot/events/$id.jsonl" 2>/dev/null || true
    echo "--- rows"
    { grep -F "\"job_id\":\"$id\"" "$croot/metrics/runs.jsonl" 2>/dev/null || true; }
    echo "--- artifacts"
    ( cd "$croot" && find crew checkpoints -type f ! -name '*.tmp.*' 2>/dev/null | LC_ALL=C sort \
        | while IFS= read -r f; do shasum -a 256 "$f"; done )
}

# ---------------------------------------------------------------------------
# Normalisation: what two runs of the same scenario may legitimately differ in.

# _ss_norm_filter — a jq program (needs --argjson subs '[[literal, token],...]'). Strings lose absolute
# root/repo paths, ISO timestamps, 40-hex shas and uuids; keys naming pids, durations, log offsets/sizes
# (they depend on the length of the root path) or epoch times lose their values.
_ss_norm_filter() {
    cat <<'JQ'
def scrub_str:
    reduce $subs[] as $s (.; split($s[0]) | join($s[1]))
    | gsub("[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]+)?Z"; "<ts>")
    | gsub("[0-9a-f]{40}"; "<sha>")
    | gsub("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"; "<uuid>")
    | gsub("\\.tmp\\.[0-9]+"; ".tmp.<pid>");
def volatile_key:
    test("(^|_)pid$|_ms$|duration|elapsed|wall_time|_epoch$|^epoch$|^not_before$|^latency|log_offset|log_size|log_bytes");
walk(
    if type == "object" then
        with_entries(
            if (.key | volatile_key) then
                (if (.value | type) == "number" then .value = 0
                 elif (.value | type) == "array" then .value = []
                 else . end)
            else . end)
    elif type == "string" then scrub_str
    else . end)
JQ
}

# _ss_subs — literal path substitutions (longest first) for every root in $SS_NORM_ROOTS, in both their
# /var and /private/var spellings; a root's repo and origin first.
_ss_subs() {
    local r phys p tab
    tab="$(printf '\t')"
    {
        for r in $SS_NORM_ROOTS; do
            phys=$(cd -P "$r" 2>/dev/null && pwd -P) || phys="$r"
            for p in "$r" "$phys"; do
                printf '%s\t%s\n' "$p/work/gaterepo" "<REPO>" "$p/origin.git" "<ORIGIN>" "$p" "<ROOT>"
            done
        done
    } | awk -F'\t' 'NF == 2 && !seen[$1]++ { print length($1) "\t" $0 }' \
        | sort -t "$tab" -k1,1nr | cut -f2- \
        | jq -Rsc 'split("\n") | map(select(length > 0) | split("\t"))'
}

# _ss_norm_job <file> — the job document, normalised. The supervisor's usage poll writes live_cost_usd /
# live_tokens (and the progress observer's progress / last_progress_at) on its own clock, so whether a poll
# landed before the run ended is timing, not contract: dropped from BOTH documents. Every other key is compared.
_ss_norm_job() {
    jq -S --argjson subs "$(_ss_subs)" \
        "del(.live_cost_usd, .live_tokens, .progress, .last_progress_at) | $(_ss_norm_filter)" "$1"
}

# _ss_norm_events <file> — the event stream as a normalised JSON array. `final_result_observed` is a
# poll-loop race, not part of the contract (the contract recorder drops it too). `worker_spawned` is appended by
# the supervisor after it starts the worker (and after three job writes); the in-agent `mother await` fixture
# answers in milliseconds, so its `awaiting_input` can land first. A real claude takes seconds, so this is a
# mock-speed race, not a product ordering bug: when (and only when) `awaiting_input` precedes `worker_spawned`,
# the two are swapped into the canonical order. Every other event keeps its position and is compared.
_ss_norm_events() {
    jq -S -s --argjson subs "$(_ss_subs)" \
        "map(select(.kind != \"final_result_observed\"))
         | (map(.kind) | index(\"worker_spawned\")) as \$w | (map(.kind) | index(\"awaiting_input\")) as \$a
         | (if \$w != null and \$a != null and \$a < \$w then .[\$a] as \$x | .[\$a] = .[\$w] | .[\$w] = \$x else . end)
         | $(_ss_norm_filter)" "$1"
}

# _ss_norm_rows <job> <metrics-file> — this job's usage rows as a normalised JSON array.
_ss_norm_rows() {
    local id="$1" f="$2"
    { grep -F "\"job_id\":\"$id\"" "$f" 2>/dev/null || true; } \
        | jq -c 'del(.apply_id)' \
        | jq -S -s --argjson subs "$(_ss_subs)" "$(_ss_norm_filter)"   # apply_id is the replay's stable row id
}

# _ss_same <label> <file-a> <file-b> — fail with a diff when the two normalised files differ.
_ss_same() {
    if ! diff -u "$2" "$3" > "$BATS_TEST_TMPDIR/diff.out"; then
        echo "$1 differs (< first / > second):" >&2
        cat "$BATS_TEST_TMPDIR/diff.out" >&2
        return 1
    fi
}

# _ss_compare_worlds <id> <root-a> <root-b> — job document, events and usage rows of <id> agree after
# normalisation.
_ss_compare_worlds() {
    local id="$1" a="$2" b="$3" t="$BATS_TEST_TMPDIR"
    _ss_norm_job "$a/jobs/$id.json" > "$t/a.job"
    _ss_norm_job "$b/jobs/$id.json" > "$t/b.job"
    _ss_same "job document" "$t/a.job" "$t/b.job" || return 1
    _ss_norm_events "$a/events/$id.jsonl" > "$t/a.events"
    _ss_norm_events "$b/events/$id.jsonl" > "$t/b.events"
    _ss_same "events" "$t/a.events" "$t/b.events" || return 1
    _ss_norm_rows "$id" "$a/metrics/runs.jsonl" > "$t/a.rows"
    _ss_norm_rows "$id" "$b/metrics/runs.jsonl" > "$t/b.rows"
    _ss_same "usage rows" "$t/a.rows" "$t/b.rows" || return 1
}

# _ss_artifact_files <root> <id> — the job's artifact tree (names), for list comparison.
_ss_artifact_files() {
    ( cd "$1" && find "crew/$2" "checkpoints/$2" -type f ! -name '*.tmp.*' 2>/dev/null | LC_ALL=C sort )
}

# _ss_assert_outbox_shape <root> <id> — the worker's outbox is a well-formed, gap-free op stream.
_ss_assert_outbox_shape() {
    local root="$1" id="$2" f="$1/outbox/$2.ndjson"
    [ -s "$f" ] || { echo "no outbox for $id at $f" >&2; return 1; }
    jq -s -e 'map(.seq) == [range(1; length + 1)]' "$f" >/dev/null \
        || { echo "outbox seqs are not 1..N" >&2; return 1; }
    jq -s -e 'all(.[]; .t as $t | ["job.set","event.append","record.append","artifact.put"] | index($t))' "$f" >/dev/null \
        || { echo "outbox holds an op type outside the protocol" >&2; return 1; }
    jq -s -e 'all(.[] | select(.t == "record.append"); .data.stream == "metrics/runs.jsonl")' "$f" >/dev/null \
        || { echo "record.append on an unknown stream" >&2; return 1; }
    [ "$(tr -d '[:space:]' < "$root/outbox/$id.seq")" = "$(jq -s 'length' "$f")" ] \
        || { echo "$id.seq does not hold the last seq" >&2; return 1; }
}

# _ss_stand_in_coordinator <id> <worker-root> — what the coordinator itself does after a replay (P1-5 derives
# it; until then this harness stands in): the replay refuses `succeeded`, the completion-evidence keys and every
# other coordinator-side key from a worker, so copy those (every mirror key outside the worker allowlist except
# the cost fields) from the worker's final document, then run the canonical cost recompute.
_ss_stand_in_coordinator() {
    local id="$1" wr="$2" wk merged
    wk=$(_ss_in_world "$SS_C" 0 bash -c 'source "$1/coord_apply.sh"; _ca_words_json "$_CA_WORKER_KEYS"' _ "$_LIB_DIR")
    merged=$(jq -n --argjson wk "$wk" 'input as $m | input
        | . + ($m | with_entries(select((.key as $k | $wk | index($k) | not) and (.key | startswith("actual_") | not))))' \
        "$wr/jobs/$id.json" "$SS_C/jobs/$id.json") || return 1
    printf '%s' "$merged" > "$SS_C/jobs/$id.json"
    _ss_in_world "$SS_C" 0 bash -c 'source "$1/state.sh"; source "$1/usage.sh"; mother_recompute_job_cost "$2"' _ "$_LIB_DIR" "$id"
}

# _ss_assert_equivalent <id> <legacy-root> <worker-root> <expected-state> — the whole equivalence contract
# for one finished pair: both reach <expected-state>, the outbox is well formed, and C (seeded with the
# worker's pre-run document and fed the outbox) matches the legacy root.
_ss_assert_equivalent() {
    local id="$1" lr="$2" wr="$3" want="$4" got
    got=$(jq -r '.state' "$lr/jobs/$id.json")
    [ "$got" = "$want" ] || { echo "legacy run ended $got, wanted $want" >&2; cat "$lr/run-job.out" >&2; return 1; }
    got=$(jq -r '.state' "$wr/jobs/$id.json")
    [ "$got" = "$want" ] || { echo "worker-mode run ended $got in the mirror, wanted $want" >&2; cat "$wr/run-job.out" >&2; return 1; }
    _ss_assert_outbox_shape "$wr" "$id" || return 1

    SS_NORM_ROOTS="$SS_NORM_ROOTS $lr $wr"
    _ss_seed_canonical "$SS_C" "$id" "$wr/seed-$id.json"
    _ss_replay_to "$SS_C" "$id" "$wr/outbox/$id.ndjson"
    [ "$status" -eq 0 ] || { echo "replay failed ($status): $output / $stderr" >&2; return 1; }
    [ "$(_ss_last_line)" = "$(tr -d '[:space:]' < "$wr/outbox/$id.seq")" ] \
        || { echo "replay printed '$output', wanted the last seq" >&2; return 1; }

    _ss_stand_in_coordinator "$id" "$wr" || return 1
    _ss_compare_worlds "$id" "$lr" "$SS_C" || return 1

    # The cost is the canonical recompute: C's equals the legacy run's, which is a real number.
    local lcost ccost
    lcost=$(jq -c '.actual_cost_usd' "$lr/jobs/$id.json")
    ccost=$(jq -c '.actual_cost_usd' "$SS_C/jobs/$id.json")
    [ "$lcost" != "null" ] || { echo "legacy run computed no actual_cost_usd" >&2; return 1; }
    jq -n -e --argjson a "$lcost" --argjson b "$ccost" '$a == $b' >/dev/null \
        || { echo "actual_cost_usd: legacy $lcost, replayed $ccost" >&2; return 1; }

    # Artifacts: same files, and the text ones byte-identical.
    _ss_artifact_files "$lr" "$id" > "$BATS_TEST_TMPDIR/a.files"
    _ss_artifact_files "$SS_C" "$id" > "$BATS_TEST_TMPDIR/b.files"
    _ss_same "artifact file list" "$BATS_TEST_TMPDIR/a.files" "$BATS_TEST_TMPDIR/b.files" || return 1
    local f
    while IFS= read -r f; do
        case "$f" in
            *.log|*.excerpt) cmp -s "$lr/$f" "$SS_C/$f" || { echo "artifact $f differs" >&2; return 1; } ;;
        esac
    done < "$BATS_TEST_TMPDIR/a.files"
    return 0
}

# _ss_op <seq> <type> <data-json> — one hand-written outbox line.
_ss_op() {
    jq -nc --argjson seq "$1" --arg t "$2" --argjson data "$3" \
        '{seq: $seq, t: $t, ts: "2026-11-08T12:00:00.000Z", data: $data}'
}

# ===========================================================================
# 1. Off is off

@test "off: without worker mode a real job run creates no outbox and produces the usual state, events and usage row" {
    local id="$SS_PLAIN_ID"
    [ "$(jq -r '.state' "$SS_FL/jobs/$id.json")" = "succeeded" ]
    [ ! -e "$SS_FL/outbox" ]
    run find "$SS_FL" \( -name '*.ndjson' -o -name '*.seq' -o -name 'outbox' \) -not -path '*/work/*' -not -path '*/origin.git/*'
    [ -z "$output" ]
    jq -e 'select(.kind == "succeeded")' "$SS_FL/events/$id.jsonl" >/dev/null
    [ "$(grep -cF "\"job_id\":\"$id\"" "$SS_FL/metrics/runs.jsonl")" = "1" ]
    [ "$(jq -r '.actual_cost_usd' "$SS_FL/jobs/$id.json")" != "null" ]
}

@test "off: an outbox directory in the environment is ignored unless MOTHER_WORKER_MODE=1" {
    local id="ss-dironly"
    mkdir -p "$SS_L/worlds/dironly"
    _ss_in_world "$SS_L/worlds/dironly" 0 _ss_prepare plain "$id"
    _ss_in_world "$SS_L/worlds/dironly" 2 _ss_run_job "$id" || true
    [ "$(jq -r '.state' "$SS_L/worlds/dironly/jobs/$id.json")" = "succeeded" ]
    [ ! -e "$SS_L/worlds/dironly/outbox" ]
}

# ===========================================================================
# 2. Equivalence: legacy run == worker-mode run replayed onto the canonical root

@test "equivalence: a plain succeeded job replays to the same job, events and usage as a legacy run" {
    _ss_assert_equivalent "$SS_PLAIN_ID" "$SS_FL" "$SS_FW" succeeded
}

@test "equivalence: an awaiting job (in-agent mother await) replays to the same job, events and usage" {
    _ss_run_pair await ss-await "$SS_L/worlds/legacy-await" "$SS_W"
    _ss_assert_equivalent ss-await "$SS_L/worlds/legacy-await" "$SS_W" awaiting
}

@test "equivalence: an enforce-gates job with a gate fix replays to the same job, events, usage and gate logs" {
    _ss_run_pair gate ss-gate "$SS_L/worlds/legacy-gate" "$SS_W"
    _ss_assert_equivalent ss-gate "$SS_L/worlds/legacy-gate" "$SS_W" succeeded
    # The scenario really went through a fix: two gate runs, two worker spawns, gate logs shipped.
    jq -e 'select(.kind == "gate_fix_started")' "$SS_C/events/ss-gate.jsonl" >/dev/null
    [ "$(jq -r '.gates.attempt' "$SS_C/jobs/ss-gate.json")" = "2" ]
    [ -s "$SS_C/crew/ss-gate/gates/1/fixme.log" ]
    # attempt 2 passes silently, so its log exists but is empty (legacy too; equality is asserted above)
    [ -f "$SS_C/crew/ss-gate/gates/2/fixme.log" ]
    [ "$(grep -cF '"job_id":"ss-gate"' "$SS_C/metrics/runs.jsonl")" = "2" ]
}

@test "equivalence: a cancelled job replays to the same job, events and usage" {
    _ss_run_pair cancel ss-cancel "$SS_L/worlds/legacy-cancel" "$SS_W"
    _ss_assert_equivalent ss-cancel "$SS_L/worlds/legacy-cancel" "$SS_W" cancelled
}

# ===========================================================================
# 3 and 4. Replay is idempotent and resumable

@test "idempotent replay: applying the same outbox twice changes nothing and duplicates no event or usage line" {
    local id="$SS_PLAIN_ID"
    _ss_seed_canonical "$SS_C" "$id" "$SS_FW/seed-$id.json"
    _ss_replay_to "$SS_C" "$id" "$SS_FW/outbox/$id.ndjson"
    [ "$status" -eq 0 ]
    _ss_snapshot "$SS_C" "$id" > "$BATS_TEST_TMPDIR/once"
    local ev_once rows_once
    ev_once=$(wc -l < "$SS_C/events/$id.jsonl" | tr -d ' ')
    rows_once=$(grep -cF "\"job_id\":\"$id\"" "$SS_C/metrics/runs.jsonl")
    [ "$ev_once" -gt 0 ]
    [ "$rows_once" = "1" ]

    _ss_replay_to "$SS_C" "$id" "$SS_FW/outbox/$id.ndjson"
    [ "$status" -eq 0 ]
    _ss_snapshot "$SS_C" "$id" > "$BATS_TEST_TMPDIR/twice"
    _ss_same "snapshot after a second replay" "$BATS_TEST_TMPDIR/once" "$BATS_TEST_TMPDIR/twice"
    [ "$(wc -l < "$SS_C/events/$id.jsonl" | tr -d ' ')" = "$ev_once" ]
    [ "$(grep -cF "\"job_id\":\"$id\"" "$SS_C/metrics/runs.jsonl")" = "$rows_once" ]
}

@test "partial replay: applying the first k ops and then the whole outbox equals one full replay" {
    local id="$SS_PLAIN_ID" ops="$SS_FW/outbox/$SS_PLAIN_ID.ndjson" n k c
    n=$(wc -l < "$ops" | tr -d ' ')
    [ "$n" -ge 6 ]

    _ss_seed_canonical "$SS_C" "$id" "$SS_FW/seed-$id.json"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    _ss_snapshot "$SS_C" "$id" > "$BATS_TEST_TMPDIR/reference"

    for k in 1 2 $((n / 2)) $((n - 1)); do
        c="$SS_L/worlds/partial-$k"
        _ss_seed_canonical "$c" "$id" "$SS_FW/seed-$id.json"
        head -n "$k" "$ops" > "$BATS_TEST_TMPDIR/prefix-$k.ndjson"
        _ss_replay_to "$c" "$id" "$BATS_TEST_TMPDIR/prefix-$k.ndjson"
        [ "$status" -eq 0 ]
        [ "$(_ss_last_line)" = "$k" ]
        _ss_replay_to "$c" "$id" "$ops"
        [ "$status" -eq 0 ]
        _ss_snapshot "$c" "$id" > "$BATS_TEST_TMPDIR/partial-$k"
        _ss_same "snapshot after prefix $k then full replay" "$BATS_TEST_TMPDIR/reference" "$BATS_TEST_TMPDIR/partial-$k"
    done
}

# ===========================================================================
# 5. Ownership

@test "ownership: ops that set coordinator-owned or unknown job keys are skipped and audited; the other ops still apply" {
    local id="own-1" ops="$BATS_TEST_TMPDIR/own.ndjson"
    _ss_seed_hand "$id"
    {
        _ss_op 1 job.set '{"set":{"repo_path":"/evil/elsewhere"},"del":[]}'
        _ss_op 2 job.set '{"set":{"activity":"building"},"del":[]}'
        _ss_op 3 job.set '{"set":{"cancel_requested":true},"del":[]}'
        _ss_op 4 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:00.000Z\",\"kind\":\"probe\",\"detail\":{\"n\":1}}"}'
        _ss_op 5 job.set '{"set":{"definitely_not_a_job_field":1},"del":[]}'
        _ss_op 6 record.append '{"stream":"metrics/runs.jsonl","line":"{\"ts\":\"2026-11-08T12:00:01.000Z\",\"job_id\":\"own-1\",\"stage\":\"cody\",\"outcome\":\"succeeded\",\"schema\":2,\"cost_usd\":0.5,\"tokens_in\":10,\"tokens_out\":5,\"cost_complete\":true}"}'
        _ss_op 7 job.set '{"set":{"question":"still applied?"},"del":[]}'
    } > "$ops"

    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]

    # Owned keys untouched, worker keys applied.
    [ "$(jq -r '.repo_path' "$SS_C/jobs/$id.json")" = "/tmp/testrepo" ]
    [ "$(jq -r '.cancel_requested // "absent"' "$SS_C/jobs/$id.json")" = "absent" ]
    [ "$(jq -r '.definitely_not_a_job_field // "absent"' "$SS_C/jobs/$id.json")" = "absent" ]
    [ "$(jq -r '.activity' "$SS_C/jobs/$id.json")" = "building" ]
    [ "$(jq -r '.question' "$SS_C/jobs/$id.json")" = "still applied?" ]
    # Event and record ops around the violations still landed.
    [ "$(jq -r 'select(.kind == "probe") | .detail.n' "$SS_C/events/$id.jsonl")" = "1" ]
    [ "$(grep -cF '"job_id":"own-1"' "$SS_C/metrics/runs.jsonl")" = "1" ]

    # The audit names every skipped key, as {ts, job, code:"ownership", keys}.
    [ -s "$SS_C/runner/leases/audit.jsonl" ]
    jq -s -e --arg id "$id" '
        [.[] | select(.code == "ownership" and .job == $id)] as $own
        | (($own | length) >= 1)
          and ($own | all(.[]; (.ts | type) == "string" and (.keys | type) == "array"))
          and ([$own[].keys[]] | ((index("repo_path") != null) and (index("cancel_requested") != null)
                                  and (index("definitely_not_a_job_field") != null)))' \
        "$SS_C/runner/leases/audit.jsonl" >/dev/null
    # Nothing was audited for the keys that were allowed.
    jq -s -e '[.[] | select(.code == "ownership") | .keys[]] | ((index("activity") == null) and (index("question") == null))' \
        "$SS_C/runner/leases/audit.jsonl" >/dev/null
}

@test "ownership: deleting a coordinator-owned key is refused and audited too" {
    local id="own-2" ops="$BATS_TEST_TMPDIR/own-del.ndjson"
    _ss_seed_hand "$id"
    {
        _ss_op 1 job.set '{"set":{},"del":["branch"]}'
        _ss_op 2 job.set '{"set":{"activity":"building"},"del":[]}'
    } > "$ops"

    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.branch' "$SS_C/jobs/$id.json")" = "feature/test" ]
    [ "$(jq -r '.activity' "$SS_C/jobs/$id.json")" = "building" ]
    jq -s -e --arg id "$id" '[.[] | select(.code == "ownership" and .job == $id) | .keys[]] | (index("branch") != null)' \
        "$SS_C/runner/leases/audit.jsonl" >/dev/null
}

# ===========================================================================
# 6. Artifacts

# _ss_emit_artifact <id> <relpath> — in the worker world: emit the file at $SS_W/<relpath> as artifact ops.
_ss_emit_artifact() {
    _ss_in_world "$SS_W" 1 bash -c '
        set -u
        source "$1/state.sh"; source "$1/outbox.sh"
        mother_outbox_artifact "$2" "$3"' _ "$_LIB_DIR" "$1" "$2"
}

@test "artifacts: files of several sizes (including chunk boundaries and a multi-chunk file) arrive byte-identical" {
    local id="art-1" size rel
    _ss_seed_hand "$id"
    mkdir -p "$SS_W/crew/$id/wave/c1"
    for size in 1 4096 262144 262145 700000; do
        rel="crew/$id/wave/c1/blob-$size.bin"
        head -c "$size" /dev/urandom > "$SS_W/$rel"
        _ss_emit_artifact "$id" "$rel"
    done
    # The big one really travelled in several chunks, the last marked final with its checksum.
    jq -s -e --arg p "crew/$id/wave/c1/blob-700000.bin" '
        [.[] | select(.t == "artifact.put" and .data.path == $p)] as $c
        | (($c | length) >= 3) and ($c[-1].data.final == true) and (($c[-1].data.sha256 | length) == 64)
          and ([$c[].data.offset] == ([$c[].data.offset] | sort))' \
        "$SS_W/outbox/$id.ndjson" >/dev/null

    _ss_replay_to "$SS_C" "$id" "$SS_W/outbox/$id.ndjson"
    [ "$status" -eq 0 ]
    for size in 1 4096 262144 262145 700000; do
        rel="crew/$id/wave/c1/blob-$size.bin"
        cmp "$SS_W/$rel" "$SS_C/$rel"
    done
    # Replaying it again leaves the same bytes.
    _ss_replay_to "$SS_C" "$id" "$SS_W/outbox/$id.ndjson"
    [ "$status" -eq 0 ]
    cmp "$SS_W/crew/$id/wave/c1/blob-700000.bin" "$SS_C/crew/$id/wave/c1/blob-700000.bin"
}

@test "artifacts: a multi-chunk file appears at its path only once the final chunk is applied, and resumes from a partial replay" {
    local id="art-2" rel="crew/art-2/wave/c1/big.bin" ops="$SS_W/outbox/art-2.ndjson"
    _ss_seed_hand "$id"
    mkdir -p "$SS_W/crew/$id/wave/c1"
    head -c 700000 /dev/urandom > "$SS_W/$rel"
    _ss_emit_artifact "$id" "$rel"
    [ "$(jq -s 'length' "$ops")" -ge 3 ]

    head -n 2 "$ops" > "$BATS_TEST_TMPDIR/first-two.ndjson"
    _ss_replay_to "$SS_C" "$id" "$BATS_TEST_TMPDIR/first-two.ndjson"
    [ "$status" -eq 0 ]
    [ ! -e "$SS_C/$rel" ]

    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    cmp "$SS_W/$rel" "$SS_C/$rel"
}

@test "artifacts: a final chunk whose sha256 does not match is refused and leaves no file at the path" {
    local id="art-3" rel="crew/art-3/wave/c1/findings.json" ops="$BATS_TEST_TMPDIR/bad-sha.ndjson"
    _ss_seed_hand "$id"
    mkdir -p "$SS_W/crew/$id/wave/c1"
    printf '{"findings":[{"id":"f1","blocking":true}]}\n' > "$SS_W/$rel"
    _ss_emit_artifact "$id" "$rel"
    jq -c 'if .t == "artifact.put" and .data.final == true
           then .data.sha256 = "0000000000000000000000000000000000000000000000000000000000000000" else . end' \
        "$SS_W/outbox/$id.ndjson" > "$ops"

    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -ne 0 ]
    [ ! -e "$SS_C/$rel" ]
}

@test "artifacts: a path that escapes crew/<job>/ or checkpoints/<job>/ is quarantined, nothing is written, and the ops around it still apply" {
    local id="art-4" bad ops i=0 b64
    b64=$(printf 'pwned' | base64 | tr -d '\n')
    for bad in \
        "../escape.txt" \
        "crew/$id/../../escape.txt" \
        "crew/$id/../other-job/x.txt" \
        "$SS_L/abs-escape.txt" \
        "crew/other-job/x.txt" \
        "checkpoints/other-job/x.txt" \
        "jobs/$id.json"; do
        i=$((i + 1))
        SS_C="$SS_L/worlds/canonical-$i"
        _ss_seed_hand "$id"
        ops="$BATS_TEST_TMPDIR/escape-$i.ndjson"
        {
            _ss_op 1 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:00.000Z\",\"kind\":\"before\",\"detail\":{}}"}'
            _ss_op 2 artifact.put "$(jq -nc --arg p "$bad" --arg b "$b64" \
                '{path: $p, offset: 0, b64: $b, final: true, sha256: "6c1b2e1c9c0d7f0b3b8d2cdb5a2f4a0b1a2c3d4e5f60718293a4b5c6d7e8f901"}')"
            _ss_op 3 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:02.000Z\",\"kind\":\"after\",\"detail\":{}}"}'
        } > "$ops"
        cp "$SS_C/jobs/$id.json" "$BATS_TEST_TMPDIR/job-before-$i.json"

        _ss_replay_to "$SS_C" "$id" "$ops"
        # Done, but with a quarantined op (exit 3): the poison op does not stall the ones after it.
        [ "$status" -eq 3 ] || { echo "path '$bad': status $status" >&2; return 1; }
        [ "$(_ss_last_line)" = "3" ] || { echo "path '$bad': printed '$output'" >&2; return 1; }
        grep -q '"kind":"before"' "$SS_C/events/$id.jsonl"
        grep -q '"kind":"after"' "$SS_C/events/$id.jsonl"
        [ "$(jq -s 'length' "$SS_C/runner/leases/$id.quarantine.ndjson")" = "1" ]
        [ "$(jq -s -r '.[0].seq' "$SS_C/runner/leases/$id.quarantine.ndjson")" = "2" ]
        jq -s -e '[.[] | select(.code == "quarantined")] | length == 1' "$SS_C/runner/leases/audit.jsonl" >/dev/null
        cmp "$BATS_TEST_TMPDIR/job-before-$i.json" "$SS_C/jobs/$id.json"
    done
    # Nothing escaped anywhere under the test tree.
    run find "$SS_L" \( -name 'escape.txt' -o -name 'x.txt' -o -name 'abs-escape.txt' \) -not -path '*/fake-home/*'
    [ -z "$output" ]
}

# ===========================================================================
# 7. A worker never writes the canonical root

@test "read-only canonical root: a worker-mode job still reaches its terminal state in the mirror and nothing is written to the canonical root" {
    [ "$(id -u)" != "0" ] || skip "root ignores file permissions"
    local id="ss-ro" canon="$SS_HOME/.mother"
    # The canonical root is where any fallback to ~/.mother would land: HOME is its parent.
    mkdir -p "$canon/jobs" "$canon/events" "$canon/metrics" "$canon/runner"
    echo '{"id":"canon-sentinel"}' > "$canon/jobs/canon-sentinel.json"
    ( cd "$canon" && find . | LC_ALL=C sort && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done ) \
        > "$BATS_TEST_TMPDIR/canon-before"
    chmod -R a-w "$canon"
    if touch "$canon/probe" 2>/dev/null; then skip "permissions are not enforced on this filesystem"; fi

    _ss_in_world "$SS_W" 0 _ss_prepare plain "$id"
    _ss_in_world "$SS_W" 1 _ss_run_job "$id" || true

    [ "$(jq -r '.state' "$SS_W/jobs/$id.json")" = "succeeded" ] || { cat "$SS_W/run-job.out" >&2; return 1; }
    _ss_assert_outbox_shape "$SS_W" "$id"
    jq -e 'select(.kind == "succeeded")' "$SS_W/events/$id.jsonl" >/dev/null

    ( cd "$canon" && find . | LC_ALL=C sort && find . -type f | LC_ALL=C sort | while IFS= read -r f; do shasum -a 256 "$f"; done ) \
        > "$BATS_TEST_TMPDIR/canon-after"
    cmp "$BATS_TEST_TMPDIR/canon-before" "$BATS_TEST_TMPDIR/canon-after"
    [ ! -e "$canon/jobs/$id.json" ]
    [ ! -e "$canon/events/$id.jsonl" ]
}

# ===========================================================================
# 8. safe_rm_tree and the worker marker

# Run safe_rm_tree in a fresh bash; sets status/output (stderr merged).
_srt() { run bash -c "source '$_LIB_DIR/safe-rm.sh'; safe_rm_tree \"\$1\"" _ "$1"; }

@test "safe_rm_tree refuses a worker root carrying .mother-worker-live and deletes nothing" {
    mkdir -p "$SS_L/victim-worker/jobs" "$SS_L/victim-worker/outbox"
    : > "$SS_L/victim-worker/.mother-worker-live"
    echo '{"seq":1}' > "$SS_L/victim-worker/outbox/j.ndjson"

    _srt "$SS_L/victim-worker"

    [ "$status" -ne 0 ]
    printf '%s' "$output" | grep -qF 'safe_rm_tree: refusing'
    [ -e "$SS_L/victim-worker/.mother-worker-live" ]
    [ -s "$SS_L/victim-worker/outbox/j.ndjson" ]
}

@test "safe_rm_tree refuses a directory that contains a worker root, even a few levels down" {
    mkdir -p "$SS_L/parent/a/b/worker-root"
    : > "$SS_L/parent/a/b/worker-root/.mother-worker-live"

    _srt "$SS_L/parent"

    [ "$status" -ne 0 ]
    printf '%s' "$output" | grep -qF 'safe_rm_tree: refusing'
    [ -e "$SS_L/parent/a/b/worker-root/.mother-worker-live" ]
}

@test "safe_rm_tree refuses an ancestor of the current worker root even when the marker is too deep to scan" {
    local deep="$SS_L/anc/a/b/c/d/e/worker-root"
    mkdir -p "$deep"
    : > "$deep/.mother-worker-live"

    run bash -c "export MOTHER_ROOT='$deep'; source '$_LIB_DIR/safe-rm.sh'; safe_rm_tree \"\$1\"" _ "$SS_L/anc"

    [ "$status" -ne 0 ]
    [ -e "$deep/.mother-worker-live" ]
}

@test "safe_rm_tree still removes an ordinary directory next to a worker root" {
    mkdir -p "$SS_L/plain-victim/a" "$SS_L/other-worker"
    : > "$SS_L/other-worker/.mother-worker-live"

    _srt "$SS_L/plain-victim"

    [ "$status" -eq 0 ]
    [ ! -e "$SS_L/plain-victim" ]
    [ -e "$SS_L/other-worker/.mother-worker-live" ]
}

# ===========================================================================
# 9. Cost is canonical

@test "cost: the worker mirror never computes actual_cost_usd; the canonical root does after replay" {
    local id="$SS_PLAIN_ID"
    # The mirror kept its usage rows (so a cost could have been computed) but computed none.
    [ "$(grep -cF "\"job_id\":\"$id\"" "$SS_FW/metrics/runs.jsonl")" = "1" ]
    [ "$(jq -r '.actual_cost_usd // "none"' "$SS_FW/jobs/$id.json")" = "none" ]

    _ss_seed_canonical "$SS_C" "$id" "$SS_FW/seed-$id.json"
    [ "$(jq -r '.actual_cost_usd // "none"' "$SS_C/jobs/$id.json")" = "none" ]
    _ss_replay_to "$SS_C" "$id" "$SS_FW/outbox/$id.ndjson"
    [ "$status" -eq 0 ]

    local ccost lcost
    ccost=$(jq -c '.actual_cost_usd' "$SS_C/jobs/$id.json")
    lcost=$(jq -c '.actual_cost_usd' "$SS_FL/jobs/$id.json")
    jq -n -e --argjson c "$ccost" '$c > 0' >/dev/null
    jq -n -e --argjson c "$ccost" --argjson l "$lcost" '$c == $l' >/dev/null
    # ...and so is the token total.
    [ "$(jq -c '.actual_tokens' "$SS_C/jobs/$id.json")" = "$(jq -c '.actual_tokens' "$SS_FL/jobs/$id.json")" ]
}

# ===========================================================================
# 9. Review fix-ups (PR #119): the replay is the boundary
#
# A worker, or an agent inside it, can write straight into its outbox, so coord_apply.sh must judge every op
# as strictly as the P1-1 Go allowlist, apply what is allowed key by key, never stall on a poison line, and
# stay exactly-once. The emitter is safe and loud, and worker mode cannot be half-on or aimed at the real tree.

SS_GO_OWNERSHIP="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../broker/workerproto" && pwd -P)/ownership.go"
SS_GO_DATA="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../broker/workerproto" && pwd -P)/data.go"

_ss_audit_keys() { # <croot> <code> — every key audited under <code>, one per line
    jq -r --arg c "$2" 'select(.code == $c) | .keys[]' "$1/runner/leases/audit.jsonl" 2>/dev/null
}

# _ss_go_list <var> — the quoted strings of `var = []string{...}` in ownership.go, space-separated, in order.
_ss_go_list() {
    awk -v v="$1" '
        $0 ~ "^[ \t]*" v " *= *\\[\\]string\\{" { on = 1 }
        on { print }
        on && /\}/ { exit }' "$SS_GO_OWNERSHIP" | grep -o '"[^"]*"' | tr -d '"' | tr '\n' ' ' | sed 's/ $//'
}

@test "allowlist: the bash key tables equal the Go constants (WorkerKeys, CoordinatorDerivedKeys, SyncDownKeys, StateValues, keyKinds, limits)" {
    run bash -c 'source "$1"; printf "%s\n%s\n%s\n%s\n%s\n%s %s %s %s\n" "$_CA_WORKER_KEYS" "$_CA_DERIVED_KEYS" "$_CA_SYNCDOWN_KEYS" "$_CA_STATE_VALUES" "$_CA_KEY_KINDS" "$_CA_MAX_TEXT" "$_CA_MAX_STRUCT" "$_CA_MAX_KEYS" "$_CA_MAX_CHUNK"' _ "$SS_COORD_APPLY"
    [ "$status" -eq 0 ]
    local lines=()
    while IFS= read -r l; do lines+=("$l"); done <<< "$output"
    [ "${lines[0]}" = "$(_ss_go_list WorkerKeys)" ]
    [ "${lines[1]}" = "$(_ss_go_list CoordinatorDerivedKeys)" ]
    [ "${lines[2]}" = "$(_ss_go_list SyncDownKeys)" ]
    [ "${lines[3]}" = "$(_ss_go_list StateValues)" ]
    # keyKinds: "key": kind pairs; Go's kText kToken kID kTS kUint kNum kBool kObject kArray -> text token id ts uint num bool object array.
    local gk
    gk=$(awk '/^var keyKinds = map/ { on = 1; next } on && /^\}/ { exit } on { print }' "$SS_GO_OWNERSHIP" \
        | grep -oE '"[a-z_]+": *k[A-Za-z]+' | sed -e 's/"\([a-z_]*\)": *k\(.*\)/\1:\2/' \
        | awk -F: '{ k = tolower($2); print $1 ":" k }' | tr '\n' ' ' | sed 's/ $//')
    # Fail loudly if the parse silently dropped keys (the gofmt-padding regression): a sane table has many entries.
    local gkn; gkn=$(wc -w <<< "$gk")
    [ "$gkn" -ge 20 ] || { echo "parsed only $gkn keyKinds entries from ownership.go" >&2; return 1; }
    [ "${lines[4]}" = "$gk" ]
    # Limits.
    local mt ms mk mc
    mt=$(grep -E '^\s*MaxTextLen\s*=' "$SS_GO_DATA" | grep -o '[0-9]\+' | head -1)
    mk=$(grep -E '^\s*MaxKeys\s*=' "$SS_GO_DATA" | grep -o '[0-9]\+' | head -1)
    [ "${lines[5]}" = "$mt $((64 << 10)) $mk $((256 << 10))" ]
}

@test "ownership: a worker cannot claim success: succeeded, pr_url and exit_code in a crafted op are refused and audited" {
    local id="own-succ" ops="$BATS_TEST_TMPDIR/succ.ndjson"
    _ss_seed_hand "$id"
    _ss_op 1 job.set '{"set":{"state":"succeeded","pr_url":"https://x","exit_code":0},"del":[]}' > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "running" ]
    [ "$(jq -r '.pr_url' "$SS_C/jobs/$id.json")" = "null" ]
    [ "$(jq -r '.exit_code // "absent"' "$SS_C/jobs/$id.json")" = "absent" ]
    local k; k=$(_ss_audit_keys "$SS_C" ownership)
    [[ "$k" == *state* && "$k" == *pr_url* && "$k" == *exit_code* ]]
}

@test "ownership: every coordinator-derived key is refused, with or without a state change; the allowed keys of the same op still apply" {
    local id="own-derived" ops="$BATS_TEST_TMPDIR/derived.ndjson" k
    _ss_seed_hand "$id"
    _ss_op 1 job.set '{"set":{"state":"awaiting","activity":"waiting","pr_url":"https://x","actual_branch":"b","finished_at":"2026-11-08T12:00:00.000Z","exit_code":0,"failure_reason":"nope"},"del":[]}' > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    # Per-key apply: the allowed keys (state awaiting, activity) landed...
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "awaiting" ]
    [ "$(jq -r '.activity' "$SS_C/jobs/$id.json")" = "waiting" ]
    # ...and the derived ones did not.
    for k in pr_url actual_branch finished_at exit_code failure_reason; do
        [ "$(jq -r --arg k "$k" '.[$k] // "none"' "$SS_C/jobs/$id.json")" = "none" ] || { echo "$k applied" >&2; return 1; }
        _ss_audit_keys "$SS_C" ownership | grep -qx "$k" || { echo "$k not audited" >&2; return 1; }
    done
}

@test "ownership: inventory keys (work_dir, base_sha, not_before, force_ignore_deps, current_tier) are refused from a worker" {
    local id="own-inv" ops="$BATS_TEST_TMPDIR/inv.ndjson" k
    _ss_seed_hand "$id"
    cp "$SS_C/jobs/$id.json" "$BATS_TEST_TMPDIR/before.json"
    _ss_op 1 job.set '{"set":{"work_dir":"/evil","base_sha":"abc","not_before":1,"force_ignore_deps":true,"current_tier":"tier_3"},"del":[]}' > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(jq -S . "$BATS_TEST_TMPDIR/before.json")" = "$(jq -S . "$SS_C/jobs/$id.json")" ]
    for k in work_dir base_sha not_before force_ignore_deps current_tier; do
        _ss_audit_keys "$SS_C" ownership | grep -qx "$k"
    done
}

@test "ownership: cancel_requested, pause_requested and force_start cannot be nulled or deleted by a worker" {
    local id="own-sync" ops="$BATS_TEST_TMPDIR/sync.ndjson" k
    _ss_seed_hand "$id"
    jq '.cancel_requested = true | .pause_requested = true | .force_start = true | .pending_answer = "a"' "$SS_C/jobs/$id.json" > "$SS_C/jobs/$id.tmp" \
        && mv "$SS_C/jobs/$id.tmp" "$SS_C/jobs/$id.json"
    {
        _ss_op 1 job.set '{"set":{"cancel_requested":null,"pause_requested":null,"force_start":null},"del":[]}'
        _ss_op 2 job.set '{"set":{},"del":["cancel_requested","pause_requested","force_start"]}'
    } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.cancel_requested' "$SS_C/jobs/$id.json")" = "true" ]
    [ "$(jq -r '.pause_requested' "$SS_C/jobs/$id.json")" = "true" ]
    [ "$(jq -r '.force_start' "$SS_C/jobs/$id.json")" = "true" ]
    for k in cancel_requested pause_requested force_start; do _ss_audit_keys "$SS_C" ownership | grep -qx "$k"; done
    # The one Go-allowed consumption: pending_answer -> null (set or delete).
    _ss_op 3 job.set '{"set":{"pending_answer":null},"del":[]}' > "$BATS_TEST_TMPDIR/pa.ndjson"
    _ss_replay_to "$SS_C" "$id" "$BATS_TEST_TMPDIR/pa.ndjson"
    [ "$(jq -r '.pending_answer' "$SS_C/jobs/$id.json")" = "null" ]
}

@test "ownership: a terminal state is never left, running is refused after a cancel, and an unknown state value is refused" {
    local id="own-term" ops="$BATS_TEST_TMPDIR/term.ndjson"
    _ss_seed_hand "$id"
    # succeeded -> failed
    jq '.state = "succeeded"' "$SS_C/jobs/$id.json" > "$SS_C/jobs/$id.tmp" && mv "$SS_C/jobs/$id.tmp" "$SS_C/jobs/$id.json"
    _ss_op 1 job.set '{"set":{"state":"failed","activity":"x"},"del":[]}' > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "succeeded" ]
    # A refused state refuses the whole op: the activity in the same op is not applied either.
    [ "$(jq -r '.activity // "none"' "$SS_C/jobs/$id.json")" = "none" ]
    _ss_audit_keys "$SS_C" op_refused | grep -qx "activity"
    # running after a cancel request
    jq '.state = "running" | .cancel_requested = true' "$SS_C/jobs/$id.json" > "$SS_C/jobs/$id.tmp" && mv "$SS_C/jobs/$id.tmp" "$SS_C/jobs/$id.json"
    _ss_op 1 job.set '{"set":{"state":"running"},"del":[]}' > "$ops"
    rm -f "$SS_C/runner/leases/applied/$id.seq"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "running" ]
    _ss_audit_keys "$SS_C" ownership | grep -qx "state"
    # unknown state value, and a state delete
    _ss_op 1 job.set '{"set":{"state":"bogus"},"del":["state"]}' > "$ops"
    rm -f "$SS_C/runner/leases/applied/$id.seq"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "running" ]
    # cancelled stays cancelled (and a worker may set it)
    jq '.state = "cancelled"' "$SS_C/jobs/$id.json" > "$SS_C/jobs/$id.tmp" && mv "$SS_C/jobs/$id.tmp" "$SS_C/jobs/$id.json"
    _ss_op 1 job.set '{"set":{"state":"running"},"del":[]}' > "$ops"
    rm -f "$SS_C/runner/leases/applied/$id.seq"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "cancelled" ]
}

@test "kinds: wrongly typed or oversized values (worker_pid abc, attention x, gates 7, live_cost_usd -5, a 300 KB question) are refused; a valid op still applies" {
    local id="kinds-1" ops="$BATS_TEST_TMPDIR/kinds.ndjson" big k
    _ss_seed_hand "$id"
    big=$(head -c 307200 /dev/zero | tr '\0' 'q')
    {
        _ss_op 1 job.set '{"set":{"worker_pid":"abc"},"del":[]}'
        _ss_op 2 job.set '{"set":{"attention":"x"},"del":[]}'
        _ss_op 3 job.set '{"set":{"gates":7},"del":[]}'
        _ss_op 4 job.set '{"set":{"live_cost_usd":-5},"del":[]}'
        _ss_op 5 job.set "$(jq -nc --arg q "$big" '{set: {question: $q}, del: []}')"
        _ss_op 6 job.set '{"set":{"activity":"has space"},"del":[]}'
        _ss_op 7 job.set '{"set":{"session_id":"a..b"},"del":[]}'
        _ss_op 8 job.set '{"set":{"started_at":""},"del":[]}'
        _ss_op 9 job.set '{"set":{"continuation_count":1.5,"resume_not_yet_acted_on":"yes"},"del":[]}'
        _ss_op 10 job.set '{"set":{"worker_pid":4242,"attention":[{"reason":"progress_stalled"}],"question":"fine","live_cost_usd":1.25},"del":[]}'
    } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ] || { echo "status $status: $stderr" >&2; return 1; }
    [ "$(_ss_last_line)" = "10" ]
    jq -e '.worker_pid == 4242 and .question == "fine" and .live_cost_usd == 1.25 and (.attention | length) == 1' "$SS_C/jobs/$id.json" >/dev/null
    [ "$(jq -r '.gates // "none"' "$SS_C/jobs/$id.json")" = "none" ]
    [ "$(jq -r '.activity // "none"' "$SS_C/jobs/$id.json")" = "none" ]
    for k in worker_pid attention gates live_cost_usd question activity session_id started_at continuation_count resume_not_yet_acted_on; do
        _ss_audit_keys "$SS_C" invalid | grep -qx "$k" || { echo "$k not audited as invalid" >&2; return 1; }
    done
}

@test "bounds: an oversized event line and an oversized usage row are quarantined, not appended" {
    local id="bound-1" ops="$BATS_TEST_TMPDIR/bound.ndjson" big
    _ss_seed_hand "$id"
    big=$(head -c 70000 /dev/zero | tr '\0' 'e')
    {
        _ss_op 1 event.append "$(jq -nc --arg b "$big" '{line: ({ts:"2026-11-08T12:00:00.000Z",kind:"big",detail:{b:$b}} | tojson)}')"
        _ss_op 2 record.append "$(jq -nc --arg b "$(head -c 20000 /dev/zero | tr '\0' 'r')" '{stream:"metrics/runs.jsonl", line: ({job_id:"bound-1",cost_usd:1,pad:$b} | tojson)}')"
        _ss_op 3 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:02.000Z\",\"kind\":\"small\",\"detail\":{}}"}'
    } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 3 ]
    ! grep -q '"kind":"big"' "$SS_C/events/$id.jsonl"
    grep -q '"kind":"small"' "$SS_C/events/$id.jsonl"
    [ ! -s "$SS_C/metrics/runs.jsonl" ]
    [ "$(jq -s 'length' "$SS_C/runner/leases/$id.quarantine.ndjson")" = "2" ]
}

@test "per-key apply: a refused key does not drop the allowed keys of the same op, and the audit names only the refused ones" {
    local id="perkey-1" ops="$BATS_TEST_TMPDIR/perkey.ndjson"
    _ss_seed_hand "$id"
    _ss_op 1 job.set '{"set":{"activity":"building","repo_path":"/evil","question":"q?","session_id":"s-1"},"del":["branch","paused_reason"]}' > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    jq -e '.activity == "building" and .question == "q?" and .session_id == "s-1" and .repo_path == "/tmp/testrepo" and .branch == "feature/test"' \
        "$SS_C/jobs/$id.json" >/dev/null
    [ "$(_ss_audit_keys "$SS_C" ownership | sort | tr '\n' ' ')" = "branch repo_path " ]
}

@test "pipeline: _review_slot_write in worker mode ships reviewer_findings, which reach the canonical job; the rest of pipeline stays coordinator-owned" {
    local id="pipe-1" rf='{"decision":"pass","findings":[]}'
    _ss_in_world "$SS_W" 0 make_job "$id" running '.kind = "pipeline" | .pipeline = {cycle_cap: 3, review_cycle: 0}'
    _ss_in_world "$SS_W" 1 bash -c '
        set -u
        source "$1/state.sh"
        eval "$(sed -n "/^_review_slot_write()/,/^}/p" "$2")"
        _review_slot_write "$JOBS_DIR/$3.json" "$4" "perri:correctness"' _ "$_LIB_DIR" "$_BIN_DIR/mother" "$id" "$rf"
    [ -s "$SS_W/outbox/$id.ndjson" ]
    cp "$SS_W/jobs/$id.json" "$BATS_TEST_TMPDIR/mirror.json"
    # Canonical: same job before the write, with its own coordinator-side pipeline state.
    SS_C="$SS_C"; mkdir -p "$SS_C/jobs" "$SS_C/events" "$SS_C/metrics" "$SS_C/runner"
    _ss_in_world "$SS_C" 0 make_job "$id" running '.kind = "pipeline" | .pipeline = {cycle_cap: 3, review_cycle: 2}'
    _ss_replay_to "$SS_C" "$id" "$SS_W/outbox/$id.ndjson"
    [ "$status" -eq 0 ]
    jq -e --argjson rf "$rf" '.pipeline.reviewer_findings["perri:correctness"] == $rf and .pipeline.review_cycle == 2 and .pipeline.cycle_cap == 3' \
        "$SS_C/jobs/$id.json" >/dev/null
}

# ---------------------------------------------------------------------------
# No poison line

@test "poison: a corrupt middle line is quarantined and audited, the ops after it apply, and the job still reaches its terminal state" {
    local id="poison-1" ops="$BATS_TEST_TMPDIR/poison.ndjson"
    _ss_seed_hand "$id"
    {
        _ss_op 1 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:00.000Z\",\"kind\":\"a\",\"detail\":{}}"}'
        printf '%s\n' '{"seq":2,"t":"event.append","data":{"line":"{\"ts\":'
        _ss_op 3 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:02.000Z\",\"kind\":\"c\",\"detail\":{}}"}'
        _ss_op 4 job.set '{"set":{"state":"cancelled"},"del":[]}'
    } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 3 ] || { echo "status $status / $stderr" >&2; return 1; }
    [ "$(_ss_last_line)" = "4" ]
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "cancelled" ]
    grep -q '"kind":"c"' "$SS_C/events/$id.jsonl"
    [ "$(jq -s 'length' "$SS_C/runner/leases/$id.quarantine.ndjson")" = "1" ]
    jq -s -e '[.[] | select(.code == "quarantined")] | length == 1' "$SS_C/runner/leases/audit.jsonl" >/dev/null
    # A retry changes nothing and quarantines nothing more.
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$(jq -s 'length' "$SS_C/runner/leases/$id.quarantine.ndjson")" = "1" ]
    [ "$(grep -c '"kind":"c"' "$SS_C/events/$id.jsonl")" = "1" ]
}

@test "poison: an op that can never apply (no .data, bad type) is quarantined; a transient failure is never quarantined, it stays pending and applies once the fault clears" {
    [ "$(id -u)" != "0" ] || skip "root ignores file permissions"
    local id="poison-2" ops="$BATS_TEST_TMPDIR/poison2.ndjson"
    _ss_seed_hand "$id"
    {
        _ss_op 1 bogus.type '{}'
        _ss_op 2 job.set '"not an object"'
        _ss_op 3 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:00.000Z\",\"kind\":\"t\",\"detail\":{}}"}'
        _ss_op 4 job.set '{"set":{"activity":"after"},"del":[]}'
    } > "$ops"
    : > "$SS_C/events/$id.jsonl"
    chmod 444 "$SS_C/events/$id.jsonl"      # the event append fails transiently
    local n
    for n in 1 2 3 4; do
        _ss_replay_to "$SS_C" "$id" "$ops"
        [ "$status" -eq 1 ] || { echo "attempt $n: status $status" >&2; return 1; }
        [ "$(_ss_last_line)" = "2" ]
        [ "$(jq -s 'length' "$SS_C/runner/leases/$id.quarantine.ndjson")" = "2" ]
    done
    jq -s -e '[.[] | select(.code == "transient_stop")] | length == 4' "$SS_C/runner/leases/audit.jsonl" >/dev/null
    jq -e '.needs_attention.reason == "apply_stalled"' "$SS_C/jobs/$id.json" >/dev/null
    chmod 644 "$SS_C/events/$id.jsonl"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(_ss_last_line)" = "4" ]
    [ "$(jq -r '.activity' "$SS_C/jobs/$id.json")" = "after" ]
    [ "$(grep -c '"kind":"t"' "$SS_C/events/$id.jsonl")" = "1" ]
    [ "$(jq -s 'length' "$SS_C/runner/leases/$id.quarantine.ndjson")" = "2" ]
}

@test "transient: three consecutive job-lock timeouts on a state-carrying job.set leave it pending; it applies once the lock frees" {
    local id="trans-1" ops="$BATS_TEST_TMPDIR/trans.ndjson" n
    _ss_seed_hand "$id"
    _ss_op 1 job.set '{"set":{"state":"cancelled"},"del":[]}' > "$ops"
    # A live process (this test) holds the job lock (the lockdir names its pid): the replay's 10 s wait times out.
    mkdir "$SS_C/jobs/$id.json.lockdir" && echo "$$" > "$SS_C/jobs/$id.json.lockdir/owner"
    for n in 1 2 3; do
        _ss_replay_to "$SS_C" "$id" "$ops"
        [ "$status" -eq 1 ] || { echo "attempt $n: status $status" >&2; return 1; }
        [ "$(_ss_last_line)" = "0" ]
    done
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "running" ]
    [ ! -e "$SS_C/runner/leases/$id.quarantine.ndjson" ]
    jq -s -e '[.[] | select(.code == "transient_stop")] | length == 3' "$SS_C/runner/leases/audit.jsonl" >/dev/null
    rm -f "$SS_C/jobs/$id.json.lockdir/owner"; rmdir "$SS_C/jobs/$id.json.lockdir"   # the lock frees
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ] || { echo "status $status / $stderr" >&2; return 1; }
    [ "$(jq -r '.state' "$SS_C/jobs/$id.json")" = "cancelled" ]
}

@test "crash: dying between apply and persist never duplicates an event or a usage row, nor double-counts cost; a repeated identical event with a new seq still applies" {
    local id="crash-1" ops="$BATS_TEST_TMPDIR/crash.ndjson" ev row n
    _ss_seed_hand "$id"
    ev='{"ts":"2026-11-08T12:00:00.000Z","kind":"same","detail":{}}'
    row=$(jq -nc --arg j "$id" '{job_id: $j, cost_usd: 1.5, tokens_in: 10, tokens_out: 5, model: "sonnet"}')
    {
        _ss_op 1 event.append "$(jq -nc --arg l "$ev" '{line: $l}')"
        _ss_op 2 record.append "$(jq -nc --arg l "$row" '{stream: "metrics/runs.jsonl", line: $l}')"
        _ss_op 3 event.append "$(jq -nc --arg l "$ev" '{line: $l}')"
    } > "$ops"
    # Crash 1: after the event landed, before seq 1 is persisted. Crash 2: after the usage row landed.
    for n in 1 2; do
        run --separate-stderr _ss_in_world "$SS_C" 0 env MOTHER_TEST_CRASH_AFTER_APPLY="$n" \
            bash -c '"$0" "$1" "$2" < "$3"' "$SS_COORD_APPLY" "$SS_C" "$id" "$ops"
        [ "$status" -ne 0 ]
    done
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ] || { echo "status $status / $stderr" >&2; return 1; }
    [ "$(_ss_last_line)" = "3" ]
    # seq 1 and seq 3 are the same line but different ops: two events; the crash added none.
    [ "$(grep -c '"kind":"same"' "$SS_C/events/$id.jsonl")" = "2" ]
    [ "$(grep -c "\"job_id\":\"$id\"" "$SS_C/metrics/runs.jsonl")" = "1" ]
    [ "$(jq -r '.actual_cost_usd' "$SS_C/jobs/$id.json")" = "1.5" ]
    [ "$(jq -r '.actual_tokens' "$SS_C/jobs/$id.json")" = "15" ]
    # A full re-run changes nothing.
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$(grep -c '"kind":"same"' "$SS_C/events/$id.jsonl")" = "2" ]
    [ "$(grep -c "\"job_id\":\"$id\"" "$SS_C/metrics/runs.jsonl")" = "1" ]
}

# ---------------------------------------------------------------------------
# Contiguous seq, safe emit

@test "seq: a gap (1 then 3) stops the replay at 1 and says so; the missing op arriving later lets it continue" {
    local id="seq-1" ops="$BATS_TEST_TMPDIR/gap.ndjson" full="$BATS_TEST_TMPDIR/gapfull.ndjson"
    _ss_seed_hand "$id"
    _ss_op 1 job.set '{"set":{"activity":"one"},"del":[]}' > "$ops"
    _ss_op 3 job.set '{"set":{"activity":"three"},"del":[]}' >> "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 1 ]
    [ "$(_ss_last_line)" = "1" ]
    [[ "$stderr" == *gap* ]]
    [ "$(jq -r '.activity' "$SS_C/jobs/$id.json")" = "one" ]
    { _ss_op 1 job.set '{"set":{"activity":"one"},"del":[]}'; _ss_op 2 job.set '{"set":{"question":"two"},"del":[]}'
      _ss_op 3 job.set '{"set":{"activity":"three"},"del":[]}'; } > "$full"
    _ss_replay_to "$SS_C" "$id" "$full"
    [ "$status" -eq 0 ]
    [ "$(jq -r '.activity' "$SS_C/jobs/$id.json")" = "three" ]
}

@test "seq: a duplicate seq is skipped, but a legitimately repeated identical line (new seq) is applied" {
    local id="seq-2" ops="$BATS_TEST_TMPDIR/dup.ndjson" ev
    _ss_seed_hand "$id"
    ev='{"line":"{\"ts\":\"2026-11-08T12:00:00.000Z\",\"kind\":\"same\",\"detail\":{}}"}'
    { _ss_op 1 event.append "$ev"; _ss_op 2 event.append "$ev"; _ss_op 2 event.append "$ev"; _ss_op 1 event.append "$ev"; } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(grep -c '"kind":"same"' "$SS_C/events/$id.jsonl")" = "2" ]
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$(grep -c '"kind":"same"' "$SS_C/events/$id.jsonl")" = "2" ]
}

# _ss_emit <id> <n> — n event.append ops from the worker world.
_ss_emit() {
    local id="$1" n="$2"
    _ss_in_world "$SS_W" 1 bash -c '
        source "$1/state.sh"
        i=0; while [ "$i" -lt "$3" ]; do i=$((i + 1)); mother_event_append "$2" probe "{\"n\":$i}" || exit 1; done' _ "$_LIB_DIR" "$id" "$n"
}

@test "emit: a seq file that cannot be written (or is stale) never causes a reused seq; the ndjson is the source of truth" {
    local id="emit-1"
    mkdir -p "$SS_W/outbox"
    printf 'garbage' > "$SS_W/outbox/$id.seq"
    _ss_emit "$id" 3
    jq -s -e 'map(.seq) == [1,2,3]' "$SS_W/outbox/$id.ndjson" >/dev/null
    printf '1' > "$SS_W/outbox/$id.seq"     # stale: behind the ndjson
    _ss_emit "$id" 2
    jq -s -e 'map(.seq) == [1,2,3,4,5]' "$SS_W/outbox/$id.ndjson" >/dev/null
    rm -f "$SS_W/outbox/$id.seq"            # missing: the ndjson still decides
    _ss_emit "$id" 1
    jq -s -e 'map(.seq) == [1,2,3,4,5,6]' "$SS_W/outbox/$id.ndjson" >/dev/null
}

@test "emit: a torn last line is terminated before the next op, so two ops are never fused; the replay quarantines the torn one and applies the rest" {
    local id="emit-2"
    _ss_seed_hand "$id"
    mkdir -p "$SS_W/outbox"
    { _ss_op 1 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:00.000Z\",\"kind\":\"one\",\"detail\":{}}"}'
      printf '{"seq":2,"t":"event.append","ts":"x","data":{"line":"{\\"ts'; } > "$SS_W/outbox/$id.ndjson"
    _ss_emit "$id" 1
    [ "$(wc -l < "$SS_W/outbox/$id.ndjson" | tr -d ' ')" = "3" ]
    [ "$(tail -n 1 "$SS_W/outbox/$id.ndjson" | jq -r '.seq')" = "2" ]
    _ss_replay_to "$SS_C" "$id" "$SS_W/outbox/$id.ndjson"
    [ "$status" -eq 3 ]
    [ "$(_ss_last_line)" = "2" ]
    grep -q '"kind":"one"' "$SS_C/events/$id.jsonl"
    grep -q '"kind":"probe"' "$SS_C/events/$id.jsonl"
}

@test "replay: an unterminated last line that is not yet a whole op is left alone (not quarantined)" {
    local id="seq-3" ops="$BATS_TEST_TMPDIR/torn.ndjson"
    _ss_seed_hand "$id"
    { _ss_op 1 event.append '{"line":"{\"ts\":\"2026-11-08T12:00:00.000Z\",\"kind\":\"one\",\"detail\":{}}"}'
      printf '{"seq":2,"t":"event.append","data":{"li'; } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 1 ]
    [ "$(_ss_last_line)" = "1" ]
    [ ! -e "$SS_C/runner/leases/$id.quarantine.ndjson" ]
}

# ---------------------------------------------------------------------------
# Emit failures are loud and hold the job

@test "emit failure: an unwritable outbox dir fails the write loudly, flags the outbox degraded, and the op is not silently dropped" {
    [ "$(id -u)" != "0" ] || skip "root ignores file permissions"
    local id="deg-1"
    _ss_in_world "$SS_W" 0 make_job "$id" running
    mkdir -p "$SS_W/outbox"
    run --separate-stderr _ss_in_world "$SS_W" 1 bash -c '
        source "$1/state.sh"
        chmod a-w "$MOTHER_WORKER_OUTBOX_DIR"       # breaks after startup validation passed
        mother_job_update "$2" ".question = \"lost?\""; echo "update rc=$?"
        mother_event_append "$2" probe "{}"; echo "event rc=$?"' _ "$_LIB_DIR" "$id"
    [[ "$output" == *"update rc=1"* ]]
    [[ "$output" == *"event rc=1"* ]]
    [[ "$stderr" == *"OUTBOX DEGRADED"* ]]
    [ -f "$SS_W/runner/$id.outbox-degraded" ]
    jq -e '.why | length > 0' "$SS_W/runner/$id.outbox-degraded" >/dev/null
    [ ! -s "$SS_W/outbox/$id.ndjson" ]
}

@test "emit failure: an empty previous document is a failed emit, not a silent skip" {
    local id="deg-2"
    _ss_in_world "$SS_W" 0 make_job "$id" running
    : > "$SS_W/jobs/$id.json.empty"
    run --separate-stderr _ss_in_world "$SS_W" 1 bash -c '
        source "$1/state.sh"
        mother_job_write_doc "$JOBS_DIR/$2.missing.json" "{\"id\":\"x\"}"; echo "rc=$?"' _ "$_LIB_DIR" "$id"
    [[ "$output" == *"rc=1"* ]]
    [ -f "$SS_W/runner/$id.missing.outbox-degraded" ]
}

@test "emit failure: a job whose outbox breaks mid-run is held (awaiting, outbox_degraded) and never reaches succeeded" {
    [ "$(id -u)" != "0" ] || skip "root ignores file permissions"
    local id="deg-3"
    mkdir -p "$SS_W"
    _ss_in_world "$SS_W" 0 _ss_prepare plain "$id"
    # The worker's run breaks the outbox (not writable any more) just before it exits.
    _ss_in_world "$SS_W" 0 _ss_behave 1 'SLEEP=0; POST='"'"'chmod a-w "$ROOT/outbox"'"'"
    run _ss_in_world "$SS_W" 1 _ss_run_job "$id"
    [ "$(jq -r '.state' "$SS_W/jobs/$id.json")" = "awaiting" ] || { cat "$SS_W/run-job.out" >&2; return 1; }
    [ "$(jq -r '.paused_reason' "$SS_W/jobs/$id.json")" = "outbox_degraded" ]
    [ -f "$SS_W/runner/$id.outbox-degraded" ]
    grep -q "OUTBOX DEGRADED" "$SS_W/run-job.out"
}

# ---------------------------------------------------------------------------
# Worker mode cannot be half-on or aimed at the real tree

@test "worker mode: MOTHER_WORKER_MODE=1 alone is refused and nothing is created under the real or default root" {
    run --separate-stderr env -u MOTHER_ROOT -u MOTHER_LIVE_ROOT -u JOBS_DIR -u EVENTS_DIR -u LOGS_DIR -u DRAFTS_DIR \
        -u CURSORS_DIR -u RUNNER_DIR -u ARCHIVE_DIR -u TEARDOWN_DIR -u MOTHER_TEST_ROOT -u MOTHER_WORKER_OUTBOX_DIR \
        HOME="$SS_HOME" MOTHER_WORKER_MODE=1 bash -c 'source "$1/state.sh"; echo survived' _ "$_LIB_DIR"
    [ "$status" -ne 0 ]
    [[ "$output" != *survived* ]]
    [[ "$stderr" == *"worker mode"* ]]
    [ ! -e "$SS_HOME/.mother" ]
    # mother-run-job refuses the same way.
    run --separate-stderr env -u MOTHER_ROOT -u MOTHER_LIVE_ROOT -u MOTHER_TEST_ROOT HOME="$SS_HOME" MOTHER_WORKER_MODE=1 \
        "$_BIN_DIR/mother-run-job" some-job
    [ "$status" -ne 0 ]
    [ ! -e "$SS_HOME/.mother" ]
}

@test "worker mode: an outbox with a canonical root (HOME/.mother, a .mother-live root, or a root disagreeing with MOTHER_LIVE_ROOT) is refused and drops no marker" {
    local live="$SS_L/live-root" out="$SS_L/some-outbox" r
    mkdir -p "$live" "$SS_HOME/.mother" "$out"
    : > "$live/.mother-live"
    for r in "$live" "$SS_HOME/.mother"; do
        run --separate-stderr env -u MOTHER_LIVE_ROOT -u MOTHER_TEST_ROOT HOME="$SS_HOME" MOTHER_ROOT="$r" \
            MOTHER_WORKER_MODE=1 MOTHER_WORKER_OUTBOX_DIR="$out" bash -c 'source "$1/state.sh"; echo survived' _ "$_LIB_DIR"
        [ "$status" -ne 0 ] || { echo "root $r accepted" >&2; return 1; }
        [ ! -e "$r/.mother-worker-live" ]
        [ ! -d "$r/jobs" ] || [ "$r" = "$live" ] || true
    done
    run --separate-stderr env -u MOTHER_TEST_ROOT HOME="$SS_HOME" MOTHER_ROOT="$SS_W" MOTHER_LIVE_ROOT="$live" \
        MOTHER_WORKER_MODE=1 MOTHER_WORKER_OUTBOX_DIR="$out" bash -c 'source "$1/state.sh"' _ "$_LIB_DIR"
    [ "$status" -ne 0 ]
    [ ! -e "$SS_W/jobs" ]
    # An outbox that cannot be written is refused too.
    chmod a-w "$out"
    run --separate-stderr env -u MOTHER_LIVE_ROOT -u MOTHER_TEST_ROOT HOME="$SS_HOME" MOTHER_ROOT="$SS_W" \
        MOTHER_WORKER_MODE=1 MOTHER_WORKER_OUTBOX_DIR="$out" bash -c 'source "$1/state.sh"' _ "$_LIB_DIR"
    [ "$status" -ne 0 ]
    [[ "$stderr" == *"outbox"* ]]
    chmod u+w "$out"
}

@test "worker mode: a properly configured worker root starts, gets its own marker (not the live one), and the in-agent view (MOTHER_LIVE_ROOT only) works too" {
    local out="$SS_W/outbox"
    run --separate-stderr env -u MOTHER_ROOT -u MOTHER_TEST_ROOT -u JOBS_DIR HOME="$SS_HOME" MOTHER_LIVE_ROOT="$SS_W" \
        MOTHER_WORKER_MODE=1 MOTHER_WORKER_OUTBOX_DIR="$out" \
        bash -c 'source "$1/state.sh"; mother_outbox_enabled && echo enabled' _ "$_LIB_DIR"
    [ "$status" -eq 0 ] || { echo "$stderr" >&2; return 1; }
    [[ "$output" == *enabled* ]]
    [ -e "$SS_W/.mother-worker-live" ]
    [ ! -e "$SS_W/.mother-live" ]
}

@test "legacy path: only MOTHER_WORKER_OUTBOX_DIR set (mode off) changes nothing: no outbox, no marker, cost recompute still runs" {
    local id="leg-1"
    _ss_in_world "$SS_L" 0 make_job "$id" running
    _ss_in_world "$SS_L" 2 bash -c '
        source "$1/state.sh"; source "$1/usage.sh"
        mother_job_update "$2" ".question = \"q\""
        mother_event_append "$2" probe "{}"
        mother_recompute_job_cost "$2"' _ "$_LIB_DIR" "$id"
    [ ! -e "$SS_L/outbox" ]
    [ ! -e "$SS_L/.mother-worker-live" ]
    [ "$(jq -r '.actual_cost_usd' "$SS_L/jobs/$id.json")" = "0" ]
    [ "$(jq -r '.question' "$SS_L/jobs/$id.json")" = "q" ]
}

@test "worker mode: the cost recompute is a no-op in a validated worker root (the canonical side owns cost)" {
    local id="cost-w"
    _ss_in_world "$SS_W" 0 make_job "$id" running
    _ss_in_world "$SS_W" 1 bash -c 'source "$1/state.sh"; source "$1/usage.sh"; mother_recompute_job_cost "$2"' _ "$_LIB_DIR" "$id"
    [ "$(jq -r '.actual_cost_usd // "absent"' "$SS_W/jobs/$id.json")" = "absent" ]
}

# ---------------------------------------------------------------------------
# Bounds

@test "bounds: an op over MOTHER_OUTBOX_MAX_OP_BYTES and an outbox over MOTHER_OUTBOX_MAX_BYTES are refused loudly (degraded), never truncated" {
    local id="cap-1" big
    big=$(head -c 3000 /dev/zero | tr '\0' 'z')
    run --separate-stderr _ss_in_world "$SS_W" 1 env MOTHER_OUTBOX_MAX_OP_BYTES=1000 bash -c '
        source "$1/state.sh"; mother_event_append "$2" probe "{\"b\":\"$3\"}"; echo "rc=$?"' _ "$_LIB_DIR" "$id" "$big"
    [[ "$output" == *"rc=1"* ]]
    [ ! -s "$SS_W/outbox/$id.ndjson" ]
    rm -f "$SS_W/runner/$id.outbox-degraded"
    run --separate-stderr _ss_in_world "$SS_W" 1 env MOTHER_OUTBOX_MAX_BYTES=300 bash -c '
        source "$1/state.sh"
        mother_event_append "$2" probe "{\"n\":1}"; echo "first rc=$?"
        mother_event_append "$2" probe "{\"n\":2}"; echo "second rc=$?"
        mother_event_append "$2" probe "{\"n\":3}"; echo "third rc=$?"' _ "$_LIB_DIR" "$id"
    [[ "$output" == *"first rc=0"* ]]
    [[ "$output" == *"third rc=1"* ]]
    [ "$(wc -l < "$SS_W/outbox/$id.ndjson" | tr -d ' ')" -lt 3 ]
}

@test "bounds: a replay stops after MOTHER_APPLY_MAX_OPS (exit 4) and a later call resumes where it stopped" {
    local id="budget-1" ops="$BATS_TEST_TMPDIR/budget.ndjson" i
    _ss_seed_hand "$id"
    for i in 1 2 3 4 5; do
        _ss_op "$i" event.append "$(jq -nc --argjson n "$i" '{line: ({ts:"2026-11-08T12:00:00.000Z",kind:"n",detail:{n:$n}} | tojson)}')"
    done > "$ops"
    run --separate-stderr env MOTHER_APPLY_MAX_OPS=2 bash -c '"$0" "$1" "$2" < "$3"' "$SS_COORD_APPLY" "$SS_C" "$id" "$ops"
    [ "$status" -eq 4 ]
    [ "$(printf '%s\n' "$output" | tail -1)" = "2" ]
    [ "$(wc -l < "$SS_C/events/$id.jsonl" | tr -d ' ')" = "2" ]
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SS_C/events/$id.jsonl" | tr -d ' ')" = "5" ]
}

@test "bounds: artifacts over the per-job byte cap are refused and their .part file is removed; a stale unfinished .part is swept" {
    local id="art-cap" rel="crew/art-cap/big.bin" ops="$BATS_TEST_TMPDIR/cap.ndjson" b64
    _ss_seed_hand "$id"
    b64=$(head -c 600 /dev/zero | base64 | tr -d '\n')
    _ss_op 1 artifact.put "$(jq -nc --arg p "$rel" --arg b "$b64" '{path:$p, offset:0, b64:$b, final:false}')" > "$ops"
    mkdir -p "$SS_C/crew/$id"
    : > "$SS_C/crew/$id/stale.bin.part"; touch -t 202001010000 "$SS_C/crew/$id/stale.bin.part"
    run --separate-stderr env MOTHER_APPLY_MAX_ARTIFACT_BYTES=400 bash -c '"$0" "$1" "$2" < "$3"' "$SS_COORD_APPLY" "$SS_C" "$id" "$ops"
    [ "$status" -eq 3 ]
    [ ! -e "$SS_C/$rel.part" ]
    [ ! -e "$SS_C/crew/$id/stale.bin.part" ]
}

# ---------------------------------------------------------------------------
# Locking and artifact finality

@test "artifacts: a final chunk with no sha256 is refused (quarantined), never stored unverified" {
    local id="art-nosha" rel="crew/art-nosha/x.txt" ops="$BATS_TEST_TMPDIR/nosha.ndjson"
    _ss_seed_hand "$id"
    _ss_op 1 artifact.put "$(jq -nc --arg p "$rel" --arg b "$(printf 'hello' | base64)" '{path:$p, offset:0, b64:$b, final:true}')" > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 3 ]
    [ ! -e "$SS_C/$rel" ]
    [ ! -e "$SS_C/$rel.part" ]
}

@test "locking: two replays of the same outbox at once apply every op exactly once" {
    local id="lock-1" ops="$BATS_TEST_TMPDIR/lock.ndjson" i p1 p2
    _ss_seed_hand "$id"
    for i in $(seq 1 25); do
        _ss_op "$i" event.append "$(jq -nc --argjson n "$i" '{line: ({ts:"2026-11-08T12:00:00.000Z",kind:"n",detail:{n:$n}} | tojson)}')"
    done > "$ops"
    ( _ss_in_world "$SS_C" 0 bash -c '"$0" "$1" "$2" < "$3"' "$SS_COORD_APPLY" "$SS_C" "$id" "$ops" >/dev/null 2>&1 ) & p1=$!
    ( _ss_in_world "$SS_C" 0 bash -c '"$0" "$1" "$2" < "$3"' "$SS_COORD_APPLY" "$SS_C" "$id" "$ops" >/dev/null 2>&1 ) & p2=$!
    wait "$p1" || true; wait "$p2" || true
    [ "$(wc -l < "$SS_C/events/$id.jsonl" | tr -d ' ')" = "25" ]
    [ "$(jq -s 'map(.detail.n) | unique | length' "$SS_C/events/$id.jsonl")" = "25" ]
}

# ---------------------------------------------------------------------------
# Nits and legacy equivalence

@test "nits: job ids . and .. are rejected by the CLI, and _ca_words_json never glob-expands its argument" {
    local id
    for id in . .. ../x; do
        run --separate-stderr bash -c '"$0" "$1" "$2" < /dev/null' "$SS_COORD_APPLY" "$SS_C" "$id"
        [ "$status" -eq 2 ] || { echo "job id '$id' accepted ($status)" >&2; return 1; }
    done
    mkdir -p "$BATS_TEST_TMPDIR/globdir" && : > "$BATS_TEST_TMPDIR/globdir/aa" && : > "$BATS_TEST_TMPDIR/globdir/bb"
    run bash -c 'cd "$2"; source "$1"; _ca_words_json "* ? b"' _ "$SS_COORD_APPLY" "$BATS_TEST_TMPDIR/globdir"
    [ "$(printf '%s' "$output" | jq -c .)" = '["*","?","b"]' ]
}

@test "concurrent writers: two worker-mode writers on one job never revert each other, and the outbox replays to the mirror's final document" {
    local id="conc-1" i
    _ss_in_world "$SS_W" 0 make_job "$id" running
    cp "$SS_W/jobs/$id.json" "$BATS_TEST_TMPDIR/seed.json"
    ( _ss_in_world "$SS_W" 1 bash -c 'source "$1/state.sh"; for i in $(seq 1 15); do mother_job_update "$2" ".activity = \"a$i\""; done' _ "$_LIB_DIR" "$id" ) & local p1=$!
    ( _ss_in_world "$SS_W" 1 bash -c 'source "$1/state.sh"; for i in $(seq 1 15); do mother_job_update "$2" ".question = \"q$i\""; done' _ "$_LIB_DIR" "$id" ) & local p2=$!
    wait "$p1"; wait "$p2"
    jq -e '.activity == "a15" and .question == "q15"' "$SS_W/jobs/$id.json" >/dev/null
    _ss_seed_canonical "$SS_C" "$id" "$BATS_TEST_TMPDIR/seed.json"
    _ss_replay_to "$SS_C" "$id" "$SS_W/outbox/$id.ndjson"
    [ "$status" -eq 0 ]
    jq -e '.activity == "a15" and .question == "q15"' "$SS_C/jobs/$id.json" >/dev/null
}

@test "legacy: _validate_and_clear_pr_url writes the same bytes as before (jq .pr_url = null, atomically) with no leftovers and no outbox" {
    local id="val-1" branch="feature/x" jf expected
    mkdir -p "$SS_L/mock-bin"
    printf '#!/bin/bash\necho "feature/other"\n' > "$SS_L/mock-bin/gh"; chmod +x "$SS_L/mock-bin/gh"
    _ss_in_world "$SS_L" 0 make_job "$id" running '.pr_url = "https://github.com/o/r/pull/9" | .branch = "'"$branch"'"'
    jf="$SS_L/jobs/$id.json"
    expected=$(jq '.pr_url = null' "$jf")
    _ss_in_world "$SS_L" 0 env PATH="$SS_L/mock-bin:$PATH" bash -c '
        SOURCE_ONLY=1 source "$1" 2>/dev/null
        _validate_and_clear_pr_url "$2" "$3"' _ "$_BIN_DIR/mother-run-job" "$id" "$branch"
    [ "$(cat "$jf")" = "$expected" ]
    ! ls "$SS_L/jobs" | grep -q '\.tmp\.'
    [ ! -e "$SS_L/outbox" ]
}

@test "mother-run-job's unquoted WRAP heredoc has no unescaped backtick (it would run as a command, e.g. docker)" {
    # A backtick inside the unquoted heredoc is a command substitution run on every worker start; one in a
    # comment once invoked `docker compose up` (CI: "docker: command not found" in a worker-mode run).
    run awk '/<<WRAP$/ {f = 1; next} /^WRAP$/ {f = 0} f && /(^|[^\\])`/ {print NR ": " $0}' "$_BIN_DIR/mother-run-job"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

# ===========================================================================
# The checkpoint manifest is the worker's word (P1-6 review fix-ups)
#
# It later picks the branch and ref a restore touches, so coord_apply only records a manifest that agrees
# with the job document (branch) and the one wip ref this job owns.

_ss_manifest_op() { # <job> <branch> <wip-ref> — a checkpoint.taken op line (no transcript delta shipped)
    local sha="0123456789abcdef0123456789abcdef01234567"
    _ss_op 1 checkpoint.taken "$(jq -nc --arg j "$1" --arg b "$2" --arg r "$3" --arg sha "$sha" --arg t "$(printf 'x%.0s' {1..64})" '
        {manifest: {v: 1, job: $j, lease: "L-1", epoch: 1, n: 1, at: "2026-11-08T12:00:00.000Z", head_sha: $sha,
                    branch: $b, base_sha: $sha, wip_sha: $sha, wip_ref: $r, pushed: true, session_id: "s1",
                    transcript: {path_rel: ("checkpoints/" + $j + "/1/transcript.delta"), bytes: 0, sha256: $t},
                    untracked_skipped: []}}')"
}

@test "checkpoint trust: a manifest that agrees with the job (branch feature/test, its own wip ref) is recorded" {
    local id="ck-ok" ops="$BATS_TEST_TMPDIR/ck.ndjson"
    _ss_seed_hand "$id"; _ss_history "$id" 1
    _ss_manifest_op "$id" feature/test "refs/mother/wip/$id" > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(wc -l < "$SS_C/checkpoints/$id/index.jsonl" | tr -d ' ')" = 1 ]
}

@test "checkpoint trust: a manifest naming another branch than the job's is refused and audited, nothing recorded" {
    local id="ck-branch" ops="$BATS_TEST_TMPDIR/ck.ndjson"
    _ss_seed_hand "$id"
    _ss_manifest_op "$id" feature/someone-elses "refs/mother/wip/$id" > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ ! -e "$SS_C/checkpoints/$id/index.jsonl" ]
    [ ! -e "$SS_C/checkpoints/$id/latest.json" ]
    [ "$(jq -r 'select(.code == "manifest_refused") | .keys[0]' "$SS_C/runner/leases/audit.jsonl")" = "branch" ]
}

@test "checkpoint trust: a manifest naming another job's wip ref is refused and audited, nothing recorded" {
    local id="ck-ref" ops="$BATS_TEST_TMPDIR/ck.ndjson"
    _ss_seed_hand "$id"
    _ss_manifest_op "$id" feature/test "refs/mother/wip/another-job" > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ ! -e "$SS_C/checkpoints/$id/index.jsonl" ]
    [ ! -e "$SS_C/checkpoints/$id/latest.json" ]
    [ "$(jq -r 'select(.code == "manifest_refused") | .keys[0]' "$SS_C/runner/leases/audit.jsonl")" = "wip_ref" ]
}

# `mother checkpoint restore` (what mother-run-job calls) must itself refuse a manifest that names another
# job or another branch than the one it is restoring for.
@test "checkpoint trust: restore refuses a manifest whose branch is not the job's (branch_mismatch), before touching git" {
    local id="ck-rbranch" m="$BATS_TEST_TMPDIR/m.json"
    _ss_seed_hand "$id"
    _ss_manifest_op "$id" feature/someone-elses "refs/mother/wip/$id" | jq -c '.data.manifest' > "$m"
    : > "$BATS_TEST_TMPDIR/t.jsonl"
    run --separate-stderr _ss_in_world "$SS_C" 0 mother checkpoint restore "$id" --manifest "$m" \
        --transcript "$BATS_TEST_TMPDIR/t.jsonl" --work-dir "$BATS_TEST_TMPDIR/wd"
    [ "$status" -eq 4 ]
    [ "$(printf '%s\n' "$output" | tail -n 1 | jq -r .why)" = "branch_mismatch" ]
    [ ! -e "$BATS_TEST_TMPDIR/wd" ]
}

@test "checkpoint trust: restore refuses a manifest for another job (job_mismatch)" {
    local id="ck-rjob" m="$BATS_TEST_TMPDIR/m.json"
    _ss_seed_hand "$id"
    _ss_manifest_op other-job feature/test "refs/mother/wip/other-job" | jq -c '.data.manifest' > "$m"
    : > "$BATS_TEST_TMPDIR/t.jsonl"
    run --separate-stderr _ss_in_world "$SS_C" 0 mother checkpoint restore "$id" --manifest "$m" \
        --transcript "$BATS_TEST_TMPDIR/t.jsonl" --work-dir "$BATS_TEST_TMPDIR/wd"
    [ "$status" -eq 4 ]
    [ "$(printf '%s\n' "$output" | tail -n 1 | jq -r .why)" = "job_mismatch" ]
}

# ===========================================================================
# Restore points are ordered by (epoch, n), and the epoch is the coordinator's (P1-6 round 2)
#
# A failover to another machine starts a new epoch whose worker may number from 1: ordering by n alone froze latest.json at the
# first lease's last checkpoint. The epoch must also be one the coordinator granted for the job (runner/leases/<job>.history.jsonl).

_ss_en_op() { # <seq> <job> <epoch> <n> — a well-formed pushed manifest op whose delta ("hello") is put in place
    local hello_sha="2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824" sha
    sha=$(printf '%040x' $(( $3 * 1000 + $4 )))
    mkdir -p "$SS_C/checkpoints/$2/$4"; printf 'hello' > "$SS_C/checkpoints/$2/$4/transcript.delta"
    _ss_op "$1" checkpoint.taken "$(jq -nc --arg j "$2" --argjson e "$3" --argjson n "$4" --arg sha "$sha" --arg t "$hello_sha" '
        {manifest: {v: 1, job: $j, lease: ("L-" + ($e|tostring)), epoch: $e, n: $n, at: "2026-11-08T12:00:00.000Z", head_sha: $sha,
                    branch: "feature/test", base_sha: $sha, wip_sha: $sha, wip_ref: ("refs/mother/wip/" + $j), pushed: true, session_id: "s1",
                    transcript: {path_rel: ("checkpoints/" + $j + "/" + ($n|tostring) + "/transcript.delta"), bytes: 5, sha256: $t, reset: true},
                    untracked_skipped: []}}')"
}

_ss_history() { # <job> <epoch>... — the coordinator's lease history
    local job="$1" e; shift
    mkdir -p "$SS_C/runner/leases"
    for e in "$@"; do jq -nc --arg j "$job" --argjson e "$e" '{job: $j, epoch: $e, id: ("L-" + ($e|tostring)), worker: "w"}' >> "$SS_C/runner/leases/$job.history.jsonl"; done
}

@test "checkpoint order: epoch 1 n=1..3 then epoch 2 n=1 leaves latest.json at epoch 2 (a new lease numbering from 1 is newer)" {
    local id="ck-ord" ops="$BATS_TEST_TMPDIR/ck.ndjson"
    _ss_seed_hand "$id"; _ss_history "$id" 1 2
    { _ss_en_op 1 "$id" 1 1; _ss_en_op 2 "$id" 1 2; _ss_en_op 3 "$id" 1 3; _ss_en_op 4 "$id" 2 1; } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    [ "$status" -eq 0 ]
    [ "$(jq -r '[.epoch, .n] | @tsv' "$SS_C/checkpoints/$id/latest.json")" = "$(printf '2\t1')" ]
    # the index keeps all four (epoch is part of the de-dupe key: epoch 1 n=1 and epoch 2 n=1 are different checkpoints)
    [ "$(wc -l < "$SS_C/checkpoints/$id/index.jsonl" | tr -d ' ')" = 4 ]
}

@test "checkpoint order: a late older-epoch manifest with a huge n, or an epoch the coordinator never granted, cannot replace or freeze latest.json" {
    local id="ck-freeze" ops="$BATS_TEST_TMPDIR/ck.ndjson"
    _ss_seed_hand "$id"; _ss_history "$id" 1 2
    { _ss_en_op 1 "$id" 2 1; _ss_en_op 2 "$id" 1 999; _ss_en_op 3 "$id" 7 999; _ss_en_op 4 "$id" 2 2; } > "$ops"
    _ss_replay_to "$SS_C" "$id" "$ops"
    # epoch 1 n=999 ranks below epoch 2; epoch 7 was never granted (refused, audited); epoch 2 n=2 still advances
    [ "$(jq -r '[.epoch, .n] | @tsv' "$SS_C/checkpoints/$id/latest.json")" = "$(printf '2\t2')" ]
    [ "$(jq -r 'select(.code == "manifest_refused") | .keys[0]' "$SS_C/runner/leases/audit.jsonl" | head -n 1)" = "epoch" ]
    ! jq -e 'select(.epoch == 7)' "$SS_C/checkpoints/$id/index.jsonl" >/dev/null 2>&1
}
