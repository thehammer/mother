package coord

import (
	"os"
	"sync/atomic"
	"testing"
	"time"

	"mother-broker/workerproto"
)

// overlapApplier is a gate applier that also records the highest number of concurrent applies per job.
type overlapApplier struct {
	gateApplier
	cur, max atomic.Int32
}

func (o *overlapApplier) Apply(job string, ops [][]byte) (int64, error) {
	n := o.cur.Add(1)
	for {
		m := o.max.Load()
		if n <= m || o.max.CompareAndSwap(m, n) {
			break
		}
	}
	defer o.cur.Add(-1)
	return o.gateApplier.Apply(job, ops)
}

func (h *harness) redispatch(job string) {
	h.t.Helper()
	if err := os.WriteFile(h.s.dispatchPath(job), []byte(`{"job":"`+job+`"}`), 0o644); err != nil {
		h.t.Fatal(err)
	}
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
}

func TestRevokePlusImmediateRedispatchDuringASlowApplyDoesNotOverlapTheApply(t *testing.T) {
	h := newHarness(t)
	g := &overlapApplier{gateApplier: *newGate()}
	t.Cleanup(g.open)
	h.s.cfg.Applier = g
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)
	flushed := make(chan struct{})
	go func() {
		h.s.mu.Lock()
		h.s.flushAll()
		h.s.mu.Unlock()
		close(flushed)
	}()
	<-g.entered
	if err := h.s.RevokeLease("j1", "operator_revoke"); err != nil {
		t.Fatal(err)
	}
	h.frames() // drain the revoke
	h.redispatch("j1")
	if offers := ofType(h.frames(), workerproto.TypeLeaseOffer); len(offers) != 0 {
		t.Fatalf("the job was re-offered (epoch %d) while the old lease's apply was still running", *offers[0].Epoch)
	}
	if r := h.rec("j1"); r.LeaseID != lease || r.State != "revoked" {
		t.Fatalf("the old lease record was replaced during its apply: %+v", r)
	}
	g.open()
	select {
	case <-flushed:
	case <-time.After(3 * time.Second):
		t.Fatal("flush never finished")
	}
	// Next pass: the apply is done, the re-dispatch proceeds on a new epoch.
	h.redispatch("j1")
	offers := ofType(h.frames(), workerproto.TypeLeaseOffer)
	if len(offers) != 1 || *offers[0].Epoch != epoch+1 {
		t.Fatalf("after the apply finished want one offer at epoch %d, got %d", epoch+1, len(offers))
	}
	if m := g.max.Load(); m != 1 {
		t.Fatalf("%d applies of one job ran at once", m)
	}
}

func TestRevokeIssuedBeforeAReofferIsAckedAndPrunedAndTheNewLeaseWorks(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	oldLease, oldEpoch := h.lease("j1")
	if err := h.s.RevokeLease("j1", "operator_revoke"); err != nil {
		t.Fatal(err)
	}
	revs := ofType(h.frames(), workerproto.TypeLeaseRevoke)
	if len(revs) != 1 {
		t.Fatalf("want one revoke, got %d", len(revs))
	}
	h.redispatch("j1") // immediate re-offer to the same worker, revoke still unacked
	offers := ofType(h.frames(), workerproto.TypeLeaseOffer)
	if len(offers) != 1 {
		t.Fatalf("want a re-offer, got %d", len(offers))
	}
	// The ack of the OLD revoke is judged against the lease it was issued for.
	h.ack(revs[0], hxCmdID(t, revs[0]), "applied", "")
	if refs := ofType(h.frames(), workerproto.TypeRefuse); len(refs) != 0 {
		t.Fatalf("the ack of a revoke owed from an earlier lease was refused: %s", refs[0].Data)
	}
	h.s.mu.Lock()
	for _, c := range h.s.jobs["j1"].cmds {
		if c.Type == workerproto.TypeLeaseRevoke {
			h.s.mu.Unlock()
			t.Fatal("the acked old revoke is still queued on the new lease")
		}
	}
	h.s.mu.Unlock()
	// The new lease works.
	newLease, newEpoch := *offers[0].Lease, *offers[0].Epoch
	if newEpoch != oldEpoch+1 || newLease == oldLease {
		t.Fatalf("unexpected new lease %s/%d", newLease, newEpoch)
	}
	h.send(workerproto.TypeCmdAck, offers[0].Job, offers[0].Lease, offers[0].Epoch, nil,
		map[string]any{"cmd_id": hxCmdID(t, offers[0]), "outcome": "applied", "for": "lease.offer"})
	h.event("j1", newLease, newEpoch, 1, 1)
	h.flush()
	if r := h.rec("j1"); r.State != "active" || r.AppliedSeq != 1 {
		t.Fatalf("the new lease did not work: %+v", r)
	}
}

func TestAnOwedRevokeOfAnOlderEpochIsDroppedOnceTheNewOfferIsAcked(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.lease("j1")
	if err := h.s.RevokeLease("j1", "operator_revoke"); err != nil {
		t.Fatal(err)
	}
	h.frames()
	h.redispatch("j1")
	offers := ofType(h.frames(), workerproto.TypeLeaseOffer)
	if len(offers) != 1 {
		t.Fatalf("want a re-offer, got %d", len(offers))
	}
	h.send(workerproto.TypeCmdAck, offers[0].Job, offers[0].Lease, offers[0].Epoch, nil,
		map[string]any{"cmd_id": hxCmdID(t, offers[0]), "outcome": "applied", "for": "lease.offer"})
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	for _, c := range h.s.jobs["j1"].cmds {
		if c.Type == workerproto.TypeLeaseRevoke {
			t.Fatal("an owed revoke for an older epoch survived the worker's ack of the new offer")
		}
	}
	if b, _ := os.ReadFile(h.s.cmdsPath("j1")); len(b) != 0 {
		t.Fatalf("the old revoke is still persisted: %s", b)
	}
}

func TestRegisterWorkerRefusesPidZero(t *testing.T) {
	r := startRig(t, nil, nil)
	if err := r.s.RegisterWorker("w1", 0, NewSecret()); err == nil {
		t.Fatal("a pid-0 registration (bind to the first connection) was accepted")
	}
	if err := r.s.RegisterWorker("w1", -1, NewSecret()); err == nil {
		t.Fatal("a negative pid was accepted")
	}
}

func TestRegisteredWorkerPidConnectionIsNotEvictedByAPreHelloFlood(t *testing.T) {
	r := startRig(t, func(c *Config) { c.MaxPreHello = 2; c.MaxConns = 16 }, nil)
	r.register("w1") // registered pid is this process's: every dialed socket is "the worker's"
	first := r.dial()
	for i := 0; i < 6; i++ {
		_ = r.dial() // flood from the same pid, nothing sent
	}
	if first.closedWithin(300 * time.Millisecond) {
		t.Fatal("a pre-hello connection from the registered worker pid was evicted by the flood")
	}
}

// A worker that reconnects while an apply of its frames is in flight has been told (welcome) the wire seq the
// coordinator had committed BEFORE that apply, and numbers its next frames from it. The in-flight apply must
// not then commit the old session's frames: wire seq N of the new session is a different frame, so a
// stale commit would make the coordinator drop the new frame as a duplicate and lose its outbox op (the
// "gap in the outbox" stall seen in coord_worker.bats under load).
func TestAReconnectDuringAnInFlightApplyDoesNotCommitTheOldSessionsFrames(t *testing.T) {
	h := newHarness(t)
	g := newGate()
	t.Cleanup(g.open)
	h.s.cfg.Applier = g
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)
	flushed := make(chan struct{})
	go func() {
		h.s.mu.Lock()
		h.s.flushAll()
		h.s.mu.Unlock()
		close(flushed)
	}()
	<-g.entered
	hxConnect(h, "w1", 1) // the worker daemon restarted: a new session, welcome says wire seq 0
	g.open()
	select {
	case <-flushed:
	case <-time.After(3 * time.Second):
		t.Fatal("flush never finished")
	}
	if r := h.rec("j1"); r.WireSeq != 0 {
		t.Fatalf("the old session's wire seq 1 was committed after the worker was welcomed at 0 (WireSeq=%d)", r.WireSeq)
	}
	h.s.mu.Lock()
	d, err := h.s.adm.AckFor(workerproto.Frame{Job: workerproto.Str("j1"), Lease: workerproto.Str(lease), Epoch: workerproto.Int(epoch)})
	h.s.mu.Unlock()
	if err != nil || d.Seq != 0 {
		t.Fatalf("stream applied seq = %d (err %v), want 0", d.Seq, err)
	}
	// The new session's frame 1 is accepted, not dropped as a duplicate.
	h.event("j1", lease, epoch, 1, 2)
	h.flush()
	if r := h.rec("j1"); r.WireSeq != 1 {
		t.Fatalf("the new session's frame 1 was not committed (WireSeq=%d)", r.WireSeq)
	}
}
