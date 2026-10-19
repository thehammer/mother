#!/usr/bin/env bats
# Headless-crew client contract: the recorded fixtures (written by
# scripts/record-contract-fixtures.sh from real runs) must satisfy
# scripts/contract-check.sh, equal a fresh recording, and the checker must reject
# drift (unknown event kind, missing required detail key, forbidden free-text
# key). The HC-16 audit tests below cover reconnect/resync (C1), the single job
# shape (C3), compatibility for old subscribers (C4) and the PHI rule (C11).

load 'test_helper'

setup() {
    PLUGIN="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    CHECK="$PLUGIN/scripts/contract-check.sh"
    FIX="$PLUGIN/tests/fixtures/contract"
    WORK="$(mktemp -d)"
    _CONTRACT_ORIG_PATH="$PATH"
    setup_mother_env
}

teardown() {
    kill_test_broker
    teardown_mother_env
    rm -rf "$WORK"
}

@test "gates_fix_pass fixture satisfies the contract" {
    run "$CHECK" "$FIX/gates_fix_pass.ndjson"
    [ "$status" -eq 0 ]
}

@test "lens_wave fixture satisfies the contract" {
    run "$CHECK" "$FIX/lens_wave.ndjson"
    [ "$status" -eq 0 ]
}

@test "gate_hold_answered fixture satisfies the contract" {
    run "$CHECK" "$FIX/gate_hold_answered.ndjson"
    [ "$status" -eq 0 ]
}

@test "checker reads an NDJSON stream from stdin" {
    run bash -c "'$CHECK' < '$FIX/lens_wave.ndjson'"
    [ "$status" -eq 0 ]
}

@test "checker accepts several files and fails if any is bad" {
    echo 'not json' > "$WORK/bad.ndjson"
    run "$CHECK" "$FIX/lens_wave.ndjson" "$WORK/bad.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"bad.ndjson:1:"* ]]
}

@test "unknown event kind fails and names file:line" {
    # Rename the lens_skipped event (line 2) to a kind the contract does not list.
    jq -c 'if .t == "lens_skipped" then .t = "lens_vanished" else . end' \
        "$FIX/lens_wave.ndjson" > "$WORK/unknown.ndjson"
    n=$(grep -n lens_vanished "$WORK/unknown.ndjson" | head -1 | cut -d: -f1)
    run "$CHECK" "$WORK/unknown.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown.ndjson:$n:"* ]]
    [[ "$output" == *"lens_vanished"* ]]
}

@test "missing required detail key fails and names file:line" {
    jq -c 'if .t == "gate_result" and .data.name == "lint" then del(.data.exit_code) else . end' \
        "$FIX/gates_fix_pass.ndjson" > "$WORK/missing.ndjson"
    n=$(grep -n '"gate_result"' "$WORK/missing.ndjson" | grep -v exit_code | head -1 | cut -d: -f1)
    [ -n "$n" ]
    run "$CHECK" "$WORK/missing.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"missing.ndjson:$n:"* ]]
    [[ "$output" == *"exit_code"* ]]
}

@test "forbidden free-text key in a new-kind detail fails and names file:line" {
    jq -c 'if .t == "gates_exhausted" then .data.excerpt = "FAIL: something leaked" else . end' \
        "$FIX/gate_hold_answered.ndjson" > "$WORK/leak.ndjson"
    n=$(grep -n excerpt "$WORK/leak.ndjson" | head -1 | cut -d: -f1)
    [ -n "$n" ]
    run "$CHECK" "$WORK/leak.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"leak.ndjson:$n:"* ]]
    [[ "$output" == *"excerpt"* ]]
}

@test "forbidden key nested in a new job key fails" {
    jq -c 'if .t == "snapshot" then .data.jobs[0].gates.summary = "lint failed" else . end' \
        "$FIX/gates_fix_pass.ndjson" > "$WORK/jobleak.ndjson"
    run "$CHECK" "$WORK/jobleak.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"jobleak.ndjson:"*"summary"* ]]
}

@test "text is allowed on the answer cmd but nowhere else" {
    run bash -c "grep -c '\"text\"' '$FIX/gate_hold_answered.ndjson'"
    [ "$output" -ge 1 ]
    jq -c 'if .t == "decision_resolved" then .data.text = "x" else . end' \
        "$FIX/gate_hold_answered.ndjson" > "$WORK/text.ndjson"
    run "$CHECK" "$WORK/text.ndjson"
    [ "$status" -eq 1 ]
    [[ "$output" == *"text"* ]]
}

@test "fixture job records keep Nostromo's decoded keys and ISO-8601 millisecond Z timestamps" {
    for f in gates_fix_pass lens_wave gate_hold_answered; do
        run jq -e -s '
            [ .[] | select(.t == "snapshot") | .data.jobs[] ] as $jobs
            | ($jobs | length) > 0
            and ($jobs | all(
                has("id") and has("state") and has("repo") and has("isolation") and has("title")
                and has("created_at") and has("started_at") and has("finished_at")
                and (.created_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}\\.[0-9]{3}Z$"))
            ))' "$FIX/$f.ndjson"
        [ "$status" -eq 0 ]
    done
}

# =============================================================================
# HC-16 contract-fixture tests (recordings, resync, single shape, PHI, compat)
# =============================================================================

SENT="SENTINEL-PHI-42"
SCENARIOS="gates_fix_pass lens_wave gate_hold_answered"

setup_file() {
    # The Go source changes with the contract, so always rebuild (never trust a stale binary).
    _CONTRACT_BROKER_OK=0
    if command -v go >/dev/null 2>&1; then
        local plugin
        plugin="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
        if "$plugin/scripts/build-broker.sh" >"$BATS_FILE_TMPDIR/build.log" 2>&1; then
            : > "$BATS_FILE_TMPDIR/broker-built"
        fi
    fi
}

need_go() {
    command -v go >/dev/null 2>&1 || skip "go not found"
}

need_broker() {
    need_go
    [ -f "$BATS_FILE_TMPDIR/broker-built" ] || skip "broker build failed (see $BATS_FILE_TMPDIR/build.log)"
}

kill_test_broker() {
    # Only the pid this test started.
    if [ -n "${_CT_BROKER_PID:-}" ]; then
        kill "$_CT_BROKER_PID" 2>/dev/null || true
        wait "$_CT_BROKER_PID" 2>/dev/null || true
        _CT_BROKER_PID=""
    fi
}

start_test_broker() {
    export MOTHER_BROKER_SOCK="$MOTHER_ROOT/broker.sock"
    export MOTHER_BROKER_ANSWER_GUARD=0
    export MOTHER_CLI="$_BIN_DIR/mother"
    "$PLUGIN/broker/bin/mother-broker" >"$MOTHER_ROOT/broker.log" 2>&1 &
    _CT_BROKER_PID=$!
    local i=0
    while [ $i -lt 50 ]; do
        [ -S "$MOTHER_BROKER_SOCK" ] && return 0
        sleep 0.1
        i=$((i + 1))
    done
    cat "$MOTHER_ROOT/broker.log" >&2
    return 1
}

# Record the three fixtures once per bats file into $BATS_FILE_TMPDIR/rec (cached, failure cached too).
record_once() {
    need_go
    REC="$BATS_FILE_TMPDIR/rec"
    REPORT="$BATS_FILE_TMPDIR/rec-report.json"
    if [ -f "$BATS_FILE_TMPDIR/rec.failed" ]; then
        cat "$BATS_FILE_TMPDIR/rec.log" >&2
        return 1
    fi
    [ -f "$REC/.done" ] && return 0
    mkdir -p "$REC"
    local envargs=(HOME="$_MOTHER_TEST_REAL_HOME" PATH="$_CONTRACT_ORIG_PATH" PYTHONIOENCODING=utf-8)
    local v
    for v in TMPDIR LANG LC_ALL USER GOPATH GOCACHE GOFLAGS GOMODCACHE GOROOT; do
        [ -n "${!v:-}" ] && envargs+=("$v=${!v}")
    done
    if ! env -i "${envargs[@]}" "$PLUGIN/scripts/record-contract-fixtures.sh" \
            --out "$REC" --report "$REPORT" >"$BATS_FILE_TMPDIR/rec.log" 2>&1; then
        : > "$BATS_FILE_TMPDIR/rec.failed"
        cat "$BATS_FILE_TMPDIR/rec.log" >&2
        return 1
    fi
    : > "$REC/.done"
}

# _pyfile <code> — write Python code to a file in this test's tmpdir and echo
# its path. Clients run from a file, never `python3 -c` or stdin: endpoint
# security flags inline/stdin Python that opens a socket ("Reverse Shell Via
# Python"), even for a local AF_UNIX socket.
_pyfile() {
    local f
    f=$(mktemp "$BATS_TEST_TMPDIR/py.XXXXXX")
    printf '%s\n' "$1" > "$f"
    echo "$f"
}

# Run python3 reading fixtures; show its output on failure.
pyrun() {
    local f; f=$(_pyfile "$1")
    run python3 -I "$f" "${@:2}"
    if [ "$status" -ne 0 ]; then echo "$output" >&2; fi
    [ "$status" -eq 0 ]
}

PY_FX='
import json, sys, os
FIX = os.environ["FIXDIR"]
SCN = ["gates_fix_pass", "lens_wave", "gate_hold_answered"]
def load(name):
    return [json.loads(l) for l in open(os.path.join(FIX, name + ".ndjson")) if l.strip()]
def snaps(msgs):
    return [m for m in msgs if m["dir"] == "event" and m["t"] == "snapshot"]
def jobs(msgs):
    return [(m, j) for m in snaps(msgs) for j in m["data"]["jobs"]]
'

# Python unix-socket client used by the live broker tests.
PY_CLIENT='
import json, socket, time, os
SOCK = os.environ["MOTHER_BROKER_SOCK"]
CATS = ["state", "activity", "await", "current_activity", "quota", "progress"]
class C:
    def __init__(self):
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(SOCK)
        self.buf = b""
        self.n = 0
        self.hello = self.recv()
    def recv(self, timeout=5):
        self.s.settimeout(timeout)
        while True:
            while b"\n" in self.buf:
                line, self.buf = self.buf.split(b"\n", 1)
                if not line.strip():
                    continue
                m = json.loads(line)
                if m.get("t") == "ping":
                    continue
                return m
            chunk = self.s.recv(65536)
            if not chunk:
                raise EOFError("closed")
            self.buf += chunk
    def send(self, t, data):
        self.n += 1
        cid = "c%d" % self.n
        msg = {"v": 1, "dir": "cmd", "t": t, "id": cid,
               "ts": time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime()), "data": data}
        self.s.sendall((json.dumps(msg) + "\n").encode())
        return cid
    def request(self, t, data):
        cid = self.send(t, data)
        while True:
            m = self.recv()
            if m["dir"] == "ack" and m["id"] == cid:
                return m
    def subscribe(self, cats=CATS, sub="nostromo"):
        cid = self.send("subscribe", {"sub": sub, "jobs": ["all"], "categories": cats})
        ack = None
        while True:
            m = self.recv()
            if m["dir"] == "ack" and m["id"] == cid:
                assert m["data"]["ok"], m
                ack = m
            elif m["t"] == "snapshot" and ack is not None:
                return m
    def drain(self, seconds):
        out = []
        end = time.time() + seconds
        while True:
            left = end - time.time()
            if left <= 0:
                return out
            try:
                out.append(self.recv(timeout=left))
            except socket.timeout:
                return out
    def wait_kind(self, kind, timeout=5):
        end = time.time() + timeout
        while True:
            left = end - time.time()
            assert left > 0, "timed out waiting for " + kind
            m = self.recv(timeout=left)
            if m["dir"] == "event" and m["t"] == kind:
                return m
def append_event(job, kind, detail):
    path = os.path.join(os.environ["EVENTS_DIR"], job + ".jsonl")
    ts = time.strftime("%Y-%m-%dT%H:%M:%S.000Z", time.gmtime())
    with open(path, "a") as f:
        f.write(json.dumps({"ts": ts, "kind": kind, "detail": detail}) + "\n")
'

# Seed a job file (+ progress file) from the last lens_wave snapshot job. $1 = "flags" adds a progress flag.
# Sets LIVE_ID. Leaves the progress object in $MOTHER_ROOT/live-progress.json.
seed_live_job() {
    local with_flag="${1:-}"
    local last
    last="$(jq -c 'select(.dir=="event" and .t=="snapshot") | .data.jobs[0]' "$FIX/lens_wave.ndjson" | tail -1)"
    LIVE_ID="$(jq -r .id <<<"$last")"
    jq 'del(.progress, .attention_reasons)' <<<"$last" > "$JOBS_DIR/$LIVE_ID.json"
    mkdir -p "$MOTHER_ROOT/progress"
    if [ "$with_flag" = "flags" ]; then
        jq '.flags = [{"reason":"progress_stalled","since":"2026-10-18T11:00:09.000Z","detail":{"stage":"review","stuck_s":900}}]' \
            <<<"$last" | jq '.progress' > "$MOTHER_ROOT/live-progress.json"
    else
        jq '.progress' <<<"$last" > "$MOTHER_ROOT/live-progress.json"
    fi
    cp "$MOTHER_ROOT/live-progress.json" "$MOTHER_ROOT/progress/$LIVE_ID.json"
    : > "$EVENTS_DIR/$LIVE_ID.jsonl"
}

# ---------------------------------------------------------------- (a) recordings validate

@test "(a) every committed fixture passes contract-check" {
    for f in $SCENARIOS; do
        run "$CHECK" "$FIX/$f.ndjson"
        [ "$status" -eq 0 ] || { echo "$f: $output" >&2; false; }
    done
}

# ---------------------------------------------------------------- (b) fixtures are fresh

@test "(b) committed fixtures are byte-identical to a fresh recording" {
    record_once
    local f bad=""
    for f in $SCENARIOS; do
        if ! cmp -s "$REC/$f.ndjson" "$FIX/$f.ndjson"; then
            bad="$bad $f"
            diff "$FIX/$f.ndjson" "$REC/$f.ndjson" | head -10 >&2 || true
        fi
    done
    if [ -n "$bad" ]; then
        echo "stale fixtures:$bad -- re-run plugins/mother/scripts/record-contract-fixtures.sh" >&2
        false
    fi
}

# ---------------------------------------------------------------- (c) C1 reconnect / resync

@test "(c) lens_wave last snapshot carries gates, review_wave, progress, decision, attention_reasons" {
    FIXDIR="$FIX" pyrun "$PY_FX"'
msgs = load("lens_wave")
ss = snaps(msgs)
last = ss[-1]["data"]["jobs"][0]
for k in ("gates", "review_wave", "progress", "decision", "attention_reasons"):
    assert last.get(k) is not None, "last snapshot missing " + k
assert "decision_awaiting" in [r["reason"] for r in last["attention_reasons"]]
mid = [j for _, j in jobs(msgs) if j.get("activity") == "review_wave"]
assert mid, "no mid-wave snapshot (activity == review_wave)"
for j in mid:
    for k in ("gates", "review_wave", "progress"):
        assert j.get(k) is not None, "mid-wave snapshot missing " + k
'
}

@test "(c) gates_fix_pass snapshot taken during gate_fix carries gates and progress" {
    FIXDIR="$FIX" pyrun "$PY_FX"'
mid = [j for _, j in jobs(load("gates_fix_pass")) if j.get("activity") == "gate_fix"]
assert mid, "no gate_fix snapshot"
for j in mid:
    for k in ("gates", "progress"):
        assert j.get(k) is not None, "gate_fix snapshot missing " + k
'
}

@test "(c) live resync: a re-subscribe after a progress_updated returns all five new job keys" {
    need_broker
    seed_live_job
    start_test_broker
    LIVE_ID="$LIVE_ID" pyrun "$PY_CLIENT"'
c = C()
c.subscribe()
detail = json.load(open(os.path.join(os.environ["MOTHER_ROOT"], "live-progress.json")))
append_event(os.environ["LIVE_ID"], "progress_updated", detail)   # after connect: the broker only tails live
c.wait_kind("progress_updated")
snap = c.subscribe()
j = [x for x in snap["data"]["jobs"] if x["id"] == os.environ["LIVE_ID"]][0]
for k in ("gates", "review_wave", "progress", "decision", "attention_reasons"):
    assert j.get(k) is not None, "resync snapshot missing " + k
assert "decision_awaiting" in [r["reason"] for r in j["attention_reasons"]]
'
}

# ---------------------------------------------------------------- (d) C3 single shape / (A5)

@test "(d) gates, review_wave, progress, decision, attention_reasons have one shape across list, status and broker" {
    need_broker
    seed_live_job flags
    start_test_broker
    # Broker side: append progress_updated after connecting, then query.get / query.list.
    _live_py=$(_pyfile "$PY_CLIENT"'
c = C()
c.subscribe()
detail = json.load(open(os.path.join(os.environ["MOTHER_ROOT"], "live-progress.json")))
append_event(os.environ["LIVE_ID"], "progress_updated", detail)
c.wait_kind("progress_updated")
g = c.request("query.get", {"job": os.environ["LIVE_ID"]})
assert g["data"]["ok"], g
l = c.request("query.list", {})
assert l["data"]["ok"], l
lj = [x for x in l["data"]["jobs"] if x["id"] == os.environ["LIVE_ID"]][0]
json.dump({"get": g["data"]["job"], "list": lj}, open(os.path.join(os.environ["MOTHER_ROOT"], "broker-out.json"), "w"))
')
    LIVE_ID="$LIVE_ID" run python3 -I "$_live_py"
    [ "$status" -eq 0 ] || { echo "$output" >&2; false; }

    mother list --format json > "$MOTHER_ROOT/cli-list.json"
    mother status "$LIVE_ID" --format json > "$MOTHER_ROOT/cli-status.json"
    local k a b c d e
    for k in gates review_wave progress decision attention_reasons; do
        a="$(jq -S --arg id "$LIVE_ID" ".[] | select(.id==\$id) | .$k" "$MOTHER_ROOT/cli-list.json")"
        b="$(jq -S ".job.$k" "$MOTHER_ROOT/cli-status.json")"
        c="$(jq -S ".get.$k" "$MOTHER_ROOT/broker-out.json")"
        d="$(jq -S ".list.$k" "$MOTHER_ROOT/broker-out.json")"
        [ "$a" != "null" ] && [ -n "$a" ] || { echo "list has no $k" >&2; false; }
        [ "$a" = "$b" ] || { echo "$k: list != status" >&2; diff <(echo "$a") <(echo "$b") >&2; false; }
        [ "$a" = "$c" ] || { echo "$k: list != broker query.get" >&2; diff <(echo "$a") <(echo "$c") >&2; false; }
        [ "$a" = "$d" ] || { echo "$k: list != broker query.list" >&2; diff <(echo "$a") <(echo "$d") >&2; false; }
    done
}

@test "(A5) query.get and query.list gain progress after progress_updated; attention_reasons is always present" {
    need_broker
    seed_live_job
    start_test_broker
    LIVE_ID="$LIVE_ID" pyrun "$PY_CLIENT"'
jid = os.environ["LIVE_ID"]
c = C()
c.subscribe()
def both():
    g = c.request("query.get", {"job": jid})["data"]["job"]
    l = [x for x in c.request("query.list", {})["data"]["jobs"] if x["id"] == jid][0]
    return g, l
g, l = both()
for r in (g, l):
    assert "progress" not in r, "progress present before any progress_updated"
    assert isinstance(r.get("attention_reasons"), list), "attention_reasons missing before event"
detail = json.load(open(os.path.join(os.environ["MOTHER_ROOT"], "live-progress.json")))
append_event(jid, "progress_updated", detail)
c.wait_kind("progress_updated")
g, l = both()
for r in (g, l):
    assert r["progress"]["pct"] == detail["pct"], r["progress"]
    assert r["progress"]["label"] == detail["label"], r["progress"]
    assert isinstance(r.get("attention_reasons"), list) and r["attention_reasons"], "attention_reasons missing after event"
'
}

# ---------------------------------------------------------------- (e) C11 PHI rule

@test "(e) the sentinel really is seeded in the side files of every scenario (the PHI check is not vacuous)" {
    record_once
    local s
    for s in $SCENARIOS; do
        [ "$(jq --arg s "$s" '.side_files[$s] | length' "$REPORT")" -gt 0 ] || { echo "$s: no side files hold the sentinel" >&2; false; }
        jq -e --arg s "$s" '.side_files[$s] | any(test("^crew/<job>/gates/"))' "$REPORT" >/dev/null || { echo "$s: no gates side file" >&2; false; }
    done
    jq -e '.side_files.lens_wave | any(test("/wave/"))' "$REPORT" >/dev/null
    jq -e '.side_files.lens_wave | any(test("/adherence/"))' "$REPORT" >/dev/null
    jq -e '[.side_files[][]] | any(test("^checklists/"))' "$REPORT" >/dev/null
}

@test "(e) no sentinel text appears in the committed or the freshly recorded fixtures" {
    record_once
    local f dir
    for dir in "$FIX" "$REC"; do
        for f in $SCENARIOS; do
            ! grep -F "$SENT" "$dir/$f.ndjson" || { echo "$dir/$f leaks the sentinel" >&2; false; }
            ! grep -F "SENTINEL" "$dir/$f.ndjson" || { echo "$dir/$f leaks SENTINEL" >&2; false; }
        done
    done
}

@test "(e) no free-text keys (excerpt, summary, quote, criterion_text, text) under any event data; text only on the answer cmd" {
    FIXDIR="$FIX" pyrun "$PY_FX"'
FORBID = {"excerpt", "summary", "quote", "criterion_text", "text"}
def walk(o, path, where):
    if isinstance(o, dict):
        for k, v in o.items():
            assert k not in FORBID, "%s: forbidden key %s at %s" % (where, k, path)
            walk(v, path + "." + k, where)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            walk(v, "%s[%d]" % (path, i), where)
for n in SCN:
    for i, m in enumerate(load(n), 1):
        if m["dir"] == "event":
            walk(m["data"], "data", "%s:%d" % (n, i))
        elif m["dir"] == "cmd" and not (m["t"] == "answer"):
            walk(m["data"], "data", "%s:%d" % (n, i))
'
}

# ---------------------------------------------------------------- (f) C4 compatibility

@test "(f) a subscriber without the progress category never receives progress_updated; one with it does" {
    need_broker
    seed_live_job
    start_test_broker
    LIVE_ID="$LIVE_ID" pyrun "$PY_CLIENT"'
jid = os.environ["LIVE_ID"]
old = C(); new = C()
old.subscribe(["state", "activity", "await", "current_activity", "quota"])
new.subscribe(CATS)
detail = json.load(open(os.path.join(os.environ["MOTHER_ROOT"], "live-progress.json")))
append_event(jid, "gate_result", {"attempt": 1, "name": "lint", "result": "passed", "blocking": True, "duration_s": 1, "exit_code": 0})
old.wait_kind("gate_result")          # the activity event arrives first, so the silence below is meaningful
append_event(jid, "progress_updated", detail)
got = new.wait_kind("progress_updated")
assert got["data"]["category"] == "progress"
extra = old.drain(1.5)
assert not [m for m in extra if m["t"] == "progress_updated"], "old subscriber received progress_updated"
'
}

@test "(f) every pre-Phase-1 job key keeps its type in every fixture snapshot" {
    FIXDIR="$FIX" pyrun "$PY_FX"'
S, N, A, B = "string", "number", "array", "null"
TYPES = {}
for k in "id repo isolation title state branch base_ref executor plan_path log_path current_tier created_at".split():
    TYPES[k] = {S}
for k in "started_at finished_at pr_url tmux_window".split():
    TYPES[k] = {S, B}
TYPES["depends_on"] = {A}
for k in "worker_pid max_cost_usd actual_cost_usd".split():
    TYPES[k] = {N, B}
for k in "retry_count escalation_count adherence_attempts".split():
    TYPES[k] = {N}
for k in "question paused_reason adherence_status activity kind".split():
    TYPES[k] = {S, B}
for k in ("phases", "cycles"):
    TYPES[k] = {A}
def jt(v):
    if v is None: return B
    if isinstance(v, bool): return "boolean"
    if isinstance(v, (int, float)): return N
    if isinstance(v, str): return S
    if isinstance(v, list): return A
    return "object"
seen = 0
for n in SCN:
    for m, j in jobs(load(n)):
        for k, allowed in TYPES.items():
            if k in j:
                seen += 1
                assert jt(j[k]) in allowed, "%s: job key %s has type %s, allowed %s" % (n, k, jt(j[k]), allowed)
assert seen > 0
'
}

# ---------------------------------------------------------------- HC16-5 answered hold

@test "(HC16-5) gate_hold_answered shows the answer, its ack, decision_resolved and a resolved last snapshot" {
    FIXDIR="$FIX" pyrun "$PY_FX"'
msgs = load("gate_hold_answered")
ans = [(i, m) for i, m in enumerate(msgs) if m["dir"] == "cmd" and m["t"] == "answer"]
assert len(ans) == 1, ans
i, a = ans[0]
d = a["data"]
assert d["option"] == "resume_with_guidance"
assert isinstance(d.get("text"), str) and d["text"].strip()
assert d["source"] == "nostromo_app"
acks = [m for m in msgs if m["dir"] == "ack" and m["t"] == "answer" and m["id"] == a["id"]]
assert len(acks) == 1 and acks[0]["data"]["ok"] is True, acks
assert any(m["dir"] == "event" and m["t"] == "decision_resolved" for m in msgs[i + 1:]), "no decision_resolved after the answer"
last = snaps(msgs)[-1]["data"]["jobs"][0]
assert last["state"] != "awaiting", last["state"]
assert last["decision"]["resolved_at"] is not None
'
}

# ---------------------------------------------------------------- (A4) timestamps

@test "(A4) envelope ts is monotonic, acks never precede their cmd, and progress updated_at only moves forward" {
    FIXDIR="$FIX" pyrun "$PY_FX"'
for n in SCN:
    msgs = load(n)
    prev = ""
    cmds = {}
    for i, m in enumerate(msgs, 1):
        assert m["ts"] >= prev, "%s:%d envelope ts went backwards" % (n, i)
        prev = m["ts"]
        if m["dir"] == "cmd":
            cmds[m["id"]] = m["ts"]
        elif m["dir"] == "ack" and m["id"] in cmds:
            assert m["ts"] >= cmds[m["id"]], "%s:%d ack precedes its cmd" % (n, i)
    latest = {}
    for i, m in enumerate(msgs, 1):
        if m["dir"] == "event" and m["t"] == "progress_updated":
            job, u = m["data"]["job"], m["data"]["updated_at"]
            if job in latest:
                assert u > latest[job], "%s:%d progress_updated.updated_at did not strictly increase" % (n, i)
            latest[job] = u
        elif m["dir"] == "event" and m["t"] == "snapshot":
            for j in m["data"]["jobs"]:
                if j.get("progress") and j["id"] in latest:
                    assert j["progress"]["updated_at"] >= latest[j["id"]], "%s:%d snapshot progress older than a progress_updated already seen" % (n, i)
'
}

# ---------------------------------------------------------------- (A1/A2/A6) shapes

@test "(A1/A2/A6) attention_reasons, progress label and signals, decision options and crew have the documented shapes" {
    FIXDIR="$FIX" pyrun "$PY_FX"'
n_prog = 0
for n in SCN:
    msgs = load(n)
    for m, j in jobs(msgs):
        for r in j.get("attention_reasons") or []:
            assert set(["reason", "since", "acked"]) <= set(r), r
            assert isinstance(r["acked"], bool), r
        crew = j.get("crew")
        if crew is not None:
            for k in ("version", "gates", "phi_sensitive"):
                assert k in crew, "%s: crew lacks %s" % (n, k)
        if j.get("decision"):
            assert all(isinstance(o, dict) for o in j["decision"]["options"]), "decision.options must be objects"
    progs = [m["data"] for m in msgs if m["dir"] == "event" and m["t"] == "progress_updated"]
    progs += [j["progress"] for _, j in jobs(msgs) if j.get("progress")]
    for p in progs:
        n_prog += 1
        assert p["label"].startswith("≈"), p["label"]
        assert "ETA ~under" not in p["label"], p["label"]
        g = p["signals"].get("gates")
        assert g is None or set(["passed", "failed", "total"]) <= set(g), g
    for m in msgs:
        if m["dir"] == "event" and m["t"] == "decision_opened":
            assert all(isinstance(o, str) for o in m["data"]["options"]), m["data"]["options"]
assert n_prog > 0
'
}
