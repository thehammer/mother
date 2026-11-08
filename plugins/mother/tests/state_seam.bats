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

# _ss_norm_job <file> — the job document, normalised.
_ss_norm_job() { jq -S --argjson subs "$(_ss_subs)" "$(_ss_norm_filter)" "$1"; }

# _ss_norm_events <file> — the event stream as a normalised JSON array. `final_result_observed` is a
# poll-loop race, not part of the contract (the contract recorder drops it too).
_ss_norm_events() {
    jq -S -s --argjson subs "$(_ss_subs)" \
        "map(select(.kind != \"final_result_observed\")) | $(_ss_norm_filter)" "$1"
}

# _ss_norm_rows <job> <metrics-file> — this job's usage rows as a normalised JSON array.
_ss_norm_rows() {
    local id="$1" f="$2"
    { grep -F "\"job_id\":\"$id\"" "$f" 2>/dev/null || true; } \
        | jq -S -s --argjson subs "$(_ss_subs)" "$(_ss_norm_filter)"
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

@test "artifacts: a path that escapes crew/<job>/ or checkpoints/<job>/ is rejected, the replay stops there and nothing is written" {
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
        if [ "$status" -eq 0 ]; then echo "path '$bad' was accepted" >&2; return 1; fi
        # The first op applied; the op after the rejected one did not.
        [ "$(_ss_last_line)" = "1" ] || { echo "path '$bad': printed '$output'" >&2; return 1; }
        grep -q '"kind":"before"' "$SS_C/events/$id.jsonl"
        if grep -q '"kind":"after"' "$SS_C/events/$id.jsonl"; then echo "path '$bad': a later op was applied" >&2; return 1; fi
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
