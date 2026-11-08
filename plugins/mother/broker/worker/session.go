package worker

import (
	"bufio"
	"context"
	cryptorand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	"sync"
	"time"

	"mother-broker/workerproto"
)

// session is one connection to the coordinator.
type session struct {
	d    *Daemon
	conn net.Conn
	wmu  sync.Mutex
}

func (s *session) send(b []byte) error {
	s.wmu.Lock()
	defer s.wmu.Unlock()
	_ = s.conn.SetWriteDeadline(time.Now().Add(10 * time.Second))
	_, err := s.conn.Write(b)
	if err != nil {
		s.conn.Close()
	}
	return err
}

func newFrameID() string { return "f-" + itoa(time.Now().UnixNano()) + "-" + itoa(frameCounter()) }

var (
	fcMu sync.Mutex
	fc   int64
)

func frameCounter() int64 { fcMu.Lock(); defer fcMu.Unlock(); fc++; return fc }

// build encodes a frame. l (optional) supplies job/lease/epoch; seq (optional) the stream seq.
func build(t string, l *lease, seq *int64, data any) ([]byte, error) {
	f, err := workerproto.NewFrame(t, newFrameID(), time.Now(), data)
	if err != nil {
		return nil, err
	}
	if l != nil {
		f.Job, f.Lease, f.Epoch = workerproto.Str(l.loc.Job), workerproto.Str(l.loc.LeaseID), workerproto.Int(l.loc.Epoch)
	}
	f.Seq = seq
	return workerproto.Encode(f)
}

// runSession dials, handshakes and serves one connection until it fails. welcomed reports whether the
// handshake completed (so the caller can reset its backoff).
func (d *Daemon) runSession(ctx context.Context) (welcomed bool, err error) {
	conn, err := dial(d.cfg.CoordSock)
	if err != nil {
		return false, err
	}
	s := &session{d: d, conn: conn}
	// Every goroutine of the session is owned here: sctx ends them, wg waits for them, so a reconnect
	// never leaves one behind.
	sctx, cancel := context.WithCancel(ctx)
	var wg sync.WaitGroup
	defer wg.Wait()
	defer conn.Close()
	defer cancel()
	wg.Add(1)
	go func() { defer wg.Done(); <-sctx.Done(); conn.Close() }()

	h := workerproto.Hello{
		ProtoMin: workerproto.ProtoMin, ProtoMax: workerproto.ProtoMax, Caps: d.caps(), WorkerID: d.cfg.ID,
		InstanceID: d.instance, Kind: "worker", Auth: workerproto.Auth{Method: workerproto.AuthMethodPeercred},
	}
	if d.cfg.Secret != "" {
		nb := make([]byte, 16)
		_, _ = cryptorand.Read(nb)
		h.Auth.Nonce = hex.EncodeToString(nb) // per connection
		h.Auth.Credential = workerproto.CredentialProof(d.cfg.Secret, h)
	}
	hello := helloData{Hello: h, Slots: d.cfg.Slots}
	b, err := build(workerproto.TypeHello, nil, nil, hello)
	if err != nil {
		return false, err
	}
	if err := s.send(b); err != nil {
		return false, err
	}
	br := bufio.NewReaderSize(conn, 64<<10)
	_ = conn.SetReadDeadline(time.Now().Add(10 * time.Second))
	line, err := workerproto.ReadFrame(br)
	if err != nil {
		return false, err
	}
	_ = conn.SetReadDeadline(time.Time{})
	f, err := workerproto.Decode(line)
	if err == nil {
		err = workerproto.ValidateFrom(workerproto.FromCoordinator, f)
	}
	if err != nil {
		return false, err
	}
	if f.T == workerproto.TypeRefuse {
		var r workerproto.Refuse
		_ = json.Unmarshal(f.Data, &r)
		return false, fmt.Errorf("coordinator refused the handshake: %s", r.Code)
	}
	if f.T != workerproto.TypeWelcome {
		return false, fmt.Errorf("expected welcome, got %s", f.T)
	}
	var w workerproto.Welcome
	_ = json.Unmarshal(f.Data, &w)
	hb := time.Duration(w.HbIntervalS) * time.Second
	if hb < time.Second {
		hb = time.Second
	}
	if len(w.Jobs) > workerproto.MaxHbJobs {
		w.Jobs = w.Jobs[:workerproto.MaxHbJobs]
	}
	d.mu.Lock()
	d.sess = s
	d.rebase(w.Jobs)
	d.sendHb(s)
	d.mu.Unlock()
	d.logf("connected to the coordinator (%d lease(s) resumed)", len(w.Jobs))

	wg.Add(2)
	go func() { defer wg.Done(); d.shipLoop(sctx, s) }()
	go func() { defer wg.Done(); d.hbLoop(sctx, s, hb) }()
	defer func() {
		d.mu.Lock()
		if d.sess == s {
			d.sess = nil
		}
		for _, l := range d.leases {
			l.ship = nil
		}
		d.mu.Unlock()
	}()
	for {
		line, err := workerproto.ReadFrame(br)
		if err != nil {
			return true, err
		}
		f, err := workerproto.Decode(line)
		if err == nil {
			err = workerproto.ValidateFrom(workerproto.FromCoordinator, f)
		}
		if err != nil {
			d.logf("bad frame from the coordinator: %v", err)
			// An unknown or malformed command is still answered when it carries a usable cmd_id.
			d.mu.Lock()
			d.rejectBad(s, f, err)
			d.mu.Unlock()
			continue
		}
		d.mu.Lock()
		d.handleFrame(s, f)
		d.mu.Unlock()
	}
}

func (d *Daemon) hbLoop(ctx context.Context, s *session, every time.Duration) {
	t := time.NewTicker(every)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			d.mu.Lock()
			d.sendHb(s)
			d.mu.Unlock()
		}
	}
}

// sendHb heartbeats every lease the worker holds and is actually supervising. A lease whose supervisor
// is gone without a releasable state is left out, so the coordinator's TTL decides its fate.
func (d *Daemon) sendHb(s *session) {
	var jobs []workerproto.HbJob
	for _, l := range d.leases {
		if l.loc.State != stateActive || l.noHB {
			continue
		}
		var last int64
		if l.ship != nil {
			last = l.ship.base + l.ship.out.Last()
		}
		jobs = append(jobs, workerproto.HbJob{Job: l.loc.Job, Lease: l.loc.LeaseID, Epoch: l.loc.Epoch, LastSeq: last, Degraded: l.degraded})
		if len(jobs) >= workerproto.MaxHbJobs {
			break
		}
	}
	b, err := build(workerproto.TypeHb, nil, nil, workerproto.Hb{Jobs: jobs})
	if err == nil {
		_ = s.send(b)
	}
}

func (d *Daemon) shipLoop(ctx context.Context, s *session) {
	t := time.NewTicker(100 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			d.mu.Lock()
			for _, l := range d.leases {
				if d.sess != s {
					break
				}
				if l.loc.State == stateActive && l.ship != nil {
					d.shipLease(s, l)
				}
			}
			d.mu.Unlock()
		}
	}
}

// handleFrame dispatches a validated coordinator frame. Caller holds d.mu.
func (d *Daemon) handleFrame(s *session, f workerproto.Frame) {
	switch f.T {
	case workerproto.TypeAck:
		d.onAck(s, f)
	case workerproto.TypeRefuse:
		d.onRefuse(f)
	case workerproto.TypeBye, workerproto.TypeWelcome:
	default:
		if workerproto.IsCommandType(f.T) {
			d.handleCommand(s, f)
		}
	}
}

// onRefuse: a refuse that names a lease the coordinator no longer recognises (fenced, not_leased,
// unknown_job) fences it. Other refusals carry nothing the worker can act on beyond waiting for acks.
func (d *Daemon) onRefuse(f workerproto.Frame) {
	var r workerproto.Refuse
	_ = json.Unmarshal(f.Data, &r)
	d.logf("refused by the coordinator: %s (job %v)", r.Code, strOrNil(f.Job))
	if f.Job == nil || f.Lease == nil || f.Epoch == nil {
		return
	}
	switch r.Code {
	case workerproto.CodeFenced, workerproto.CodeNotLeased, workerproto.CodeUnknownJob:
	default:
		return
	}
	l := d.leases[*f.Job]
	if l == nil || l.loc.LeaseID != *f.Lease || l.loc.Epoch != *f.Epoch {
		return
	}
	d.fence(l, r.Code)
}

func strOrNil(p *string) string {
	if p == nil {
		return "-"
	}
	return *p
}
