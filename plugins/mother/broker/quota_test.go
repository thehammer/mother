package main

// quota_test.go — the broker's side of the quota gate.
//
// Contract (see ../tests/fixtures/quota_block.json, the golden wire fixture):
//   - every subscribe snapshot's data carries `quota`: exactly what
//     `mother quota status --json` prints.
//   - command `quota-gate` {state: on|off|off_until_reset, origin?} routes to
//     `mother quota on|off|off-until-reset --source broker:<origin>`; an unknown
//     state is rejected as `malformed` without touching the CLI; setting the
//     current state again is fine (the CLI makes it a no-op) and acks ok.
//   - ok ack data: {ok:true, state, quota}.
//   - quota-gate is advertised in hello capabilities.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

const quotaFixturePath = "../tests/fixtures/quota_block.json"

// quotaFixture is the decoded golden fixture.
type quotaFixture struct {
	Doc             string          `json:"_doc"`
	QuotaBlock      json.RawMessage `json:"quota_block"`
	SnapshotEnv     Message         `json:"snapshot_envelope"`
	CommandEnvelope struct {
		Request         Message `json:"request"`
		OKAck           Message `json:"ok_ack"`
		RejectedRequest Message `json:"rejected_request"`
		RejectedAck     Message `json:"rejected_ack"`
	} `json:"command_envelopes"`
}

func loadQuotaFixture(t *testing.T) quotaFixture {
	t.Helper()
	raw, err := os.ReadFile(quotaFixturePath)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var f quotaFixture
	if err := json.Unmarshal(raw, &f); err != nil {
		t.Fatalf("decode fixture: %v", err)
	}
	if len(f.QuotaBlock) == 0 {
		t.Fatal("fixture has no quota_block")
	}
	return f
}

// jsonEqual compares two JSON documents structurally.
func jsonEqual(t *testing.T, got, want json.RawMessage) bool {
	t.Helper()
	var g, w any
	if err := json.Unmarshal(got, &g); err != nil {
		t.Fatalf("jsonEqual: got is not JSON: %v (%s)", err, got)
	}
	if err := json.Unmarshal(want, &w); err != nil {
		t.Fatalf("jsonEqual: want is not JSON: %v (%s)", err, want)
	}
	return reflect.DeepEqual(g, w)
}

// newQuotaHub installs a fake `mother` CLI that
//   - answers `quota status --json` with the fixture's quota_block,
//   - answers `quota on|off|off-until-reset ...` with exit 0, or, when
//     failMsg is non-empty, prints failMsg to stderr and exits 1,
//   - appends every invocation (space-joined argv) to <rec>/calls.
func newQuotaHub(t *testing.T, failMsg string) (*testHub, string, quotaFixture) {
	t.Helper()
	fx := loadQuotaFixture(t)
	th := newTestHub(t, 1024)
	rec := t.TempDir()
	blockFile := filepath.Join(rec, "block.json")
	if err := os.WriteFile(blockFile, fx.QuotaBlock, 0o644); err != nil {
		t.Fatalf("write block: %v", err)
	}
	failFile := filepath.Join(rec, "fail")
	if failMsg != "" {
		if err := os.WriteFile(failFile, []byte(failMsg+"\n"), 0o644); err != nil {
			t.Fatalf("write fail: %v", err)
		}
	}
	script := `#!/bin/sh
echo "$*" >> '` + rec + `/calls'
if [ "$1" = quota ]; then
  case "$2" in
    status) cat '` + blockFile + `'; exit 0 ;;
    on|off|off-until-reset)
      if [ -f '` + failFile + `' ]; then cat '` + failFile + `' >&2; exit 1; fi
      echo "quota gate changed"; exit 0 ;;
  esac
fi
echo "mother: unknown subcommand: $*" >&2
exit 1
`
	cli := filepath.Join(rec, "fake-mother")
	if err := os.WriteFile(cli, []byte(script), 0o755); err != nil {
		t.Fatalf("write fake CLI: %v", err)
	}
	th.runner.cliPath = cli
	return th, rec, fx
}

// quotaCalls returns the recorded invocations that change the gate (everything
// except `quota status`), each as its argv fields.
func quotaCalls(t *testing.T, rec string) [][]string {
	t.Helper()
	b, err := os.ReadFile(filepath.Join(rec, "calls"))
	if err != nil {
		return nil
	}
	var out [][]string
	for _, line := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		f := strings.Fields(line)
		if len(f) >= 2 && f[0] == "quota" && f[1] != "status" {
			out = append(out, f)
		}
	}
	return out
}

// quotaGateAck sends a quota-gate command on a fresh connection and returns
// the ack message.
func quotaGateAck(t *testing.T, th *testHub, id string, data map[string]any) Message {
	t.Helper()
	conn := th.connect(t)
	if _, err := readNext(t, conn); err != nil { // hello
		t.Fatalf("hello: %v", err)
	}
	sendCmd(t, conn, CmdQuotaGate, id, data)
	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading quota-gate ack: %v", err)
	}
	if ack.Dir != DirAck || ack.T != CmdQuotaGate {
		t.Fatalf("reply dir=%s t=%s, want ack quota-gate", ack.Dir, ack.T)
	}
	if ack.ID != id {
		t.Fatalf("ack id = %q, want %q", ack.ID, id)
	}
	return ack
}

// ---------------------------------------------------------------------------
// Snapshot carries the quota block
// ---------------------------------------------------------------------------

func TestQuotaSnapshot_carriesTheQuotaBlockFromTheCLI(t *testing.T) {
	th, _, fx := newQuotaHub(t, "")
	th.injectJob(t, "job-q-1", map[string]any{"state": "ready"})
	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	snap := subscribeSimple(t, conn, "main", []string{"all"}, []string{CatState})

	var data map[string]json.RawMessage
	if err := json.Unmarshal(snap.Data, &data); err != nil {
		t.Fatalf("decode snapshot data: %v", err)
	}
	quota, present := data["quota"]
	if !present {
		t.Fatalf("snapshot data has no quota key: %s", snap.Data)
	}
	if !jsonEqual(t, quota, fx.QuotaBlock) {
		t.Errorf("snapshot quota = %s, want the fixture block %s", quota, fx.QuotaBlock)
	}
	// The quota block rides alongside, not instead of, the existing keys.
	if _, ok := data["sub"]; !ok {
		t.Error("snapshot lost its sub key")
	}
	var jobs []any
	if err := json.Unmarshal(data["jobs"], &jobs); err != nil || len(jobs) != 1 {
		t.Errorf("snapshot jobs = %s, want 1 job", data["jobs"])
	}
}

func TestQuotaSnapshot_everySubscribeGetsTheBlock(t *testing.T) {
	th, _, fx := newQuotaHub(t, "")
	for i, name := range []string{"first", "second"} {
		conn := th.connect(t)
		_, _ = readNext(t, conn)
		snap := subscribeSimple(t, conn, name, []string{"all"}, []string{CatState})
		var data map[string]json.RawMessage
		_ = json.Unmarshal(snap.Data, &data)
		if q, ok := data["quota"]; !ok || !jsonEqual(t, q, fx.QuotaBlock) {
			t.Errorf("subscribe #%d (%s): quota = %s, want fixture block", i+1, name, q)
		}
	}
}

func TestQuotaSnapshot_stillDeliveredWhenTheCLICannotReportQuota(t *testing.T) {
	// The default test hub's CLI is `false`: `quota status` fails. The snapshot
	// (jobs) must still arrive; a quota outage must not take subscriptions down.
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-q-2", map[string]any{"state": "ready"})
	conn := th.connect(t)
	_, _ = readNext(t, conn)

	snap := subscribeSimple(t, conn, "main", []string{"all"}, []string{CatState})
	data := mustDecodeData(t, snap)
	if jobs, _ := data["jobs"].([]any); len(jobs) != 1 {
		t.Errorf("snapshot jobs = %v, want 1 job", data["jobs"])
	}
}

// ---------------------------------------------------------------------------
// quota-gate command
// ---------------------------------------------------------------------------

func TestQuotaGate_acceptsEachStateAndRoutesToTheMatchingCLISubcommand(t *testing.T) {
	cases := []struct{ state, sub string }{
		{"on", "on"},
		{"off", "off"},
		{"off_until_reset", "off-until-reset"},
	}
	for _, tc := range cases {
		t.Run(tc.state, func(t *testing.T) {
			th, rec, fx := newQuotaHub(t, "")
			ack := quotaGateAck(t, th, "q1", map[string]any{"state": tc.state, "origin": "nostromo"})

			var data map[string]json.RawMessage
			if err := json.Unmarshal(ack.Data, &data); err != nil {
				t.Fatalf("decode ack: %v", err)
			}
			if string(data["ok"]) != "true" {
				t.Fatalf("ack = %s, want ok:true", ack.Data)
			}
			var gotState string
			_ = json.Unmarshal(data["state"], &gotState)
			if gotState != tc.state {
				t.Errorf("ack state = %q, want %q", gotState, tc.state)
			}
			if q, ok := data["quota"]; !ok || !jsonEqual(t, q, fx.QuotaBlock) {
				t.Errorf("ack quota = %s, want the fixture block", q)
			}

			want := []string{"quota", tc.sub, "--source", "broker:nostromo"}
			calls := quotaCalls(t, rec)
			if len(calls) != 1 || !reflect.DeepEqual(calls[0], want) {
				t.Errorf("CLI gate calls = %q, want exactly [%q]", calls, want)
			}
		})
	}
}

func TestQuotaGate_unknownStateIsMalformedAndTheCLIIsNotCalled(t *testing.T) {
	for _, state := range []string{"sometimes", "ON", "off-until-reset", ""} {
		th, rec, _ := newQuotaHub(t, "")
		ack := quotaGateAck(t, th, "q2", map[string]any{"state": state})
		data := mustDecodeData(t, ack)
		if code := ackErrCode(t, data); code != ErrMalformed {
			t.Errorf("state %q: error.code = %q, want %q", state, code, ErrMalformed)
		}
		if calls := quotaCalls(t, rec); len(calls) != 0 {
			t.Errorf("state %q: CLI was asked to change the gate: %q", state, calls)
		}
	}
}

func TestQuotaGate_missingStateIsMalformed(t *testing.T) {
	th, rec, _ := newQuotaHub(t, "")
	ack := quotaGateAck(t, th, "q3", map[string]any{"origin": "nostromo"})
	if code := ackErrCode(t, mustDecodeData(t, ack)); code != ErrMalformed {
		t.Errorf("error.code = %q, want %q", code, ErrMalformed)
	}
	if calls := quotaCalls(t, rec); len(calls) != 0 {
		t.Errorf("CLI was asked to change the gate: %q", calls)
	}
}

func TestQuotaGate_sourceIsBrokerPlusOriginAndIsSafeAsOneArgument(t *testing.T) {
	th, rec, _ := newQuotaHub(t, "")
	_ = quotaGateAck(t, th, "q4", map[string]any{"state": "off", "origin": "evil; rm -rf / $(x)\nnewline"})
	calls := quotaCalls(t, rec)
	if len(calls) != 1 {
		t.Fatalf("CLI gate calls = %q, want 1", calls)
	}
	// "quota off --source broker:<something>": the origin must collapse to a
	// single printable token (no spaces, shell metacharacters or newlines).
	if len(calls[0]) != 4 || calls[0][2] != "--source" || !strings.HasPrefix(calls[0][3], "broker:") {
		t.Fatalf("argv = %q, want quota off --source broker:<origin> as four fields", calls[0])
	}
	if strings.ContainsAny(calls[0][3], ";$()/\\`'\"|&<> \t\n") {
		t.Errorf("source %q carries unsafe characters", calls[0][3])
	}
}

func TestQuotaGate_noOriginStillRecordsABrokerSource(t *testing.T) {
	th, rec, _ := newQuotaHub(t, "")
	_ = quotaGateAck(t, th, "q5", map[string]any{"state": "on"})
	calls := quotaCalls(t, rec)
	if len(calls) != 1 || len(calls[0]) != 4 || !strings.HasPrefix(calls[0][3], "broker:") || len(calls[0][3]) <= len("broker:") {
		t.Errorf("argv = %q, want a non-empty broker:<origin> source", calls)
	}
}

func TestQuotaGate_isIdempotentTheSameStateTwiceAcksOkBothTimes(t *testing.T) {
	th, _, _ := newQuotaHub(t, "")
	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello
	for _, id := range []string{"a", "b"} {
		sendCmd(t, conn, CmdQuotaGate, id, map[string]any{"state": "off", "origin": "nostromo"})
		ack, err := readNext(t, conn)
		if err != nil {
			t.Fatalf("ack %s: %v", id, err)
		}
		data := mustDecodeData(t, ack)
		if data["ok"] != true || data["state"] != "off" {
			t.Errorf("ack %s = %v, want ok:true state:off", id, data)
		}
	}
}

func TestQuotaGate_aCLIFailureBecomesAnErrorAck(t *testing.T) {
	th, _, _ := newQuotaHub(t, "mother: quota: refused: the quota gate is operator-controlled")
	ack := quotaGateAck(t, th, "q6", map[string]any{"state": "off", "origin": "nostromo"})
	data := mustDecodeData(t, ack)
	if data["ok"] != false {
		t.Fatalf("ack = %v, want ok:false", data)
	}
	if code := ackErrCode(t, data); code != ErrUnauthorized {
		t.Errorf("error.code = %q, want %q (CLI said refused)", code, ErrUnauthorized)
	}
}

func TestQuotaGate_fromAWorkerConnectionIsUnauthorizedAndTheCLIIsNotCalled(t *testing.T) {
	th, rec, _ := newQuotaHub(t, "")
	th.hub.guard = fakeGuard{worker: true}
	ack := quotaGateAck(t, th, "q7", map[string]any{"state": "off", "origin": "nostromo"})
	if code := ackErrCode(t, mustDecodeData(t, ack)); code != ErrUnauthorized {
		t.Errorf("error.code = %q, want %q", code, ErrUnauthorized)
	}
	if calls := quotaCalls(t, rec); len(calls) != 0 {
		t.Errorf("a worker changed the gate: %q", calls)
	}
}

func TestQuotaGate_nonWorkerConnectionPassesTheGuard(t *testing.T) {
	th, rec, _ := newQuotaHub(t, "")
	th.hub.guard = fakeGuard{worker: false}
	ack := quotaGateAck(t, th, "q8", map[string]any{"state": "on", "origin": "nostromo"})
	if mustDecodeData(t, ack)["ok"] != true {
		t.Errorf("ack = %s, want ok:true", ack.Data)
	}
	if len(quotaCalls(t, rec)) != 1 {
		t.Errorf("CLI gate calls = %q, want 1", quotaCalls(t, rec))
	}
}

func TestQuotaGate_isAdvertisedInHelloCapabilities(t *testing.T) {
	th := newTestHub(t, 1024)
	conn := th.connect(t)
	hello, _ := readNext(t, conn)
	caps, _ := mustDecodeData(t, hello)["capabilities"].([]any)
	found := false
	for _, c := range caps {
		if c == "quota-gate" {
			found = true
		}
	}
	if !found {
		t.Errorf("hello capabilities %v missing %q", caps, "quota-gate")
	}
	if CmdQuotaGate != "quota-gate" {
		t.Errorf("CmdQuotaGate = %q, want the wire name %q", CmdQuotaGate, "quota-gate")
	}
}

// ---------------------------------------------------------------------------
// Golden fixture envelopes
// ---------------------------------------------------------------------------

func TestQuotaFixture_envelopesDecodeAsBrokerMessages(t *testing.T) {
	raw, err := os.ReadFile(quotaFixturePath)
	if err != nil {
		t.Fatal(err)
	}
	var top map[string]json.RawMessage
	if err := json.Unmarshal(raw, &top); err != nil {
		t.Fatal(err)
	}
	var cmds map[string]json.RawMessage
	if err := json.Unmarshal(top["command_envelopes"], &cmds); err != nil {
		t.Fatal(err)
	}
	envelopes := map[string]json.RawMessage{
		"snapshot_envelope": top["snapshot_envelope"],
		"request":           cmds["request"],
		"ok_ack":            cmds["ok_ack"],
		"rejected_request":  cmds["rejected_request"],
		"rejected_ack":      cmds["rejected_ack"],
	}
	want := map[string]struct{ dir, typ string }{
		"snapshot_envelope": {DirEvent, TypeSnapshot},
		"request":           {DirCmd, CmdQuotaGate},
		"ok_ack":            {DirAck, CmdQuotaGate},
		"rejected_request":  {DirCmd, CmdQuotaGate},
		"rejected_ack":      {DirAck, CmdQuotaGate},
	}
	for name, env := range envelopes {
		m, err := decodeMessage(env)
		if err != nil {
			t.Errorf("%s: decode: %v", name, err)
			continue
		}
		if m.V != ProtocolVersion {
			t.Errorf("%s: v = %d, want %d", name, m.V, ProtocolVersion)
		}
		if m.Dir != want[name].dir || m.T != want[name].typ {
			t.Errorf("%s: dir=%q t=%q, want dir=%q t=%q", name, m.Dir, m.T, want[name].dir, want[name].typ)
		}
		if m.ID == "" {
			t.Errorf("%s: empty id", name)
		}
		if len(m.Data) == 0 {
			t.Errorf("%s: no data", name)
		}
	}
}

func TestQuotaFixture_okRequestGetsTheDocumentedAck(t *testing.T) {
	th, _, fx := newQuotaHub(t, "")
	var req map[string]any
	if err := json.Unmarshal(fx.CommandEnvelope.Request.Data, &req); err != nil {
		t.Fatal(err)
	}
	ack := quotaGateAck(t, th, fx.CommandEnvelope.Request.ID, req)

	var got, want map[string]json.RawMessage
	_ = json.Unmarshal(ack.Data, &got)
	// The fixture's ack data carries the "<quota_block>" placeholder; compare
	// the keys and the concrete values, and the block against the real block.
	if err := json.Unmarshal(fx.CommandEnvelope.OKAck.Data, &want); err != nil {
		t.Fatal(err)
	}
	for k := range want {
		if _, ok := got[k]; !ok {
			t.Errorf("ack data lacks documented key %q: %s", k, ack.Data)
		}
	}
	if string(got["ok"]) != string(want["ok"]) || string(got["state"]) != string(want["state"]) {
		t.Errorf("ack ok/state = %s/%s, want %s/%s", got["ok"], got["state"], want["ok"], want["state"])
	}
	if !jsonEqual(t, got["quota"], fx.QuotaBlock) {
		t.Errorf("ack quota = %s, want fixture block", got["quota"])
	}
}

func TestQuotaFixture_rejectedRequestGetsTheDocumentedAck(t *testing.T) {
	th, rec, fx := newQuotaHub(t, "")
	var req map[string]any
	if err := json.Unmarshal(fx.CommandEnvelope.RejectedRequest.Data, &req); err != nil {
		t.Fatal(err)
	}
	ack := quotaGateAck(t, th, fx.CommandEnvelope.RejectedRequest.ID, req)
	if !jsonEqual(t, ack.Data, fx.CommandEnvelope.RejectedAck.Data) {
		t.Errorf("rejected ack data = %s, want %s", ack.Data, fx.CommandEnvelope.RejectedAck.Data)
	}
	if calls := quotaCalls(t, rec); len(calls) != 0 {
		t.Errorf("CLI called for a rejected request: %q", calls)
	}
}
