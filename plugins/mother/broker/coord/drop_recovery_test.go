package coord

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"testing"

	"mother-broker/workerproto"
)

// A connection the coordinator drops for a full send queue leaves the lease live; when the worker is back
// the welcome resumes it at the committed positions, the new session's next frame is applied, and one
// coordinator log line says which leases recovered.
func TestLeaseResumesAfterTheCoordinatorDropsAFullQueueAndLogsTheRecovery(t *testing.T) {
	h := newHarness(t)
	var mu sync.Mutex
	var logs []string
	h.s.cfg.Logf = func(f string, a ...any) {
		mu.Lock()
		defer mu.Unlock()
		logs = append(logs, strings.TrimSpace(fmt.Sprintf(f, a...)))
	}
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)
	h.flush()
	if r := h.rec("j1"); r.AppliedSeq != 1 || r.WireSeq != 1 {
		t.Fatalf("setup: %+v", r)
	}
	old := h.w

	// Nothing reads from the worker any more: pile frames up until the coordinator gives up on it.
	h.s.mu.Lock()
	line := []byte(`{"t":"sync.file"}` + "\n")
	for i := 0; i < 20000 && !old.closed(); i++ {
		h.s.enqueue(old, line)
	}
	h.s.mu.Unlock()
	if !old.closed() {
		t.Fatal("the full queue did not drop the connection")
	}
	if st := h.rec("j1").State; st != "active" {
		t.Fatalf("dropping the connection ended the lease: %s", st)
	}

	// The worker comes back (same id): welcome resumes the lease where the coordinator committed.
	hxConnect(h, "w1", 1)
	welcomes := ofType(h.frames(), workerproto.TypeWelcome)
	if len(welcomes) != 1 {
		t.Fatalf("want one welcome, got %d", len(welcomes))
	}
	var w workerproto.Welcome
	_ = json.Unmarshal(welcomes[0].Data, &w)
	if len(w.Jobs) != 1 || w.Jobs[0].Job != "j1" || w.Jobs[0].Lease != lease || w.Jobs[0].WireSeq != 1 || w.Jobs[0].AppliedSeq != 1 {
		t.Fatalf("welcome does not resume the lease at wire 1 / applied 1: %+v", w.Jobs)
	}
	// The new session's next frame is applied.
	h.event("j1", lease, epoch, 2, 2)
	h.flush()
	if r := h.rec("j1"); r.AppliedSeq != 2 || r.WireSeq != 2 {
		t.Fatalf("the lease did not progress after the reconnect: %+v", r)
	}
	mu.Lock()
	defer mu.Unlock()
	var got string
	for _, l := range logs {
		if strings.Contains(l, "leases recovered") {
			got = l
		}
	}
	if !strings.Contains(got, "worker w1: reconnected") || !strings.Contains(got, "send queue full") || !strings.Contains(got, "j1@e1(wire 1, applied 1)") {
		t.Fatalf("no recovery line naming the lease; logs: %q", logs)
	}
	if n := strings.Count(strings.Join(logs, "\n"), "leases recovered"); n != 1 {
		t.Fatalf("%d recovery lines, want 1", n)
	}
}

// Acks and advisory refusals are redundant (an ack is cumulative, a refusal is repeated by the next bad frame):
// a worker that reads slowly must never be dropped for them, and the ack it is owed must still arrive once it
// reads again. Dropping the connection for redundant frames is what turned a slow reader into a reconnect loop.
func TestRedundantFramesAreShedNotDroppedForASlowReader(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)
	h.flush()
	h.frames() // drain what the setup queued; from here the peer reads nothing until told to

	w := h.w
	anchor := workerproto.Frame{Job: workerproto.Str("j1"), Lease: workerproto.Str(lease), Epoch: workerproto.Int(epoch)}
	h.s.mu.Lock()
	jl := h.s.jobs["j1"]
	for i := 0; i < 3*cap(w.out); i++ {
		h.s.sendAck(w, jl, anchor)
		h.s.sendRefuse(w, &anchor, workerproto.CodeTooLarge)
	}
	closed, queued, owed := w.closed(), len(w.out), jl.ackAnchor != nil
	h.s.mu.Unlock()
	if closed {
		t.Fatal("redundant acks and refusals dropped the connection of a slow reader")
	}
	if queued > cap(w.out)/2 {
		t.Fatalf("%d redundant frames queued (cap %d): they are not shed", queued, cap(w.out))
	}
	if !owed {
		t.Fatal("the shed ack is not owed any more: the worker would never learn the committed position")
	}

	// The worker reads again: the owed ack is sent on the next flush.
	h.frames()
	h.flush()
	var acks []workerproto.Frame
	for _, f := range h.frames() {
		if f.T == workerproto.TypeAck {
			acks = append(acks, f)
		}
	}
	if len(acks) == 0 {
		t.Fatal("the owed ack never arrived once the worker read again")
	}
}
