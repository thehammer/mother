package coord

import (
	"encoding/json"
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
	a, b := net.Pipe()
	defer a.Close()
	defer b.Close()
	h.w = newWorkerConn("w2", "i-w2", 1, nil, a, h.now)
	h.salvage("j1", lease, epoch)
	h.w = w1
	if h.marker("j1", epoch) {
		t.Fatal("worker w2 salvaged worker w1's lease")
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
