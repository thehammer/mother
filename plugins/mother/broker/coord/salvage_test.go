package coord

import (
	"encoding/json"
	"io"
	"net"
	"os"
	"strings"
	"testing"

	"mother-broker/workerproto"
)

const salvageSHA = "0123456789abcdef0123456789abcdef01234567"

var job1 = "j1"

func (h *harness) salvage(job, lease string, epoch int64) {
	h.t.Helper()
	h.send(workerproto.TypeSalvage, &job, &lease, &epoch, nil,
		workerproto.Salvage{Ref: workerproto.SalvageRef(job, epoch), WipSHA: salvageSHA})
}

func (h *harness) marker(job string, epoch int64) bool {
	_, err := os.Stat(h.s.salvageMarkerPath(job, epoch))
	return err == nil
}

func auditHas(t *testing.T, s *Server, code string) bool {
	t.Helper()
	b, _ := os.ReadFile(s.auditPath())
	return strings.Contains(string(b), `"code":"`+code+`"`)
}

// registerOther registers a second worker connection without touching the harness's own (h.w, h.peer, h.rd), whose goroutines read them.
func (h *harness) registerOther(id string) *workerConn {
	a, b := net.Pipe()
	h.t.Cleanup(func() { a.Close(); b.Close() })
	w := newWorkerConn(id, "i-"+id, 1, nil, a, h.now)
	go func() {
		for line := range w.out {
			_, _ = a.Write(line)
		}
	}()
	go func() { _, _ = io.Copy(io.Discard, b) }()
	h.s.mu.Lock()
	h.s.register(w, &workerproto.Welcome{Proto: 1})
	h.s.mu.Unlock()
	return w
}

func auditCount(t *testing.T, s *Server, code string) int {
	t.Helper()
	b, _ := os.ReadFile(s.auditPath())
	return strings.Count(string(b), `"code":"`+code+`"`)
}

// An epoch that appears twice in the history resolves to the LAST grant, never the first.
func TestLeaseHistoryLookupUsesLatestGrant(t *testing.T) {
	h := newHarness(t)
	h.s.leaseHistoryAppend(workerproto.Lease{Job: "jx", Epoch: 4, ID: "L-old", Worker: "w1"})
	h.s.leaseHistoryAppend(workerproto.Lease{Job: "jx", Epoch: 4, ID: "L-new", Worker: "w2"})
	got, ok := h.s.leaseHistoryLookup("jx", 4)
	if !ok || got.ID != "L-new" || got.Worker != "w2" {
		t.Fatalf("lookup of a repeated epoch = %+v ok=%v, want the latest grant L-new/w2", got, ok)
	}
}

// The history file is bounded, keeps the newest grants and still answers for them.
func TestLeaseHistoryIsBounded(t *testing.T) {
	h := newHarness(t)
	for e := int64(1); e <= historyMaxLines+40; e++ {
		h.s.leaseHistoryAppend(workerproto.Lease{Job: "jy", Epoch: e, ID: "L" + itoa(int(e)), Worker: "w1"})
	}
	b, _ := os.ReadFile(h.s.historyPath("jy"))
	if n := strings.Count(string(b), "\n"); n > historyMaxLines {
		t.Fatalf("history has %d lines, cap is %d", n, historyMaxLines)
	}
	last := int64(historyMaxLines + 40)
	if g, ok := h.s.leaseHistoryLookup("jy", last); !ok || g.ID != "L"+itoa(int(last)) {
		t.Fatal("the newest grant was lost by pruning")
	}
	if _, ok := h.s.leaseHistoryLookup("jy", 1); ok {
		t.Fatal("the oldest grant should have been pruned")
	}
}

// A worker's salvage frame is believed only for a lease the coordinator granted to that worker and
// that is no longer live.
func TestSalvageRefusedUnlessOwnLapsedLease(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")

	// live lease: refused
	h.salvage("j1", lease, epoch)
	if h.marker("j1", epoch) || !auditHas(t, h.s, "salvage_of_live_lease") {
		t.Fatal("a salvage of a live lease must be refused and audited")
	}

	h.s.mu.Lock()
	_ = h.s.revokeLocked("j1", "test")
	h.s.mu.Unlock()

	// unknown (job, epoch): refused
	h.salvage("j1", lease, epoch+7)
	if h.marker("j1", epoch+7) || !auditHas(t, h.s, "salvage_unknown_lease") {
		t.Fatal("a salvage of an unknown epoch must be refused and audited")
	}
	h.salvage("nojob", "L-x", 1)
	if h.marker("nojob", 1) {
		t.Fatal("a salvage of an unknown job wrote a marker")
	}

	// right epoch, wrong lease id: refused
	h.salvage("j1", "L-forged", epoch)
	if h.marker("j1", epoch) || !auditHas(t, h.s, "salvage_not_owner") {
		t.Fatal("a salvage naming the wrong lease id must be refused and audited")
	}

	// another worker's lease: refused
	w1 := h.w
	h.w = h.registerOther("w2") // registered: an unregistered connection's frames are dropped before they reach the salvage check
	before := auditCount(t, h.s, "salvage_not_owner")
	h.salvage("j1", lease, epoch)
	h.w = w1
	if h.marker("j1", epoch) {
		t.Fatal("worker w2 salvaged worker w1's lease")
	}
	if got := auditCount(t, h.s, "salvage_not_owner"); got != before+1 {
		t.Fatalf("another worker's salvage of this lease must add one salvage_not_owner audit line (had %d, now %d)", before, got)
	}

	// the owner, once the lease is no longer live: accepted
	h.salvage("j1", lease, epoch)
	if !h.marker("j1", epoch) {
		t.Fatal("the owner's salvage of its revoked lease was refused")
	}
}

// The manifest the worker sent is parsed by Go (case-insensitive keys, last duplicate wins) and drives
// restores; bash/jq must receive Go's own re-serialisation, never the worker's bytes, or the two parsers
// can disagree about what the manifest says.
func TestCheckpointManifestIsReserialisedBeforeApply(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	sha := "0123456789abcdef0123456789abcdef01234567"
	tsha := strings.Repeat("a", 64)
	raw := `{"oseq":1,"manifest":{"v":1,"job":"j1","lease":"` + lease + `","epoch":` + itoa(int(epoch)) + `,"n":1,` +
		`"at":"2026-11-08T12:00:00.000Z","head_sha":"` + sha + `","branch":"feature/ok","Branch":"feature/other",` +
		`"base_sha":"` + sha + `","wip_sha":"` + sha + `","wip_ref":"refs/mother/wip/j1","pushed":true,"session_id":"s1",` +
		`"transcript":{"path_rel":"checkpoints/j1/1/transcript.delta","bytes":5,"bytes":9,"sha256":"` + tsha + `"},` +
		`"untracked_skipped":[]}}`
	seq := int64(1)
	h.send(workerproto.TypeCheckpointTaken, &job1, &lease, &epoch, &seq, json.RawMessage(raw))
	h.flush()
	h.app.mu.Lock()
	defer h.app.mu.Unlock()
	if len(h.app.ops) != 1 {
		t.Fatalf("want 1 applied op, got %d (refused: %v)", len(h.app.ops), ofType(h.frames(), workerproto.TypeRefuse))
	}
	got := string(h.app.ops[0])
	var op struct {
		Data workerproto.CheckpointTaken `json:"data"`
	}
	if err := json.Unmarshal(h.app.ops[0], &op); err != nil {
		t.Fatal(err)
	}
	want, _ := json.Marshal(op.Data)
	var envl struct {
		Data json.RawMessage `json:"data"`
	}
	_ = json.Unmarshal(h.app.ops[0], &envl)
	if string(envl.Data) != string(want) {
		t.Fatalf("applied data is not Go's re-serialisation:\n got %s\nwant %s", envl.Data, want)
	}
	if strings.Contains(got, `"Branch"`) || strings.Count(got, `"bytes"`) != 1 {
		t.Fatalf("worker-supplied duplicate / case-variant keys reached the applier: %s", got)
	}
}
