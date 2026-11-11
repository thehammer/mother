package coord

// The never-shed rules. The coordinator sheds acks and advisory refusals while a worker's send queue is more than
// half full (enqueueRedundant). Everything else the worker acts on must still be queued in that state, or the
// connection dropped, never silently skipped: a fencing refusal (the worker stops its supervisor on it), a command
// (hold, release, revoke, sync.job...) and the welcome (the resume positions). Each test below puts a peer that never
// reads in that state (queue between half and full) and asserts one class of frame still arrives.

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strings"
	"testing"
	"time"

	"mother-broker/workerproto"
)

const neverShedCap = 64 // the smallest queue the coordinator runs with (MinSendQueue)

// stuckConn is a worker connection whose peer never reads: nothing drains its send queue, so len(w.out) is exactly
// what has been queued. It is not registered; see registerStuck.
func stuckConn(h *harness, id string, qcap int) *workerConn {
	h.t.Helper()
	a, b := net.Pipe()
	h.t.Cleanup(func() { a.Close(); b.Close() })
	w := newWorkerConn(id, "i-"+id, 1, nil, a, h.now)
	w.out = make(chan []byte, qcap)
	return w
}

// fillTo queues filler frames (sync.file, which the coordinator would send anyway) until n frames are queued.
func fillTo(h *harness, w *workerConn, n int) {
	h.t.Helper()
	line := []byte(`{"t":"sync.file"}` + "\n")
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	for len(w.out) < n {
		h.s.enqueue(w, line)
	}
	if w.closed() {
		h.t.Fatalf("setup: the filler dropped the connection at %d frames", len(w.out))
	}
}

// registerStuck registers w as the worker's connection (displacing the previous one) and makes it the harness's
// current connection, so h.send speaks for it. It returns with the welcome and what register queued already in w.out.
func registerStuck(h *harness, w *workerConn) {
	h.t.Helper()
	h.s.mu.Lock()
	h.s.register(w, &workerproto.Welcome{Proto: 1})
	h.s.mu.Unlock()
	h.w = w
}

// drainQueue empties w's send queue and returns the decoded frames.
func drainQueue(h *harness, w *workerConn) []workerproto.Frame {
	h.t.Helper()
	var out []workerproto.Frame
	for {
		select {
		case b := <-w.out:
			f, err := workerproto.Decode(b)
			if err != nil {
				// the filler is not a real frame
				continue
			}
			out = append(out, f)
		default:
			return out
		}
	}
}

// wantFrame asserts that a frame of type t (and, for a refusal, code) was queued for w, or that the coordinator
// dropped the connection instead. A frame silently skipped fails.
func wantFrame(h *harness, w *workerConn, t, code string) {
	h.t.Helper()
	h.s.mu.Lock()
	dropped := w.closed()
	h.s.mu.Unlock()
	if dropped {
		return
	}
	for _, f := range drainQueue(h, w) {
		if f.T != t {
			continue
		}
		if code == "" {
			return
		}
		var r workerproto.Refuse
		_ = json.Unmarshal(f.Data, &r)
		if r.Code == code {
			return
		}
	}
	h.t.Fatalf("no %s %s frame was queued for a worker whose send queue was past half full, and its connection was not dropped: the frame was silently shed", t, code)
}

// pastHalf connects the lease's worker on a stuck connection whose queue is past half full and returns it.
func pastHalf(h *harness, id string) *workerConn {
	h.t.Helper()
	w := stuckConn(h, id, neverShedCap)
	registerStuck(h, w)
	drainQueue(h, w) // the welcome and sync files of the registration
	fillTo(h, w, neverShedCap*3/4)
	if len(w.out) <= cap(w.out)/2 {
		h.t.Fatalf("setup: queue at %d of %d is not past half", len(w.out), cap(w.out))
	}
	return w
}

func TestFencingRefusalsAreNeverShedWhileTheQueueIsPastHalf(t *testing.T) {
	// A frame of a stale lease epoch (fenced) and a frame for a job nobody leased (unknown_job).
	for _, tc := range []struct {
		name string
		code string
		send func(h *harness, lease string, epoch int64)
	}{
		{"fenced stream frame", workerproto.CodeFenced, func(h *harness, lease string, epoch int64) {
			j := "j1"
			h.event(j, lease, epoch+1, 1, 1)
		}},
		{"unknown_job stream frame", workerproto.CodeUnknownJob, func(h *harness, lease string, epoch int64) {
			h.event("nope", lease, epoch, 1, 1)
		}},
		{"fenced heartbeat entry", workerproto.CodeFenced, func(h *harness, lease string, epoch int64) {
			h.send(workerproto.TypeHb, nil, nil, nil, nil, workerproto.Hb{Jobs: []workerproto.HbJob{{Job: "j1", Lease: lease, Epoch: epoch + 1}}})
		}},
		{"unknown_job heartbeat entry", workerproto.CodeUnknownJob, func(h *harness, lease string, epoch int64) {
			h.send(workerproto.TypeHb, nil, nil, nil, nil, workerproto.Hb{Jobs: []workerproto.HbJob{{Job: "nope", Lease: lease, Epoch: epoch}}})
		}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			h := newHarness(t)
			hxConnect(h, "w1", 1)
			lease, epoch := leaseWaiting(h, "j1")
			w := pastHalf(h, "w1")
			tc.send(h, lease, epoch)
			wantFrame(h, w, workerproto.TypeRefuse, tc.code)
		})
	}
}

func TestNotLeasedRefusalIsNeverShedWhileTheQueueIsPastHalf(t *testing.T) {
	for _, hb := range []bool{false, true} {
		name := "stream frame"
		if hb {
			name = "heartbeat entry"
		}
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			hxConnect(h, "w2", 1)
			lease2, epoch2 := leaseWaiting(h, "j2") // leased to w2
			hxConnect(h, "w1", 1)
			leaseWaiting(h, "j1")
			w := pastHalf(h, "w1")
			// w1 speaks for j2's lease, which w2 holds.
			if hb {
				h.send(workerproto.TypeHb, nil, nil, nil, nil, workerproto.Hb{Jobs: []workerproto.HbJob{{Job: "j2", Lease: lease2, Epoch: epoch2}}})
			} else {
				h.event("j2", lease2, epoch2, 1, 1)
			}
			wantFrame(h, w, workerproto.TypeRefuse, workerproto.CodeNotLeased)
		})
	}
}

func TestACommandIsNeverShedWhileTheQueueIsPastHalf(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	leaseWaiting(h, "j1")
	w := pastHalf(h, "w1")
	h.s.mu.Lock()
	err := h.s.queueCmd(h.s.jobs["j1"], workerproto.TypeHold, workerproto.Hold{CmdID: "c-hold", Code: "limiter", Reason: "test"})
	h.s.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	wantFrame(h, w, workerproto.TypeHold, "")
}

func TestARedeliveredCommandIsNeverShedWhileTheQueueIsPastHalf(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	leaseWaiting(h, "j1")
	h.s.mu.Lock()
	err := h.s.queueCmd(h.s.jobs["j1"], workerproto.TypeHold, workerproto.Hold{CmdID: "c-hold", Code: "limiter", Reason: "test"})
	h.s.mu.Unlock()
	if err != nil {
		t.Fatal(err)
	}
	// The worker reconnects with a queue that is already past half full (the registration itself finds it so):
	// the unacked hold must be redelivered.
	w := stuckConn(h, "w1", neverShedCap)
	fillTo(h, w, neverShedCap*3/4)
	registerStuck(h, w)
	wantFrame(h, w, workerproto.TypeHold, "")
}

func TestTheWelcomeIsNeverShedWhileTheQueueIsPastHalf(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	leaseWaiting(h, "j1")
	w := stuckConn(h, "w1", neverShedCap)
	fillTo(h, w, neverShedCap*3/4)
	registerStuck(h, w)
	wantFrame(h, w, workerproto.TypeWelcome, "")
}

// The clamp: a queue of 1 or 2 frames cannot hold a welcome, so a coordinator configured with one would drop every
// connection it accepted; the shedding threshold (half the capacity) would also be 0, so every ack would be shed.
func TestASendQueueBelowTheMinimumIsRaisedToIt(t *testing.T) {
	for _, tc := range []struct{ in, want int }{
		{0, 0}, // unset: handleConn keeps the 4096 default
		{1, MinSendQueue},
		{2, MinSendQueue},
		{MinSendQueue - 1, MinSendQueue},
		{MinSendQueue, MinSendQueue},
		{100, 100},
	} {
		s, err := New(Config{Root: t.TempDir(), SendQueue: tc.in})
		if err != nil {
			t.Fatal(err)
		}
		if s.cfg.SendQueue != tc.want {
			t.Errorf("SendQueue %d: got %d, want %d", tc.in, s.cfg.SendQueue, tc.want)
		}
		s.Close()
	}
}

// tests/coord_worker.bats greps the coordinator log for "send queue full (" to flag a dropped connection in its
// failure dump. This pins the real line (it carries the queue profile in parentheses) so that grep cannot go stale again.
func TestTheDropLogLineMatchesWhatCoordWorkerBatsGreps(t *testing.T) {
	h := newHarness(t)
	var lines []string
	h.s.cfg.Logf = func(f string, a ...any) { lines = append(lines, fmt.Sprintf(f, a...)) }
	w := stuckConn(h, "w1", neverShedCap)
	h.s.mu.Lock()
	for i := 0; i < neverShedCap+1; i++ {
		h.s.enqueue(w, []byte(`{"t":"sync.file"}`+"\n"))
	}
	h.s.mu.Unlock()
	if !w.closed() {
		t.Fatal("overflowing the queue did not drop the connection")
	}
	var got string
	for _, l := range lines {
		if strings.Contains(l, "send queue full (") {
			got = l
		}
	}
	if !strings.Contains(got, "worker w1: send queue full (") || !strings.HasSuffix(got, "); dropping the connection") {
		t.Fatalf("the drop log line changed (update the grep in tests/coord_worker.bats _cw_dump): %q", lines)
	}
}

// leaseWaiting is harness.lease, but it waits for the offer instead of reading until the pipe has been quiet for
// 150ms, which a loaded host does not always meet.
func leaseWaiting(h *harness, job string) (leaseID string, epoch int64) {
	h.t.Helper()
	h.writeJob(job, nil)
	if err := os.WriteFile(h.s.dispatchPath(job), []byte(`{"job":"`+job+`"}`), 0o644); err != nil {
		h.t.Fatal(err)
	}
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	var offer *workerproto.Frame
	for deadline := time.Now().Add(10 * time.Second); offer == nil && time.Now().Before(deadline); {
		for _, f := range ofType(h.frames(), workerproto.TypeLeaseOffer) {
			f := f
			offer = &f
		}
	}
	if offer == nil {
		h.t.Fatal("no lease.offer arrived within 10s")
	}
	var o struct {
		CmdID string `json:"cmd_id"`
	}
	_ = json.Unmarshal(offer.Data, &o)
	h.send(workerproto.TypeCmdAck, offer.Job, offer.Lease, offer.Epoch, nil, map[string]any{"cmd_id": o.CmdID, "outcome": "applied", "for": "lease.offer"})
	return *offer.Lease, *offer.Epoch
}
