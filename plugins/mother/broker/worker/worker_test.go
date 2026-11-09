package worker

import (
	"bufio"
	"encoding/json"
	"net"
	"os"
	"path/filepath"
	"sync"
	"syscall"
	"testing"
	"time"

	"mother-broker/workerproto"
)

type capture struct {
	mu     sync.Mutex
	frames []workerproto.Frame
}

func (c *capture) all() []workerproto.Frame {
	c.mu.Lock()
	defer c.mu.Unlock()
	return append([]workerproto.Frame(nil), c.frames...)
}

func (c *capture) wait(t *testing.T, n int) []workerproto.Frame {
	t.Helper()
	for i := 0; i < 100; i++ {
		if fs := c.all(); len(fs) >= n {
			return fs
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("wanted %d frames, got %d", n, len(c.all()))
	return nil
}

func newDaemon(t *testing.T) (*Daemon, *session, *capture) {
	t.Helper()
	root := t.TempDir()
	d, err := New(Config{ID: "w1", Root: root, Slots: 2, SpawnCmd: func(string) (string, []string) { return "sleep", []string{"60"} }, Logf: t.Logf})
	if err != nil {
		t.Fatal(err)
	}
	a, b := net.Pipe()
	t.Cleanup(func() { a.Close(); b.Close() })
	c := &capture{}
	go func() {
		br := bufio.NewReader(b)
		for {
			line, err := workerproto.ReadFrame(br)
			if err != nil {
				return
			}
			f, err := workerproto.Decode(line)
			if err != nil {
				continue
			}
			c.mu.Lock()
			c.frames = append(c.frames, f)
			c.mu.Unlock()
		}
	}()
	return d, &session{d: d, conn: a}, c
}

func cmdFrame(t *testing.T, typ, job, leaseID string, epoch int64, data map[string]any) workerproto.Frame {
	t.Helper()
	f, err := workerproto.NewFrame(typ, newFrameID(), time.Now(), data)
	if err != nil {
		t.Fatal(err)
	}
	f.Job, f.Lease, f.Epoch = &job, &leaseID, &epoch
	return f
}

func (d *Daemon) offerFor(t *testing.T, s *session, job string, epoch int64) {
	t.Helper()
	doc, _ := json.Marshal(map[string]any{"id": job, "state": "running", "plan_path": "/canonical/p", "log_path": "/canonical/l"})
	f := cmdFrame(t, workerproto.TypeLeaseOffer, job, "L-"+job, epoch, map[string]any{
		"cmd_id": "offer-" + job, "job_doc": json.RawMessage(doc), "plan": "# plan", "repo": "o/r", "attempt": 1})
	d.mu.Lock()
	d.handleCommand(s, f)
	d.mu.Unlock()
}

func outcomeOf(t *testing.T, f workerproto.Frame) string {
	t.Helper()
	var a workerproto.CmdAck
	_ = json.Unmarshal(f.Data, &a)
	return a.Outcome
}

func TestOfferWritesMirrorSpawnsAndFenceKillsTheChild(t *testing.T) {
	d, s, c := newDaemon(t)
	d.offerFor(t, s, "j1", 1)
	fs := c.wait(t, 1)
	if fs[0].T != workerproto.TypeCmdAck || outcomeOf(t, fs[0]) != workerproto.OutcomeApplied {
		t.Fatalf("offer not acked applied: %s %s", fs[0].T, fs[0].Data)
	}
	// The mirror carries the job doc with plan/log paths pointed into the worker root, and the plan.
	var doc map[string]any
	b, _ := os.ReadFile(d.p("jobs", "j1.json"))
	_ = json.Unmarshal(b, &doc)
	if doc["plan_path"] != d.p("events", "j1-plan.md") || doc["log_path"] != d.p("logs", "j1.log") {
		t.Fatalf("mirror paths not rewritten: %v", doc)
	}
	if p, _ := os.ReadFile(d.p("events", "j1-plan.md")); string(p) != "# plan" {
		t.Fatalf("plan = %q", p)
	}
	d.mu.Lock()
	l := d.leases["j1"]
	pid, done := l.pid, l.done
	d.mu.Unlock()
	if pid <= 0 {
		t.Fatal("no supervisor was spawned")
	}
	if _, err := os.Stat(d.p("children", itoa(int64(pid))+".json")); err != nil {
		t.Fatalf("child not tracked: %v", err)
	}
	if err := syscall.Kill(pid, 0); err != nil {
		t.Fatalf("supervisor not running: %v", err)
	}

	// refuse{fenced} for the lease: the supervisor is terminated and the lease marked fenced.
	rf := cmdFrame(t, workerproto.TypeRefuse, "j1", "L-j1", 1, map[string]any{"code": "fenced", "msg": "x"})
	rf.T = workerproto.TypeRefuse
	d.mu.Lock()
	d.handleFrame(s, rf)
	state := d.leases["j1"].loc.State
	d.mu.Unlock()
	if state != stateFenced {
		t.Fatalf("lease state %q, want fenced", state)
	}
	select {
	case <-done:
	case <-time.After(12 * time.Second):
		t.Fatal("the supervisor survived a fence")
	}
	var loc localLease
	b, _ = os.ReadFile(d.leasePath("j1"))
	_ = json.Unmarshal(b, &loc)
	if loc.State != stateFenced {
		t.Fatalf("persisted lease state %q", loc.State)
	}
}

func TestCommandsAreDedupedAndTheSetSurvivesARestart(t *testing.T) {
	d, s, c := newDaemon(t)
	d.offerFor(t, s, "j1", 1)
	hold := func() {
		d.mu.Lock()
		d.handleCommand(s, cmdFrame(t, workerproto.TypeHold, "j1", "L-j1", 1, map[string]any{"cmd_id": "hold-1", "code": "backoff", "reason": "r"}))
		d.mu.Unlock()
	}
	hold()
	if err := os.Remove(d.p("runner", "j1.hold")); err != nil {
		t.Fatalf("hold not written: %v", err)
	}
	hold() // redelivery: must not be applied again
	if _, err := os.Stat(d.p("runner", "j1.hold")); err == nil {
		t.Fatal("a redelivered command was applied twice")
	}
	fs := c.wait(t, 3)
	if outcomeOf(t, fs[1]) != workerproto.OutcomeApplied || outcomeOf(t, fs[2]) != workerproto.OutcomeDuplicate {
		t.Fatalf("outcomes %s then %s", outcomeOf(t, fs[1]), outcomeOf(t, fs[2]))
	}
	// A fresh process reads applied-cmds.json: the same cmd_id is still a duplicate.
	d2, err := New(Config{ID: "w1", Root: d.cfg.Root, Logf: t.Logf})
	if err != nil {
		t.Fatal(err)
	}
	if !d2.dedupe.Seen("hold-1") {
		t.Fatal("dedupe set was not persisted")
	}
}

func writeOutbox(t *testing.T, d *Daemon, job string, ops ...string) {
	t.Helper()
	var b []byte
	for _, o := range ops {
		b = append(b, o...)
		b = append(b, '\n')
	}
	if err := os.WriteFile(d.p("outbox", job+".ndjson"), b, 0o644); err != nil {
		t.Fatal(err)
	}
}

func evOp(seq int) string {
	line, _ := json.Marshal(map[string]any{"ts": "2026-11-08T12:00:00.000Z", "kind": "k", "detail": map[string]any{"n": seq}})
	b, _ := json.Marshal(map[string]any{"seq": seq, "t": "event.append", "ts": "2026-11-08T12:00:00.000Z", "data": map[string]any{"line": string(line)}})
	return string(b)
}

func activeLease(t *testing.T, d *Daemon, job string) *lease {
	t.Helper()
	l := &lease{loc: localLease{Job: job, LeaseID: "L-" + job, Epoch: 1, State: stateActive}, exited: true, adoptedDead: true}
	d.mu.Lock()
	d.leases[job] = l
	d.mu.Unlock()
	return l
}

func TestShippingResumesFromTheCoordinatorsPosition(t *testing.T) {
	d, s, c := newDaemon(t)
	l := activeLease(t, d, "j1")
	l.exited = false // supervisor still running: no release
	writeOutbox(t, d, "j1", evOp(1), evOp(2), evOp(3))
	if err := os.WriteFile(d.p("logs", "j1.log"), []byte("abcdef"), 0o644); err != nil {
		t.Fatal(err)
	}
	// The coordinator applied op 1, committed wire seq 7 and holds 2 log bytes.
	d.mu.Lock()
	d.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1, AppliedSeq: 1, WireSeq: 7, LogOffset: 2}})
	d.shipLease(s, l)
	d.mu.Unlock()
	fs := c.wait(t, 3)
	var wantSeq = []int64{8, 9, 10}
	for i, f := range fs[:3] {
		if f.Seq == nil || *f.Seq != wantSeq[i] {
			t.Fatalf("frame %d (%s) seq %v, want %d", i, f.T, f.Seq, wantSeq[i])
		}
	}
	if fs[0].T != workerproto.TypeEventAppend || fs[2].T != workerproto.TypeLogAppend {
		t.Fatalf("frame types %s %s %s", fs[0].T, fs[1].T, fs[2].T)
	}
	var d0 map[string]json.RawMessage
	_ = json.Unmarshal(fs[0].Data, &d0)
	if string(d0["oseq"]) != "2" {
		t.Fatalf("first shipped op carries oseq %s, want 2", d0["oseq"])
	}
	var la workerproto.LogAppend
	_ = json.Unmarshal(fs[2].Data, &la)
	if la.Offset != 2 {
		t.Fatalf("log chunk offset %d, want 2", la.Offset)
	}
}

func TestReleaseOnlyAfterDrainedAndAcked(t *testing.T) {
	d, s, c := newDaemon(t)
	l := activeLease(t, d, "j1")
	l.adoptedDead = false
	writeOutbox(t, d, "j1", evOp(1))
	if err := os.WriteFile(d.p("jobs", "j1.json"), []byte(`{"id":"j1","state":"succeeded"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	d.mu.Lock()
	d.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1}})
	d.shipLease(s, l) // sends op 1, but it is unacked: no release yet
	d.mu.Unlock()
	fs := c.wait(t, 1)
	time.Sleep(100 * time.Millisecond)
	if len(c.all()) != 1 {
		t.Fatalf("release sent before the window drained: %d frames", len(c.all()))
	}
	ack := cmdFrame(t, workerproto.TypeAck, "j1", "L-j1", 1, map[string]any{"job": "j1", "lease": "L-j1", "epoch": 1, "seq": *fs[0].Seq})
	d.mu.Lock()
	d.onAck(s, ack)
	d.shipLease(s, l)
	d.mu.Unlock()
	fs = c.wait(t, 2)
	if fs[1].T != workerproto.TypeLeaseRelease {
		t.Fatalf("second frame is %s, want lease.release", fs[1].T)
	}
	var lr workerproto.LeaseRelease
	_ = json.Unmarshal(fs[1].Data, &lr)
	if lr.Reason != "succeeded" {
		t.Fatalf("release reason %q", lr.Reason)
	}
	// Its ack ends the lease locally.
	ack2 := cmdFrame(t, workerproto.TypeAck, "j1", "L-j1", 1, map[string]any{"job": "j1", "lease": "L-j1", "epoch": 1, "seq": *fs[1].Seq})
	d.mu.Lock()
	d.onAck(s, ack2)
	st := l.loc.State
	d.mu.Unlock()
	if st != stateReleased {
		t.Fatalf("lease state %q after the release ack", st)
	}
}

func TestReleaseIsWithheldWhenTheSupervisorDiedMidRun(t *testing.T) {
	d, s, c := newDaemon(t)
	l := activeLease(t, d, "j1")
	if err := os.WriteFile(d.p("jobs", "j1.json"), []byte(`{"id":"j1","state":"running"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	d.mu.Lock()
	d.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1}})
	d.shipLease(s, l)
	noHB := l.noHB
	d.mu.Unlock()
	time.Sleep(100 * time.Millisecond)
	if len(c.all()) != 0 || !noHB {
		t.Fatalf("a dead supervisor with state running must not release (frames %d, noHB %v)", len(c.all()), noHB)
	}
}

func TestOutboxOpsWithOnlyRefusedKeysAreSkippedAndCarriedAsOskip(t *testing.T) {
	d, s, c := newDaemon(t)
	l := activeLease(t, d, "j1")
	l.exited = false
	jobset := func(seq int, set string) string {
		return `{"seq":` + itoa(int64(seq)) + `,"t":"job.set","ts":"2026-11-08T12:00:00.000Z","data":{"set":` + set + `,"del":[]}}`
	}
	writeOutbox(t, d, "j1",
		jobset(1, `{"activity":"a","pr_url":"https://x"}`), // pr_url dropped, activity kept
		jobset(2, `{"finished_at":"2026-11-08T12:00:00.000Z"}`),
		jobset(3, `{"state":"succeeded"}`),
		evOp(4))
	d.mu.Lock()
	d.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1}})
	d.shipLease(s, l)
	d.mu.Unlock()
	fs := c.wait(t, 2)
	var first, second map[string]json.RawMessage
	_ = json.Unmarshal(fs[0].Data, &first)
	_ = json.Unmarshal(fs[1].Data, &second)
	if string(first["oseq"]) != "1" || len(first["set"]) == 0 || string(first["set"]) != `{"activity":"a"}` {
		t.Fatalf("first frame data %s", fs[0].Data)
	}
	if string(second["oseq"]) != "4" || string(second["oskip"]) != "[2,3]" {
		t.Fatalf("second frame data %s", fs[1].Data)
	}
	for _, f := range fs {
		if err := workerproto.ValidateFrom(workerproto.FromWorker, f); err != nil {
			t.Fatalf("a shipped frame fails the wire validation: %v", err)
		}
	}
}

func TestReadoptionKeepsALiveSupervisorAndFlagsADeadOne(t *testing.T) {
	d, _, _ := newDaemon(t)
	writeLease := func(job string) {
		b, _ := json.Marshal(localLease{Job: job, LeaseID: "L-" + job, Epoch: 1, State: stateActive})
		_ = os.WriteFile(d.leasePath(job), b, 0o644)
	}
	writeLease("alive")
	writeLease("dead")
	child, err := startSleep()
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = child.Process.Kill(); _ = child.Wait() }()
	b, _ := json.Marshal(childEntry{PID: child.Process.Pid, JobID: "alive"})
	_ = os.WriteFile(filepath.Join(d.p("children"), itoa(int64(child.Process.Pid))+".json"), b, 0o644)
	b, _ = json.Marshal(childEntry{PID: 999999, JobID: "dead"})
	_ = os.WriteFile(filepath.Join(d.p("children"), "999999.json"), b, 0o644)

	d.loadLeases()
	d.cfg.SpawnCmd = func(string) (string, []string) { return "sleep", []string{"60"} } // a stand-in counts as a supervisor
	d.adopt()
	d.mu.Lock()
	defer d.mu.Unlock()
	if l := d.leases["alive"]; l.pid != child.Process.Pid || !l.adopted || l.exited {
		t.Fatalf("live supervisor not re-adopted: %+v", l)
	}
	if l := d.leases["dead"]; !l.exited || !l.adoptedDead {
		t.Fatalf("dead supervisor not flagged: %+v", l)
	}
}
