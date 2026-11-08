package coord

// Hardening tests for the coordinator (PR #120 review fix-ups). They hold the coordinator to its contract
// from the outside: a real Serve on a real unix socket where the behaviour is about connections, the
// pipe-backed harness of coord_test.go where it is about lease/command bookkeeping.

import (
	"bufio"
	"bytes"
	"context"
	cryptorand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"runtime/pprof"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"testing"
	"time"

	"mother-broker/workerproto"
)

// ---------------------------------------------------------------------------------------------------
// helpers: a real coordinator on a real unix socket
// ---------------------------------------------------------------------------------------------------

// hxShortDir is a temp dir with a short path: unix socket paths are limited to 104 bytes on macOS.
func hxShortDir(t testing.TB) string {
	t.Helper()
	d, err := os.MkdirTemp("/tmp", "hx")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.RemoveAll(d) })
	return d
}

var hxCounter atomic.Int64

func hxID(prefix string) string { return prefix + strconv.FormatInt(hxCounter.Add(1), 10) }

func hxLine(t testing.TB, typ, job, lease string, epoch, seq int64, data any) []byte {
	t.Helper()
	f, err := workerproto.NewFrame(typ, hxID("hx-"), time.Now(), data)
	if err != nil {
		t.Fatal(err)
	}
	if job != "" {
		f.Job = &job
	}
	if lease != "" {
		f.Lease = &lease
	}
	if epoch > 0 {
		f.Epoch = &epoch
	}
	if seq > 0 {
		f.Seq = &seq
	}
	b, err := workerproto.Encode(f)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

type hxHello struct {
	workerproto.Hello
	Slots int `json:"slots"`
}

func hxMakeHello(id, inst string) workerproto.Hello {
	nb := make([]byte, 16)
	_, _ = cryptorand.Read(nb)
	return workerproto.Hello{
		ProtoMin: 1, ProtoMax: 1, WorkerID: id, InstanceID: inst, Kind: "worker",
		Caps: []string{"log.stream", "artifact.chunked", "checkpoint.v1", "hold.boundary"},
		Auth: workerproto.Auth{Method: workerproto.AuthMethodPeercred, Nonce: hex.EncodeToString(nb)},
	}
}

func hxSign(h workerproto.Hello, secret string) workerproto.Hello {
	h.Auth.Credential = workerproto.CredentialProof(secret, h)
	return h
}

func hxHelloLine(t testing.TB, h workerproto.Hello, slots int) []byte {
	return hxLine(t, workerproto.TypeHello, "", "", 0, 0, hxHello{Hello: h, Slots: slots})
}

type rig struct {
	t        *testing.T
	root     string
	s        *Server
	app      *fakeApplier
	cancel   context.CancelFunc
	finished chan struct{}
	serveErr error
	release  func()
	stopOnce sync.Once
}

// startRig runs a real coordinator (Lock, New, Listen, Serve) in a fresh short root. mut adjusts the
// Config; wrap decorates the listener (fault injection).
func startRig(t *testing.T, mut func(*Config), wrap func(net.Listener) net.Listener) *rig {
	t.Helper()
	root := hxShortDir(t)
	release, err := Lock(root)
	if err != nil {
		t.Fatal(err)
	}
	app := &fakeApplier{}
	cfg := Config{Root: root, Applier: app, TTL: 6 * time.Second, FlushEvery: 20 * time.Millisecond, PollEvery: 50 * time.Millisecond,
		HelloTimeout: 3 * time.Second, AcceptMinSleep: time.Millisecond, Logf: func(string, ...any) {}}
	if mut != nil {
		mut(&cfg)
	}
	s, err := New(cfg)
	if err != nil {
		release()
		t.Fatal(err)
	}
	ln, err := Listen(root)
	if err != nil {
		release()
		t.Fatal(err)
	}
	var l net.Listener = ln
	if wrap != nil {
		l = wrap(ln)
	}
	ctx, cancel := context.WithCancel(context.Background())
	r := &rig{t: t, root: root, s: s, app: app, cancel: cancel, finished: make(chan struct{}), release: release}
	go func() {
		r.serveErr = s.Serve(ctx, l)
		close(r.finished)
	}()
	t.Cleanup(r.stop)
	return r
}

func (r *rig) stop() {
	r.stopOnce.Do(func() {
		r.cancel()
		select {
		case <-r.finished:
		case <-time.After(5 * time.Second):
			r.t.Error("Serve did not return after its context was cancelled")
		}
		r.s.Close()
		r.release()
	})
}

func (r *rig) register(id string) string {
	r.t.Helper()
	secret := NewSecret()
	if err := r.s.RegisterWorker(id, os.Getpid(), secret); err != nil {
		r.t.Fatal(err)
	}
	return secret
}

// wire is the client end of one connection.
type wire struct {
	t  testing.TB
	c  net.Conn
	br *bufio.Reader
}

func (r *rig) dial() *wire {
	r.t.Helper()
	c, err := net.DialTimeout("unix", SocketPath(r.root), 2*time.Second)
	if err != nil {
		r.t.Fatal(err)
	}
	r.t.Cleanup(func() { c.Close() })
	return &wire{t: r.t, c: c, br: bufio.NewReader(c)}
}

func (w *wire) send(b []byte) error {
	_ = w.c.SetWriteDeadline(time.Now().Add(5 * time.Second))
	_, err := w.c.Write(b)
	return err
}

func (w *wire) next(d time.Duration) (workerproto.Frame, error) {
	_ = w.c.SetReadDeadline(time.Now().Add(d))
	line, err := workerproto.ReadFrame(w.br)
	if err != nil {
		return workerproto.Frame{}, err
	}
	return workerproto.Decode(line)
}

// waitFor reads (discarding) until pred matches a frame, the connection ends or d elapses.
func (w *wire) waitFor(pred func(workerproto.Frame) bool, d time.Duration) (workerproto.Frame, bool) {
	deadline := time.Now().Add(d)
	for time.Until(deadline) > 0 {
		f, err := w.next(time.Until(deadline))
		if err != nil {
			return workerproto.Frame{}, false
		}
		if pred(f) {
			return f, true
		}
	}
	return workerproto.Frame{}, false
}

func ofTypeP(t string) func(workerproto.Frame) bool {
	return func(f workerproto.Frame) bool { return f.T == t }
}

// closedWithin reports whether the peer ends the connection (EOF or reset) within d, discarding frames.
func (w *wire) closedWithin(d time.Duration) bool {
	deadline := time.Now().Add(d)
	for time.Until(deadline) > 0 {
		if _, err := w.next(time.Until(deadline)); err != nil {
			var ne net.Error
			return !(errors.As(err, &ne) && ne.Timeout())
		}
	}
	return false
}

// connect dials and says hello; the first reply (welcome or refuse) is returned. An empty frame means the
// coordinator closed the connection without answering.
func (r *rig) connect(id, inst, secret string) (*wire, workerproto.Frame) {
	r.t.Helper()
	h := hxMakeHello(id, inst)
	if secret != "" {
		h = hxSign(h, secret)
	}
	w := r.dial()
	if err := w.send(hxHelloLine(r.t, h, 2)); err != nil {
		return w, workerproto.Frame{}
	}
	f, err := w.next(3 * time.Second)
	if err != nil {
		return w, workerproto.Frame{}
	}
	return w, f
}

func (r *rig) mustConnect(id, inst, secret string) *wire {
	r.t.Helper()
	w, f := r.connect(id, inst, secret)
	if f.T != workerproto.TypeWelcome {
		r.t.Fatalf("handshake for %s/%s: got %q %s, want welcome", id, inst, f.T, f.Data)
	}
	return w
}

// connectEventually retries while the coordinator has not yet noticed that an earlier connection ended.
func (r *rig) connectEventually(id, inst, secret string) (*wire, bool) {
	r.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		w, f := r.connect(id, inst, secret)
		if f.T == workerproto.TypeWelcome {
			return w, true
		}
		w.c.Close()
		time.Sleep(50 * time.Millisecond)
	}
	return nil, false
}

func hxRefuseCode(f workerproto.Frame) string {
	if f.T != workerproto.TypeRefuse {
		return ""
	}
	var rf workerproto.Refuse
	_ = json.Unmarshal(f.Data, &rf)
	return rf.Code
}

func hxWelcome(t testing.TB, f workerproto.Frame) workerproto.Welcome {
	t.Helper()
	var w workerproto.Welcome
	if f.T != workerproto.TypeWelcome || json.Unmarshal(f.Data, &w) != nil {
		t.Fatalf("not a welcome: %s %s", f.T, f.Data)
	}
	return w
}

type hxL struct {
	job, lease string
	epoch      int64
	cmd        string
}

func hxWriteAtomic(t testing.TB, path string, b []byte) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatal(err)
	}
	tmp := path + ".tmp.hx"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Rename(tmp, path); err != nil {
		t.Fatal(err)
	}
}

func (r *rig) putJob(job string) {
	r.t.Helper()
	b, _ := json.Marshal(map[string]any{"id": job, "state": "running", "repo": "r", "repo_path": r.root})
	hxWriteAtomic(r.t, r.s.jobPath(job), b)
}

func (r *rig) request(job string) {
	r.t.Helper()
	hxWriteAtomic(r.t, r.s.dispatchPath(job), []byte(`{"job":"`+job+`"}`))
}

func (w *wire) takeOffer(job string) hxL {
	w.t.Helper()
	f, ok := w.waitFor(func(f workerproto.Frame) bool {
		return f.T == workerproto.TypeLeaseOffer && f.Job != nil && *f.Job == job
	}, 3*time.Second)
	if !ok {
		w.t.Fatalf("no lease.offer for %s", job)
	}
	var o struct {
		CmdID string `json:"cmd_id"`
	}
	_ = json.Unmarshal(f.Data, &o)
	return hxL{job: job, lease: *f.Lease, epoch: *f.Epoch, cmd: o.CmdID}
}

func (w *wire) cmdAck(l hxL, cmdID, outcome, why, forType string) error {
	return w.send(hxLine(w.t, workerproto.TypeCmdAck, l.job, l.lease, l.epoch, 0,
		map[string]any{"cmd_id": cmdID, "outcome": outcome, "why": why, "for": forType}))
}

func (r *rig) state(job string) string {
	r.s.mu.Lock()
	defer r.s.mu.Unlock()
	if jl := r.s.jobs[job]; jl != nil {
		return jl.rec.State
	}
	return ""
}

func (r *rig) waitState(job, want string) {
	r.t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if r.state(job) == want {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	r.t.Fatalf("lease of %s is %q, want %q", job, r.state(job), want)
}

// lease dispatches job and has the connected worker accept the offer.
func (r *rig) lease(w *wire, job string) hxL {
	r.t.Helper()
	r.putJob(job)
	r.request(job)
	l := w.takeOffer(job)
	if err := w.cmdAck(l, l.cmd, workerproto.OutcomeApplied, "", workerproto.TypeLeaseOffer); err != nil {
		r.t.Fatal(err)
	}
	r.waitState(job, "active")
	return l
}

const hxEventLine = `{"ts":"2026-11-08T12:00:00.000Z","kind":"k","detail":{}}`

func (w *wire) event(l hxL, seq int64) error {
	return w.send(hxLine(w.t, workerproto.TypeEventAppend, l.job, l.lease, l.epoch, seq, map[string]any{"line": hxEventLine, "oseq": seq}))
}

func (w *wire) hb(ls ...hxL) error {
	var jobs []workerproto.HbJob
	for _, l := range ls {
		jobs = append(jobs, workerproto.HbJob{Job: l.job, Lease: l.lease, Epoch: l.epoch})
	}
	return w.send(hxLine(w.t, workerproto.TypeHb, "", "", 0, 0, workerproto.Hb{Jobs: jobs}))
}

// waitAck reads until an ack for l with seq >= atLeast arrives.
func (w *wire) waitAck(l hxL, atLeast int64, d time.Duration) bool {
	_, ok := w.waitFor(func(f workerproto.Frame) bool {
		if f.T != workerproto.TypeAck {
			return false
		}
		var a workerproto.AckData
		_ = json.Unmarshal(f.Data, &a)
		return a.Job == l.job && a.Seq >= atLeast
	}, d)
	return ok
}

func (r *rig) rec(job string) LeaseRec {
	r.s.mu.Lock()
	defer r.s.mu.Unlock()
	if jl := r.s.jobs[job]; jl != nil {
		return jl.rec
	}
	return LeaseRec{}
}

func hxAuditLines(t testing.TB, s *Server) []map[string]any {
	t.Helper()
	var out []map[string]any
	b, _ := os.ReadFile(s.auditPath())
	for _, l := range strings.Split(strings.TrimSpace(string(b)), "\n") {
		if l == "" {
			continue
		}
		var m map[string]any
		if json.Unmarshal([]byte(l), &m) != nil {
			t.Fatalf("audit line is not JSON: %q", l)
		}
		out = append(out, m)
	}
	return out
}

func hxCountCode(t testing.TB, s *Server, code string) int {
	n := 0
	for _, m := range hxAuditLines(t, s) {
		if m["code"] == code {
			n++
		}
	}
	return n
}

// hxSettle polls until the goroutine count is at most limit.
func hxSettle(t testing.TB, limit int, d time.Duration) {
	t.Helper()
	deadline := time.Now().Add(d)
	for {
		if n := runtime.NumGoroutine(); n <= limit {
			return
		}
		if time.Now().After(deadline) {
			var buf bytes.Buffer
			_ = pprof.Lookup("goroutine").WriteTo(&buf, 1)
			t.Fatalf("%d goroutines, want at most %d:\n%s", runtime.NumGoroutine(), limit, buf.String())
		}
		time.Sleep(25 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------------------------------
// the helper process (the standard Go re-exec pattern): an "agent" or a launched worker in another process
// ---------------------------------------------------------------------------------------------------

func TestHelperAgentProcess(t *testing.T) {
	mode := os.Getenv("HX_HELPER")
	if mode == "" {
		t.Skip("helper process only")
	}
	defer os.Exit(0)
	switch mode {
	case "lock":
		root := os.Getenv("HX_ROOT")
		if rel, err := Lock(root); err != nil {
			fmt.Println("HX_LOCK=err:" + strings.ReplaceAll(err.Error(), "\n", " "))
		} else {
			fmt.Println("HX_LOCK=ok")
			rel()
		}
		if ln, err := Listen(root); err != nil {
			fmt.Println("HX_LISTEN=err")
		} else {
			fmt.Println("HX_LISTEN=ok")
			ln.Close()
		}
	case "flood": // many idle sockets from a pid that is not any worker's
		var keep []net.Conn
		for i := 0; i < 100; i++ {
			c, err := net.Dial("unix", os.Getenv("HX_SOCK"))
			if err != nil {
				fmt.Println("HX_FLOOD=err")
				return
			}
			keep = append(keep, c)
		}
		fmt.Println("HX_FLOOD=ready")
		time.Sleep(time.Minute)
		_ = keep
	case "hello", "launched":
		id, inst, secret := os.Getenv("HX_ID"), os.Getenv("HX_INST"), os.Getenv("HX_SECRET")
		if mode == "launched" {
			fd, _ := strconv.Atoi(os.Getenv("MOTHER_WORKER_SECRET_FD"))
			f := os.NewFile(uintptr(fd), "secret")
			b := make([]byte, 256)
			n, _ := f.Read(b)
			secret = strings.TrimSpace(string(b[:n]))
			inst = "i-launched"
			fmt.Printf("HX_SECRET_IN_ENV=%v\n", os.Getenv("MOTHER_WORKER_SECRET") != "")
		}
		var reply string
		// A launched worker may be quicker than the parent's RegisterWorker; a real worker retries too.
		for i := 0; i < 40; i++ {
			reply = hxHelperHello(os.Getenv("HX_SOCK"), id, inst, secret)
			if mode != "launched" || reply == "welcome" {
				break
			}
			time.Sleep(50 * time.Millisecond)
		}
		fmt.Println("HX_REPLY=" + reply)
	}
}

func hxHelperHello(sock, id, inst, secret string) string {
	c, err := net.DialTimeout("unix", sock, 2*time.Second)
	if err != nil {
		return "dial:" + err.Error()
	}
	defer c.Close()
	h := hxMakeHello(id, inst)
	if secret != "" {
		h = hxSign(h, secret)
	}
	f, err := workerproto.NewFrame(workerproto.TypeHello, hxID("hh-"), time.Now(), hxHello{Hello: h, Slots: 1})
	if err != nil {
		return "frame:" + err.Error()
	}
	b, _ := workerproto.Encode(f)
	_, _ = c.Write(b)
	_ = c.SetReadDeadline(time.Now().Add(3 * time.Second))
	line, err := workerproto.ReadFrame(bufio.NewReader(c))
	if err != nil {
		return "closed"
	}
	rf, err := workerproto.Decode(line)
	if err != nil {
		return "bad:" + err.Error()
	}
	if rf.T == workerproto.TypeRefuse {
		return "refuse:" + hxRefuseCode(rf)
	}
	return rf.T
}

// hxRunHelper runs the helper process and returns its HX_* output lines.
func hxRunHelper(t *testing.T, env ...string) map[string]string {
	t.Helper()
	cmd := exec.Command(os.Args[0], "-test.run=^TestHelperAgentProcess$", "-test.count=1")
	cmd.Env = append(os.Environ(), env...)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("helper process: %v\n%s", err, out)
	}
	return hxParseHelperOutput(string(out))
}

func hxParseHelperOutput(out string) map[string]string {
	m := map[string]string{}
	for _, l := range strings.Split(out, "\n") {
		if strings.HasPrefix(l, "HX_") {
			if k, v, ok := strings.Cut(l, "="); ok {
				m[k] = v
			}
		}
	}
	return m
}

// ---------------------------------------------------------------------------------------------------
// 1. identity
// ---------------------------------------------------------------------------------------------------

func TestHandshakeRefusesEveryPeerThatCannotProveTheWorkersCredential(t *testing.T) {
	r := startRig(t, nil, nil)
	secret := r.register("w1")

	short := hxMakeHello("w1", "i-x")
	short.Auth.Nonce = "tooshort"
	short = hxSign(short, secret) // a valid proof, but over a nonce too short to be fresh
	replay := hxMakeHello("w1", "i-b")
	replay.Auth.Credential = workerproto.CredentialProof(secret, hxMakeHello("w1", "i-a")) // proof lifted from another hello
	other := hxSign(hxMakeHello("w1", "i-o"), NewSecret())
	unknown := hxSign(hxMakeHello("ghost", "i-g"), secret)

	cases := []struct {
		name string
		h    workerproto.Hello
		want string
	}{
		{"no credential at all", hxMakeHello("w1", "i-n"), "no_credential"},
		{"wrong secret", other, "bad_credential"},
		{"proof from a different hello", replay, "bad_credential"},
		{"valid proof over a too-short nonce", short, "no_credential"},
		{"worker id nobody registered", unknown, "unknown_worker"},
	}
	var msgs []string
	for _, c := range cases {
		w := r.dial()
		if err := w.send(hxHelloLine(t, c.h, 1)); err != nil {
			t.Fatal(err)
		}
		f, err := w.next(3 * time.Second)
		if err != nil {
			t.Fatalf("%s: no refuse: %v", c.name, err)
		}
		if f.T == workerproto.TypeWelcome {
			t.Fatalf("%s: was welcomed", c.name)
		}
		if hxRefuseCode(f) != workerproto.CodeAuthFailed {
			t.Fatalf("%s: got %s %s, want refuse auth_failed", c.name, f.T, f.Data)
		}
		var rf workerproto.Refuse
		_ = json.Unmarshal(f.Data, &rf)
		msgs = append(msgs, rf.Msg)
		if !w.closedWithin(2 * time.Second) {
			t.Fatalf("%s: the connection stayed open after the refusal", c.name)
		}
		if hxCountCode(t, r.s, "auth_failed:"+c.want) == 0 {
			t.Fatalf("%s: audit has no auth_failed:%s (codes %v)", c.name, c.want, auditCodes(t, r.s))
		}
	}
	// The reason is audited, never told to the peer: every refusal reads the same.
	for _, m := range msgs[1:] {
		if m != msgs[0] {
			t.Fatalf("refusal text differs by reason, which is an oracle for the peer: %q vs %q", m, msgs[0])
		}
	}
	// None of that disturbed the real worker.
	if _, f := r.connect("w1", "i-real", secret); f.T != workerproto.TypeWelcome {
		t.Fatalf("the real worker was refused after the attacks: %s %s", f.T, f.Data)
	}
}

func TestAnotherProcessCannotTakeOverARegisteredWorkerId(t *testing.T) {
	r := startRig(t, nil, nil)
	secret := r.register("w1") // pid = this process, registered explicitly
	real := r.mustConnect("w1", "i-real", secret)
	l := r.lease(real, "j1")
	if err := real.event(l, 1); err != nil || !real.waitAck(l, 1, 3*time.Second) {
		t.Fatal("the real worker's stream does not work before the attack")
	}

	sock := SocketPath(r.root)
	helper := func(inst, sec string) string {
		return hxRunHelper(t, "HX_HELPER=hello", "HX_SOCK="+sock, "HX_ID=w1", "HX_INST="+inst, "HX_SECRET="+sec)["HX_REPLY"]
	}
	// An agent that stole the secret and brings a new instance id...
	if got := helper("i-agent", secret); got != "refuse:auth_failed" {
		t.Fatalf("a second process with the stolen secret got %q, want refuse:auth_failed", got)
	}
	if hxCountCode(t, r.s, "auth_failed:pid_mismatch") == 0 {
		t.Fatalf("stolen secret from another pid is not audited as pid_mismatch: %v", auditCodes(t, r.s))
	}
	// ...or that claims to be the very same instance (the reconnect path)...
	if got := helper("i-real", secret); got != "refuse:auth_failed" {
		t.Fatalf("a second process claiming the live instance id got %q, want refuse:auth_failed", got)
	}
	// ...or one with no secret at all.
	if got := helper("i-agent", ""); got != "refuse:auth_failed" {
		t.Fatalf("a second process without a secret got %q", got)
	}
	if hxCountCode(t, r.s, "auth_failed:no_credential") == 0 {
		t.Fatalf("missing credential not audited: %v", auditCodes(t, r.s))
	}

	// The real worker's connection and lease are undisturbed.
	if err := real.event(l, 2); err != nil || !real.waitAck(l, 2, 3*time.Second) {
		t.Fatal("the real worker's connection was disturbed by the refused takeover")
	}
	if err := real.hb(l); err != nil {
		t.Fatal(err)
	}
	if st := r.state("j1"); st != "active" {
		t.Fatalf("the real worker's lease is %q after the takeover attempts", st)
	}
	r.s.mu.Lock()
	cur := r.s.workers["w1"]
	r.s.mu.Unlock()
	if cur == nil || cur.instance != "i-real" || cur.closed() {
		t.Fatalf("the registered connection was displaced: %+v", cur)
	}
}

func TestWorkerIdIsBoundToTheRegisteredPidAndAReusedPidIsRefusedUntilReRegistered(t *testing.T) {
	r := startRig(t, nil, nil)
	secret := NewSecret()
	// Registered with another live process's pid (the test's parent): this process has the secret but not the pid.
	if err := r.s.RegisterWorker("w1", os.Getppid(), secret); err != nil {
		t.Fatal(err)
	}
	if _, f := r.connect("w1", "i-1", secret); hxRefuseCode(f) != workerproto.CodeAuthFailed {
		t.Fatalf("a process with the secret but not the registered pid got %s", f.T)
	}
	if hxCountCode(t, r.s, "auth_failed:pid_mismatch") == 0 {
		t.Fatalf("not audited as pid_mismatch: %v", auditCodes(t, r.s))
	}
	// Re-registering with the real pid (a restarted launch) is what lets it in.
	if err := r.s.RegisterWorker("w1", os.Getpid(), secret); err != nil {
		t.Fatal(err)
	}
	if _, ok := r.connectEventually("w1", "i-2", secret); !ok {
		t.Fatal("the re-registered pid was never accepted")
	}
}

func TestLegitimateReconnectResumesTheLeaseAndReplacesTheOldConnection(t *testing.T) {
	r := startRig(t, nil, nil)
	secret := r.register("w1")
	c1 := r.mustConnect("w1", "i-1", secret)
	l := r.lease(c1, "j1")
	for i := int64(1); i <= 3; i++ {
		if err := c1.event(l, i); err != nil {
			t.Fatal(err)
		}
	}
	if !c1.waitAck(l, 3, 3*time.Second) {
		t.Fatal("events 1..3 were not acked")
	}

	// The worker redials (same instance, fresh nonce and proof) while the coordinator still holds the old
	// connection: that is a reconnect, not an intruder.
	c2, f := r.connect("w1", "i-1", secret)
	w := hxWelcome(t, f)
	if len(w.Jobs) != 1 || w.Jobs[0].Job != "j1" || w.Jobs[0].Lease != l.lease || w.Jobs[0].Epoch != l.epoch {
		t.Fatalf("welcome does not resume the lease: %+v", w.Jobs)
	}
	if w.Jobs[0].WireSeq != 3 || w.Jobs[0].AppliedSeq != 3 {
		t.Fatalf("welcome resumes at wire %d applied %d, want 3 and 3", w.Jobs[0].WireSeq, w.Jobs[0].AppliedSeq)
	}
	if !c1.closedWithin(2 * time.Second) {
		t.Fatal("the replaced connection was not closed")
	}
	if err := c2.event(l, 4); err != nil || !c2.waitAck(l, 4, 3*time.Second) {
		t.Fatal("shipping did not continue on the new connection")
	}

	// A different instance while the new one is live is refused and does not disturb it.
	c3, f3 := r.connect("w1", "i-other", secret)
	if hxRefuseCode(f3) != workerproto.CodeAuthFailed {
		t.Fatalf("a second live instance got %s %s, want auth_failed", f3.T, f3.Data)
	}
	if hxCountCode(t, r.s, "auth_failed:already_connected") == 0 {
		t.Fatalf("not audited as already_connected: %v", auditCodes(t, r.s))
	}
	_ = c3
	if err := c2.event(l, 5); err != nil || !c2.waitAck(l, 5, 3*time.Second) {
		t.Fatal("the live connection was disturbed by the refused second instance")
	}
	if r.state("j1") != "active" {
		t.Fatal("the lease did not survive")
	}

	// Once the live connection is gone, a restarted worker (new instance) is welcome and resumes the lease.
	c2.c.Close()
	c4, ok := r.connectEventually("w1", "i-restarted", secret)
	if !ok {
		t.Fatal("a restarted worker was never accepted after its predecessor disconnected")
	}
	_ = c4
}

func TestLaunchWorkerHandsTheSecretOverAnFdAndRegistersThePid(t *testing.T) {
	r := startRig(t, nil, nil)
	cmd := exec.Command(os.Args[0], "-test.run=^TestHelperAgentProcess$", "-test.count=1")
	cmd.Env = append(os.Environ(), "HX_HELPER=launched", "HX_SOCK="+SocketPath(r.root), "HX_ID=wl")
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := r.s.LaunchWorker("wl", cmd); err != nil {
		t.Fatal(err)
	}
	pid := cmd.Process.Pid
	t.Cleanup(func() {
		if cmd.ProcessState == nil { // still ours and unreaped: stop that exact pid
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
	})
	if err := cmd.Wait(); err != nil {
		t.Fatalf("launched helper: %v\n%s", err, out.String())
	}
	got := hxParseHelperOutput(out.String())
	if got["HX_REPLY"] != "welcome" {
		t.Fatalf("the launched worker was not welcomed with the fd-delivered secret: %v", got)
	}
	if got["HX_SECRET_IN_ENV"] != "false" {
		t.Fatalf("the secret reached the child through its environment: %v", got)
	}
	r.s.mu.Lock()
	c := r.s.creds["wl"]
	r.s.mu.Unlock()
	if c == nil || c.pid != pid {
		t.Fatalf("the launched pid %d was not registered as the worker's explicit pid: %+v", pid, c)
	}
}

func TestRegisterWorkerRefusesWeakOrMalformedRegistrations(t *testing.T) {
	r := startRig(t, nil, nil)
	if err := r.s.RegisterWorker("w1", 0, "short"); err == nil {
		t.Fatal("a 5-character secret was accepted")
	}
	if err := r.s.RegisterWorker("../x", 0, NewSecret()); err == nil {
		t.Fatal("a path-like worker id was accepted")
	}
	if a, b := NewSecret(), NewSecret(); a == b || len(a) < 32 {
		t.Fatalf("NewSecret is not a fresh strong value: %q %q", a, b)
	}
}

func TestReRegisteringAWorkerDropsItsLiveConnectionAndInvalidatesTheOldSecret(t *testing.T) {
	r := startRig(t, nil, nil)
	old := r.register("w1")
	c := r.mustConnect("w1", "i-1", old)
	fresh := NewSecret()
	if err := r.s.RegisterWorker("w1", os.Getpid(), fresh); err != nil {
		t.Fatal(err)
	}
	if !c.closedWithin(2 * time.Second) {
		t.Fatal("re-registering did not drop the live connection")
	}
	if _, f := r.connect("w1", "i-1", old); hxRefuseCode(f) != workerproto.CodeAuthFailed {
		t.Fatalf("the replaced secret still works: %s", f.T)
	}
	if _, ok := r.connectEventually("w1", "i-1", fresh); !ok {
		t.Fatal("the new secret does not work")
	}
}

// ---------------------------------------------------------------------------------------------------
// 2. directory, singleton, file modes
// ---------------------------------------------------------------------------------------------------

func TestLockIsAnExclusiveSingletonPerRoot(t *testing.T) {
	root := hxShortDir(t)
	const n = 8
	var wins atomic.Int32
	var wg sync.WaitGroup
	start := make(chan struct{})
	releases := make(chan func(), n)
	errs := make(chan error, n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			rel, err := Lock(root)
			if err != nil {
				errs <- err
				return
			}
			wins.Add(1)
			releases <- rel
		}()
	}
	close(start)
	wg.Wait()
	if wins.Load() != 1 {
		t.Fatalf("%d concurrent Lock calls on one root succeeded, want exactly 1", wins.Load())
	}
	close(errs)
	for err := range errs {
		if !strings.Contains(err.Error(), "already running") {
			t.Fatalf("loser's error does not say the coordinator is running: %v", err)
		}
	}
	rel := <-releases
	if b, _ := os.ReadFile(PidPath(root)); strings.TrimSpace(string(b)) != strconv.Itoa(os.Getpid()) {
		t.Fatalf("pidfile %q does not name the lock holder", b)
	}
	rel()
	rel() // idempotent
	if _, err := os.Stat(PidPath(root)); !os.IsNotExist(err) {
		t.Fatal("the pidfile outlived the lock")
	}
	rel2, err := Lock(root)
	if err != nil {
		t.Fatalf("the lock is not reusable after release: %v", err)
	}
	rel2()
}

func TestRacingCoordinatorStartsOnOneRootLetExactlyOneProceed(t *testing.T) {
	root := hxShortDir(t)
	const n = 6
	var proceeded atomic.Int32
	var wg, ready sync.WaitGroup
	start, finish := make(chan struct{}), make(chan struct{})
	ready.Add(n)
	for i := 0; i < n; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			ready.Done()
			<-start
			rel, err := Lock(root)
			if err != nil {
				return
			}
			defer rel()
			s, err := New(Config{Root: root, Applier: &fakeApplier{}, PollEvery: 50 * time.Millisecond})
			if err != nil {
				t.Errorf("the lock holder could not start: %v", err)
				return
			}
			ln, err := Listen(root)
			if err != nil {
				t.Errorf("the lock holder could not listen: %v", err)
				return
			}
			ctx, cancel := context.WithCancel(context.Background())
			done := make(chan struct{})
			go func() { _ = s.Serve(ctx, ln); close(done) }()
			proceeded.Add(1)
			<-finish
			cancel()
			<-done
			s.Close()
		}()
	}
	ready.Wait()
	close(start)
	time.Sleep(300 * time.Millisecond) // every loser has had its chance to (wrongly) get in
	if got := proceeded.Load(); got != 1 {
		close(finish)
		wg.Wait()
		t.Fatalf("%d coordinators proceeded on one root, want 1", got)
	}
	// The winner's socket is still the one bound: a loser never unlinked it.
	c, err := net.Dial("unix", SocketPath(root))
	if err != nil {
		close(finish)
		wg.Wait()
		t.Fatalf("the winner's socket is gone: %v", err)
	}
	c.Close()
	close(finish)
	wg.Wait()
}

func TestAnotherProcessCannotLockOrListenOnALockedRoot(t *testing.T) {
	r := startRig(t, nil, nil) // this process holds the lock and is serving
	got := hxRunHelper(t, "HX_HELPER=lock", "HX_ROOT="+r.root)
	if !strings.HasPrefix(got["HX_LOCK"], "err:") || !strings.Contains(got["HX_LOCK"], "already running") {
		t.Fatalf("a second process locked the root or failed oddly: %q", got["HX_LOCK"])
	}
	if got["HX_LISTEN"] != "err" {
		t.Fatalf("a process that does not hold the lock was allowed to Listen: %q", got["HX_LISTEN"])
	}
	// It did not unlink or replace our socket.
	if _, f := r.connect("nobody", "i-x", ""); f.T != workerproto.TypeRefuse {
		t.Fatalf("the running coordinator no longer answers on its socket: %q", f.T)
	}
}

func TestListenRefusesWithoutTheLock(t *testing.T) {
	root := hxShortDir(t)
	if ln, err := Listen(root); err == nil {
		ln.Close()
		t.Fatal("Listen succeeded without Lock")
	}
	if _, err := os.Stat(SocketPath(root)); !os.IsNotExist(err) {
		t.Fatal("Listen without the lock left a socket behind")
	}
	rel, err := Lock(root)
	if err != nil {
		t.Fatal(err)
	}
	rel()
	if ln, err := Listen(root); err == nil {
		ln.Close()
		t.Fatal("Listen succeeded after the lock was released")
	}
}

func TestCoordDirMustBeAPrivateRealDirectory(t *testing.T) {
	t.Run("a new one is created 0700", func(t *testing.T) {
		root := hxShortDir(t)
		rel, err := Lock(root)
		if err != nil {
			t.Fatal(err)
		}
		defer rel()
		fi, err := os.Lstat(CoordDir(root))
		if err != nil || !fi.IsDir() || fi.Mode().Perm() != 0o700 {
			t.Fatalf("coord dir: %v %v", fi, err)
		}
	})
	t.Run("a symlink is refused and nothing is written through it", func(t *testing.T) {
		root := hxShortDir(t)
		target := hxShortDir(t)
		if err := os.Chmod(target, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(root, "runner"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, CoordDir(root)); err != nil {
			t.Fatal(err)
		}
		if rel, err := Lock(root); err == nil {
			rel()
			t.Fatal("Lock accepted a symlinked coord dir")
		}
		if ents, _ := os.ReadDir(target); len(ents) != 0 {
			t.Fatalf("Lock wrote through the symlink: %v", ents)
		}
	})
	t.Run("a group/world-accessible dir is refused", func(t *testing.T) {
		root := hxShortDir(t)
		if err := os.MkdirAll(CoordDir(root), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(CoordDir(root), 0o755); err != nil {
			t.Fatal(err)
		}
		rel, err := Lock(root)
		if err == nil {
			rel()
			t.Fatal("Lock accepted a 0755 coord dir")
		}
		if !strings.Contains(err.Error(), "0700") {
			t.Fatalf("error does not say what is required: %v", err)
		}
	})
	t.Run("a regular file in its place is refused", func(t *testing.T) {
		root := hxShortDir(t)
		if err := os.MkdirAll(filepath.Join(root, "runner"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(CoordDir(root), nil, 0o600); err != nil {
			t.Fatal(err)
		}
		if rel, err := Lock(root); err == nil {
			rel()
			t.Fatal("Lock accepted a file as the coord dir")
		}
	})
	t.Run("Listen re-verifies the directory after Lock", func(t *testing.T) {
		root := hxShortDir(t)
		rel, err := Lock(root)
		if err != nil {
			t.Fatal(err)
		}
		defer rel()
		// loosened after the lock was taken
		if err := os.Chmod(CoordDir(root), 0o755); err != nil {
			t.Fatal(err)
		}
		if ln, err := Listen(root); err == nil {
			ln.Close()
			t.Fatal("Listen accepted a coord dir that became 0755")
		}
		if err := os.Chmod(CoordDir(root), 0o700); err != nil {
			t.Fatal(err)
		}
		// swapped for a symlink after the lock was taken
		target := hxShortDir(t)
		if err := os.Chmod(target, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Rename(CoordDir(root), CoordDir(root)+".moved"); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(target, CoordDir(root)); err != nil {
			t.Fatal(err)
		}
		if ln, err := Listen(root); err == nil {
			ln.Close()
			t.Fatal("Listen accepted a coord dir that became a symlink")
		}
		if ents, _ := os.ReadDir(target); len(ents) != 0 {
			t.Fatalf("Listen bound a socket through the symlink: %v", ents)
		}
	})
}

func TestSocketAndStateAreReadableOnlyByTheCoordinatorUser(t *testing.T) {
	r := startRig(t, nil, nil)
	secret := r.register("w1")
	c := r.mustConnect("w1", "i-1", secret)
	l := r.lease(c, "j1")
	if err := c.event(l, 1); err != nil || !c.waitAck(l, 1, 3*time.Second) {
		t.Fatal("no ack")
	}
	_, _ = r.connect("w1", "i-x", "") // an auth refusal puts a line in audit.jsonl
	r.s.mu.Lock()
	r.s.audit("w1", "j1", l.lease, l.epoch, "x")
	r.s.mu.Unlock()
	_ = r.s.RevokeLease("j1", "operator") // leaves j1.cmds.jsonl until acked

	private := func(path string, dir bool) {
		t.Helper()
		fi, err := os.Stat(path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		if fi.Mode().Perm()&0o077 != 0 {
			t.Fatalf("%s is mode %o; group/other must have no access", path, fi.Mode().Perm())
		}
		if dir != fi.IsDir() {
			t.Fatalf("%s: dir=%v", path, fi.IsDir())
		}
	}
	private(CoordDir(r.root), true)
	private(SocketPath(r.root), false)
	if fi, _ := os.Stat(SocketPath(r.root)); fi.Mode().Perm() != 0o600 {
		t.Fatalf("socket mode %o, want 0600", fi.Mode().Perm())
	}
	private(r.s.leasesDir(), true)
	private(r.s.auditPath(), false)
	private(r.s.tablePath(), false)
	private(r.s.recPath("j1"), false)
	private(r.s.cmdsPath("j1"), false)
	private(PidPath(r.root), false)
	private(LockPath(r.root), false)
	private(StatusPath(r.root), false)
}

func TestLeaseDirIsTightenedWhenItAlreadyExistsLoose(t *testing.T) {
	root := hxShortDir(t)
	dir := filepath.Join(root, "runner", "leases")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if _, err := New(Config{Root: root, Applier: &fakeApplier{}}); err != nil {
		t.Fatal(err)
	}
	fi, _ := os.Stat(dir)
	if fi.Mode().Perm() != 0o700 {
		t.Fatalf("lease dir is %o, want 0700", fi.Mode().Perm())
	}
}

// ---------------------------------------------------------------------------------------------------
// 3. goroutine leaks
// ---------------------------------------------------------------------------------------------------

func TestConnectDisconnectCyclesDoNotLeakGoroutines(t *testing.T) {
	r := startRig(t, nil, nil)
	secret := r.register("w1")
	cycle := func() {
		w, f := r.connect("w1", "i-1", secret)
		if f.T != workerproto.TypeWelcome {
			t.Fatalf("handshake: %s %s", f.T, f.Data)
		}
		_ = w.hb()
		w.c.Close()
	}
	cycle() // warm: lazily started goroutines exist before the baseline is taken
	time.Sleep(100 * time.Millisecond)
	base := runtime.NumGoroutine()
	for i := 0; i < 30; i++ {
		cycle()
	}
	for i := 0; i < 10; i++ { // refused handshakes
		w, _ := r.connect("w1", "i-1", NewSecret())
		w.c.Close()
	}
	for i := 0; i < 10; i++ { // connect and vanish without a word
		c, err := net.Dial("unix", SocketPath(r.root))
		if err != nil {
			t.Fatal(err)
		}
		c.Close()
	}
	hxSettle(t, base+4, 4*time.Second)
	deadline := time.Now().Add(3 * time.Second)
	for {
		r.s.connMu.Lock()
		pre, total := r.s.preConn, len(r.s.conns)
		r.s.connMu.Unlock()
		if pre == 0 && total == 0 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("connection accounting leaked: %d pre-hello, %d tracked after every client left", pre, total)
		}
		time.Sleep(25 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------------------------------
// 4. bounds
// ---------------------------------------------------------------------------------------------------

func TestIdleConnectionFloodDoesNotStarveOrCrashTheCoordinator(t *testing.T) {
	r := startRig(t, func(c *Config) { c.MaxConns = 16; c.MaxPreHello = 4; c.HelloTimeout = 5 * time.Second }, nil)
	secret := r.register("w1")
	r2secret := r.register("w2")
	warm := r.mustConnect("w2", "i-w2", r2secret)
	base := runtime.NumGoroutine()

	// The flood comes from another process: sockets from the registered worker's own pid are exempt from
	// eviction, so a same-pid flood would be a different test.
	fl := exec.Command(os.Args[0], "-test.run=TestHelperAgentProcess")
	fl.Env = append(os.Environ(), "HX_HELPER=flood", "HX_SOCK="+SocketPath(r.root))
	fo, err := fl.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := fl.Start(); err != nil {
		t.Fatal(err)
	}
	stopFlood := func() { _ = fl.Process.Kill(); _ = fl.Wait() }
	var floodOnce sync.Once
	t.Cleanup(func() { floodOnce.Do(stopFlood) })
	if line, _ := bufio.NewReader(fo).ReadString('\n'); !strings.Contains(line, "ready") {
		t.Fatalf("flood helper: %q", line)
	}
	time.Sleep(200 * time.Millisecond)
	r.s.connMu.Lock()
	pre, total := r.s.preConn, len(r.s.conns)
	r.s.connMu.Unlock()
	if pre > 4 || total > 16 {
		t.Fatalf("bounds not enforced: %d pre-hello (max 4), %d total (max 16)", pre, total)
	}

	// A real worker gets in (the oldest idle pre-hello socket is evicted for it) and works.
	real, f := r.connect("w1", "i-1", secret)
	if f.T != workerproto.TypeWelcome {
		t.Fatalf("the real worker could not handshake during the flood: %q", f.T)
	}
	l := r.lease(real, "j1")
	if err := real.event(l, 1); err != nil || !real.waitAck(l, 1, 3*time.Second) {
		t.Fatal("the real worker's stream stopped during the flood")
	}
	// the already-connected worker is unaffected too
	if err := warm.hb(); err != nil {
		t.Fatal(err)
	}

	floodOnce.Do(stopFlood)
	deadline := time.Now().Add(3 * time.Second)
	for {
		r.s.connMu.Lock()
		pre, total = r.s.preConn, len(r.s.conns)
		r.s.connMu.Unlock()
		if pre == 0 && total == 2 {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("after the flood: %d pre-hello, %d tracked; want 0 and 2 (the two real workers)", pre, total)
		}
		time.Sleep(25 * time.Millisecond)
	}
	hxSettle(t, base+6, 3*time.Second)
}

func TestConnectionsBeyondTheTotalLimitAreRefusedAndTheSlotIsReusable(t *testing.T) {
	r := startRig(t, func(c *Config) { c.MaxConns = 2 }, nil)
	s1, s2, s3 := r.register("w1"), r.register("w2"), r.register("w3")
	r.mustConnect("w1", "i-1", s1)
	c2 := r.mustConnect("w2", "i-2", s2)
	if w3, f := r.connect("w3", "i-3", s3); f.T != "" {
		t.Fatalf("a third connection was served past MaxConns=2: %q", f.T)
	} else if !w3.closedWithin(time.Second) {
		t.Fatal("the over-limit connection was left open")
	}
	c2.c.Close()
	if _, ok := r.connectEventually("w3", "i-3", s3); !ok {
		t.Fatal("a slot freed by a disconnect was never reusable")
	}
}

type hxTempErr struct{}

func (hxTempErr) Error() string   { return "temporary accept failure" }
func (hxTempErr) Timeout() bool   { return false }
func (hxTempErr) Temporary() bool { return true }

type hxFlakyListener struct {
	net.Listener
	remaining atomic.Int32
	err       error
}

func (f *hxFlakyListener) Accept() (net.Conn, error) {
	if f.remaining.Add(-1) >= 0 {
		return nil, f.err
	}
	return f.Listener.Accept()
}

func TestTemporaryAcceptErrorsAreSurvived(t *testing.T) {
	errs := map[string]error{
		"EMFILE":       syscall.EMFILE,
		"ENFILE":       &net.OpError{Op: "accept", Net: "unix", Err: syscall.ENFILE},
		"ECONNABORTED": syscall.ECONNABORTED,
		"temporary":    hxTempErr{},
	}
	for name, e := range errs {
		t.Run(name, func(t *testing.T) {
			r := startRig(t, nil, func(ln net.Listener) net.Listener {
				f := &hxFlakyListener{Listener: ln, err: e}
				f.remaining.Store(4)
				return f
			})
			secret := r.register("w1")
			if _, ok := r.connectEventually("w1", "i-1", secret); !ok {
				t.Fatalf("the coordinator stopped serving after a temporary %s accept error", name)
			}
			select {
			case <-r.finished:
				t.Fatalf("Serve returned after a temporary accept error: %v", r.serveErr)
			default:
			}
		})
	}
}

func TestAFatalAcceptErrorEndsServeInsteadOfHanging(t *testing.T) {
	boom := errors.New("listener is broken")
	r := startRig(t, nil, func(ln net.Listener) net.Listener {
		f := &hxFlakyListener{Listener: ln, err: boom}
		f.remaining.Store(1 << 20)
		return f
	})
	select {
	case <-r.finished:
	case <-time.After(3 * time.Second):
		t.Fatal("Serve kept running on a permanently failing listener")
	}
	if !errors.Is(r.serveErr, boom) {
		t.Fatalf("Serve returned %v, want the accept error", r.serveErr)
	}
}

func TestSilentPostHelloConnectionIsDroppedAfterTheIdleTimeoutButHeartbeatsKeepItAlive(t *testing.T) {
	const idle = 800 * time.Millisecond
	r := startRig(t, func(c *Config) { c.IdleTimeout = idle }, nil)
	s1, s2 := r.register("w1"), r.register("w2")
	quiet := r.mustConnect("w1", "i-1", s1)
	r.lease(quiet, "j1")
	start := time.Now() // the quiet worker's last frame was just before this
	chatty := r.mustConnect("w2", "i-2", s2)
	l2 := r.lease(chatty, "j2")

	stop := make(chan struct{})
	var kept atomic.Bool
	kept.Store(true)
	go func() {
		for {
			select {
			case <-stop:
				return
			case <-time.After(100 * time.Millisecond):
				if chatty.hb(l2) != nil {
					kept.Store(false)
				}
			}
		}
	}()
	dropped := quiet.closedWithin(3 * time.Second)
	elapsed := time.Since(start)
	close(stop)
	if !dropped {
		t.Fatal("a connection that went silent after hello was never dropped")
	}
	if elapsed < idle/2 {
		t.Fatalf("dropped after %s, well before the %s idle timeout", elapsed, idle)
	}
	if !kept.Load() {
		t.Fatal("the heartbeating connection was dropped")
	}
	if err := chatty.event(l2, 1); err != nil || !chatty.waitAck(l2, 1, 3*time.Second) {
		t.Fatal("the connection that kept heartbeating was dropped by the idle timeout")
	}
	// Dropping the silent connection is not ending its lease: coordinator-side loss is the TTL's job.
	if st := r.state("j1"); st != "active" {
		t.Fatalf("an idle drop ended the lease: %q", st)
	}
}

func TestServeReturnsPromptlyOnCancelAndWaitsForItsGoroutines(t *testing.T) {
	r := startRig(t, nil, nil)
	secrets := map[string]string{}
	var clients []*wire
	for _, id := range []string{"w1", "w2", "w3"} {
		secrets[id] = r.register(id)
		clients = append(clients, r.mustConnect(id, "i-"+id, secrets[id]))
	}
	idle := r.dial() // pre-hello, silent
	half := r.dial() // pre-hello, half a frame
	_, _ = half.c.Write([]byte(`{"v":1,"t":"hel`))
	time.Sleep(100 * time.Millisecond)

	start := time.Now()
	r.cancel()
	select {
	case <-r.finished:
	case <-time.After(3 * time.Second):
		t.Fatal("Serve did not return after cancel")
	}
	if d := time.Since(start); d > 2*time.Second {
		t.Fatalf("Serve took %s to return", d)
	}
	if r.serveErr != nil {
		t.Fatalf("a cancelled Serve returned %v, want nil", r.serveErr)
	}
	// It waited for everything it started.
	done := make(chan struct{})
	go func() { r.s.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(500 * time.Millisecond):
		t.Fatal("goroutines of Serve were still running after it returned")
	}
	for i, c := range append(clients, idle, half) {
		if !c.closedWithin(2 * time.Second) {
			t.Fatalf("client %d was not disconnected by shutdown", i)
		}
	}
}

// ---------------------------------------------------------------------------------------------------
// 5. forgetting leases: revoke, release, abandon, loss
// ---------------------------------------------------------------------------------------------------

func hxStreams(h *harness) int {
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	return h.s.adm.StreamCount()
}

// hxConnect is harness.connect without the shared-variable race: it can be called repeatedly.
func hxConnect(h *harness, id string, slots int) {
	h.t.Helper()
	a, b := net.Pipe()
	w := newWorkerConn(id, "i-"+id, slots, nil, a, h.now)
	h.peer, h.rd, h.w = b, bufio.NewReader(b), w
	h.t.Cleanup(func() { w.close(); b.Close() })
	go func() {
		for {
			select {
			case <-w.done:
				return
			case line := <-w.out:
				if _, err := a.Write(line); err != nil {
					return
				}
			}
		}
	}()
	h.s.mu.Lock()
	h.s.register(w, &workerproto.Welcome{Proto: 1})
	h.s.mu.Unlock()
}

// hxDisconnect is what handleConn does when a worker's connection ends.
func hxDisconnect(h *harness) {
	h.s.mu.Lock()
	if h.s.workers[h.w.id] == h.w {
		delete(h.s.workers, h.w.id)
	}
	h.s.mu.Unlock()
	h.w.close()
}

func hxCmdID(t testing.TB, f workerproto.Frame) string {
	var c struct {
		CmdID string `json:"cmd_id"`
	}
	_ = json.Unmarshal(f.Data, &c)
	if c.CmdID == "" {
		t.Fatalf("frame %s has no cmd_id", f.T)
	}
	return c.CmdID
}

func (h *harness) ack(f workerproto.Frame, cmdID, outcome, why string) {
	h.t.Helper()
	h.send(workerproto.TypeCmdAck, f.Job, f.Lease, f.Epoch, nil, map[string]any{"cmd_id": cmdID, "outcome": outcome, "why": why, "for": f.T})
}

func TestRevokeWhileConnectedDeliversTheRevokeAcceptsItsAckAndForgetsTheLease(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	if n := hxStreams(h); n != 1 {
		t.Fatalf("a live lease holds %d streams, want 1", n)
	}
	if err := h.s.RevokeLease("j1", "operator_revoke"); err != nil {
		t.Fatal(err)
	}
	fs := h.frames()
	revs := ofType(fs, workerproto.TypeLeaseRevoke)
	if len(revs) != 1 || *revs[0].Lease != lease || *revs[0].Epoch != epoch {
		t.Fatalf("want one lease.revoke for the lease, got %d", len(revs))
	}
	var rv workerproto.LeaseRevoke
	_ = json.Unmarshal(revs[0].Data, &rv)
	if rv.Reason != "operator_revoke" {
		t.Fatalf("revoke reason %q", rv.Reason)
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("a revoked lease still holds %d inbound streams", n)
	}
	if r := h.rec("j1"); r.State != "revoked" || r.EndReason != "operator_revoke" {
		t.Fatalf("lease record %+v", r)
	}
	if _, err := os.Stat(h.s.cmdsPath("j1")); err != nil {
		t.Fatal("the revoke is not persisted for redelivery")
	}

	// A forged ack (right command id, wrong epoch) is not an ack of this revoke.
	h.send(workerproto.TypeCmdAck, strp("j1"), &lease, ptr64(epoch+1), nil, map[string]any{"cmd_id": hxCmdID(t, revs[0]), "outcome": "applied", "for": "lease.revoke"})
	if len(ofType(h.frames(), workerproto.TypeRefuse)) != 1 {
		t.Fatal("an ack of the revoke under the wrong epoch was not refused")
	}
	if _, err := os.Stat(h.s.cmdsPath("j1")); err != nil {
		t.Fatal("a forged ack removed the queued revoke")
	}

	// The real ack is accepted even though the lease has already ended.
	h.ack(revs[0], hxCmdID(t, revs[0]), "applied", "")
	if refs := ofType(h.frames(), workerproto.TypeRefuse); len(refs) != 0 {
		t.Fatalf("the ack of a revoke was refused: %s", refs[0].Data)
	}
	if _, err := os.Stat(h.s.cmdsPath("j1")); !os.IsNotExist(err) {
		t.Fatal(".cmds.jsonl survived the revoke's ack")
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("acking a revoke re-created %d stream(s)", n)
	}
	h.s.mu.Lock()
	live := h.s.liveCount("w1")
	h.s.mu.Unlock()
	if live != 0 {
		t.Fatalf("worker still occupies %d slot(s)", live)
	}
}

func ptr64(n int64) *int64 { return &n }

func TestRevokeWhileTheWorkerIsAwayIsRedeliveredOnEveryConnectUntilAcked(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.lease("j1")
	hxDisconnect(h)
	if err := h.s.RevokeLease("j1", "operator_revoke"); err != nil {
		t.Fatalf("revoking a lease whose worker is away: %v", err)
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("%d streams after revoking with the worker away", n)
	}

	var revoke workerproto.Frame
	for i := 0; i < 2; i++ { // the worker keeps coming back without acking
		hxConnect(h, "w1", 1)
		fs := h.frames()
		revs := ofType(fs, workerproto.TypeLeaseRevoke)
		if len(revs) != 1 {
			t.Fatalf("connect %d: lease.revoke delivered %d times, want 1", i+1, len(revs))
		}
		revoke = revs[0]
		w := hxWelcomeFromFrames(t, fs)
		if len(w.Jobs) != 0 {
			t.Fatalf("welcome still lists the revoked lease: %+v", w.Jobs)
		}
	}
	h.ack(revoke, hxCmdID(t, revoke), "applied", "")
	if len(ofType(h.frames(), workerproto.TypeRefuse)) != 0 {
		t.Fatal("the revoke's ack was refused after a reconnect")
	}
	hxConnect(h, "w1", 1)
	if n := len(ofType(h.frames(), workerproto.TypeLeaseRevoke)); n != 0 {
		t.Fatalf("an acked revoke was delivered again (%d)", n)
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("%d streams at the end", n)
	}
}

func hxWelcomeFromFrames(t testing.TB, fs []workerproto.Frame) workerproto.Welcome {
	ws := ofType(fs, workerproto.TypeWelcome)
	if len(ws) != 1 {
		t.Fatalf("want one welcome, got %d", len(ws))
	}
	return hxWelcome(t, ws[0])
}

func TestReleaseEndsTheLeaseAndForgetsItsStream(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	seq := int64(1)
	h.send(workerproto.TypeLeaseRelease, strp("j1"), &lease, &epoch, &seq, map[string]any{"reason": "succeeded"})
	h.flush()
	if r := h.rec("j1"); r.State != "released" || r.EndReason != "succeeded" {
		t.Fatalf("lease record after release: %+v", r)
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("a released lease still holds %d inbound stream(s): flushing the release must not re-create its stream", n)
	}
	h.s.mu.Lock()
	live := h.s.liveCount("w1")
	h.s.mu.Unlock()
	if live != 0 {
		t.Fatalf("a released lease still occupies %d slot(s)", live)
	}
}

func TestAnOfferThatCannotBeSentIsAbandonedWithoutLeakingAStreamOrAnEpoch(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	// A job document too big for one lease.offer frame.
	h.writeJob("j1", map[string]any{"blob": strings.Repeat("x", workerproto.MaxFrameBytes+1024)})
	if err := os.WriteFile(h.s.dispatchPath("j1"), []byte(`{"job":"j1"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	if n := len(ofType(h.frames(), workerproto.TypeLeaseOffer)); n != 0 {
		t.Fatalf("an unsendable offer was sent (%d)", n)
	}
	h.s.mu.Lock()
	l, ok := h.s.leases.Get("j1")
	jl := h.s.jobs["j1"]
	live := h.s.liveCount("w1")
	streams := h.s.adm.StreamCount()
	h.s.mu.Unlock()
	if !ok || l.State != workerproto.LeaseRevoked {
		t.Fatalf("the abandoned lease is %v in the table, want revoked (a busy job for a TTL otherwise)", l.State)
	}
	if jl != nil || live != 0 || streams != 0 {
		t.Fatalf("abandoned offer left state behind: job lease %v, %d slots, %d streams", jl, live, streams)
	}
	if _, err := os.Stat(h.s.cmdsPath("j1")); !os.IsNotExist(err) {
		t.Fatal("abandoned offer left a command file")
	}
	var req dispatchReq
	b, _ := os.ReadFile(h.s.dispatchPath("j1"))
	_ = json.Unmarshal(b, &req)
	if req.WaitReason != waitOffer {
		t.Fatalf("dispatch request not annotated: %q", req.WaitReason)
	}
	// The job is fixed: the next offer goes out under a fresh epoch (the abandoned one is never reused).
	h.writeJob("j1", nil)
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	offers := ofType(h.frames(), workerproto.TypeLeaseOffer)
	if len(offers) != 1 || *offers[0].Epoch != l.Epoch+1 {
		t.Fatalf("re-offer after an abandon: %d offers, epoch %v (want %d)", len(offers), offers, l.Epoch+1)
	}
}

func TestALostLeaseForgetsItsStream(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.lease("j1")
	h.now = h.now.Add(time.Hour)
	h.s.mu.Lock()
	h.s.upSince = h.now.Add(-time.Hour)
	h.now = h.now.Add(7 * time.Second)
	h.s.expire()
	h.s.mu.Unlock()
	if r := h.rec("j1"); r.State != "lost" {
		t.Fatalf("lease not lost: %+v", r)
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("a lost lease still holds %d stream(s)", n)
	}
}

func TestRevokeRequestFileRevokesTheLeaseAndIsConsumed(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.lease("j1")
	hxWriteAtomic(t, filepath.Join(h.s.revokeDir(), "j1.json"), []byte(`{"reason":"operator_revoke"}`))
	h.s.pollOnce()
	if _, err := os.Stat(filepath.Join(h.s.revokeDir(), "j1.json")); !os.IsNotExist(err) {
		t.Fatal("the revoke request was not consumed")
	}
	revs := ofType(h.frames(), workerproto.TypeLeaseRevoke)
	if len(revs) != 1 {
		t.Fatalf("want one lease.revoke, got %d", len(revs))
	}
	if r := h.rec("j1"); r.State != "revoked" || r.EndReason != "operator_revoke" {
		t.Fatalf("lease record %+v", r)
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("%d streams after an operator revoke", n)
	}
}

func TestRevokeRequestForAJobWithNoLiveLeaseIsDropped(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	hxWriteAtomic(t, filepath.Join(h.s.revokeDir(), "ghost.json"), []byte(`{"reason":"x"}`))
	hxWriteAtomic(t, filepath.Join(h.s.revokeDir(), "bad name.json"), []byte(`{}`))
	hxWriteAtomic(t, filepath.Join(h.s.revokeDir(), "junk.json"), []byte(`not json`))
	h.s.pollOnce()
	if _, err := os.Stat(filepath.Join(h.s.revokeDir(), "ghost.json")); !os.IsNotExist(err) {
		t.Fatal("a request for a job with no lease stayed forever")
	}
	if n := len(ofType(h.frames(), workerproto.TypeLeaseRevoke)); n != 0 {
		t.Fatalf("%d revoke frames fabricated", n)
	}
}

// An operator's free-form reason must not make the revoke disappear: the request file is consumed on every
// outcome, so a revoke that fails here is lost without a trace.
func TestRevokeRequestWithAFreeFormReasonStillRevokes(t *testing.T) {
	for name, reason := range map[string]string{
		"spaces":       "stopped by operator: wrong plan",
		"long":         strings.Repeat("r", 90),
		"punctuation":  "wrong plan!! (see #120)",
		"only symbols": "!!!",
	} {
		t.Run(name, func(t *testing.T) {
			h := newHarness(t)
			hxConnect(h, "w1", 1)
			h.lease("j1")
			b, _ := json.Marshal(map[string]string{"reason": reason})
			hxWriteAtomic(t, filepath.Join(h.s.revokeDir(), "j1.json"), b)
			h.s.pollOnce()
			if r := h.rec("j1"); r.State != "revoked" {
				t.Fatalf("a revoke request with reason %q left the lease %q (and the request was consumed)", reason, r.State)
			}
			if n := len(ofType(h.frames(), workerproto.TypeLeaseRevoke)); n != 1 {
				t.Fatalf("worker was sent %d revokes", n)
			}
		})
	}
}

// A graceful cancel is not a revoke: it travels as cancel_requested (sync.job), so the worker finishes and
// releases and its last ops and log still land. Only an explicit revoke ends the lease under the worker.
func TestCancelledCanonicalJobIsNotRevokedButCancelRequestedReachesTheWorker(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.lease("j1")
	h.writeJob("j1", map[string]any{"state": "cancelled", "cancel_requested": true})
	h.s.pollOnce()
	fs := h.frames()
	if n := len(ofType(fs, workerproto.TypeLeaseRevoke)); n != 0 {
		t.Fatalf("a cancelled job's lease was revoked (%d revokes): a graceful cancel must let the worker finish and release", n)
	}
	syncs := ofType(fs, workerproto.TypeSyncJob)
	if len(syncs) != 1 || !strings.Contains(string(syncs[0].Data), `"cancel_requested":true`) {
		t.Fatalf("cancel_requested did not reach the worker: %d sync.job frames", len(syncs))
	}
	if st := h.rec("j1").State; st != "active" {
		t.Fatalf("lease is %q, want active until the worker releases it", st)
	}
	// An explicit revoke request still ends it.
	hxWriteAtomic(t, filepath.Join(h.s.revokeDir(), "j1.json"), []byte(`{"reason":"cancel_escalation"}`))
	h.s.pollOnce()
	if st := h.rec("j1").State; st != "revoked" {
		t.Fatalf("an explicit revoke request left the lease %q", st)
	}
}

// ---------------------------------------------------------------------------------------------------
// 6. slow applies
// ---------------------------------------------------------------------------------------------------

// gateApplier blocks every Apply until release is closed, announcing the job it holds on entered.
type gateApplier struct {
	fakeApplier
	entered chan string
	release chan struct{}
	once    sync.Once
}

// open lets every blocked and future Apply through (idempotent).
func (g *gateApplier) open() { g.once.Do(func() { close(g.release) }) }

func newGate() *gateApplier {
	return &gateApplier{entered: make(chan string, 16), release: make(chan struct{})}
}

func (g *gateApplier) Apply(job string, ops [][]byte) (int64, error) {
	g.entered <- job
	<-g.release
	return g.fakeApplier.Apply(job, ops)
}

func TestHeartbeatsAreHandledWhileASlowApplyIsInFlight(t *testing.T) {
	h := newHarness(t)
	g := newGate()
	t.Cleanup(g.open)
	h.s.cfg.Applier = g
	hxConnect(h, "w1", 2)
	lease, epoch := h.lease("j1")
	h.event("j1", lease, epoch, 1, 1)

	flushed := make(chan struct{})
	go func() {
		h.s.mu.Lock()
		h.s.flushAll()
		h.s.mu.Unlock()
		close(flushed)
	}()
	select {
	case <-g.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("the applier was never entered")
	}
	start := time.Now()
	hb := workerproto.Hb{Jobs: []workerproto.HbJob{{Job: "j1", Lease: lease, Epoch: epoch}}}
	h.send(workerproto.TypeHb, nil, nil, nil, nil, hb)
	// Another job's whole life proceeds too: a lease offered and accepted while j1's apply is in flight.
	h.lease("j2")
	if d := time.Since(start); d > time.Second {
		t.Fatalf("a heartbeat and a second lease took %s behind one slow apply: the coordinator lock is held while applying", d)
	}
	// The same job is not applied twice concurrently.
	h.flush()
	select {
	case j := <-g.entered:
		t.Fatalf("a second concurrent apply of %s started", j)
	default:
	}
	g.open()
	select {
	case <-flushed:
	case <-time.After(3 * time.Second):
		t.Fatal("flush never finished")
	}
	if r := h.rec("j1"); r.AppliedSeq != 1 || r.WireSeq != 1 {
		t.Fatalf("after the slow apply: %+v", r)
	}
}

func TestRevokeDuringASlowApplyEndsTheLeaseCleanly(t *testing.T) {
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
	if err := h.s.RevokeLease("j1", "operator_revoke"); err != nil {
		t.Fatal(err)
	}
	g.open()
	select {
	case <-flushed:
	case <-time.After(3 * time.Second):
		t.Fatal("flush never finished")
	}
	if r := h.rec("j1"); r.State != "revoked" {
		t.Fatalf("a flush that finished after the revoke changed the lease: %+v", r)
	}
	if n := hxStreams(h); n != 0 {
		t.Fatalf("the late flush re-created %d stream(s) for the revoked lease", n)
	}
	if n := len(ofType(h.frames(), workerproto.TypeAck)); n != 0 {
		t.Fatalf("an ack was sent for a revoked lease (%d)", n)
	}
}

func TestInFlightFrameKeepsAWorkersLeaseFromExpiringBehindABusyCoordinator(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.lease("j1")
	h.now = h.now.Add(time.Hour)
	h.s.mu.Lock()
	h.s.upSince = h.now.Add(-time.Hour)
	h.now = h.now.Add(7 * time.Second) // past the TTL since the last heartbeat
	h.w.readAt.Store(time.Now().UnixNano())
	h.s.expire()
	h.s.mu.Unlock()
	if r := h.rec("j1"); r.State != "active" {
		t.Fatalf("a worker whose frame was already read (waiting on the lock) lost its lease: %s", r.State)
	}
	// Control: the same silence with nothing in flight does expire it.
	h.w.readAt.Store(0)
	h.now = h.now.Add(7 * time.Second)
	h.s.mu.Lock()
	h.s.expire()
	h.s.mu.Unlock()
	if r := h.rec("j1"); r.State != "lost" {
		t.Fatalf("a silent worker's lease did not expire: %s", r.State)
	}
}

func TestSlowAppliesOfTwoJobsDoNotExpireHealthyLeases(t *testing.T) {
	g := newGate()
	r := startRig(t, func(c *Config) { c.TTL = time.Second; c.Applier = g }, nil)
	t.Cleanup(g.open) // runs before the rig's own stop, so a failed test cannot wedge shutdown
	secret := r.register("w1")
	w := r.mustConnect("w1", "i-1", secret)
	l1 := r.lease(w, "j1")
	l2 := r.lease(w, "j2")
	if err := w.event(l1, 1); err != nil {
		t.Fatal(err)
	}
	if err := w.event(l2, 1); err != nil {
		t.Fatal(err)
	}
	select {
	case <-g.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("no apply started")
	}
	// Hold the apply for longer than the lease TTL while the worker heartbeats both leases.
	deadline := time.Now().Add(1600 * time.Millisecond)
	for time.Now().Before(deadline) {
		if err := w.hb(l1, l2); err != nil {
			t.Fatalf("heartbeat: %v", err)
		}
		locked := make(chan struct{})
		go func() { r.s.mu.Lock(); r.s.mu.Unlock(); close(locked) }() //nolint:staticcheck
		select {
		case <-locked:
		case <-time.After(500 * time.Millisecond):
			t.Fatal("the coordinator lock is held for the whole apply")
		}
		time.Sleep(100 * time.Millisecond)
	}
	if hxCountCode(t, r.s, "lease_lost") != 0 || r.state("j1") != "active" || r.state("j2") != "active" {
		t.Fatalf("a healthy lease expired during a slow apply: j1=%s j2=%s audit=%v", r.state("j1"), r.state("j2"), auditCodes(t, r.s))
	}
	g.open()
	deadline = time.Now().Add(3 * time.Second)
	for r.rec("j1").AppliedSeq != 1 || r.rec("j2").AppliedSeq != 1 {
		if time.Now().After(deadline) {
			t.Fatalf("applies never completed: j1=%+v j2=%+v", r.rec("j1"), r.rec("j2"))
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// ---------------------------------------------------------------------------------------------------
// 8. rejected offers, 9. forged cmd.ack
// ---------------------------------------------------------------------------------------------------

func hxDispatchFile(t testing.TB, h *harness, job string) map[string]any {
	t.Helper()
	b, err := os.ReadFile(h.s.dispatchPath(job))
	if err != nil {
		t.Fatalf("dispatch file of %s: %v", job, err)
	}
	var m map[string]any
	if json.Unmarshal(b, &m) != nil {
		t.Fatalf("dispatch file is not JSON: %q", b)
	}
	return m
}

func TestRejectedOfferFreesTheSlotIsRetriedAndHeldAfterThreeRejections(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.writeJob("j1", nil)
	if err := os.WriteFile(h.s.dispatchPath("j1"), []byte(`{"job":"j1"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	reject := func(attempt int) {
		t.Helper()
		h.s.mu.Lock()
		h.s.dispatchPass()
		h.s.mu.Unlock()
		offers := ofType(h.frames(), workerproto.TypeLeaseOffer)
		if len(offers) != 1 {
			t.Fatalf("attempt %d: %d offers, want 1", attempt, len(offers))
		}
		if int(*offers[0].Epoch) != attempt {
			t.Fatalf("attempt %d offered under epoch %d", attempt, *offers[0].Epoch)
		}
		h.ack(offers[0], hxCmdID(t, offers[0]), "rejected", "no_slot")
		r := h.rec("j1")
		if r.State != "revoked" || r.EndReason != "offer_rejected:no_slot" {
			t.Fatalf("attempt %d: lease record %+v", attempt, r)
		}
		h.s.mu.Lock()
		live, streams := h.s.liveCount("w1"), h.s.adm.StreamCount()
		h.s.mu.Unlock()
		if live != 0 || streams != 0 {
			t.Fatalf("attempt %d: %d slots and %d streams still held by a rejected offer", attempt, live, streams)
		}
	}
	reject(1)
	if m := hxDispatchFile(t, h, "j1"); m["rejects"] != float64(1) || m["held"] != nil && m["held"] != "" {
		t.Fatalf("after 1 rejection: %v", m)
	}
	reject(2)
	if m := hxDispatchFile(t, h, "j1"); m["rejects"] != float64(2) || m["held"] != nil && m["held"] != "" {
		t.Fatalf("after 2 rejections: %v", m)
	}
	reject(3)
	m := hxDispatchFile(t, h, "j1")
	if m["rejects"] != float64(3) || m["held"] != "offer_rejected:no_slot" {
		t.Fatalf("after 3 rejections the request is not held: %v", m)
	}
	if !strings.Contains(fmt.Sprint(m["wait_reason"]), "held") {
		t.Fatalf("wait_reason does not say it is held: %v", m["wait_reason"])
	}
	for i := 0; i < 3; i++ {
		h.s.mu.Lock()
		h.s.dispatchPass()
		h.s.mu.Unlock()
	}
	if n := len(ofType(h.frames(), workerproto.TypeLeaseOffer)); n != 0 {
		t.Fatalf("a held request was offered again (%d)", n)
	}
	if n := hxCountCode(t, h.s, "offer_rejected"); n != 3 {
		t.Fatalf("%d offer_rejected audit lines, want 3", n)
	}
}

func TestCmdAckCannotActivateALeaseWithACmdIdThatWasNotItsOffer(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 2)
	for _, j := range []string{"j1", "j2"} {
		h.writeJob(j, nil)
		if err := os.WriteFile(h.s.dispatchPath(j), []byte(`{"job":"`+j+`"}`), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	offers := map[string]workerproto.Frame{}
	for _, f := range ofType(h.frames(), workerproto.TypeLeaseOffer) {
		offers[*f.Job] = f
	}
	if len(offers) != 2 {
		t.Fatalf("want offers for j1 and j2, got %d", len(offers))
	}
	o1, o2 := offers["j1"], offers["j2"]
	stillOffered := func(why string) {
		t.Helper()
		if st := h.rec("j1").State; st != "offered" {
			t.Fatalf("%s: lease j1 is %q, want offered", why, st)
		}
		if _, err := os.Stat(h.s.dispatchPath("j1")); err != nil {
			t.Fatalf("%s: dispatch request of j1 was consumed", why)
		}
	}

	h.ack(o1, "c-forged-0001", "applied", "")
	if refs := ofType(h.frames(), workerproto.TypeRefuse); len(refs) != 1 || hxRefuseCode(refs[0]) != workerproto.CodeInvalid {
		t.Fatalf("a made-up cmd_id was not refused invalid: %v", refs)
	}
	stillOffered("forged cmd_id")

	h.ack(o1, hxCmdID(t, o2), "applied", "") // another lease's offer id
	if refs := ofType(h.frames(), workerproto.TypeRefuse); len(refs) != 1 {
		t.Fatalf("another lease's offer id was not refused (%d refuses)", len(refs))
	}
	stillOffered("another lease's offer id")

	h.ack(o1, "c-forged-0002", "rejected", "no_slot") // a forged rejection cannot kill the offer either
	h.frames()
	stillOffered("forged rejection")

	h.ack(o1, hxCmdID(t, o1), "applied", "")
	if refs := ofType(h.frames(), workerproto.TypeRefuse); len(refs) != 0 {
		t.Fatalf("the genuine ack was refused: %s", refs[0].Data)
	}
	if st := h.rec("j1").State; st != "active" {
		t.Fatalf("the genuine ack left the lease %q", st)
	}
	if _, err := os.Stat(h.s.dispatchPath("j1")); !os.IsNotExist(err) {
		t.Fatal("the dispatch request was not removed when the lease became active")
	}
	if _, err := os.Stat(h.s.dispatchPath("j2")); err != nil {
		t.Fatal("activating j1 consumed j2's dispatch request")
	}
	if st := h.rec("j2").State; st != "offered" {
		t.Fatalf("j2 is %q; acking j1 must not touch it", st)
	}
}

// ---------------------------------------------------------------------------------------------------
// 10. outbox loss reported by a worker
// ---------------------------------------------------------------------------------------------------

func hxStatus(t testing.TB, h *harness) Status {
	t.Helper()
	h.s.mu.Lock()
	h.s.writeStatus()
	h.s.mu.Unlock()
	var st Status
	if err := readJSON(StatusPath(h.root), &st); err != nil {
		t.Fatal(err)
	}
	return st
}

func TestWorkerReportedOutboxLossIsAuditedMarkedAndSurfacedOnce(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	hb := func(epoch int64, why string) {
		h.send(workerproto.TypeHb, nil, nil, nil, nil, workerproto.Hb{Jobs: []workerproto.HbJob{{Job: "j1", Lease: lease, Epoch: epoch, Degraded: why}}})
	}

	hb(epoch+1, "op_not_an_object") // a heartbeat for a lease the worker does not hold is not believed
	h.frames()
	if r := h.rec("j1"); r.Degraded != "" {
		t.Fatalf("a stale-epoch heartbeat marked the job degraded: %q", r.Degraded)
	}
	if hxCountCode(t, h.s, "outbox_degraded") != 0 {
		t.Fatal("a stale-epoch heartbeat was audited as outbox loss")
	}

	hb(epoch, "op_not_an_object")
	hb(epoch, "op_not_an_object")
	hb(epoch, "op_too_large") // a different reason later does not re-announce
	if r := h.rec("j1"); r.Degraded != "op_not_an_object" {
		t.Fatalf("lease record degraded = %q", r.Degraded)
	}
	if n := hxCountCode(t, h.s, "outbox_degraded"); n != 1 {
		t.Fatalf("%d outbox_degraded audit lines, want exactly 1", n)
	}
	var marker map[string]any
	if err := readJSON(h.s.degradedPath("j1"), &marker); err != nil {
		t.Fatalf("no degraded marker for the runner's hold: %v", err)
	}
	if marker["job"] != "j1" || marker["lease_id"] != lease || marker["why"] != "op_not_an_object" || marker["worker_id"] != "w1" {
		t.Fatalf("marker content %v", marker)
	}
	if fi, _ := os.Stat(h.s.degradedPath("j1")); fi.Mode().Perm()&0o077 != 0 {
		t.Fatalf("marker mode %o", fi.Mode().Perm())
	}
	hasAttention := func(st Status) bool {
		for _, a := range st.Attention {
			if a.Job == "j1" && a.Reason == "outbox_degraded" && a.Detail == "op_not_an_object" {
				return true
			}
		}
		return false
	}
	if st := hxStatus(t, h); !hasAttention(st) {
		t.Fatalf("coord-status.json does not flag the degraded job: %+v", st.Attention)
	}

	// The coordinator crashes and restarts: the flag is still there.
	h.start()
	hxConnect(h, "w1", 1)
	if st := hxStatus(t, h); !hasAttention(st) {
		t.Fatalf("the degraded flag was lost across a coordinator restart: %+v", st.Attention)
	}
	if _, err := os.Stat(h.s.degradedPath("j1")); err != nil {
		t.Fatal("the marker did not survive the restart")
	}
}

// ---------------------------------------------------------------------------------------------------
// 11. refusal path
// ---------------------------------------------------------------------------------------------------

func hxHandle(h *harness, line []byte) bool {
	h.s.mu.Lock()
	defer h.s.mu.Unlock()
	return h.s.handleLine(h.w, line)
}

func TestFencedFloodIsThrottledInTheAuditAndTheConnectionIsDropped(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	stale := func(seq int) []byte {
		return hxLine(t, workerproto.TypeEventAppend, "j1", lease, epoch+5, int64(seq), map[string]any{"line": hxEventLine, "oseq": seq})
	}
	closedAt := 0
	for i := 1; i <= 500; i++ {
		if hxHandle(h, stale(i)) {
			closedAt = i
			break
		}
	}
	if closedAt != maxConsecutiveRefusal {
		t.Fatalf("the connection was dropped at refusal %d, want %d", closedAt, maxConsecutiveRefusal)
	}
	if n := len(hxAuditLines(t, h.s)); n > 3 {
		t.Fatalf("%d audit lines for one flood; the audit must be throttled: %v", n, auditCodes(t, h.s))
	}
	if codes := auditCodes(t, h.s); len(codes) == 0 || codes[0] != "fenced" {
		t.Fatalf("audit codes %v", codes)
	}
	// Once the throttle window has passed, the next line carries what was suppressed.
	h.now = h.now.Add(auditThrottle + time.Second)
	hxHandle(h, stale(99))
	found := false
	for _, m := range hxAuditLines(t, h.s) {
		if m["code"] == "fenced" && m["suppressed"] == float64(maxConsecutiveRefusal-1) {
			found = true
		}
	}
	if !found {
		t.Fatalf("no audit line carries the suppressed count (%d): %v", maxConsecutiveRefusal-1, hxAuditLines(t, h.s))
	}
	if hxCountCode(t, h.s, "too_many_refusals") == 0 {
		t.Fatal("the drop is not audited")
	}
}

func TestAGoodFrameResetsTheConsecutiveRefusalCount(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	bad := func(seq int) []byte {
		return hxLine(t, workerproto.TypeEventAppend, "j1", lease, epoch+5, int64(seq), map[string]any{"line": hxEventLine, "oseq": seq})
	}
	for round := 0; round < 3; round++ {
		for i := 0; i < maxConsecutiveRefusal-1; i++ {
			if hxHandle(h, bad(i+1)) {
				t.Fatalf("round %d: dropped after only %d consecutive refusals", round, i+1)
			}
		}
		good := hxLine(t, workerproto.TypeHb, "", "", 0, 0, workerproto.Hb{Jobs: []workerproto.HbJob{{Job: "j1", Lease: lease, Epoch: epoch}}})
		if hxHandle(h, good) {
			t.Fatal("a heartbeat closed the connection")
		}
	}
}

func TestAuditLogRotatesPastItsLimit(t *testing.T) {
	h := newHarness(t)
	h.s.cfg.AuditMaxBytes = 600
	for i := 0; i < 60; i++ {
		h.s.audit("w1", "j1", "L-1", 1, "code_"+strconv.Itoa(i))
	}
	fi, err := os.Stat(h.s.auditPath())
	if err != nil {
		t.Fatal(err)
	}
	if fi.Size() > 600+400 {
		t.Fatalf("audit.jsonl grew to %d bytes with a 600 byte limit", fi.Size())
	}
	if _, err := os.Stat(h.s.auditPath() + ".1"); err != nil {
		t.Fatalf("no rotated generation: %v", err)
	}
	ents, _ := os.ReadDir(h.s.leasesDir())
	n := 0
	for _, e := range ents {
		if strings.HasPrefix(e.Name(), "audit") {
			n++
		}
	}
	if n != 2 {
		t.Fatalf("%d audit files, want the current and one previous generation", n)
	}
	if codes := auditCodes(t, h.s); len(codes) == 0 || codes[len(codes)-1] != "code_59" {
		t.Fatalf("the newest line is not in the current file: %v", codes)
	}
	if fi, _ := os.Stat(h.s.auditPath()); fi.Mode().Perm()&0o077 != 0 {
		t.Fatalf("audit file mode %o", fi.Mode().Perm())
	}
}

func TestRefusalFloodFromOneWorkerDoesNotDelayAnotherAndIsDropped(t *testing.T) {
	r := startRig(t, nil, nil)
	s1, s2 := r.register("w1"), r.register("w2")
	c1 := r.mustConnect("w1", "i-1", s1)
	c2 := r.mustConnect("w2", "i-2", s2)
	l1 := r.lease(c1, "j1")
	l2 := r.lease(c2, "j2")

	floodDone := make(chan struct{})
	go func() {
		defer close(floodDone)
		for i := int64(1); i <= 500; i++ {
			stale := l1
			stale.epoch += 9
			if c1.event(stale, i) != nil {
				return
			}
		}
	}()
	start := time.Now()
	if err := c2.event(l2, 1); err != nil || !c2.waitAck(l2, 1, 2*time.Second) {
		t.Fatal("another worker's frame was not acked promptly during the flood")
	}
	if d := time.Since(start); d > 1500*time.Millisecond {
		t.Fatalf("the other worker waited %s for its ack during a refusal flood", d)
	}
	<-floodDone
	refuses := 0
	for {
		f, err := c1.next(2 * time.Second)
		if err != nil {
			break
		}
		if f.T == workerproto.TypeRefuse {
			refuses++
		}
	}
	if refuses > maxConsecutiveRefusal+1 {
		t.Fatalf("the coordinator answered %d refusals; it must hang up after %d", refuses, maxConsecutiveRefusal)
	}
	var wlines int
	for _, m := range hxAuditLines(t, r.s) {
		if m["worker_id"] == "w1" {
			wlines++
		}
	}
	if wlines > 4 {
		t.Fatalf("%d audit lines from 500 refused frames", wlines)
	}
	if r.state("j2") != "active" || r.state("j1") != "active" {
		t.Fatalf("a refusal flood changed lease states: j1=%s j2=%s", r.state("j1"), r.state("j2"))
	}
}

// ---------------------------------------------------------------------------------------------------
// 12. hostile and unlucky I/O
// ---------------------------------------------------------------------------------------------------

func TestOversizedFrameDropsThatConnectionOnly(t *testing.T) {
	r := startRig(t, nil, nil)
	s1, s2 := r.register("w1"), r.register("w2")
	c1 := r.mustConnect("w1", "i-1", s1)
	c2 := r.mustConnect("w2", "i-2", s2)
	l1 := r.lease(c1, "j1")
	l2 := r.lease(c2, "j2")

	junk := bytes.Repeat([]byte("a"), 64<<10)
	go func() { // 1.5 MiB with no newline: the coordinator must stop reading at the limit
		for i := 0; i < 24; i++ {
			if c1.send(junk) != nil {
				return
			}
		}
	}()
	if !c1.closedWithin(3 * time.Second) {
		t.Fatal("a connection that sent an unbounded frame was not dropped")
	}
	if err := c2.event(l2, 1); err != nil || !c2.waitAck(l2, 1, 3*time.Second) {
		t.Fatal("another worker was affected by the oversized frame")
	}
	if r.state("j1") != "active" {
		t.Fatalf("the sender's lease was ended by its oversized frame: %s", r.state("j1"))
	}
	// The sender can come back and resume.
	c1b, f := r.connect("w1", "i-1", s1)
	w := hxWelcome(t, f)
	if len(w.Jobs) != 1 || w.Jobs[0].Job != "j1" {
		t.Fatalf("resume after the drop: %+v", w.Jobs)
	}
	if err := c1b.event(l1, 1); err != nil || !c1b.waitAck(l1, 1, 3*time.Second) {
		t.Fatal("the reconnected worker could not ship")
	}
}

func TestPartialFramesNeverWedgeTheCoordinator(t *testing.T) {
	r := startRig(t, func(c *Config) { c.HelloTimeout = 300 * time.Millisecond; c.IdleTimeout = 700 * time.Millisecond }, nil)
	secret := r.register("w1")

	pre := r.dial()
	if err := pre.send([]byte(`{"v":1,"t":"hello","id":"x`)); err != nil {
		t.Fatal(err)
	}
	if !pre.closedWithin(2 * time.Second) {
		t.Fatal("a half-sent hello held its slot forever")
	}

	w := r.mustConnect("w1", "i-1", secret)
	l := r.lease(w, "j1")
	half := hxLine(t, workerproto.TypeEventAppend, "j1", l.lease, l.epoch, 1, map[string]any{"line": hxEventLine, "oseq": 1})
	if err := w.send(half[:len(half)/2]); err != nil {
		t.Fatal(err)
	}
	if !w.closedWithin(2 * time.Second) {
		t.Fatal("a worker that sent half a frame and stopped was never dropped")
	}
	if r.state("j1") != "active" {
		t.Fatal("the half frame ended the lease")
	}
	// The half frame left no trace: the worker resumes and ships the whole frame.
	w2, ok := r.connectEventually("w1", "i-1", secret)
	if !ok {
		t.Fatal("could not reconnect")
	}
	if err := w2.event(l, 1); err != nil || !w2.waitAck(l, 1, 3*time.Second) {
		t.Fatal("the frame was not applied after the reconnect")
	}
}

func TestSlowReaderIsDroppedWithoutLeakingOrBlockingOthers(t *testing.T) {
	r := startRig(t, nil, nil)
	s1, s2 := r.register("w1"), r.register("w2")
	slow := r.mustConnect("w1", "i-1", s1)
	other := r.mustConnect("w2", "i-2", s2)
	r.lease(slow, "j1")
	l2 := r.lease(other, "j2")
	base := runtime.NumGoroutine()

	// From here on the slow worker never reads. Output queued for it piles up behind a full socket: the
	// coordinator must give up on it rather than buffer without bound or stall everyone else.
	line := append(bytes.Repeat([]byte("x"), 1023), '\n')
	dropped := false
	r.s.mu.Lock()
	w := r.s.workers["w1"]
	for i := 0; i < 50000 && !dropped; i++ {
		r.s.enqueue(w, line)
		dropped = w.closed()
		if i%256 == 255 { // let the writer goroutine push into the socket and block on it
			r.s.mu.Unlock()
			time.Sleep(time.Millisecond)
			r.s.mu.Lock()
		}
	}
	r.s.mu.Unlock()
	if !dropped {
		t.Fatal("50000 queued frames for a peer that never reads did not get it dropped: the send queue is unbounded")
	}
	deadline := time.Now().Add(3 * time.Second)
	for {
		r.s.mu.Lock()
		cur := r.s.workers["w1"]
		r.s.mu.Unlock()
		if cur == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("the dropped connection is still registered")
		}
		time.Sleep(25 * time.Millisecond)
	}
	if err := other.event(l2, 1); err != nil || !other.waitAck(l2, 1, 2*time.Second) {
		t.Fatal("another worker was blocked by the slow reader")
	}
	slow.c.Close()
	hxSettle(t, base+3, 4*time.Second)
	if r.state("j1") != "active" {
		t.Fatalf("dropping a slow reader ended its lease: %s", r.state("j1"))
	}
}

func TestIdleCoordinatorDoesNotPollInALoopOnItsOwnStatusFile(t *testing.T) {
	// Only the file watcher can wake the coordinator here (the poll tick is an hour away). Its own status
	// file lives under the directory it watches; rewriting it must not wake it again.
	r := startRig(t, func(c *Config) { c.PollEvery = time.Hour }, nil)
	time.Sleep(200 * time.Millisecond)
	seen := map[string]bool{}
	end := time.Now().Add(800 * time.Millisecond)
	for time.Now().Before(end) {
		var st Status
		if readJSON(StatusPath(r.root), &st) == nil {
			seen[st.UpdatedAt] = true
		}
		time.Sleep(2 * time.Millisecond)
	}
	if len(seen) > 2 {
		t.Fatalf("an idle coordinator rewrote coord-status.json %d times in 800ms: its own write is waking its own poll loop", len(seen))
	}
}

func TestPartitionAndReconnectLoseAndDuplicateNothing(t *testing.T) {
	r := startRig(t, nil, nil)
	secret := r.register("w1")
	c1 := r.mustConnect("w1", "i-1", secret)
	l := r.lease(c1, "j1")
	for i := int64(1); i <= 10; i++ {
		if err := c1.event(l, i); err != nil {
			t.Fatal(err)
		}
	}
	if !c1.waitAck(l, 10, 3*time.Second) {
		t.Fatal("first ten events not acked")
	}
	for i := int64(11); i <= 15; i++ { // in flight when the link dies
		if err := c1.event(l, i); err != nil {
			t.Fatal(err)
		}
	}
	c1.c.Close()

	c2, f := r.connect("w1", "i-1", secret)
	w := hxWelcome(t, f)
	if len(w.Jobs) != 1 {
		t.Fatalf("welcome jobs: %+v", w.Jobs)
	}
	wire := w.Jobs[0].WireSeq
	if wire < 10 || wire > 15 || w.Jobs[0].AppliedSeq != wire {
		t.Fatalf("welcome resumes at wire %d applied %d, want both in 10..15 and equal", wire, w.Jobs[0].AppliedSeq)
	}
	// Resume from the coordinator's position, replaying a few already-applied frames on top.
	for _, s := range []int64{8, 9, 10} {
		if err := c2.event(l, s); err != nil {
			t.Fatal(err)
		}
	}
	for s := wire + 1; s <= 20; s++ {
		if err := c2.event(l, s); err != nil {
			t.Fatal(err)
		}
	}
	if !c2.waitAck(l, 20, 3*time.Second) {
		t.Fatal("events up to 20 were not acked after the reconnect")
	}
	rec := r.rec("j1")
	if rec.AppliedSeq != 20 || rec.WireSeq != 20 {
		t.Fatalf("lease record after recovery: %+v", rec)
	}
	// The applier never saw a hole, and every op landed.
	r.app.mu.Lock()
	defer r.app.mu.Unlock()
	top := int64(0)
	for _, b := range r.app.batches {
		for i, s := range b {
			if i > 0 && s != b[i-1]+1 {
				t.Fatalf("batch %v is not contiguous", b)
			}
		}
		if len(b) > 0 {
			if b[0] > top+1 {
				t.Fatalf("batch %v skips past %d: the applier was fed a gap", b, top)
			}
			if b[len(b)-1] > top {
				top = b[len(b)-1]
			}
		}
	}
	if top != 20 || r.app.applied != 20 {
		t.Fatalf("applied up to %d (top fed %d), want 20", r.app.applied, top)
	}
}

func TestCoordinatorCrashLosesNothingAndKeepsIssuedOffersAckable(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	h.writeJob("j1", nil)
	if err := os.WriteFile(h.s.dispatchPath("j1"), []byte(`{"job":"j1"}`), 0o644); err != nil {
		t.Fatal(err)
	}
	h.s.mu.Lock()
	h.s.dispatchPass()
	h.s.mu.Unlock()
	offers := ofType(h.frames(), workerproto.TypeLeaseOffer)
	if len(offers) != 1 {
		t.Fatalf("want one offer, got %d", len(offers))
	}
	offer := offers[0]
	if h.rec("j1").State != "offered" {
		t.Fatal("setup: not offered")
	}

	// kill -9: the server is abandoned mid-air, never closed. A new process starts on the same root.
	h.start()
	hxConnect(h, "w1", 1)
	fs := h.frames()
	re := ofType(fs, workerproto.TypeLeaseOffer)
	if len(re) != 1 || hxCmdID(t, re[0]) != hxCmdID(t, offer) || *re[0].Epoch != *offer.Epoch {
		t.Fatalf("the unacked offer was not redelivered intact after the crash: %d frames", len(re))
	}
	// The restored command is known as issued, so the worker's ack of it is accepted and activates the lease.
	h.ack(re[0], hxCmdID(t, re[0]), "applied", "")
	if refs := ofType(h.frames(), workerproto.TypeRefuse); len(refs) != 0 {
		t.Fatalf("the ack of a persisted offer was refused after a restart: %s", refs[0].Data)
	}
	if st := h.rec("j1").State; st != "active" {
		t.Fatalf("lease is %q after the ack of the redelivered offer, want active", st)
	}
	if _, err := os.Stat(h.s.dispatchPath("j1")); !os.IsNotExist(err) {
		t.Fatal("the dispatch request outlived the accepted offer")
	}
}

func TestCrashAfterTheApplierAppliedButBeforeThePositionWasPersistedResumesAtTheAppliedOp(t *testing.T) {
	h := newHarness(t)
	hxConnect(h, "w1", 1)
	lease, epoch := h.lease("j1")
	// coord_apply applied outbox ops 1 and 2 and recorded them in its own file, then the coordinator was
	// killed before it persisted the lease position (wire_seq 0).
	seqFile := h.s.appliedSeqFile("j1")
	if err := os.MkdirAll(filepath.Dir(seqFile), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(seqFile, []byte("2\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h.app.applied = 2
	h.start()
	hxConnect(h, "w1", 1)
	w := hxWelcomeFromFrames(t, h.frames())
	if len(w.Jobs) != 1 || w.Jobs[0].AppliedSeq != 2 || w.Jobs[0].WireSeq != 0 {
		t.Fatalf("welcome after the crash: %+v; want applied 2 (the applier's truth) and wire 0", w.Jobs)
	}
	// The worker resumes: the first frame it can send is wire seq 1, carrying outbox op 3.
	h.event("j1", lease, epoch, 1, 3)
	h.flush()
	if r := h.rec("j1"); r.AppliedSeq != 3 || r.WireSeq != 1 {
		t.Fatalf("after resuming: %+v, want applied 3 wire 1", r)
	}
	h.app.mu.Lock()
	defer h.app.mu.Unlock()
	if last := h.app.batches[len(h.app.batches)-1]; len(last) != 1 || last[0] != 3 {
		t.Fatalf("the applier was handed %v, want only op 3 (1 and 2 are already applied)", last)
	}
}
