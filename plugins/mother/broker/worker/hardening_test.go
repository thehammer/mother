package worker

// Hardening tests for the worker daemon (PR #120 review fix-ups): what a fenced supervisor leaves behind,
// what the supervisor's environment carries, what happens to an outbox op that cannot be shipped, and the
// worker/coordinator pair agreeing on identity.

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"mother-broker/coord"
	"mother-broker/workerproto"
)

// newDaemonWith is newDaemon with a configurable Config. Every supervisor it started is killed (by exact
// process group) when the test ends.
func newDaemonWith(t *testing.T, mut func(*Config)) (*Daemon, *session, *capture) {
	t.Helper()
	var finished atomic.Bool
	t.Cleanup(func() { finished.Store(true) })
	cfg := Config{ID: "w1", Root: t.TempDir(), Slots: 2, SpawnCmd: func(string) (string, []string) { return "sleep", []string{"60"} },
		Logf: func(f string, a ...any) {
			if !finished.Load() {
				t.Logf(f, a...)
			}
		}}
	if mut != nil {
		mut(&cfg)
	}
	d, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	a, b := net.Pipe()
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
	t.Cleanup(func() { a.Close(); b.Close() })
	t.Cleanup(func() {
		d.mu.Lock()
		defer d.mu.Unlock()
		for _, l := range d.leases {
			if l.done != nil && !l.exited && l.pid > 0 { // our own child, started in its own group
				_ = syscall.Kill(-l.pid, syscall.SIGKILL)
				_ = syscall.Kill(l.pid, syscall.SIGKILL)
			}
		}
	})
	return d, &session{d: d, conn: a}, c
}

func eventually(t *testing.T, what string, d time.Duration, cond func() bool) {
	t.Helper()
	deadline := time.Now().Add(d)
	for !cond() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", what)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

func gone(pid int) bool { return syscall.Kill(pid, 0) == syscall.ESRCH }

func readPid(path string) int {
	b, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	n, _ := strconv.Atoi(strings.TrimSpace(string(b)))
	return n
}

// ---------------------------------------------------------------------------------------------------
// the supervisor's environment
// ---------------------------------------------------------------------------------------------------

func TestScrubbedEnvNeverCarriesTheWorkerSecret(t *testing.T) {
	const envSecret, cfgSecret = "env-secret-value-0123456789", "config-secret-value-0123456789"
	t.Setenv("MOTHER_WORKER_SECRET", envSecret)
	t.Setenv("MOTHER_WORKER_SECRET_FD", "3")
	t.Setenv("MOTHER_LIVE_ROOT", "/canonical/live")
	t.Setenv("MOTHER_ROOT", "/canonical/root")
	t.Setenv("MOTHER_JOB_ID", "someone-elses-job")
	t.Setenv("HX_KEEP", "kept")
	d, _, _ := newDaemonWith(t, func(c *Config) { c.Secret = cfgSecret })
	env := d.scrubbedEnv("EXTRA=1")

	roots := 0
	seen := map[string]string{}
	for _, kv := range env {
		k, v, _ := strings.Cut(kv, "=")
		seen[k] = v
		if strings.Contains(kv, envSecret) || strings.Contains(kv, cfgSecret) {
			t.Fatalf("a secret value is in the environment: %q", k)
		}
		if k == "MOTHER_WORKER_SECRET" || k == "MOTHER_WORKER_SECRET_FD" {
			t.Fatalf("%s is passed on to the supervisor", k)
		}
		if k == "MOTHER_ROOT" {
			roots++
		}
	}
	if roots != 1 || seen["MOTHER_ROOT"] != d.cfg.Root {
		t.Fatalf("MOTHER_ROOT must appear once, as the worker root: %d times, %q", roots, seen["MOTHER_ROOT"])
	}
	if _, ok := seen["MOTHER_LIVE_ROOT"]; ok {
		t.Fatal("MOTHER_LIVE_ROOT leaked a canonical path into the worker environment")
	}
	if _, ok := seen["MOTHER_JOB_ID"]; ok {
		t.Fatal("MOTHER_JOB_ID leaked")
	}
	if seen["MOTHER_WORKER_MODE"] != "1" || seen["HX_KEEP"] != "kept" || seen["EXTRA"] != "1" || seen["MOTHER_WORKER_OUTBOX_DIR"] != d.p("outbox") {
		t.Fatalf("the worker's own variables are missing or the inherited ones were lost: %v", seen)
	}
}

func TestSupervisorIsStartedWithoutTheWorkerSecretInItsEnvironment(t *testing.T) {
	const secret = "stub-secret-value-0123456789"
	t.Setenv("MOTHER_WORKER_SECRET", secret)
	t.Setenv("MOTHER_WORKER_SECRET_FD", "3")
	dump := filepath.Join(t.TempDir(), "env.txt")
	d, s, c := newDaemonWith(t, func(cfg *Config) {
		cfg.Secret = secret
		cfg.SpawnCmd = func(string) (string, []string) { return "sh", []string{"-c", "env > '" + dump + "'; sleep 60"} }
	})
	d.offerFor(t, s, "j1", 1)
	c.wait(t, 1)
	var env string
	eventually(t, "the stub supervisor to dump its environment", 5*time.Second, func() bool {
		b, _ := os.ReadFile(dump)
		env = string(b)
		return strings.Contains(env, "MOTHER_LEASE_EPOCH=")
	})
	if strings.Contains(env, "MOTHER_WORKER_SECRET") || strings.Contains(env, secret) {
		t.Fatalf("the supervisor was started with the worker's secret in its environment:\n%s", env)
	}
	for _, want := range []string{"MOTHER_ROOT=" + d.cfg.Root, "MOTHER_WORKER_MODE=1", "MOTHER_LEASE_ID=L-j1", "MOTHER_LEASE_EPOCH=1", "MOTHER_WORKER_OUTBOX_DIR=" + d.p("outbox")} {
		if !strings.Contains(env, want+"\n") {
			t.Fatalf("supervisor environment lacks %q", want)
		}
	}
	if strings.Contains(env, "MOTHER_LIVE_ROOT=") {
		t.Fatal("MOTHER_LIVE_ROOT reached the supervisor")
	}
}

// ---------------------------------------------------------------------------------------------------
// fencing: the whole supervisor group goes, and only our own supervisor
// ---------------------------------------------------------------------------------------------------

func revokeCmd(t *testing.T, job string) workerproto.Frame {
	return cmdFrame(t, workerproto.TypeLeaseRevoke, job, "L-"+job, 1, map[string]any{"cmd_id": "rv-" + job, "reason": "operator_revoke"})
}

func TestFencingKillsASupervisorThatIgnoresSIGTERMAndItsChildTogether(t *testing.T) {
	dir := t.TempDir()
	pidfile := filepath.Join(dir, "child.pid")
	script := `trap "" TERM; sleep 300 & echo $! > '` + pidfile + `'; wait`
	d, s, c := newDaemonWith(t, func(cfg *Config) {
		cfg.TermGrace = 300 * time.Millisecond
		cfg.SpawnCmd = func(string) (string, []string) { return "sh", []string{"-c", script} }
	})
	d.offerFor(t, s, "j1", 1)
	c.wait(t, 1)
	var child int
	eventually(t, "the stub supervisor to start its child", 5*time.Second, func() bool { child = readPid(pidfile); return child > 0 })
	t.Cleanup(func() {
		if child > 0 && !gone(child) {
			_ = syscall.Kill(child, syscall.SIGKILL) // the exact pid the stub recorded
		}
	})
	d.mu.Lock()
	sup, done := d.leases["j1"].pid, d.leases["j1"].done
	d.mu.Unlock()
	if sup <= 0 || gone(sup) || gone(child) {
		t.Fatalf("setup: supervisor %d / child %d not running", sup, child)
	}

	d.mu.Lock()
	d.handleCommand(s, revokeCmd(t, "j1"))
	d.mu.Unlock()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("a supervisor that ignores SIGTERM survived the fence")
	}
	eventually(t, "the supervisor's child to die with it", 3*time.Second, func() bool { return gone(child) })
	d.mu.Lock()
	st := d.leases["j1"].loc.State
	d.mu.Unlock()
	if st != stateFenced {
		t.Fatalf("lease state %q, want fenced", st)
	}
}

func TestFencingTermsTheWholeGroupBeforeResortingToKill(t *testing.T) {
	dir := t.TempDir()
	pidfile, mark := filepath.Join(dir, "child.pid"), filepath.Join(dir, "term.mark")
	script := `trap 'echo term > '"'` + mark + `'"'; exit 0' TERM; sleep 300 & echo $! > '` + pidfile + `'; wait`
	d, s, c := newDaemonWith(t, func(cfg *Config) {
		cfg.TermGrace = 30 * time.Second // a polite supervisor must not need it
		cfg.SpawnCmd = func(string) (string, []string) { return "sh", []string{"-c", script} }
	})
	d.offerFor(t, s, "j1", 1)
	c.wait(t, 1)
	var child int
	eventually(t, "child", 5*time.Second, func() bool { child = readPid(pidfile); return child > 0 })
	t.Cleanup(func() {
		if child > 0 && !gone(child) {
			_ = syscall.Kill(child, syscall.SIGKILL)
		}
	})
	d.mu.Lock()
	done := d.leases["j1"].done
	d.handleCommand(s, revokeCmd(t, "j1"))
	d.mu.Unlock()
	select {
	case <-done:
	case <-time.After(3 * time.Second):
		t.Fatal("a supervisor that handles SIGTERM was not stopped by it")
	}
	if _, err := os.Stat(mark); err != nil {
		t.Fatal("the supervisor never saw SIGTERM: fencing went straight to SIGKILL")
	}
	eventually(t, "the child to die", 3*time.Second, func() bool { return gone(child) })
}

func startSleepProc(t *testing.T) (pid int, exited <-chan struct{}) {
	t.Helper()
	cmd := exec.Command("sleep", "60")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	ch := make(chan struct{})
	go func() { _ = cmd.Wait(); close(ch) }()
	t.Cleanup(func() {
		select {
		case <-ch:
		default:
			_ = cmd.Process.Kill() // our own child, by handle
			<-ch
		}
	})
	return cmd.Process.Pid, ch
}

func TestTerminateLeavesAnAdoptedPidAloneWhenItIsNotTheSupervisorWeRecorded(t *testing.T) {
	d, _, _ := newDaemonWith(t, func(c *Config) { c.TermGrace = 200 * time.Millisecond; c.SpawnCmd = nil })
	pid, exited := startSleepProc(t)
	survives := func(what string) {
		t.Helper()
		select {
		case <-exited:
			t.Fatalf("an unrelated live process was signalled: %s", what)
		case <-time.After(500 * time.Millisecond):
		}
	}
	// The pid was reused: it is alive, but its start time is not the one recorded for the old supervisor.
	d.terminate(pid, "Thu Jan  1 00:00:00 1970", nil)
	survives("start time mismatch (pid reuse)")
	// The start time matches but the process is not a mother-run-job.
	d.terminate(pid, procStart(pid), nil)
	survives("not a mother-run-job")

	// Control: a recorded supervisor (the test double counts as one) with a matching start time is stopped.
	d.cfg.SpawnCmd = func(string) (string, []string) { return "sleep", nil }
	d.terminate(pid, procStart(pid), nil)
	select {
	case <-exited:
	case <-time.After(5 * time.Second):
		t.Fatal("a verified adopted supervisor was not terminated")
	}
}

// ---------------------------------------------------------------------------------------------------
// offers the worker cannot take
// ---------------------------------------------------------------------------------------------------

func TestWorkerRejectsAnOfferItCannotTakeAndLeavesTheHeldLeaseAlone(t *testing.T) {
	d, s, c := newDaemonWith(t, func(cfg *Config) { cfg.Slots = 1 })
	d.offerFor(t, s, "j1", 1)
	d.offerFor(t, s, "j2", 1) // no slot left
	d.mu.Lock()
	d.handleCommand(s, cmdFrame(t, workerproto.TypeLeaseOffer, "j1", "L-other", 2, map[string]any{
		"cmd_id": "offer-other", "job_doc": json.RawMessage(`{"id":"j1","state":"running"}`), "plan": "p", "repo": "o/r", "attempt": 1}))
	pidBefore := d.leases["j1"].pid
	d.mu.Unlock()
	d.offerFor(t, s, "j1", 1) // the same offer redelivered

	fs := c.wait(t, 4)
	var why []string
	for _, f := range fs[:4] {
		var a workerproto.CmdAck
		_ = json.Unmarshal(f.Data, &a)
		why = append(why, a.Outcome+":"+a.Why)
	}
	want := []string{"applied:", "rejected:no_slot", "rejected:busy_local", "applied:"}
	for i := range want {
		if why[i] != want[i] {
			t.Fatalf("offer acks %v, want %v", why, want)
		}
	}
	if _, err := os.Stat(d.p("jobs", "j2.json")); !os.IsNotExist(err) {
		t.Fatal("a rejected offer wrote a mirror")
	}
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.leases["j2"] != nil {
		t.Fatal("a rejected offer left a lease behind")
	}
	if l := d.leases["j1"]; l.loc.LeaseID != "L-j1" || l.loc.State != stateActive || l.pid != pidBefore {
		t.Fatalf("the held lease was disturbed: %+v pid %d (was %d)", l.loc, l.pid, pidBefore)
	}
}

// ---------------------------------------------------------------------------------------------------
// outbox ops that cannot be shipped
// ---------------------------------------------------------------------------------------------------

func hbJobs(t *testing.T, fs []workerproto.Frame) []workerproto.HbJob {
	t.Helper()
	var out []workerproto.HbJob
	for _, f := range fs {
		if f.T == workerproto.TypeHb {
			var hb workerproto.Hb
			_ = json.Unmarshal(f.Data, &hb)
			out = hb.Jobs
		}
	}
	return out
}

func countType(fs []workerproto.Frame, typ string) int {
	n := 0
	for _, f := range fs {
		if f.T == typ {
			n++
		}
	}
	return n
}

func TestAnOutboxOpThatCannotBeShippedStopsShippingFlagsTheLeaseAndNeverFabricatesAFrame(t *testing.T) {
	huge := `{"seq":2,"t":"event.append","ts":"2026-11-08T12:00:00.000Z","data":{"line":"` + strings.Repeat("x", workerproto.MaxFrameBytes+4096) + `"}}`
	cases := map[string]string{
		"data is a string":      `{"seq":2,"t":"event.append","ts":"2026-11-08T12:00:00.000Z","data":"not an object"}`,
		"data is an array":      `{"seq":2,"t":"event.append","ts":"2026-11-08T12:00:00.000Z","data":[1,2,3]}`,
		"data is null":          `{"seq":2,"t":"event.append","ts":"2026-11-08T12:00:00.000Z","data":null}`,
		"data larger than 1MiB": huge,
		"not JSON at all":       `this is not json`,
		"an unknown op type":    `{"seq":2,"t":"bogus.op","ts":"2026-11-08T12:00:00.000Z","data":{}}`,
	}
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			d, s, c := newDaemonWith(t, nil)
			l := activeLease(t, d, "j1")
			l.exited = false
			writeOutbox(t, d, "j1", evOp(1), bad, evOp(3))
			d.mu.Lock()
			d.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1}})
			d.shipLease(s, l)
			d.mu.Unlock()
			c.wait(t, 1)
			time.Sleep(150 * time.Millisecond)
			// Op 1 shipped. Nothing stands in for op 2 and op 3 is held back behind it.
			if fs := c.all(); countType(fs, workerproto.TypeEventAppend) != 1 || len(fs) != 1 {
				t.Fatalf("frames after a lost op: %d (event.append %d), want exactly the one for op 1", len(fs), countType(fs, workerproto.TypeEventAppend))
			}
			d.mu.Lock()
			why := l.degraded
			d.mu.Unlock()
			if why == "" {
				t.Fatal("the lease was not marked degraded")
			}
			flag := d.p("runner", "j1.outbox-degraded")
			b, err := os.ReadFile(flag)
			if err != nil {
				t.Fatalf("no outbox-degraded flag for the supervisor's hold: %v", err)
			}
			var rec map[string]any
			if json.Unmarshal(b, &rec) != nil || rec["op"] != float64(2) {
				t.Fatalf("flag content %q does not name op 2", b)
			}

			// More ops arrive and the loop keeps running: still nothing is shipped past the loss.
			writeOutbox(t, d, "j1", evOp(1), bad, evOp(3), evOp(4))
			for i := 0; i < 3; i++ {
				d.mu.Lock()
				d.shipLease(s, l)
				d.mu.Unlock()
			}
			time.Sleep(100 * time.Millisecond)
			if n := len(c.all()); n != 1 {
				t.Fatalf("%d frames shipped after the loss", n)
			}

			// The next heartbeat carries the reason, and still covers the lease.
			d.mu.Lock()
			d.sendHb(s)
			d.mu.Unlock()
			c.wait(t, 2)
			jobs := hbJobs(t, c.all())
			if len(jobs) != 1 || jobs[0].Job != "j1" || jobs[0].Degraded != why {
				t.Fatalf("heartbeat jobs %+v, want j1 with degraded %q", jobs, why)
			}

			// The supervisor ends with a releasable state; the lease must still not be released over a hole.
			if err := os.WriteFile(d.p("jobs", "j1.json"), []byte(`{"id":"j1","state":"succeeded"}`), 0o644); err != nil {
				t.Fatal(err)
			}
			d.mu.Lock()
			l.exited = true
			d.onAck(s, cmdFrame(t, workerproto.TypeAck, "j1", "L-j1", 1, map[string]any{"job": "j1", "lease": "L-j1", "epoch": 1, "seq": 1}))
			d.shipLease(s, l)
			d.mu.Unlock()
			time.Sleep(100 * time.Millisecond)
			if n := countType(c.all(), workerproto.TypeLeaseRelease); n != 0 {
				t.Fatal("the lease was released although an outbox op was lost")
			}
		})
	}
}

func TestAWorkerThatRestartsWithALostOpInItsOutboxDetectsItAgain(t *testing.T) {
	d, s, c := newDaemonWith(t, nil)
	l := activeLease(t, d, "j1")
	l.exited = false
	writeOutbox(t, d, "j1", evOp(1), `{"seq":2,"t":"event.append","ts":"2026-11-08T12:00:00.000Z","data":"nope"}`)
	d.mu.Lock()
	d.persistLease(l)
	d.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1}})
	d.shipLease(s, l)
	d.mu.Unlock()
	c.wait(t, 1)

	d2, err := New(Config{ID: "w1", Root: d.cfg.Root, Slots: 2})
	if err != nil {
		t.Fatal(err)
	}
	d2.loadLeases()
	d2.mu.Lock()
	l2 := d2.leases["j1"]
	l2.exited = false
	// The coordinator applied op 1 before the restart.
	d2.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1, AppliedSeq: 1, WireSeq: 1}})
	d2.shipLease(s, l2)
	why := l2.degraded
	d2.mu.Unlock()
	if why == "" {
		t.Fatal("the restarted worker did not notice the op that can never be shipped")
	}
}

// An op whose data is missing, or a job.set whose data is not a job.set object, must be treated like any
// other unshippable op. Consuming it as "every key refused by the ownership table" loses the op without
// anyone being told, and the next op's oskip then makes the coordinator fill the hole with a no-op.
func TestAnOpWithMissingOrMalformedDataIsNotSilentlyDropped(t *testing.T) {
	cases := map[string]string{
		"job.set data is a string":   `{"seq":2,"t":"job.set","ts":"2026-11-08T12:00:00.000Z","data":"not an object"}`,
		"job.set data is an array":   `{"seq":2,"t":"job.set","ts":"2026-11-08T12:00:00.000Z","data":[1]}`,
		"job.set data is missing":    `{"seq":2,"t":"job.set","ts":"2026-11-08T12:00:00.000Z"}`,
		"job.set data is null":       `{"seq":2,"t":"job.set","ts":"2026-11-08T12:00:00.000Z","data":null}`,
		"event.append data missing":  `{"seq":2,"t":"event.append","ts":"2026-11-08T12:00:00.000Z"}`,
		"record.append data missing": `{"seq":2,"t":"record.append","ts":"2026-11-08T12:00:00.000Z"}`,
	}
	for name, bad := range cases {
		t.Run(name, func(t *testing.T) {
			d, s, c := newDaemonWith(t, nil)
			l := activeLease(t, d, "j1")
			l.exited = false
			writeOutbox(t, d, "j1", evOp(1), bad, evOp(3))
			d.mu.Lock()
			d.rebase([]workerproto.WelcomeJob{{Job: "j1", Lease: "L-j1", Epoch: 1}})
			d.shipLease(s, l)
			why := l.degraded
			d.mu.Unlock()
			c.wait(t, 1)
			time.Sleep(100 * time.Millisecond)
			if why == "" {
				t.Fatalf("an unshippable op was dropped silently: the lease is not degraded and %d frame(s) went out (op 3 was shipped over the hole)", len(c.all()))
			}
			if n := len(c.all()); n != 1 {
				t.Fatalf("%d frames shipped, want only op 1", n)
			}
		})
	}
}

// ---------------------------------------------------------------------------------------------------
// the worker and the coordinator, together
// ---------------------------------------------------------------------------------------------------

type seqApplier struct {
	mu      sync.Mutex
	applied int64
}

func (a *seqApplier) Apply(job string, ops [][]byte) (int64, error) {
	a.mu.Lock()
	defer a.mu.Unlock()
	for _, o := range ops {
		var op struct {
			Seq int64 `json:"seq"`
		}
		_ = json.Unmarshal(o, &op)
		if op.Seq == a.applied+1 {
			a.applied = op.Seq
		}
	}
	return a.applied, nil
}

type pair struct {
	root, wroot string
	s           *coord.Server
	d           *Daemon
	cancel      context.CancelFunc
	secret      string
}

func shortTemp(t *testing.T) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "hw")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	return d
}

// startPair runs a real coordinator and a real worker daemon against it. workerSecret is what the worker
// presents; the coordinator knows the right one.
func startPair(t *testing.T, workerSecret string) *pair {
	t.Helper()
	var finished atomic.Bool
	logf := func(f string, a ...any) {
		if !finished.Load() {
			t.Logf(f, a...)
		}
	}
	p := &pair{root: shortTemp(t), wroot: shortTemp(t), secret: coord.NewSecret()}
	release, err := coord.Lock(p.root)
	if err != nil {
		t.Fatal(err)
	}
	p.s, err = coord.New(coord.Config{Root: p.root, Applier: &seqApplier{}, PollEvery: 50 * time.Millisecond, FlushEvery: 20 * time.Millisecond, Logf: logf})
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

	if workerSecret == "" {
		workerSecret = p.secret
	}
	p.d, err = New(Config{ID: "w1", Root: p.wroot, CoordSock: coord.SocketPath(p.root), Slots: 1, Secret: workerSecret,
		TermGrace: 300 * time.Millisecond, BackoffBase: 50 * time.Millisecond, BackoffMax: 100 * time.Millisecond, Logf: logf,
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
				_ = syscall.Kill(-l.pid, syscall.SIGKILL)
				_ = syscall.Kill(l.pid, syscall.SIGKILL)
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
	return p
}

func (p *pair) dispatch(t *testing.T, job string) {
	t.Helper()
	doc, _ := json.Marshal(map[string]any{"id": job, "state": "running", "repo": "r", "repo_path": p.root})
	if err := os.MkdirAll(filepath.Join(p.root, "jobs"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(p.root, "jobs", job+".json"), doc, 0o644); err != nil {
		t.Fatal(err)
	}
	req := filepath.Join(p.root, "runner", "dispatch", job+".json")
	if err := os.WriteFile(req+".tmp.x", []byte(`{"job":"`+job+`"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(req+".tmp.x", req); err != nil {
		t.Fatal(err)
	}
}

func (p *pair) leaseOf(job string) (state string, pid int, done <-chan struct{}) {
	p.d.mu.Lock()
	defer p.d.mu.Unlock()
	if l := p.d.leases[job]; l != nil {
		return l.loc.State, l.pid, l.done
	}
	return "", 0, nil
}

func TestWorkerAuthenticatesToTheCoordinatorAndARevokeStopsItsSupervisor(t *testing.T) {
	p := startPair(t, "")
	p.dispatch(t, "j1")
	var pid int
	var done <-chan struct{}
	eventually(t, "the worker to accept the lease and start its supervisor", 5*time.Second, func() bool {
		var st string
		st, pid, done = p.leaseOf("j1")
		return st == stateActive && pid > 0
	})
	// The coordinator sees an authenticated worker holding the lease.
	eventually(t, "coord-status.json to show the worker and its active lease", 5*time.Second, func() bool {
		var st coord.Status
		b, err := os.ReadFile(coord.StatusPath(p.root))
		if err != nil || json.Unmarshal(b, &st) != nil {
			return false
		}
		return len(st.Workers) == 1 && st.Workers[0].ID == "w1" && len(st.Leases) == 1 && st.Leases[0].State == "active"
	})
	// The operator revokes: the worker fences, and its supervisor dies.
	req := filepath.Join(p.root, "runner", "revoke", "j1.json")
	if err := os.MkdirAll(filepath.Dir(req), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(req, []byte(`{"reason":"operator_revoke"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	eventually(t, "the worker to fence the revoked lease", 5*time.Second, func() bool {
		st, _, _ := p.leaseOf("j1")
		return st == stateFenced
	})
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("the revoked lease's supervisor is still running")
	}
	eventually(t, "the revoke request to be consumed", 3*time.Second, func() bool { _, err := os.Stat(req); return os.IsNotExist(err) })
}

func TestAWorkerThatCannotProveItsSecretIsNeverGivenWork(t *testing.T) {
	p := startPair(t, coord.NewSecret())
	p.dispatch(t, "j1")
	time.Sleep(700 * time.Millisecond) // several reconnect attempts
	if st, _, _ := p.leaseOf("j1"); st != "" {
		t.Fatalf("a worker with the wrong secret was given the lease (%s)", st)
	}
	b, _ := os.ReadFile(filepath.Join(p.root, "runner", "dispatch", "j1.json"))
	if !strings.Contains(string(b), "no_worker_connected") {
		t.Fatalf("the dispatch request is not waiting for a worker: %s", b)
	}
	var st coord.Status
	sb, _ := os.ReadFile(coord.StatusPath(p.root))
	_ = json.Unmarshal(sb, &st)
	if len(st.Workers) != 0 {
		t.Fatalf("an unauthenticated worker is listed as connected: %+v", st.Workers)
	}
	if audit, _ := os.ReadFile(filepath.Join(p.root, "runner", "leases", "audit.jsonl")); !bytes.Contains(audit, []byte("auth_failed:bad_credential")) {
		t.Fatalf("the refusals are not audited: %s", audit)
	}
}
