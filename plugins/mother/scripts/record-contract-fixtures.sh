#!/usr/bin/env bash
# record-contract-fixtures.sh — record the headless-crew client-contract fixtures from REAL runs.
#
# Usage:
#   record-contract-fixtures.sh [--out DIR] [--report FILE]
#
#   --out DIR      where the three fixtures are written
#                  (default: plugins/mother/tests/fixtures/contract)
#   --report FILE  JSON describing what the scenarios seeded, so a test can prove its sentinel
#                  check is real: {"sentinel": "...", "side_files": {"<scenario>": [paths with it]}}
#
# Each scenario gets a temp MOTHER_ROOT, a temp git repo (its basename is in MOTHER_PHI_REPOS) with an
# enforce-mode .mother/crew.yml, a fake gh and a scripted `claude`, and the REAL broker binary. A python
# client subscribes to every category (progress included) and records every message it sends and
# receives. The jobs go through the real `mother add`, `mother-run-job` and (via the broker `answer`
# command) `mother resume --option`; `mother-usage progress-tick` is run at fixed points like the daemon
# would. The raw recordings are then normalised (ids, timestamps, shas, paths, volatile numbers become
# stable placeholders) and written as:
#
#   gates_fix_pass.ndjson     gates fail, a fix run, gates pass, PR ready
#   lens_wave.ndjson          reviewer wave: a skipped lens, findings, a refuted claim, a review hold
#   gate_hold_answered.ndjson gates exhausted, a hold answered by option over the broker
#
# `final_result_observed` (a poll-loop event whose position among the gate events is a timing race and
# which is not part of the contract) is dropped; reviewers are released one at a time so their events
# arrive in a fixed order; the parallel spawn events are put in reviewer-name order.
#
# Sentinel text (SENTINEL-PHI-42) is seeded into gate output, finding text, claim quotes, adherence
# notes and acceptance-criteria text of a PHI repo; none of it may appear in a recording.
#
# Re-run after any contract change. Needs go, python3 (PyYAML), jq, git.

set -u

PLUGIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT="$PLUGIN/tests/fixtures/contract"
REPORT=""
SENTINEL="SENTINEL-PHI-42"
# A gate command that prints the sentinel. Assembled at run time so the literal never appears in the
# check's `run` text (which legitimately travels in the job's crew snapshot): only real gate OUTPUT has it.
EMIT="printf '%sINEL-%s-%s\\n' SENT PHI 42"

while [ $# -gt 0 ]; do
    case "$1" in
        --out) OUT="$2"; shift 2 ;;
        --report) REPORT="$2"; shift 2 ;;
        -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) echo "record-contract-fixtures: unknown argument: $1" >&2; exit 2 ;;
    esac
done

for tool in go python3 jq git; do
    command -v "$tool" >/dev/null 2>&1 || { echo "record-contract-fixtures: $tool is required" >&2; exit 2; }
done

# Never inherit a real state tree (CLAUDE.md "State safety"); test_helper builds a temp one per scenario.
unset MOTHER_ROOT MOTHER_LIVE_ROOT MOTHER_JOB_ID
export GIT_AUTHOR_DATE="2026-10-01T00:00:00Z" GIT_COMMITTER_DATE="2026-10-01T00:00:00Z"

# shellcheck source=/dev/null
source "$PLUGIN/tests/test_helper.bash"
# shellcheck source=/dev/null
source "$PLUGIN/tests/gh_mock.bash"

mkdir -p "$OUT" || exit 1
OUT="$(cd "$OUT" && pwd -P)"
SCRATCH="$(mktemp -d)"
trap '_stop_all; if [ -z "${RECORD_KEEP:-}" ]; then safe_rm_tree "$SCRATCH" 2>/dev/null || true; else echo "kept: $SCRATCH" >&2; fi' EXIT

BROKER_BIN="$PLUGIN/broker/bin/mother-broker"
"$PLUGIN/scripts/build-broker.sh" >/dev/null 2>&1 || true
[ -x "$BROKER_BIN" ] || { echo "record-contract-fixtures: broker build failed" >&2; exit 1; }

PR_URL="https://github.com/Carefeed/admin-portal/pull/42"
CAPS='["state","activity","await","current_activity","quota","progress"]'

BG_PIDS=""
_stop_all() {
    local p
    for p in $BG_PIDS; do kill "$p" 2>/dev/null || true; done
    BG_PIDS=""
}

# ---------------------------------------------------------------------------
# The python recorder client. One connection; records every message it sends and receives (pings
# excluded) as the envelope, in arrival order. Commands are fed in as files in CTL.
CLIENT_PY="$SCRATCH/record_client.py"
cat > "$CLIENT_PY" <<'PY'
import json, os, socket, sys, threading, time

sock_path, rec_path, ctl = sys.argv[1], sys.argv[2], sys.argv[3]
lock = threading.Lock()
out = open(rec_path, "a", buffering=1)

def now_ms():
    t = time.time()
    return time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(t)) + ".%03dZ" % (int(t * 1000) % 1000)

def log(msg):
    with lock:
        out.write(json.dumps(msg, separators=(",", ":")) + "\n")

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.connect(sock_path)

def reader():
    buf = b""
    while True:
        try:
            chunk = s.recv(65536)
        except OSError:
            return
        if not chunk:
            return
        buf += chunk
        while b"\n" in buf:
            line, buf = buf.split(b"\n", 1)
            if not line.strip():
                continue
            m = json.loads(line)
            if m.get("t") == "ping":
                continue
            log(m)

threading.Thread(target=reader, daemon=True).start()
open(os.path.join(ctl, "ready"), "w").close()

while not os.path.exists(os.path.join(ctl, "STOP")):
    for name in sorted(n for n in os.listdir(ctl) if n.endswith(".cmd")):
        p = os.path.join(ctl, name)
        spec = json.load(open(p))
        msg = {"v": 1, "dir": "cmd", "t": spec["t"], "id": spec["id"], "ts": now_ms(), "data": spec["data"]}
        with lock:
            out.write(json.dumps(msg, separators=(",", ":")) + "\n")
            s.sendall((json.dumps(msg) + "\n").encode())
        os.rename(p, p + ".sent")
    time.sleep(0.05)
s.close()
PY

# ---------------------------------------------------------------------------
# The claude stand-in: workers and reviewers, told apart by argv (same shape as the bats harnesses).
#   worker n: $ROOT/behave.<n> is sourced (cwd = the job's work dir); blocks while $ROOT/hold.w<n> exists.
#   reviewer: canned reply from $ROOT/rv/<agent>[.<lens>].jsonl; blocks while $ROOT/hold.rv.<agent>[.<lens>] exists.
install_claude() {
    {
        printf '#!/usr/bin/env bash\nMOCK_CLAUDE_BIN=%q\n' "$PLUGIN/tests/mock_claude"
        cat <<'CLAUDE'
ROOT="${MOTHER_LIVE_ROOT:-${MOTHER_ROOT:-}}"
agent=""; prev=""
for a in "$@"; do
    if [ "$prev" = "--agent" ]; then agent="$a"; break; fi
    prev="$a"
done
case "$agent" in
archie|perri-lens)
    rkey="$agent"; [ "$agent" = "perri-lens" ] && rkey="perri-lens.${MOTHER_REVIEW_LENS:-}"
    while [ -f "$ROOT/hold.rv.$rkey" ]; do sleep 0.1; done
    MOCK_CLAUDE_STDOUT_BY_AGENT_DIR="$ROOT/rv" MOCK_CLAUDE_ARGS_FILE="$ROOT/rv-args" \
        MOCK_CLAUDE_STDIN_FILE="$ROOT/rv-stdin" exec "$MOCK_CLAUDE_BIN" "$@"
    ;;
esac
n=$(( $(cat "$ROOT/ge-count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$ROOT/ge-count"
cat > "$ROOT/stdin.$n"
BR=$(git rev-parse --abbrev-ref HEAD 2>/dev/null)
if [ -f "$ROOT/behave.$n" ]; then . "$ROOT/behave.$n"; fi
while [ -f "$ROOT/hold.w$n" ]; do sleep 0.1; done
git push -q origin "HEAD:refs/heads/$BR" >/dev/null 2>&1 || true
if [ "$n" = "1" ]; then
    echo "opened https://github.com/Carefeed/admin-portal/pull/42"
fi
cat <<'EOF'
{"type":"assistant","message":{"id":"msg_rec","model":"claude-sonnet-5","parent_tool_use_id":null,"usage":{"input_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":5}}}
{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.01,"modelUsage":{}}
EOF
exit 0
CLAUDE
    } > "$_MOCK_BIN/claude"
    chmod +x "$_MOCK_BIN/claude"
}

# A fake `rwx` so no gate or lifecycle step ever reaches a real sandbox.
install_rwx() {
    printf '#!/usr/bin/env bash\nexit 0\n' > "$_MOCK_BIN/rwx"
    chmod +x "$_MOCK_BIN/rwx"
}

# ---------------------------------------------------------------------------
# Reviewer replies (stream-json, the way real claude prints them).
_emit() {
    jq -nc '{type: "assistant", message: {id: "msg_rv", model: "claude-sonnet-5", parent_tool_use_id: null,
             usage: {input_tokens: 1000, cache_creation_input_tokens: 0, cache_read_input_tokens: 0, output_tokens: 150}}}'
    jq -nc --arg r "$1" '{type: "result", subtype: "success", is_error: false, total_cost_usd: 0.02, result: $r}'
}
_lens_reply() { # <lens> <findings-json>
    _emit "$(printf 'Reviewed the patch.\n\n```findings\n%s\n```\n\n```examined\n%s\n```' "$2" '["app/Foo.php","resources/js/App.vue"]')" \
        > "$MOTHER_ROOT/rv/perri-lens.$1.jsonl"
}
_adherence_reply() { _emit "$(printf 'ADHERENCE: pass\nNOTES:\nAdherence notes %s' "$SENTINEL")" > "$MOTHER_ROOT/rv/archie.jsonl"; }

# ---------------------------------------------------------------------------
# Scenario plumbing

SCN=""; JOB=""; REPO=""; ORIGIN=""; REC=""; CTL=""; CMD_N=0; TICK_N=0

# new_scenario <name> <crew.yml body> — temp root, repo with crew.yml on main, broker, client.
new_scenario() {
    SCN="$1"
    setup_mother_env
    export MOTHER_POSTURE_ENABLED=0 MOTHER_GATES_ENABLED=1 MOTHER_LENSES_ENABLED=1
    export MOTHER_IDLE_REAP_SECONDS=120 MOTHER_RESULT_GRACE_SECONDS=120
    export MOTHER_PHI_REPOS="admin-portal referral-monitor"
    export MOTHER_NOTIFY_ENABLED=0 MOTHER_BACKUP_ENABLED=0
    export MOTHER_BROKER_SOCK="$MOTHER_ROOT/broker.sock" MOTHER_BROKER_ANSWER_GUARD=0
    export MOTHER_CLI="$_BIN_DIR/mother"
    gh_mock_install
    install_claude
    install_rwx
    mkdir -p "$MOTHER_ROOT/rv" "$MOTHER_ROOT/plans"

    ORIGIN="$MOTHER_ROOT/origin.git"
    REPO="$MOTHER_ROOT/work/admin-portal"
    mkdir -p "$REPO"
    git init -q --bare "$ORIGIN"
    (
        cd "$REPO" || exit 1
        git init -q
        git symbolic-ref HEAD refs/heads/main
        git config user.email "test@example.com"
        git config user.name "Test"
        echo "# repo" > README.md
        mkdir -p .mother
        printf '%s\n' "$2" > .mother/crew.yml
        git add .
        git commit -q -m "init"
        git remote add origin "$ORIGIN"
        git push -q -u origin main
    ) >/dev/null 2>&1

    REC="$SCRATCH/$SCN.raw.ndjson"; : > "$REC"
    CTL="$SCRATCH/$SCN.ctl"; mkdir -p "$CTL"
    CMD_N=0; TICK_N=0
    "$BROKER_BIN" >"$SCRATCH/$SCN.broker.log" 2>&1 &
    BG_PIDS="$BG_PIDS $!"
    wait_for 100 '[ -S "$MOTHER_BROKER_SOCK" ]' || die "broker socket did not appear"
    python3 -I "$CLIENT_PY" "$MOTHER_BROKER_SOCK" "$REC" "$CTL" >"$SCRATCH/$SCN.client.log" 2>&1 &
    BG_PIDS="$BG_PIDS $!"
    wait_for 100 '[ -f "$CTL/ready" ]' || die "client did not connect"
}

die() { echo "record-contract-fixtures: $SCN: $*" >&2; exit 1; }

# wait_for <tries> <shell-test> — poll every 0.1s.
wait_for() {
    local _
    for _ in $(seq 1 "$1"); do
        eval "$2" && return 0
        sleep 0.1
    done
    return 1
}

# send <type> <data-json> — queue a command; waits until its ack is recorded.
send() {
    CMD_N=$((CMD_N + 1))
    local id="c$CMD_N"
    local f; f="$CTL/$(printf '%03d' "$CMD_N")"
    jq -nc --arg t "$1" --arg id "$id" --argjson d "$2" '{t: $t, id: $id, data: $d}' > "$f.tmp" && mv "$f.tmp" "$f.cmd"
    wait_rec "any(.[]; .dir == \"ack\" and .id == \"$id\")" 150 || die "no ack for $1"
}

# subscribe — (re)subscribe to every category; the broker answers with a fresh snapshot.
subscribe() {
    local before
    before=$(jq -s '[.[] | select(.t == "snapshot")] | length' "$REC")
    send subscribe "{\"sub\":\"nostromo\",\"jobs\":[\"all\"],\"categories\":$CAPS}"
    wait_rec "([.[] | select(.t == \"snapshot\")] | length) > $before" 100 || die "no snapshot after subscribe"
}

# wait_rec <jq-bool-over-slurped-recording> [tries]
wait_rec() {
    local _
    for _ in $(seq 1 "${2:-300}"); do
        jq -se "$1" "$REC" >/dev/null 2>&1 && return 0
        sleep 0.1
    done
    return 1
}

# wait_event <kind> [min-count] — until the client has received that event kind.
wait_event() { wait_rec "[.[] | select(.dir == \"event\" and .t == \"$1\")] | length >= ${2:-1}" 300 || die "never received event $1"; }

# settle — wait until the recording has been quiet for 1.5s (nothing else is about to arrive).
settle() {
    local n m
    n=$(wc -l < "$REC")
    while sleep 1.5; do
        m=$(wc -l < "$REC")
        [ "$m" = "$n" ] && return 0
        n=$m
    done
}

# hold_reviewers / release_reviewers_in_order — park every reviewer, then let them finish one at a time
# (adherence last) so the results arrive in a fixed order: release_reviewers_in_order <key>... .
hold_reviewers() { local k; for k in archie perri-lens.correctness perri-lens.phi-security perri-lens.tests; do hold "rv.$k"; done; }
release_reviewers_in_order() {
    local n=0 k
    for k in "$@"; do
        n=$((n + 1))
        release "rv.$k"
        wait_event reviewed "$n"
    done
}

# job_field <jq-expr> — over the job file.
job_field() { jq -r "$1" "$JOBS_DIR/$JOB.json"; }
wait_job() { wait_for "${2:-300}" "[ \"\$(job_field '$1')\" = true ]" || die "job never reached: $1"; }

# tick — one progress-tick as the daemon would run it. --now steps 2 minutes per tick so the 60s
# per-job emission gap never swallows a visible change, and updated_at strictly increases.
tick() {
    TICK_N=$((TICK_N + 1))
    local now
    now=$(python3 -c 'import sys,time; t=time.time()+120*int(sys.argv[1]); print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t)))' "$TICK_N")
    mother-usage progress-tick --root "$MOTHER_ROOT" --now "$now" >/dev/null 2>&1 || die "progress-tick failed"
}

# add_job <plan-extra-criteria> — a real `mother add`; sets JOB.
add_job() {
    local plan="$MOTHER_ROOT/plans/job.md"
    make_plan "$plan"
    # Acceptance criteria carrying the sentinel (checklist text must never go on the wire).
    python3 - "$plan" "$SENTINEL" <<'PY'
import sys
p, s = sys.argv[1], sys.argv[2]
t = open(p).read().replace("- It works.", "- [ ] **REC-1** The export endpoint works %s\n- [ ] **REC-2** Totals are backfilled" % s)
open(p, "w").write(t)
PY
    JOB=$(mother add --plan-file "$plan" --repo admin-portal --repo-path "$REPO" --base origin/main \
        --branch "feature/rec-$SCN" --isolation main-dir --title "$1" --format json 2>"$SCRATCH/add.err" | jq -r '.id // empty')
    [ -n "$JOB" ] || { cat "$SCRATCH/add.err" >&2; die "mother add failed"; }
    # What the daemon's tick does: queued -> ready (no dependencies).
    bash -c 'source "$MOTHER_LIB_DIR/state.sh"; _promote_ready' >/dev/null 2>&1
    [ "$(job_field .state)" = ready ] || die "job $JOB did not become ready"
    gh_mock_set_pr "$PR_URL" OPEN "feature/rec-$SCN"
}

# run_job_bg — the real supervisor, in the background.
run_job_bg() {
    mother-run-job "$JOB" >"$SCRATCH/$SCN.run-job.out" 2>&1 3>&- &
    RUN_PID=$!
    BG_PIDS="$BG_PIDS $RUN_PID"
}
wait_run() { wait "$RUN_PID" 2>/dev/null; true; }

# worker_behave <n> <snippet> / hold_worker <n> / release_worker <n>
worker_behave() { printf '%s\n' "$2" > "$MOTHER_ROOT/behave.$1"; }
hold() { : > "$MOTHER_ROOT/hold.$1"; }
release() { rm -f "$MOTHER_ROOT/hold.$1"; }

# finish — let the broker deliver the tail, then write the raw recording and what normalisation needs.
finish() {
    sleep 1.5
    touch "$CTL/STOP"
    sleep 0.3
    cp "$REC" "$SCRATCH/$SCN.final.ndjson"
    cp "$EVENTS_DIR/$JOB.jsonl" "$SCRATCH/$SCN.events.jsonl" 2>/dev/null || true   # debugging aid
    {
        printf 'JOB=%s\nROOT=%s\nREPO=%s\nORIGIN=%s\nSCRATCH=%s\n' "$JOB" "$MOTHER_ROOT" "$REPO" "$ORIGIN" "$SCRATCH"
    } > "$SCRATCH/$SCN.meta"
    # side files that hold the sentinel text (proves the seeding is real)
    grep -rlF "$SENTINEL" "$MOTHER_ROOT/crew/$JOB" "$MOTHER_ROOT/checklists" 2>/dev/null \
        | sed "s|^$MOTHER_ROOT/||; s|/$JOB/|/<job>/|; s|$JOB|<job>|" | sort > "$SCRATCH/$SCN.sidefiles" || true
    _stop_all
    teardown_mother_env
}

# ---------------------------------------------------------------------------
# Scenario 1 — gates_fix_pass: red gate, a fix run in the same session, green gates, PR ready.

scenario_gates_fix_pass() {
    new_scenario gates_fix_pass 'version: 1
gates:
  mode: enforce
  max_attempts: 3
  budget_minutes: 15
  checks:
    - name: lint
      run: |
        '"$EMIT"'; true
    - name: unit
      run: |
        [ -f .gate-fixed ] || { '"$EMIT"'; exit 1; }
      hint: "Fix the failing unit test."
    - name: static
      run: |
        '"$EMIT"'; true'
    subscribe
    add_job "Add facility export endpoint"
    worker_behave 1 'mkdir -p app; echo "<?php" > app/Foo.php; git add app/Foo.php; git commit -q -m "feature work"'
    worker_behave 2 'touch .gate-fixed; git add .gate-fixed; git commit -q -m "fix the gates"'
    # A PHI repo always gets the phi-security lens (mandatory); every reviewer is clean here.
    _adherence_reply
    local l
    for l in correctness phi-security tests ops-infra; do _lens_reply "$l" '[]'; done
    hold w1; hold w2; hold_reviewers
    run_job_bg
    wait_job '.state == "running" and ((.worker_pid // 0) > 0)'
    wait_event worker_spawned
    settle
    tick                                   # build stage
    release w1
    wait_job '.activity == "gate_fix"'
    wait_event gate_fix_started
    wait_event worker_spawned 2
    settle
    tick                                   # gate_fix: progress moved back
    settle
    subscribe                              # reconnect mid-scenario: the snapshot carries the live crew data
    release w2
    wait_event review_spawned 1             # a PHI repo's only lens is phi-security (observe mode)
    settle
    release_reviewers_in_order perri-lens.phi-security archie
    wait_run
    wait_event succeeded
    settle
    tick                                   # terminal
    finish
}

# ---------------------------------------------------------------------------
# Scenario 2 — lens_wave: a reviewer wave with a skipped lens, findings, a refuted claim; a human
# blocking finding holds the job (review_hold).

scenario_lens_wave() {
    new_scenario lens_wave 'version: 1
gates:
  mode: enforce
  max_attempts: 3
  checks:
    - name: lint
      run: |
        '"$EMIT"'; true
lenses:
  mode: enforce
  default: [correctness, phi-security, tests, ops-infra]
  mandatory: [correctness]
  scopes:
    ops-infra: ["infra/**", ".github/**"]
  budget_usd: 3
  cycle_cap: 2'
    subscribe
    add_job "Rework consent form validation"
    worker_behave 1 'mkdir -p app resources/js
{ printf "<?php\nfunction provision(\$isApache) {\n    if (\$isApache) { // %s\n        return 1;\n    }\n}\n" "'"$SENTINEL"'"; } > app/Foo.php
echo "<template><div>hello</div></template>" > resources/js/App.vue
git add app resources; git commit -q -m "feature work"'
    _adherence_reply
    local human advisory refuted
    human=$(jq -nc --arg s "Summary $SENTINEL" --arg d "Detail $SENTINEL" --arg q "if (\$isApache) { // $SENTINEL" '
        {id: "f1", target: "human", severity: "blocking", location: "app/Foo.php:3", summary: $s, detail: $d,
         claims: [{path: "app/Foo.php", line: 3, quote: $q}], asserts_existing_code: true}')
    advisory=$(jq -nc --arg s "Advisory $SENTINEL" '
        {id: "f2", target: "cody", severity: "advisory", location: "app/Foo.php:2", summary: $s, detail: "More detail"}')
    refuted=$(jq -nc --arg s "Refuted $SENTINEL" --arg q "QUOTE_ABSENT_zz9 $SENTINEL" '
        {id: "f3", target: "cody", severity: "advisory", location: "resources/js/App.vue:1", summary: $s, detail: "d",
         claims: [{path: "resources/js/App.vue", line: 1, quote: $q}], asserts_existing_code: true}')
    _lens_reply correctness "[$human,$refuted]"
    _lens_reply tests "[$advisory]"
    _lens_reply phi-security '[]'
    _lens_reply ops-infra '[]'
    hold w1; hold_reviewers
    run_job_bg
    wait_job '.state == "running" and ((.worker_pid // 0) > 0)'
    wait_event worker_spawned
    settle
    tick                                   # build
    release w1
    wait_job '.activity == "review_wave"'
    wait_event review_spawned 3
    settle
    tick                                   # review stage
    settle
    subscribe                              # reconnect while the reviewers work
    release_reviewers_in_order perri-lens.correctness perri-lens.phi-security perri-lens.tests archie
    wait_run
    wait_event decision_opened
    wait_event awaiting_input
    settle
    tick                                   # held
    settle
    subscribe                              # reconnect at the hold: gates, wave, progress, decision, attention
    finish
}

# ---------------------------------------------------------------------------
# Scenario 3 — gate_hold_answered: attempts exhausted, a hold, answered by option over the broker.

scenario_gate_hold_answered() {
    new_scenario gate_hold_answered 'version: 1
gates:
  mode: enforce
  max_attempts: 2
  checks:
    - name: unit
      run: |
        '"$EMIT"'; exit 1
      hint: "Fix the failing unit test."'
    subscribe
    add_job "Backfill invoice totals"
    worker_behave 1 'mkdir -p app; echo "<?php" > app/Foo.php; git add app/Foo.php; git commit -q -m "feature work"'
    worker_behave 2 'echo "// attempted fix" >> app/Foo.php; git add app/Foo.php; git commit -q -m "attempted fix"'
    hold w1
    run_job_bg
    wait_job '.state == "running" and ((.worker_pid // 0) > 0)'
    wait_event worker_spawned
    settle
    tick
    release w1
    wait_run
    wait_event gates_exhausted
    wait_event awaiting_input
    settle
    tick
    settle
    subscribe                              # reconnect at the hold
    send answer "$(jq -nc --arg j "$JOB" '{job: $j, option: "resume_with_guidance",
        text: "The unit failure is a fixture ordering issue in InvoiceTotalsTest; fix the seed, do not touch the totals query.",
        source: "nostromo_app"}')"
    wait_event decision_resolved
    wait_event resumed
    settle
    tick
    settle
    subscribe                              # the job has left awaiting
    finish
}

# ---------------------------------------------------------------------------
# Normalisation: raw recording -> stable fixture.

NORMALISE_PY="$SCRATCH/normalise.py"
cat > "$NORMALISE_PY" <<'PY'
import json, os, re, sys
from datetime import datetime, timezone, timedelta

raw_path, meta_path, out_path, placeholder_job = sys.argv[1:5]
meta = dict(l.rstrip("\n").split("=", 1) for l in open(meta_path) if "=" in l)
msgs = [json.loads(l) for l in open(raw_path) if l.strip()]

ISO = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?Z$")
SHA40 = re.compile(r"\b[0-9a-f]{40}\b")
DECISION = re.compile(r"\bd-\d{6,}\b")
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")

# Reviewers (adherence and every lens) are spawned in parallel, so the order of a cycle's spawn events is a
# race: put each consecutive run of them in reviewer-name order (adherence is archie:adherence).
SPAWN_KINDS = ("review_spawned", "adherence_review_spawned")
def _sort_spawned(msgs):
    out, i = [], 0
    while i < len(msgs):
        if msgs[i].get("t") in SPAWN_KINDS:
            j = i
            while j < len(msgs) and msgs[j].get("t") in SPAWN_KINDS:
                j += 1
            out.extend(sorted(msgs[i:j], key=lambda m: m["data"].get("reviewer", "archie:adherence")))
            i = j
        else:
            out.append(msgs[i])
            i += 1
    return out
msgs = _sort_spawned(msgs)
# The ack of an `answer` is sent when `mother resume` exits, so whether it lands before or after the events
# that command wrote (decision_resolved, resumed) is a delivery race: put it just before the client's next
# command (or at the end), i.e. after those events.
def _ack_after_events(msgs):
    out, held = [], []
    for m in msgs:
        if m.get("dir") == "ack" and m.get("t") == "answer":
            held.append(m)
            continue
        if m.get("dir") == "cmd" and held:
            out.extend(held)
            held = []
        out.append(m)
    return out + held
msgs = _ack_after_events(msgs)
# final_result_observed is emitted by the supervisor's poll loop, so where it lands relative to the
# gate events is a timing race. It is not part of the headless-crew contract: drop it.
msgs = [m for m in msgs if m.get("t") != "final_result_observed"]

def parse_ts(s):
    if "." in s:
        head, frac = s[:-1].split(".")
        frac = (frac + "000")[:3]
    else:
        head, frac = s[:-1], "000"
    dt = datetime.strptime(head, "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc)
    return int(dt.timestamp()) * 1000 + int(frac)

def fmt_ts(ms):
    dt = datetime.fromtimestamp(ms // 1000, tz=timezone.utc)
    return dt.strftime("%Y-%m-%dT%H:%M:%S") + ".%03dZ" % (ms % 1000)

# --- path prefixes (longest first); macOS reports /private/var for /var
prefixes = []
for key, ph in (("ROOT", "/tmp/mother-root"), ("REPO", "/tmp/work/admin-portal"), ("ORIGIN", "/tmp/origin.git")):
    p = meta[key]
    for variant in {p, os.path.realpath(p)}:
        prefixes.append((variant, ph))
prefixes.sort(key=lambda x: -len(x[0]))
job_real = meta["JOB"]

# --- key-based stable numbers / strings
FIXED_NUM = {"duration_s": 1, "elapsed_active_s": 120, "worker_pid": 4242, "supervisor_pid": 4241,
             "live_tokens": 0, "live_cost_usd": 0, "pid": 4242, "pct_moved_at_active_s": 60, "log_offset": 0,
             "usd": 0, "actual_cost_usd": 0, "actual_tokens": 0}
QUANTISE = {"stage_frac": 0.25}       # key -> step; the real value depends on a few seconds of wall clock
FIXED_STR = {"cwd": "/tmp/work/admin-portal", "enqueued_by": "operator", "project": "admin-portal"}
# final_result_at is stamped by the supervisor poll loop, so whether a mid-scenario snapshot has it is a race.
DROP_KEYS = {"final_result_at"}

# --- pass 1: gather the data timestamps (everything except the envelope ts).
# Ranking all of them together would make a placeholder depend on whether two unrelated real timestamps
# happened to coincide. Instead every timestamp key (created_at, updated_at, ...) is its own rank space
# (the value's rank among that key's distinct values, one second apart, in real order, so e.g.
# progress.updated_at strictly increases), and the key spaces sit in a fixed lifecycle order.
KEY_ORDER = ["created_at", "started_at", "spawned_at", "final_result_at", "finished_at", "opened_at",
             "since", "paused_at", "updated_at", "at", "resumed_at", "resolved_at"]
by_key = {}
def gather(o, key=None):
    if isinstance(o, dict):
        for k, v in o.items(): gather(v, k)
    elif isinstance(o, list):
        for v in o: gather(v, key)
    elif isinstance(o, str) and ISO.match(o):
        by_key.setdefault(key, set()).add(parse_ts(o))
for m in msgs:
    gather(m.get("data"))
T0 = parse_ts("2026-10-18T12:00:00Z")
keys = KEY_ORDER + sorted(k for k in by_key if k not in KEY_ORDER)
ts_map = {}
for ki, k in enumerate(keys):
    for rank, ms in enumerate(sorted(by_key.get(k, ()))):
        ts_map[(k, ms)] = T0 - 3600_000 + ki * 100_000 + rank * 1000

counters = {"sha": {}, "uuid": {}, "decision": {}}
def seq_map(table, val, fmt):
    if val not in table: table[val] = fmt(len(table) + 1)
    return table[val]

def norm_str(s):
    for src, dst in prefixes:
        s = s.replace(src, dst)
    s = s.replace(job_real, placeholder_job)
    s = DECISION.sub(lambda m: seq_map(counters["decision"], m.group(0), lambda n: "d-%04d" % n), s)
    s = SHA40.sub(lambda m: seq_map(counters["sha"], m.group(0), lambda n: "%040x" % n), s)
    s = UUID.sub(lambda m: seq_map(counters["uuid"], m.group(0), lambda n: "00000000-0000-4000-8000-%012d" % n), s)
    # short head shas (gates_started.head_sha, 7+ hex chars) are handled by key below
    return s

def walk(o, key=None):
    if isinstance(o, dict):
        return {k: walk(v, k) for k, v in o.items() if k not in DROP_KEYS}
    if isinstance(o, list):
        return [walk(v, key) for v in o]
    if isinstance(o, str):
        if ISO.match(o):
            return fmt_ts(ts_map[(key, parse_ts(o))])
        if key in ("head_sha", "source_sha", "remote_sha_at_start", "head_sha_at_start") and re.fullmatch(r"[0-9a-f]{7,40}", o):
            return seq_map(counters["sha"], o, lambda n: "%040x" % n)
        if key in FIXED_STR and o:
            return FIXED_STR[key]
        return norm_str(o)
    if isinstance(o, (int, float)) and not isinstance(o, bool):
        if key in FIXED_NUM:
            return FIXED_NUM[key]
        if key in QUANTISE:
            return round(round(o / QUANTISE[key]) * QUANTISE[key], 2) + 0.0
    return o

out = []
for i, m in enumerate(msgs):
    m = dict(m)
    m["ts"] = fmt_ts(T0 + i * 10)          # strictly increasing per stream; an ack is never earlier than its cmd
    if m.get("data") is not None:
        m["data"] = walk(m["data"])
    if isinstance(m.get("id"), str) and m.get("dir") == "event":
        m["id"] = str(i + 1)
    out.append(m)

# event ids: per-connection monotonic counter, renumbered from 1 over events only
n = 0
for m in out:
    if m["dir"] == "event":
        n += 1
        m["id"] = str(n)

with open(out_path, "w") as f:
    for m in out:
        f.write(json.dumps(m, separators=(",", ":"), sort_keys=False) + "\n")
PY

normalise() { # <scenario> <placeholder-job-id>
    python3 -I "$NORMALISE_PY" "$SCRATCH/$1.final.ndjson" "$SCRATCH/$1.meta" "$OUT/$1.ndjson" "$2" \
        || die "normalising $1 failed"
}

# ---------------------------------------------------------------------------

# RECORD_ONLY=<name> records a single scenario (debugging); the report then needs all three.
want() { [ -z "${RECORD_ONLY:-}" ] || [ "$RECORD_ONLY" = "$1" ]; }
want gates_fix_pass && { scenario_gates_fix_pass; normalise gates_fix_pass j-gates1; }
want lens_wave && { scenario_lens_wave; normalise lens_wave j-wave1; }
want gate_hold_answered && { scenario_gate_hold_answered; normalise gate_hold_answered j-hold1; }

if [ -n "$REPORT" ] && [ -z "${RECORD_ONLY:-}" ]; then
    jq -n --arg s "$SENTINEL" \
        --rawfile a "$SCRATCH/gates_fix_pass.sidefiles" \
        --rawfile b "$SCRATCH/lens_wave.sidefiles" \
        --rawfile c "$SCRATCH/gate_hold_answered.sidefiles" \
        '{sentinel: $s, side_files: {
            gates_fix_pass: ($a | split("\n") | map(select(length > 0))),
            lens_wave: ($b | split("\n") | map(select(length > 0))),
            gate_hold_answered: ($c | split("\n") | map(select(length > 0)))}}' > "$REPORT"
fi

echo "recorded: $OUT/{gates_fix_pass,lens_wave,gate_hold_answered}.ndjson"
