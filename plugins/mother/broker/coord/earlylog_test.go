package coord

import (
	"encoding/base64"
	"os"
	"testing"
	"time"

	"mother-broker/workerproto"
)

// blockingApplier holds every Apply until released, like a coord_apply exec that takes seconds.
type blockingApplier struct {
	fakeApplier
	entered chan struct{}
	release chan struct{}
}

func (b *blockingApplier) Apply(job string, ops [][]byte) (int64, error) {
	b.entered <- struct{}{}
	<-b.release
	return b.fakeApplier.Apply(job, ops)
}

// The banner and first output must reach the canonical log while the ops ahead of them are still being
// applied (dispatch latency): the chunk is written by offset, then reached again in order without a duplicate.
func TestLogChunkIsWrittenWhileEarlierOpsAreStillApplying(t *testing.T) {
	h := newHarness(t)
	ba := &blockingApplier{entered: make(chan struct{}, 4), release: make(chan struct{})}
	h.s.cfg.Applier = ba
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)
	seq := int64(2)
	h.send(workerproto.TypeLogAppend, strp("j1"), &lease, &epoch, &seq, map[string]any{"offset": 0, "b64": base64.StdEncoding.EncodeToString([]byte("=== banner\n"))})

	done := make(chan struct{})
	go func() { h.flush(); close(done) }()
	select {
	case <-ba.entered:
	case <-time.After(5 * time.Second):
		t.Fatal("the applier was never called")
	}
	// The apply is blocked: the log must already be there.
	b, _ := os.ReadFile(h.s.logPath("j1"))
	if string(b) != "=== banner\n" {
		t.Fatalf("log while the earlier op is applying = %q", b)
	}
	// A later flush tick during the apply writes newly arrived chunks too.
	seq = 3
	h.send(workerproto.TypeLogAppend, strp("j1"), &lease, &epoch, &seq, map[string]any{"offset": 11, "b64": base64.StdEncoding.EncodeToString([]byte("more\n"))})
	h.flush()
	b, _ = os.ReadFile(h.s.logPath("j1"))
	if string(b) != "=== banner\nmore\n" {
		t.Fatalf("log after a second chunk during the apply = %q", b)
	}
	close(ba.release)
	<-done
	h.flush()
	b, _ = os.ReadFile(h.s.logPath("j1"))
	if string(b) != "=== banner\nmore\n" {
		t.Fatalf("log duplicated or changed once the ops were applied: %q", b)
	}
	if r := h.rec("j1"); r.WireSeq != 3 {
		t.Fatalf("frames not committed in order afterwards: %+v", r)
	}
}

// A chunk behind a gap is never written early (the in-order path reports the gap).
func TestEarlyLogNeverWritesPastAGap(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	seq := int64(1)
	h.send(workerproto.TypeLogAppend, strp("j1"), &lease, &epoch, &seq, map[string]any{"offset": 50, "b64": base64.StdEncoding.EncodeToString([]byte("late"))})
	h.s.mu.Lock()
	h.s.writeEarlyLogs(h.s.jobs["j1"])
	h.s.mu.Unlock()
	if b, _ := os.ReadFile(h.s.logPath("j1")); len(b) != 0 {
		t.Fatalf("wrote past a gap: %q", b)
	}
}

// A worker retransmitting its window while a slow apply runs must not draw one ack per frame: the queue to the
// worker is bounded (4096) and was overflowed, dropping the connection in a loop, at five concurrent jobs.
func TestDuplicateFramesAreReAckedOncePerFlush(t *testing.T) {
	h := newHarness(t)
	h.connect("w1", 1)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)
	h.flush()
	_ = h.frames()
	for i := 0; i < 500; i++ {
		h.event("j1", lease, epoch, 1, 1) // duplicates
	}
	if n := len(ofType(h.frames(), workerproto.TypeAck)); n != 0 {
		t.Fatalf("%d acks were sent before the flush tick; they are owed, not sent per frame", n)
	}
	h.flush()
	if n := len(ofType(h.frames(), workerproto.TypeAck)); n != 1 {
		t.Fatalf("%d re-acks for 500 duplicates in one tick, want exactly 1", n)
	}
}
