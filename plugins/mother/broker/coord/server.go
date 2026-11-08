// Package coord is the coordinator end of Mother's worker protocol (docs/worker-protocol.md) on a
// local Unix socket. All protocol logic (framing, handshake, fencing, stream accounting, leases,
// ownership) is workerproto's; this package owns the I/O around it: the socket, persistence, applying
// ops onto the canonical tree, and the downlink from canonical state to workers.
package coord

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"

	"mother-broker/workerproto"
)

// ServerCaps are the capabilities the coordinator advertises.
var ServerCaps = []string{"log.stream", "artifact.chunked", "checkpoint.v1", "hold.boundary"}

// downlinkKeys are the job keys mirrored to a worker with sync.job: the intersection of the plan's list
// and workerproto.SyncDownKeys (paused_reason and auto_resume_at are not in the shared table: a worker
// owns paused_reason, and the supervisor derives the pause details from pause_requested).
var downlinkKeys = []string{"cancel_requested", "pause_requested", "max_cost_usd", "force_start"}

type Config struct {
	Root       string // canonical $MOTHER_ROOT
	LibDir     string // plugin lib dir (coord_apply.sh)
	TTL        time.Duration
	Now        func() time.Time
	Applier    Applier
	FlushEvery time.Duration // default 200ms
	FlushOps   int           // default 64
	PollEvery  time.Duration // default 1s
	Logf       func(format string, args ...any)
}

type workerConn struct {
	id       string
	instance string
	slots    int
	caps     []string
	conn     net.Conn
	out      chan []byte
	since    time.Time
	once     sync.Once
}

func (w *workerConn) close() { w.once.Do(func() { w.conn.Close() }) }

// Server is the coordinator. One mutex guards all state; connection goroutines only parse, then
// call into handleLine under it.
type Server struct {
	cfg Config

	mu       sync.Mutex
	leases   *workerproto.LeaseTable
	adm      *workerproto.Admitter
	jobs     map[string]*jobLease
	workers  map[string]*workerConn
	upSince  time.Time
	fileSent map[string]string
	kick     chan struct{}
	ln       net.Listener
}

func New(cfg Config) (*Server, error) {
	if cfg.Now == nil {
		cfg.Now = time.Now
	}
	if cfg.TTL <= 0 {
		cfg.TTL = workerproto.LeaseTTL
	}
	if cfg.FlushEvery <= 0 {
		cfg.FlushEvery = 200 * time.Millisecond
	}
	if cfg.FlushOps <= 0 {
		cfg.FlushOps = 64
	}
	if cfg.PollEvery <= 0 {
		cfg.PollEvery = time.Second
	}
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	if cfg.Applier == nil {
		cfg.Applier = ExecApplier{Root: cfg.Root, LibDir: cfg.LibDir}
	}
	s := &Server{cfg: cfg, jobs: map[string]*jobLease{}, workers: map[string]*workerConn{}, fileSent: map[string]string{}, kick: make(chan struct{}, 1)}
	s.upSince = cfg.Now()
	if err := os.MkdirAll(s.leasesDir(), 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(s.dispatchDir(), 0o755); err != nil {
		return nil, err
	}
	if err := s.restore(); err != nil {
		return nil, err
	}
	for _, p := range workerproto.SyncFilePaths() {
		s.fileSent[p] = s.readSyncFile(p)
	}
	return s, nil
}

func (s *Server) logf(format string, args ...any) { s.cfg.Logf(format, args...) }

// restore loads the lease table snapshot and each live lease's record and queued commands. A corrupt
// snapshot is refused (never loaded): reissuing an epoch could let a stale worker write.
func (s *Server) restore() error {
	var snap workerproto.LeaseSnapshot
	if b, err := os.ReadFile(s.tablePath()); err == nil {
		if err := json.Unmarshal(b, &snap); err != nil {
			return fmt.Errorf("lease table %s is corrupt: %w", s.tablePath(), err)
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	if snap.Epochs == nil {
		snap.Epochs = map[string]int64{}
	}
	t, err := workerproto.RestoreLeaseTable(snap)
	if err != nil {
		return fmt.Errorf("lease table %s: %w", s.tablePath(), err)
	}
	s.leases = t
	s.adm = workerproto.NewAdmitter(t, s.jobState)
	for _, r := range snap.Leases {
		jl := &jobLease{job: r.Job, pending: map[int64]workerproto.Frame{}}
		if err := readJSON(s.recPath(r.Job), &jl.rec); err != nil || jl.rec.LeaseID != r.ID {
			jl.rec = LeaseRec{Job: r.Job, LeaseID: r.ID, Epoch: r.Epoch, WorkerID: r.Worker, OfferedAt: fmtTime(r.LastHB)}
		}
		jl.rec.State = string(r.State)
		jl.rec.LastHB = fmtTime(r.LastHB)
		s.loadCmds(jl)
		s.jobs[r.Job] = jl
		s.adm.SetApplied(r.Job, r.ID, r.Epoch, jl.rec.WireSeq)
	}
	return nil
}

// Close stops accepting and drops every connection; leases are untouched (coordinator absence never
// ends a lease).
func (s *Server) Close() {
	s.mu.Lock()
	if s.ln != nil {
		s.ln.Close()
	}
	for _, w := range s.workers {
		w.close()
	}
	for _, jl := range s.jobs {
		if jl.rec.State == string(workerproto.LeaseActive) || jl.rec.State == string(workerproto.LeaseOffered) {
			s.persistRec(jl)
		}
	}
	_ = s.persistTable()
	s.mu.Unlock()
}

// Serve runs the daemon on ln until ctx is done.
func (s *Server) Serve(ctx context.Context, ln net.Listener) error {
	s.mu.Lock()
	s.ln = ln
	s.mu.Unlock()
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); s.loops(ctx) }()
	go func() { <-ctx.Done(); ln.Close() }()
	for {
		c, err := ln.Accept()
		if err != nil {
			wg.Wait()
			if ctx.Err() != nil {
				return nil
			}
			return err
		}
		uc, ok := c.(*net.UnixConn)
		if !ok {
			c.Close()
			continue
		}
		go s.handleConn(uc)
	}
}

func (s *Server) loops(ctx context.Context) {
	flush := time.NewTicker(s.cfg.FlushEvery)
	poll := time.NewTicker(s.cfg.PollEvery)
	expEvery := s.cfg.TTL / 3
	if expEvery > 5*time.Second {
		expEvery = 5 * time.Second
	}
	if expEvery < 100*time.Millisecond {
		expEvery = 100 * time.Millisecond
	}
	expire := time.NewTicker(expEvery)
	defer flush.Stop()
	defer poll.Stop()
	defer expire.Stop()

	if w, err := fsnotify.NewWatcher(); err == nil {
		defer w.Close()
		_ = w.Add(s.dispatchDir())
		_ = w.Add(s.path("runner"))
		go func() {
			for {
				select {
				case <-ctx.Done():
					return
				case _, ok := <-w.Events:
					if !ok {
						return
					}
					select {
					case s.kick <- struct{}{}:
					default:
					}
				case <-w.Errors:
				}
			}
		}()
	}
	s.pollOnce()
	for {
		select {
		case <-ctx.Done():
			return
		case <-flush.C:
			s.mu.Lock()
			s.flushAll()
			s.mu.Unlock()
		case <-expire.C:
			s.mu.Lock()
			s.expire()
			s.mu.Unlock()
		case <-poll.C:
			s.pollOnce()
		case <-s.kick:
			s.pollOnce()
		}
	}
}

func (s *Server) pollOnce() {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.dispatchPass()
	s.holdPass()
	s.syncJobPass()
	s.syncFilePass()
	s.writeStatus()
}

// ---------- connections ----------

func (s *Server) handleConn(c *net.UnixConn) {
	defer c.Close()
	if err := peerUIDOK(c); err != nil {
		s.logf("refusing worker connection: %v", err)
		return
	}
	br := bufio.NewReaderSize(c, 64<<10)
	_ = c.SetReadDeadline(time.Now().Add(10 * time.Second))
	line, err := workerproto.ReadFrame(br)
	if err != nil {
		return
	}
	reply := func(t string, data any) {
		f, e := workerproto.NewFrame(t, newID("f-"), s.now(), data)
		if e != nil {
			return
		}
		if b, e := workerproto.Encode(f); e == nil {
			_, _ = c.Write(b)
		}
	}
	f, err := workerproto.Decode(line)
	if err == nil {
		err = workerproto.ValidateFrom(workerproto.FromWorker, f)
	}
	if err == nil && f.T != workerproto.TypeHello {
		err = &workerproto.ProtoError{Code: workerproto.CodeInvalid, Msg: "first frame must be hello"}
	}
	if err != nil {
		reply(workerproto.TypeRefuse, workerproto.RefuseFor(err))
		return
	}
	var h workerproto.Hello
	_ = json.Unmarshal(f.Data, &h)
	slots := helloSlots(f.Data)
	welcome, ref := workerproto.Negotiate(h, workerproto.ProtoMin, workerproto.ProtoMax, ServerCaps)
	if ref != nil {
		reply(workerproto.TypeRefuse, ref)
		return
	}
	w := &workerConn{id: h.WorkerID, instance: h.InstanceID, slots: slots, caps: welcome.Caps, conn: c, out: make(chan []byte, 4096), since: s.now()}
	s.mu.Lock()
	// hello goes through Admit like every frame: the identity is the connection's, not the frame's.
	if _, err := s.adm.Admit(w.id, line, s.now()); err != nil {
		s.mu.Unlock()
		reply(workerproto.TypeRefuse, workerproto.RefuseFor(err))
		return
	}
	s.register(w, welcome)
	s.mu.Unlock()
	_ = c.SetReadDeadline(time.Time{})

	go func() {
		for b := range w.out {
			_ = c.SetWriteDeadline(time.Now().Add(10 * time.Second))
			if _, err := c.Write(b); err != nil {
				w.close()
				return
			}
		}
	}()
	defer func() {
		s.mu.Lock()
		if s.workers[w.id] == w {
			delete(s.workers, w.id)
		}
		s.mu.Unlock()
		w.close()
	}()
	for {
		line, err := workerproto.ReadFrame(br)
		if err != nil {
			if workerproto.ErrorCode(err) == workerproto.CodeTooLarge {
				s.mu.Lock()
				s.sendRefuse(w, nil, workerproto.CodeTooLarge)
				s.mu.Unlock()
			}
			return
		}
		s.mu.Lock()
		closeIt := s.handleLine(w, line)
		s.mu.Unlock()
		if closeIt {
			return
		}
	}
}

// helloSlots reads the additive hello.data.slots field (default 1).
func helloSlots(data json.RawMessage) int {
	var d struct {
		Slots int `json:"slots"`
	}
	_ = json.Unmarshal(data, &d)
	if d.Slots < 1 {
		return 1
	}
	if d.Slots > 64 {
		return 64
	}
	return d.Slots
}

func (s *Server) hbIntervalS() int {
	n := int(s.cfg.TTL.Seconds() / 3)
	if n > workerproto.HeartbeatIntervalS {
		n = workerproto.HeartbeatIntervalS
	}
	if n < 1 {
		n = 1
	}
	return n
}

// register installs a freshly welcomed connection: welcome (with the resume position of each of the
// worker's live leases), redelivery of unacked commands, and the current sync files. Streams are
// rebased to the committed position: anything buffered from an earlier connection is discarded, because
// the worker re-derives its frames from that position.
func (s *Server) register(w *workerConn, welcome *workerproto.Welcome) {
	if old := s.workers[w.id]; old != nil {
		old.close()
	}
	s.workers[w.id] = w
	welcome.HbIntervalS = s.hbIntervalS()
	welcome.LeaseTTLS = int(s.cfg.TTL.Seconds())
	for _, jl := range s.sortedJobs() {
		if jl.rec.WorkerID != w.id || !live(jl.rec.State) {
			continue
		}
		jl.pending = map[int64]workerproto.Frame{}
		s.adm.SetApplied(jl.job, jl.rec.LeaseID, jl.rec.Epoch, jl.rec.WireSeq)
		welcome.Jobs = append(welcome.Jobs, workerproto.WelcomeJob{
			Job: jl.job, Lease: jl.rec.LeaseID, Epoch: jl.rec.Epoch,
			AppliedSeq: s.truthApplied(jl), WireSeq: jl.rec.WireSeq, LogOffset: s.logSize(jl.job),
		})
	}
	s.sendFrame(w, workerproto.TypeWelcome, nil, welcome)
	for _, jl := range s.sortedJobs() {
		if jl.rec.WorkerID != w.id || !live(jl.rec.State) {
			continue
		}
		for _, c := range jl.cmds {
			if f, err := workerproto.Decode(c.Frame); err == nil {
				s.adm.Issued(f)
			}
			s.enqueue(w, append(append([]byte{}, c.Frame...), '\n'))
		}
	}
	for _, p := range workerproto.SyncFilePaths() {
		s.sendSyncFile(w, p, s.readSyncFile(p))
	}
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

func live(state string) bool {
	return state == string(workerproto.LeaseActive) || state == string(workerproto.LeaseOffered)
}

func (s *Server) sortedJobs() []*jobLease {
	out := make([]*jobLease, 0, len(s.jobs))
	for _, jl := range s.jobs {
		out = append(out, jl)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].job < out[j].job })
	return out
}

func (s *Server) enqueue(w *workerConn, b []byte) {
	select {
	case w.out <- b:
	default:
		s.logf("worker %s: send queue full; dropping the connection", w.id)
		w.close()
	}
}

// sendFrame builds and queues a frame. lease (optional) supplies the job/lease/epoch envelope.
func (s *Server) sendFrame(w *workerConn, t string, jl *jobLease, data any) {
	b, err := s.buildFrame(t, jl, data)
	if err != nil {
		s.logf("build %s: %v", t, err)
		return
	}
	s.enqueue(w, b)
}

func (s *Server) buildFrame(t string, jl *jobLease, data any) ([]byte, error) {
	f, err := workerproto.NewFrame(t, newID("f-"), s.now(), data)
	if err != nil {
		return nil, err
	}
	if jl != nil {
		f.Job, f.Lease, f.Epoch = workerproto.Str(jl.job), workerproto.Str(jl.rec.LeaseID), workerproto.Int(jl.rec.Epoch)
	}
	return workerproto.Encode(f)
}

func (s *Server) sendRefuse(w *workerConn, f *workerproto.Frame, code string) {
	r := workerproto.Refuse{Code: code, Msg: "frame refused"}
	fr, err := workerproto.NewFrame(workerproto.TypeRefuse, newID("f-"), s.now(), r)
	if err != nil {
		return
	}
	if f != nil {
		fr.Job, fr.Lease, fr.Epoch = f.Job, f.Lease, f.Epoch
	}
	if b, err := workerproto.Encode(fr); err == nil {
		s.enqueue(w, b)
	}
}

// ---------- ingest ----------

// handleLine admits one worker frame. It returns true when the connection should be closed.
func (s *Server) handleLine(w *workerConn, line []byte) bool {
	now := s.now()
	adm, err := s.adm.Admit(w.id, line, now)
	f := adm.Frame
	if err != nil {
		code := workerproto.ErrorCode(err)
		if code == "" {
			code = workerproto.CodeInvalid
		}
		switch code {
		case workerproto.CodeFenced, workerproto.CodeNotLeased, workerproto.CodeUnknownJob, workerproto.CodeOwnership:
			job, lease, epoch := "", "", int64(0)
			if f.Job != nil {
				job = *f.Job
			}
			if f.Lease != nil {
				lease = *f.Lease
			}
			if f.Epoch != nil {
				epoch = *f.Epoch
			}
			s.audit(w.id, job, lease, epoch, code)
		}
		s.sendRefuse(w, &f, code)
		return false
	}
	switch f.T {
	case workerproto.TypeHello:
		s.sendRefuse(w, &f, workerproto.CodeInvalid)
	case workerproto.TypeBye:
		return true
	case workerproto.TypeHb:
		s.onHb(w, f, adm)
	case workerproto.TypeCmdAck:
		s.onCmdAck(w, f)
	default:
		s.onStream(w, f, adm.Verdict)
	}
	return false
}

func (s *Server) onHb(w *workerConn, f workerproto.Frame, adm workerproto.Admission) {
	var hb workerproto.Hb
	_ = json.Unmarshal(f.Data, &hb)
	refused := map[string]string{}
	for _, r := range adm.HbRefused {
		refused[r.Job] = r.Code
	}
	for _, j := range hb.Jobs {
		if code, bad := refused[j.Job]; bad {
			// A heartbeat for a lease still `offered` to this worker (its offer ack not yet processed, or
			// the offer being redelivered after a restart) is early, not stale: wait for the ack.
			if l, ok := s.leases.Get(j.Job); ok && l.State == workerproto.LeaseOffered && l.ID == j.Lease && l.Epoch == j.Epoch && l.Worker == w.id {
				continue
			}
			s.audit(w.id, j.Job, j.Lease, j.Epoch, code)
			fr := workerproto.Frame{Job: workerproto.Str(j.Job), Lease: workerproto.Str(j.Lease), Epoch: workerproto.Int(j.Epoch)}
			s.sendRefuse(w, &fr, code)
			continue
		}
		jl := s.jobs[j.Job]
		if jl == nil {
			continue
		}
		if l, ok := s.leases.Get(j.Job); ok && l.ID == j.Lease {
			jl.rec.LastHB = fmtTime(l.LastHB)
			s.persistRec(jl)
		}
	}
}

func (s *Server) onCmdAck(w *workerConn, f workerproto.Frame) {
	var ack workerproto.CmdAck
	_ = json.Unmarshal(f.Data, &ack)
	if f.Job == nil {
		return // a sync.file ack: nothing is persisted for those
	}
	jl := s.jobs[*f.Job]
	if jl == nil {
		return
	}
	var typ string
	for i, c := range jl.cmds {
		if c.ID == ack.CmdID {
			typ = c.Type
			jl.cmds = append(jl.cmds[:i], jl.cmds[i+1:]...)
			s.persistCmds(jl)
			break
		}
	}
	if typ != workerproto.TypeLeaseOffer {
		return
	}
	if ack.Outcome == workerproto.OutcomeRejected {
		s.audit(w.id, jl.job, jl.rec.LeaseID, jl.rec.Epoch, "offer_rejected")
		return
	}
	if l, ok := s.leases.Get(jl.job); ok && l.State == workerproto.LeaseActive && jl.rec.State != string(workerproto.LeaseActive) {
		jl.rec.State = string(workerproto.LeaseActive)
		jl.rec.LastHB = fmtTime(l.LastHB)
		s.persistRec(jl)
		_ = s.persistTable()
		_ = os.Remove(s.dispatchPath(jl.job))
	}
}

func (s *Server) onStream(w *workerConn, f workerproto.Frame, v workerproto.Verdict) {
	jl := s.jobs[*f.Job]
	if jl == nil {
		return
	}
	switch v {
	case workerproto.Apply, workerproto.Gap:
		jl.pending[*f.Seq] = f
		jl.dirty = true
		if v == workerproto.Gap {
			s.sendAck(w, jl, f)
		}
		if len(jl.pending) >= s.cfg.FlushOps {
			s.flushJob(jl)
		}
	default: // Duplicate: already applied (or already buffered); re-ack so the worker's window trims.
		s.sendAck(w, jl, f)
	}
}

func (s *Server) sendAck(w *workerConn, jl *jobLease, f workerproto.Frame) {
	d, err := s.adm.AckFor(f)
	if err != nil {
		return
	}
	s.sendFrame(w, workerproto.TypeAck, jl, d)
}

func (s *Server) flushAll() {
	for _, jl := range s.sortedJobs() {
		if jl.dirty {
			s.flushJob(jl)
		}
	}
}

func isOp(t string) bool {
	return t == workerproto.TypeJobSet || t == workerproto.TypeEventAppend || t == workerproto.TypeRecordAppend || t == workerproto.TypeArtifactPut
}

// flushJob applies the contiguous run of pending frames: ops as one coord_apply batch, log chunks
// directly, then (apply, persist, commit, ack) in that order. A stalled op (applier error, gap) leaves
// the rest pending for the next tick.
func (s *Server) flushJob(jl *jobLease) {
	if !live(jl.rec.State) {
		jl.pending = map[int64]workerproto.Frame{}
		jl.dirty = false
		return
	}
	anchor := workerproto.Frame{Job: workerproto.Str(jl.job), Lease: workerproto.Str(jl.rec.LeaseID), Epoch: workerproto.Int(jl.rec.Epoch)}
	d, err := s.adm.AckFor(anchor)
	if err != nil {
		return
	}
	var run []workerproto.Frame
	for seq := d.Seq + 1; len(run) < 256; seq++ {
		f, ok := jl.pending[seq]
		if !ok {
			break
		}
		run = append(run, f)
	}
	if len(run) == 0 {
		jl.dirty = len(jl.pending) > 0
		return
	}
	// Build the apply batch. A frame without a usable oseq cannot be an outbox op: audit and skip it
	// (still committed, so the stream does not wedge on one bad frame).
	type item struct {
		f     workerproto.Frame
		oseq  int64 // 0: not an applier op
		valid bool
	}
	items := make([]item, len(run))
	var ops [][]byte
	for i, f := range run {
		items[i] = item{f: f, valid: true}
		if !isOp(f.T) {
			continue
		}
		oseq, skip, data, ok := splitOseq(f.Data)
		if !ok {
			s.audit(jl.rec.WorkerID, jl.job, jl.rec.LeaseID, jl.rec.Epoch, "invalid_op")
			items[i].valid = false
			continue
		}
		items[i].oseq = oseq
		// Outbox ops the worker consumed without sending (every key refused by the ownership table) are
		// filled with empty job.set ops, which coord_apply accepts as no-ops, so its seq stays contiguous.
		for n := skip[0]; skip[1] >= skip[0] && n <= skip[1]; n++ {
			ph, _ := json.Marshal(map[string]any{"seq": n, "t": workerproto.TypeJobSet, "ts": f.TS, "data": map[string]any{"set": map[string]any{}, "del": []string{}}})
			ops = append(ops, ph)
		}
		line, _ := json.Marshal(struct {
			Seq  int64           `json:"seq"`
			T    string          `json:"t"`
			TS   string          `json:"ts"`
			Data json.RawMessage `json:"data"`
		}{oseq, f.T, f.TS, data})
		ops = append(ops, line)
		if f.T == workerproto.TypeJobSet {
			s.noteWorkerSet(jl, data)
		}
	}
	var applied int64
	if len(ops) > 0 {
		var aerr error
		applied, aerr = s.cfg.Applier.Apply(jl.job, ops)
		if aerr != nil {
			s.logf("apply %s: %v", jl.job, aerr)
		}
	}
	committed := 0
	var release *workerproto.LeaseRelease
	for _, it := range items {
		if it.oseq > applied {
			break
		}
		if it.f.T == workerproto.TypeLogAppend {
			var la workerproto.LogAppend
			_ = json.Unmarshal(it.f.Data, &la)
			if ok := s.writeLog(jl, la); !ok {
				break
			}
		}
		if it.f.T == workerproto.TypeLeaseRelease {
			var lr workerproto.LeaseRelease
			_ = json.Unmarshal(it.f.Data, &lr)
			release = &lr
		}
		if err := s.adm.Commit(jl.rec.WorkerID, it.f); err != nil {
			s.logf("commit %s seq %d: %v", jl.job, *it.f.Seq, err)
			break
		}
		delete(jl.pending, *it.f.Seq)
		committed++
		jl.rec.WireSeq = *it.f.Seq
		if it.oseq > jl.rec.AppliedSeq {
			jl.rec.AppliedSeq = it.oseq
		}
		if release != nil {
			break
		}
	}
	if applied > jl.rec.AppliedSeq {
		jl.rec.AppliedSeq = applied
	}
	jl.rec.LogOffset = s.logSize(jl.job)
	if release != nil {
		s.endLease(jl, workerproto.LeaseReleased, release.Reason)
	} else {
		s.persistRec(jl)
	}
	jl.dirty = len(jl.pending) > 0
	if w := s.workers[jl.rec.WorkerID]; w != nil && committed > 0 {
		s.sendAck(w, jl, anchor)
	}
}

// maxSkip bounds the placeholder range one frame may ask for.
const maxSkip = 4096

// splitOseq pulls the additive outbox fields out of an op frame's data: oseq (this op's outbox seq) and
// the optional oskip [from,to] (ops before it that were never sent). It returns the data without them.
func splitOseq(data json.RawMessage) (oseq int64, skip [2]int64, rest json.RawMessage, ok bool) {
	var m map[string]json.RawMessage
	if json.Unmarshal(data, &m) != nil {
		return 0, skip, nil, false
	}
	raw, found := m["oseq"]
	if !found || json.Unmarshal(raw, &oseq) != nil || oseq < 1 {
		return 0, skip, nil, false
	}
	if r, found := m["oskip"]; found {
		var pair []int64
		if json.Unmarshal(r, &pair) != nil || len(pair) != 2 || pair[0] < 1 || pair[1] < pair[0] || pair[1] >= oseq || pair[1]-pair[0] >= maxSkip {
			return 0, skip, nil, false
		}
		skip = [2]int64{pair[0], pair[1]}
	} else {
		skip = [2]int64{1, 0}
	}
	delete(m, "oseq")
	delete(m, "oskip")
	b, err := json.Marshal(m)
	if err != nil {
		return 0, skip, nil, false
	}
	return oseq, skip, b, true
}

// noteWorkerSet records downlink-key values a worker's job.set carries, so the canonical value that
// results is not echoed back to it (echo suppression).
func (s *Server) noteWorkerSet(jl *jobLease, data json.RawMessage) {
	var js workerproto.JobSet
	if json.Unmarshal(data, &js) != nil {
		return
	}
	for _, k := range downlinkKeys {
		if v, ok := js.Set[k]; ok {
			s.setSynced(jl, k, v)
		}
	}
	for _, k := range js.Del {
		for _, dk := range downlinkKeys {
			if k == dk {
				s.setSynced(jl, k, json.RawMessage("null"))
			}
		}
	}
}

func (s *Server) setSynced(jl *jobLease, k string, v json.RawMessage) {
	if jl.rec.Synced == nil {
		jl.rec.Synced = map[string]json.RawMessage{}
	}
	jl.rec.Synced[k] = v
}

// writeLog appends a log chunk at its offset. Older bytes are trimmed or dropped; a hole is refused
// (the caller leaves the frame uncommitted so the worker is asked to resend).
func (s *Server) writeLog(jl *jobLease, la workerproto.LogAppend) bool {
	raw, err := base64.StdEncoding.DecodeString(la.B64)
	if err != nil {
		return true // cannot happen after Validate; never wedge the stream on it
	}
	size := s.logSize(jl.job)
	switch {
	case la.Offset > size:
		s.audit(jl.rec.WorkerID, jl.job, jl.rec.LeaseID, jl.rec.Epoch, "log_gap")
		return false
	case la.Offset+int64(len(raw)) <= size:
		return true
	}
	raw = raw[size-la.Offset:]
	if err := os.MkdirAll(s.path("logs"), 0o755); err != nil {
		return false
	}
	f, err := os.OpenFile(s.logPath(jl.job), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0o644)
	if err != nil {
		s.logf("log %s: %v", jl.job, err)
		return false
	}
	defer f.Close()
	if _, err := f.Write(raw); err != nil {
		s.logf("log %s: %v", jl.job, err)
		return false
	}
	return true
}

// endLease records a terminal lease state (released, lost or revoked).
func (s *Server) endLease(jl *jobLease, to workerproto.LeaseState, reason string) {
	jl.rec.State = string(to)
	jl.rec.EndedAt = fmtTime(s.now())
	jl.rec.EndReason = reason
	jl.pending = map[int64]workerproto.Frame{}
	jl.cmds = nil
	jl.dirty = false
	s.persistCmds(jl)
	s.persistRec(jl)
	if err := s.persistTable(); err != nil {
		s.logf("persist lease table: %v", err)
	}
}

// ---------- loss ----------

func (s *Server) expire() {
	for _, l := range s.leases.ExpireTTL(s.now(), s.upSince, s.cfg.TTL) {
		jl := s.jobs[l.Job]
		if jl == nil || jl.rec.LeaseID != l.ID {
			continue
		}
		s.endLease(jl, workerproto.LeaseLost, "lost")
		s.audit(l.Worker, l.Job, l.ID, l.Epoch, "lease_lost")
		note, _ := json.Marshal(map[string]any{"job": l.Job, "lease_id": l.ID, "epoch": l.Epoch, "worker_id": l.Worker, "at": fmtTime(s.now()), "last_hb": fmtTime(l.LastHB)})
		if err := writeFileAtomic(s.lostPath(l.Job), append(note, '\n'), false); err != nil {
			s.logf("write lost marker %s: %v", l.Job, err)
		}
		s.adm.Forget(l.Job, l.ID, l.Epoch)
	}
}

// ---------- status ----------

type StatusWorker struct {
	ID        string   `json:"id"`
	Instance  string   `json:"instance_id"`
	Slots     int      `json:"slots"`
	Free      int      `json:"free"`
	Caps      []string `json:"caps"`
	Connected bool     `json:"connected"`
	Since     string   `json:"connected_since"`
}

type StatusLease struct {
	Job      string  `json:"job"`
	LeaseID  string  `json:"lease_id"`
	Epoch    int64   `json:"epoch"`
	WorkerID string  `json:"worker_id"`
	State    string  `json:"state"`
	HbAgeS   float64 `json:"hb_age_s"`
}

type Status struct {
	Running   bool           `json:"running"`
	PID       int            `json:"pid"`
	UpdatedAt string         `json:"updated_at"`
	Workers   []StatusWorker `json:"workers"`
	Leases    []StatusLease  `json:"leases"`
}

func (s *Server) liveCount(worker string) int {
	n := 0
	for _, jl := range s.jobs {
		if jl.rec.WorkerID == worker && live(jl.rec.State) {
			n++
		}
	}
	return n
}

func (s *Server) writeStatus() {
	st := Status{Running: true, PID: os.Getpid(), UpdatedAt: fmtTime(s.now()), Workers: []StatusWorker{}, Leases: []StatusLease{}}
	ids := make([]string, 0, len(s.workers))
	for id := range s.workers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	for _, id := range ids {
		w := s.workers[id]
		st.Workers = append(st.Workers, StatusWorker{ID: id, Instance: w.instance, Slots: w.slots, Free: w.slots - s.liveCount(id), Caps: w.caps, Connected: true, Since: fmtTime(w.since)})
	}
	for _, jl := range s.sortedJobs() {
		if !live(jl.rec.State) {
			continue
		}
		age := 0.0
		if l, ok := s.leases.Get(jl.job); ok {
			age = s.now().Sub(l.LastHB).Seconds()
		}
		st.Leases = append(st.Leases, StatusLease{Job: jl.job, LeaseID: jl.rec.LeaseID, Epoch: jl.rec.Epoch, WorkerID: jl.rec.WorkerID, State: jl.rec.State, HbAgeS: age})
	}
	_ = writeJSONAtomic(s.path("runner", "coord-status.json"), st, false)
}

// ---------- commands ----------

// queueCmd persists a command for a job's lease, records it as issued and sends it when the worker is
// connected. It stays in runner/leases/<job>.cmds.jsonl until the worker's cmd.ack.
func (s *Server) queueCmd(jl *jobLease, t string, data any) error {
	b, err := s.buildFrame(t, jl, data)
	if err != nil {
		return err
	}
	f, err := workerproto.Decode(b)
	if err != nil {
		return err
	}
	if err := workerproto.ValidateFrom(workerproto.FromCoordinator, f); err != nil {
		return err
	}
	var c struct {
		CmdID string `json:"cmd_id"`
	}
	_ = json.Unmarshal(f.Data, &c)
	jl.cmds = append(jl.cmds, cmdEntry{ID: c.CmdID, Type: t, Frame: []byte(strings.TrimRight(string(b), "\n"))})
	s.persistCmds(jl)
	s.adm.Issued(f)
	if w := s.workers[jl.rec.WorkerID]; w != nil {
		s.enqueue(w, b)
	}
	return nil
}

// RevokeLease ends a job's live lease at the coordinator's request and tells the worker to stop.
func (s *Server) RevokeLease(job, reason string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.revokeLocked(job, reason)
}

func (s *Server) revokeLocked(job, reason string) error {
	jl := s.jobs[job]
	if jl == nil || !live(jl.rec.State) {
		return fmt.Errorf("no live lease for %s", job)
	}
	if err := s.queueCmd(jl, workerproto.TypeLeaseRevoke, workerproto.LeaseRevoke{CmdID: newID("c-"), Reason: reason}); err != nil {
		return err
	}
	if err := s.leases.Revoke(job, jl.rec.LeaseID, jl.rec.Epoch); err != nil {
		return err
	}
	cmds := jl.cmds
	s.endLease(jl, workerproto.LeaseRevoked, reason)
	jl.cmds = cmds // keep the revoke queued for redelivery
	s.persistCmds(jl)
	return nil
}

func (s *Server) holdPass() {
	for _, jl := range s.sortedJobs() {
		if jl.rec.State != string(workerproto.LeaseActive) {
			continue
		}
		b, err := os.ReadFile(s.path("runner", jl.job+".hold"))
		if err == nil {
			content := string(b)
			if content == jl.rec.HoldSent && jl.rec.HoldActive {
				continue
			}
			var h struct {
				Code   string `json:"code"`
				Reason string `json:"reason"`
			}
			_ = json.Unmarshal(b, &h)
			if h.Code == "" {
				h.Code = "hold"
			}
			if h.Reason == "" {
				h.Reason = "held"
			}
			if err := s.queueCmd(jl, workerproto.TypeHold, workerproto.Hold{CmdID: newID("c-"), Code: h.Code, Reason: h.Reason}); err != nil {
				s.logf("hold %s: %v", jl.job, err)
				continue
			}
			jl.rec.HoldSent, jl.rec.HoldActive = content, true
			s.persistRec(jl)
		} else if jl.rec.HoldActive {
			if err := s.queueCmd(jl, workerproto.TypeRelease, workerproto.ReleaseCmd{CmdID: newID("c-")}); err != nil {
				continue
			}
			jl.rec.HoldSent, jl.rec.HoldActive = "", false
			s.persistRec(jl)
		}
	}
}

func (s *Server) syncJobPass() {
	for _, jl := range s.sortedJobs() {
		if jl.rec.State != string(workerproto.LeaseActive) {
			continue
		}
		cur := s.downlinkValues(jl.job)
		if cur == nil {
			continue
		}
		set := map[string]json.RawMessage{}
		for _, k := range downlinkKeys {
			if !sameJSON(cur[k], jl.rec.Synced[k]) {
				set[k] = cur[k]
			}
		}
		if len(set) == 0 {
			continue
		}
		if err := s.queueCmd(jl, workerproto.TypeSyncJob, workerproto.SyncJob{CmdID: newID("c-"), Set: set}); err != nil {
			s.logf("sync.job %s: %v", jl.job, err)
			continue
		}
		for k, v := range set {
			s.setSynced(jl, k, v)
		}
		s.persistRec(jl)
	}
}

// downlinkValues reads the canonical job's downlink keys ("null" for absent). nil when unreadable.
func (s *Server) downlinkValues(job string) map[string]json.RawMessage {
	b, err := os.ReadFile(s.jobPath(job))
	if err != nil {
		return nil
	}
	var doc map[string]json.RawMessage
	if json.Unmarshal(b, &doc) != nil {
		return nil
	}
	out := map[string]json.RawMessage{}
	for _, k := range downlinkKeys {
		if v, ok := doc[k]; ok {
			out[k] = v
		} else {
			out[k] = json.RawMessage("null")
		}
	}
	return out
}

func sameJSON(a, b json.RawMessage) bool {
	norm := func(r json.RawMessage) string {
		if len(r) == 0 {
			return "null"
		}
		var v any
		if json.Unmarshal(r, &v) != nil {
			return string(r)
		}
		n, _ := json.Marshal(v)
		return string(n)
	}
	return norm(a) == norm(b)
}

const fileMissing = "\x00missing"

func (s *Server) readSyncFile(p string) string {
	b, err := os.ReadFile(s.path(p))
	if err != nil {
		return fileMissing
	}
	return string(b)
}

func (s *Server) sendSyncFile(w *workerConn, p, content string) {
	var cv any
	if content != fileMissing {
		cv = content
	}
	data := struct {
		CmdID   string `json:"cmd_id"`
		Path    string `json:"path"`
		Content any    `json:"content"`
	}{newID("c-"), p, cv}
	b, err := s.buildFrame(workerproto.TypeSyncFile, nil, data)
	if err != nil {
		return
	}
	if f, err := workerproto.Decode(b); err == nil {
		s.adm.Issued(f)
	}
	s.enqueue(w, b)
}

func (s *Server) syncFilePass() {
	for _, p := range workerproto.SyncFilePaths() {
		cur := s.readSyncFile(p)
		if cur == s.fileSent[p] {
			continue
		}
		s.fileSent[p] = cur
		for _, w := range s.workers {
			s.sendSyncFile(w, p, cur)
		}
	}
}
