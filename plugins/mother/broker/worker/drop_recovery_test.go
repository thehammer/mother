package worker

// The worker and the coordinator together while the connection keeps being dropped: the stuck-lease bug
// (a dropped connection, "send queue full; dropping the connection", after which the lease never
// reached `released`). A strict applier stands in for lib/coord_apply.sh: it applies only the next op
// in sequence and stops, with an error, at a gap in the outbox.

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"mother-broker/coord"
	"mother-broker/workerproto"
)

// strictApplier is coord_apply's contract: idempotent below its applied seq, one op at a time, a gap stops it.
type strictApplier struct {
	mu      sync.Mutex
	applied int64
	gaps    atomic.Int64
	ops     []int64
	delay   time.Duration // each apply takes this long (a script exec on a loaded host)
	failN   int           // every failN-th apply lands only a prefix and fails (a transient stop)
	calls   int
}

func (a *strictApplier) Apply(job string, ops [][]byte) (int64, error) {
	if a.delay > 0 {
		time.Sleep(a.delay)
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	a.calls++
	for i, o := range ops {
		if a.failN > 0 && a.calls%a.failN == 0 && i == len(ops)/2 {
			return a.applied, fmt.Errorf("coord_apply: op failed transiently; stopping")
		}
		var op struct {
			Seq int64 `json:"seq"`
		}
		_ = json.Unmarshal(o, &op)
		switch {
		case op.Seq <= a.applied:
		case op.Seq == a.applied+1:
			a.applied = op.Seq
			a.ops = append(a.ops, op.Seq)
		default:
			a.gaps.Add(1)
			return a.applied, fmt.Errorf("coord_apply: gap in the outbox: applied through seq %d, next op is seq %d; stopping", a.applied, op.Seq)
		}
	}
	return a.applied, nil
}

func (a *strictApplier) appliedSeq() int64 {
	a.mu.Lock()
	defer a.mu.Unlock()
	return a.applied
}

// startStrictPair is startPair with a strict applier and a coordinator send queue of queueLen frames.
func startStrictPair(t *testing.T, queueLen int) (*pair, *strictApplier) {
	t.Helper()
	var finished atomic.Bool
	logf := func(f string, a ...any) {
		if !finished.Load() {
			t.Logf(f, a...)
		}
	}
	app := &strictApplier{}
	p := &pair{root: shortTemp(t), wroot: shortTemp(t), secret: coord.NewSecret()}
	release, err := coord.Lock(p.root)
	if err != nil {
		t.Fatal(err)
	}
	p.s, err = coord.New(coord.Config{Root: p.root, Applier: app, PollEvery: 50 * time.Millisecond, FlushEvery: 20 * time.Millisecond,
		SendQueue: queueLen, Logf: logf})
	if err != nil {
		release()
		t.Fatal(err)
	}
	if err := p.s.RegisterWorker("w1", os.Getpid(), p.secret); err != nil {
		t.Fatal(err)
	}
	ln, err := coord.Listen(p.root)
	if err != nil {
		release()
		t.Fatal(err)
	}
	cctx, ccancel := context.WithCancel(context.Background())
	served := make(chan struct{})
	go func() { _ = p.s.Serve(cctx, ln); close(served) }()
	p.d, err = New(Config{ID: "w1", Root: p.wroot, CoordSock: coord.SocketPath(p.root), Slots: 1, Secret: p.secret,
		TermGrace: 300 * time.Millisecond, BackoffBase: 20 * time.Millisecond, BackoffMax: 50 * time.Millisecond, Logf: logf,
		SpawnCmd: func(string) (string, []string) { return "sleep", []string{"300"} }})
	if err != nil {
		t.Fatal(err)
	}
	wctx, wcancel := context.WithCancel(context.Background())
	p.cancel = wcancel
	ran := make(chan struct{})
	go func() { _ = p.d.Run(wctx); close(ran) }()
	t.Cleanup(func() {
		wcancel()
		<-ran
		p.d.mu.Lock()
		for _, l := range p.d.leases {
			if l.done != nil && !l.exited && l.pid > 0 {
				_ = syscallKillGroup(l.pid)
			}
		}
		p.d.mu.Unlock()
		ccancel()
		select {
		case <-served:
		case <-time.After(5 * time.Second):
			t.Error("coordinator did not stop")
		}
		p.s.Close()
		release()
		finished.Store(true)
	})
	return p, app
}

// leaseRecState is the coordinator's record of the job's lease (runner/leases/<job>.json).
func (p *pair) leaseRecState(job string) string {
	b, err := os.ReadFile(filepath.Join(p.root, "runner", "leases", job+".json"))
	if err != nil {
		return ""
	}
	var r struct {
		State string `json:"state"`
	}
	_ = json.Unmarshal(b, &r)
	return r.State
}

// produce appends ops (and log bytes) to the worker's outbox the way a supervisor would.
func produce(t *testing.T, wroot, job string, from, to int64) {
	t.Helper()
	f, err := os.OpenFile(filepath.Join(wroot, "outbox", job+".ndjson"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	lf, err := os.OpenFile(filepath.Join(wroot, "logs", job+".log"), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	defer lf.Close()
	for n := from; n <= to; n++ {
		line, _ := json.Marshal(map[string]any{"ts": "2026-11-11T12:00:00.000Z", "kind": "k", "detail": map[string]any{"n": n}})
		op, _ := json.Marshal(map[string]any{"seq": n, "t": workerproto.TypeEventAppend, "data": map[string]any{"line": string(line)}})
		if _, err := f.Write(append(op, '\n')); err != nil {
			t.Fatal(err)
		}
		if _, err := fmt.Fprintf(lf, "log line %d\n", n); err != nil {
			t.Fatal(err)
		}
	}
}

// dropConn closes the worker's current connection, as a coordinator-side drop would end it.
func (p *pair) dropConn() {
	p.d.mu.Lock()
	s := p.d.sess
	p.d.mu.Unlock()
	if s != nil {
		s.conn.Close()
	}
}

// A worker whose connection is dropped over and over while its supervisor keeps producing must still get
// every op applied once and, when the supervisor is done, its lease released.
func TestLeaseRecoversWhenTheConnectionIsDroppedRepeatedly(t *testing.T) {
	p, app := startStrictPair(t, 0)
	app.delay, app.failN = 30*time.Millisecond, 4
	p.dispatch(t, "j1")
	eventually(t, "the lease to be active", 10*time.Second, func() bool { return p.leaseRecState("j1") == "active" })
	const total = 600
	stop := make(chan struct{})
	var dropper sync.WaitGroup
	dropper.Add(1)
	go func() {
		defer dropper.Done()
		for {
			select {
			case <-stop:
				return
			case <-time.After(40 * time.Millisecond):
				p.dropConn()
			}
		}
	}()
	for n := int64(1); n <= total; n += 20 {
		produce(t, p.wroot, "j1", n, n+19)
		time.Sleep(15 * time.Millisecond)
	}
	close(stop)
	dropper.Wait()
	eventually(t, fmt.Sprintf("all %d ops to be applied (applied through %d, %d gap stops)", total, app.appliedSeq(), app.gaps.Load()),
		20*time.Second, func() bool { return app.appliedSeq() >= total })
	if g := app.gaps.Load(); g != 0 {
		t.Fatalf("%d applies stopped at a gap in the outbox", g)
	}
	// The supervisor finishes: the mirror says succeeded and the supervisor exits.
	if err := os.WriteFile(filepath.Join(p.wroot, "jobs", "j1.json"), []byte(`{"id":"j1","state":"succeeded"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	p.d.mu.Lock()
	l := p.d.leases["j1"]
	pid := l.pid
	p.d.mu.Unlock()
	_ = syscallKillGroup(pid)
	eventually(t, "the lease to be released", 20*time.Second, func() bool { return p.leaseRecState("j1") == "released" })
}

func syscallKillGroup(pid int) error {
	if pid <= 0 {
		return nil
	}
	_ = syscall.Kill(-pid, syscall.SIGKILL)
	return syscall.Kill(pid, syscall.SIGKILL)
}

// A coordinator whose per-connection send queue is tiny drops the connection itself ("send queue full"):
// the lease must still recover, whatever the cause of the drops.
func TestLeaseRecoversWhenTheCoordinatorDropsTheConnectionForAFullSendQueue(t *testing.T) {
	p, app := startStrictPair(t, 64)
	app.delay = 150 * time.Millisecond
	p.dispatch(t, "j1")
	eventually(t, "the lease to be active", 10*time.Second, func() bool { return p.leaseRecState("j1") == "active" })
	const total = 600
	for n := int64(1); n <= total; n += 100 {
		produce(t, p.wroot, "j1", n, n+99)
		time.Sleep(10 * time.Millisecond)
	}
	eventually(t, fmt.Sprintf("all %d ops to be applied (applied through %d, %d gap stops)", total, app.appliedSeq(), app.gaps.Load()),
		60*time.Second, func() bool { return app.appliedSeq() >= total })
	if g := app.gaps.Load(); g != 0 {
		t.Fatalf("%d applies stopped at a gap in the outbox", g)
	}
	if err := os.WriteFile(filepath.Join(p.wroot, "jobs", "j1.json"), []byte(`{"id":"j1","state":"succeeded"}`), 0o600); err != nil {
		t.Fatal(err)
	}
	p.d.mu.Lock()
	pid := p.d.leases["j1"].pid
	p.d.mu.Unlock()
	_ = syscallKillGroup(pid)
	eventually(t, "the lease to be released", 60*time.Second, func() bool { return p.leaseRecState("j1") == "released" })
}
