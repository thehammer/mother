package coord

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"mother-broker/workerproto"
)

// fakeApplier records the batches it is given and "applies" them by remembering the highest seq.
type fakeApplier struct {
	mu      sync.Mutex
	applied int64
	batches [][]int64
	ops     [][]byte
	fail    bool
}

func (f *fakeApplier) Apply(job string, ops [][]byte) (int64, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	var seqs []int64
	for _, o := range ops {
		var op struct {
			Seq int64 `json:"seq"`
		}
		_ = json.Unmarshal(o, &op)
		seqs = append(seqs, op.Seq)
		f.ops = append(f.ops, append([]byte(nil), o...))
	}
	f.batches = append(f.batches, seqs)
	if f.fail {
		return f.applied, os.ErrInvalid
	}
	for _, s := range seqs {
		if s == f.applied+1 {
			f.applied = s
		}
	}
	return f.applied, nil
}

type harness struct {
	t    *testing.T
	s    *Server
	app  *fakeApplier
	now  time.Time
	w    *workerConn
	peer net.Conn
	rd   *bufio.Reader
	root string
}

func newHarness(t *testing.T) *harness {
	t.Helper()
	root := t.TempDir()
	h := &harness{t: t, app: &fakeApplier{}, now: time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC), root: root}
	h.start()
	return h
}

func (h *harness) start() {
	h.t.Helper()
	s, err := New(Config{Root: h.root, Applier: h.app, TTL: 6 * time.Second, Now: func() time.Time { return h.now }, FlushEvery: time.Hour})
	if err != nil {
		h.t.Fatal(err)
	}
	h.s = s
}

func (h *harness) connect(id string, slots int) {
	h.t.Helper()
	a, b := net.Pipe()
	h.peer = b
	h.rd = bufio.NewReader(b)
	h.w = newWorkerConn(id, "i-"+id, slots, nil, a, h.now)
	go func() {
		for line := range h.w.out {
			_, _ = a.Write(line)
		}
	}()
	h.s.mu.Lock()
	welcome := &workerproto.Welcome{Proto: 1}
	h.s.register(h.w, welcome)
	h.s.mu.Unlock()
}

// frames reads frames the coordinator queued for the worker until quiet.
func (h *harness) frames() []workerproto.Frame {
	h.t.Helper()
	var out []workerproto.Frame
	for {
		_ = h.peer.SetReadDeadline(time.Now().Add(150 * time.Millisecond))
		line, err := workerproto.ReadFrame(h.rd)
		if err != nil {
			return out
		}
		f, err := workerproto.Decode(line)
		if err != nil {
			h.t.Fatalf("bad frame from coordinator: %v", err)
		}
		out = append(out, f)
	}
}

func ofType(fs []workerproto.Frame, t string) []workerproto.Frame {
	var out []workerproto.Frame
	for _, f := range fs {
		if f.T == t {
			out = append(out, f)
		}
	}
	return out
}

func (h *harness) writeJob(id string, extra map[string]any) {
	h.t.Helper()
	doc := map[string]any{"id": id, "state": "running", "repo": "r", "repo_path": h.root}
	for k, v := range extra {
		doc[k] = v
	}
	b, _ := json.Marshal(doc)
	p := h.s.jobPath(id)
	_ = os.MkdirAll(filepath.Dir(p), 0o755)
	if err := os.WriteFile(p, b, 0o644); err != nil {
		h.t.Fatal(err)
	}
}

// lease dispatches job to the connected worker and has the worker accept the offer; it returns the lease.
func (h *harness) lease(job string) (leaseID string, epoch int64) {
	h.t.Helper()
	h.writeJob(job, nil)
	if err := os.WriteFile(h.s.dispatchPath(job), []byte(`{"job":"`+job+`"}`), 0o644); err != nil {
		h.t.Fatal(err)
	}
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	offers := ofType(h.frames(), workerproto.TypeLeaseOffer)
	if len(offers) != 1 {
		h.t.Fatalf("want 1 offer, got %d", len(offers))
	}
	var o struct {
		CmdID string `json:"cmd_id"`
	}
	_ = json.Unmarshal(offers[0].Data, &o)
	h.send(workerproto.TypeCmdAck, offers[0].Job, offers[0].Lease, offers[0].Epoch, nil, map[string]any{"cmd_id": o.CmdID, "outcome": "applied", "for": "lease.offer"})
	return *offers[0].Lease, *offers[0].Epoch
}

var idN int

func (h *harness) send(t string, job, lease *string, epoch, seq *int64, data any) {
	h.t.Helper()
	idN++
	f, err := workerproto.NewFrame(t, "t-"+strings.Repeat("x", 1)+string(rune('a'+idN%26))+itoa(idN), h.now, data)
	if err != nil {
		h.t.Fatal(err)
	}
	f.Job, f.Lease, f.Epoch, f.Seq = job, lease, epoch, seq
	b, err := workerproto.Encode(f)
	if err != nil {
		h.t.Fatal(err)
	}
	h.s.mu.Lock()
	h.s.handleLine(h.w, b)
	h.s.mu.Unlock()
}

func itoa(n int) string { b, _ := json.Marshal(n); return string(b) }

func (h *harness) event(job, lease string, epoch, seq, oseq int64) {
	h.t.Helper()
	line := `{"ts":"2026-11-08T12:00:00.000Z","kind":"k","detail":{}}`
	data := map[string]any{"line": line, "oseq": oseq}
	h.send(workerproto.TypeEventAppend, &job, &lease, &epoch, &seq, data)
}

func (h *harness) flush() {
	h.s.mu.Lock()
	h.s.flushAll()
	h.s.mu.Unlock()
}

func (h *harness) rec(job string) LeaseRec {
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	return h.s.jobs[job].rec
}

func auditCodes(t *testing.T, s *Server) []string {
	t.Helper()
	b, _ := os.ReadFile(s.auditPath())
	var out []string
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if l == "" {
			continue
		}
		var a struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal([]byte(l), &a)
		out = append(out, a.Code)
	}
	return out
}

func TestIngestInOrderDuplicateGapAndFenced(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 2)
	lease, epoch := h.lease("j1")
	if r := h.rec("j1"); r.State != "active" {
		t.Fatalf("lease not active after the offer ack: %s", r.State)
	}

	h.event("j1", lease, epoch, 1, 1)
	h.event("j1", lease, epoch, 2, 2)
	h.flush()
	if got := h.app.batches; len(got) != 1 || len(got[0]) != 2 || got[0][0] != 1 || got[0][1] != 2 {
		t.Fatalf("want one batch [1 2], got %v", got)
	}
	if r := h.rec("j1"); r.AppliedSeq != 2 || r.WireSeq != 2 {
		t.Fatalf("applied/wire seq = %d/%d, want 2/2", r.AppliedSeq, r.WireSeq)
	}
	acks := ofType(h.frames(), workerproto.TypeAck)
	if len(acks) == 0 {
		t.Fatal("no ack after the flush")
	}
	var a workerproto.AckData
	_ = json.Unmarshal(acks[len(acks)-1].Data, &a)
	if a.Seq != 2 {
		t.Fatalf("ack seq %d, want 2", a.Seq)
	}

	// Duplicate: dropped, re-acked, never applied again.
	h.event("j1", lease, epoch, 2, 2)
	h.flush()
	if len(h.app.batches) != 1 {
		t.Fatalf("a duplicate reached the applier: %v", h.app.batches)
	}
	if len(ofType(h.frames(), workerproto.TypeAck)) == 0 {
		t.Fatal("duplicate was not re-acked")
	}

	// Gap: seq 5 while 3 is missing is buffered and the ack asks for a resend from 3.
	h.event("j1", lease, epoch, 5, 5)
	h.flush()
	acks = ofType(h.frames(), workerproto.TypeAck)
	if len(acks) == 0 {
		t.Fatal("no ack for the gap")
	}
	_ = json.Unmarshal(acks[len(acks)-1].Data, &a)
	if a.ResendFrom == nil || *a.ResendFrom != 3 {
		t.Fatalf("resend_from = %v, want 3", a.ResendFrom)
	}
	if len(h.app.batches) != 1 {
		t.Fatalf("a gap frame was applied: %v", h.app.batches)
	}
	// The missing frames arrive: 3, 4 then the buffered 5 apply in order.
	h.event("j1", lease, epoch, 3, 3)
	h.event("j1", lease, epoch, 4, 4)
	h.flush()
	if r := h.rec("j1"); r.AppliedSeq != 5 {
		t.Fatalf("after the gap filled, applied = %d, want 5", r.AppliedSeq)
	}

	// Fenced: an old epoch is refused, audited and applies nothing.
	before := len(h.app.batches)
	h.event("j1", lease, epoch+3, 6, 6)
	h.flush()
	fs := h.frames()
	refs := ofType(fs, workerproto.TypeRefuse)
	if len(refs) != 1 {
		t.Fatalf("want one refuse, got %d", len(refs))
	}
	var rf workerproto.Refuse
	_ = json.Unmarshal(refs[0].Data, &rf)
	if rf.Code != workerproto.CodeFenced {
		t.Fatalf("refuse code %q, want fenced", rf.Code)
	}
	if len(h.app.batches) != before {
		t.Fatal("a fenced frame was applied")
	}
	if codes := auditCodes(t, h.s); len(codes) != 1 || codes[0] != "fenced" {
		t.Fatalf("audit codes %v, want [fenced]", codes)
	}
}

func TestOwnershipRefusalIsAuditedAndNotApplied(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	seq := int64(1)
	h.send(workerproto.TypeJobSet, strp("j1"), &lease, &epoch, &seq, map[string]any{"set": map[string]any{"pr_url": "https://evil"}, "oseq": 1})
	h.flush()
	if len(h.app.batches) != 0 {
		t.Fatal("an ownership-violating job.set reached the applier")
	}
	refs := ofType(h.frames(), workerproto.TypeRefuse)
	if len(refs) != 1 {
		t.Fatalf("want one refuse, got %d", len(refs))
	}
	if codes := auditCodes(t, h.s); len(codes) != 1 || codes[0] != "ownership" {
		t.Fatalf("audit codes %v, want [ownership]", codes)
	}
}

func strp(s string) *string { return &s }

func TestOskipFillsPlaceholders(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	seq := int64(1)
	line := `{"ts":"2026-11-08T12:00:00.000Z","kind":"k","detail":{}}`
	h.send(workerproto.TypeEventAppend, strp("j1"), &lease, &epoch, &seq, map[string]any{"line": line, "oseq": 3, "oskip": []int64{1, 2}})
	h.flush()
	if got := h.app.batches; len(got) != 1 || len(got[0]) != 3 || got[0][0] != 1 || got[0][2] != 3 {
		t.Fatalf("want one batch [1 2 3], got %v", got)
	}
}

func TestApplierFailureLeavesFramesPendingThenRetries(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)
	h.app.fail = true
	h.flush()
	if r := h.rec("j1"); r.WireSeq != 0 || r.AppliedSeq != 0 {
		t.Fatalf("a failed apply moved the position: %+v", r)
	}
	h.app.fail = false
	h.flush()
	if r := h.rec("j1"); r.WireSeq != 1 || r.AppliedSeq != 1 {
		t.Fatalf("retry did not apply: %+v", r)
	}
}

func TestLogAppendOffsets(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	logf := func(seq int64, off int64, s string) {
		h.send(workerproto.TypeLogAppend, strp("j1"), &lease, &epoch, &seq, map[string]any{"offset": off, "b64": base64.StdEncoding.EncodeToString([]byte(s))})
	}
	logf(1, 0, "hello ")
	logf(2, 3, "lo world") // overlaps: only the new bytes land
	h.flush()
	b, _ := os.ReadFile(h.s.logPath("j1"))
	if string(b) != "hello world" {
		t.Fatalf("log = %q", b)
	}
	logf(3, 99, "gap") // a hole is refused and not committed
	h.flush()
	if r := h.rec("j1"); r.WireSeq != 2 {
		t.Fatalf("a log gap was committed: wire %d", r.WireSeq)
	}
	b, _ = os.ReadFile(h.s.logPath("j1"))
	if string(b) != "hello world" {
		t.Fatalf("log after gap = %q", b)
	}
}

func TestCommandsPersistAndRedeliverUntilAcked(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	_ = lease
	_ = epoch
	holdPath := h.s.path("runner", "j1.hold")
	_ = os.MkdirAll(filepath.Dir(holdPath), 0o755)
	_ = os.WriteFile(holdPath, []byte(`{"code":"backoff","reason":"r","since":"x"}`), 0o644)
	h.s.mu.Lock()
	h.s.holdPass()
	h.s.mu.Unlock()
	holds := ofType(h.frames(), workerproto.TypeHold)
	if len(holds) != 1 {
		t.Fatalf("want 1 hold, got %d", len(holds))
	}
	if b, _ := os.ReadFile(h.s.cmdsPath("j1")); !strings.Contains(string(b), `"t":"hold"`) {
		t.Fatalf("the hold is not persisted: %q", b)
	}

	// The coordinator restarts before the ack: the command is still queued and goes out again on reconnect.
	h.s.Close()
	h.start()
	h.connect("w1", 1)
	redelivered := ofType(h.frames(), workerproto.TypeHold)
	if len(redelivered) != 1 || string(redelivered[0].Data) != string(holds[0].Data) {
		t.Fatalf("hold not redelivered intact: %d", len(redelivered))
	}

	var c struct {
		CmdID string `json:"cmd_id"`
	}
	_ = json.Unmarshal(redelivered[0].Data, &c)
	h.send(workerproto.TypeCmdAck, redelivered[0].Job, redelivered[0].Lease, redelivered[0].Epoch, nil, map[string]any{"cmd_id": c.CmdID, "outcome": "applied", "for": "hold"})
	if _, err := os.Stat(h.s.cmdsPath("j1")); !os.IsNotExist(err) {
		t.Fatal("an acked command is still persisted")
	}

	// The flag is removed: a release goes out.
	_ = os.Remove(holdPath)
	h.s.mu.Lock()
	h.s.holdPass()
	h.s.mu.Unlock()
	if len(ofType(h.frames(), workerproto.TypeRelease)) != 1 {
		t.Fatal("no release after the hold flag was removed")
	}
}

func TestSyncJobEchoSuppression(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	h.lease("j1")
	pass := func() []workerproto.Frame {
		h.s.mu.Lock()
		h.s.syncJobPass()
		h.s.mu.Unlock()
		return ofType(h.frames(), workerproto.TypeSyncJob)
	}
	if n := len(pass()); n != 0 {
		t.Fatalf("an unchanged job produced %d sync.job", n)
	}
	h.writeJob("j1", map[string]any{"cancel_requested": true})
	got := pass()
	if len(got) != 1 || !strings.Contains(string(got[0].Data), `"cancel_requested":true`) {
		t.Fatalf("cancel_requested not synced: %v", got)
	}
	if n := len(pass()); n != 0 {
		t.Fatalf("the same value was synced again (%d)", n)
	}
	// A value the worker itself reported for a downlink key is remembered, so the canonical copy of it is not echoed back.
	h.s.mu.Lock()
	h.s.noteWorkerSet(h.s.jobs["j1"], json.RawMessage(`{"set":{"pause_requested":true}}`))
	h.s.mu.Unlock()
	h.writeJob("j1", map[string]any{"cancel_requested": true, "pause_requested": true})
	if n := len(pass()); n != 0 {
		t.Fatalf("a worker-originated value was echoed back (%d)", n)
	}
}

func TestExpiryRespectsCoordinatorUptime(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	h.lease("j1")
	// Long after the last heartbeat, but the coordinator has only just started: nothing expires (MC-16).
	h.now = h.now.Add(time.Hour)
	h.s.mu.Lock()
	h.s.upSince = h.now
	h.s.expire()
	h.s.mu.Unlock()
	if r := h.rec("j1"); r.State != "active" {
		t.Fatalf("lease expired during the restart grace: %s", r.State)
	}
	// A full TTL of coordinator uptime with no heartbeat: lost, marked and audited.
	h.now = h.now.Add(7 * time.Second)
	h.s.mu.Lock()
	h.s.expire()
	h.s.mu.Unlock()
	if r := h.rec("j1"); r.State != "lost" || r.EndReason != "lost" {
		t.Fatalf("lease not lost: %+v", r)
	}
	if _, err := os.Stat(h.s.lostPath("j1")); err != nil {
		t.Fatal("no .lost marker")
	}
	if codes := auditCodes(t, h.s); len(codes) != 1 || codes[0] != "lease_lost" {
		t.Fatalf("audit codes %v", codes)
	}
}

func TestEpochSurvivesRestartAndFencesOldHolder(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	h.s.mu.Lock()
	_ = h.s.revokeLocked("j1", "test")
	h.s.mu.Unlock()
	h.s.Close()
	h.start()
	h.connect("w1", 1)
	_, epoch2 := h.lease("j1")
	if epoch2 != epoch+1 {
		t.Fatalf("epoch after restart = %d, want %d", epoch2, epoch+1)
	}
	h.event("j1", lease, epoch, 1, 1) // the old lease
	if len(ofType(h.frames(), workerproto.TypeRefuse)) != 1 {
		t.Fatal("the old lease was not fenced")
	}
}

func TestCorruptLeaseTableIsRefused(t *testing.T) {
	root := t.TempDir()
	_ = os.MkdirAll(filepath.Join(root, "runner", "leases"), 0o755)
	_ = os.WriteFile(filepath.Join(root, "runner", "leases", "table.json"), []byte(`{"epochs":{"j":1},"leases":[{"id":"L","job":"j","epoch":9,"worker":"w","state":"active"}]}`), 0o644)
	if _, err := New(Config{Root: root}); err == nil {
		t.Fatal("a corrupt lease table was loaded")
	}
}

func TestNoWorkerAndBusyWaitReasons(t *testing.T) {
	h := newHarness(t)
	h.writeJob("j1", nil)
	_ = os.WriteFile(h.s.dispatchPath("j1"), []byte(`{"job":"j1"}`), 0o644)
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	var req dispatchReq
	b, _ := os.ReadFile(h.s.dispatchPath("j1"))
	_ = json.Unmarshal(b, &req)
	if req.WaitReason != "no_worker_connected" {
		t.Fatalf("wait_reason = %q", req.WaitReason)
	}
	_ = os.Remove(h.s.dispatchPath("j1"))
	h.connect("w1", 1)
	h.lease("j2") // takes the only slot
	_ = os.WriteFile(h.s.dispatchPath("j1"), []byte(`{"job":"j1"}`), 0o644)
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	b, _ = os.ReadFile(h.s.dispatchPath("j1"))
	_ = json.Unmarshal(b, &req)
	if req.WaitReason != "all_workers_busy" {
		t.Fatalf("wait_reason = %q", req.WaitReason)
	}
}
