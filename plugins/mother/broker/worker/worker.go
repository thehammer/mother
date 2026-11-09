// Package worker is the worker end of Mother's worker protocol (docs/worker-protocol.md): it holds
// leased jobs, runs `mother-run-job` for each in worker mode, ships what the supervisor writes (its
// outbox and log) to the coordinator, and applies the commands that come back. A coordinator absence of
// any length never stops or kills a job (MC-16): the supervisor keeps running against its mirror and
// the worker keeps buffering (the outbox and log are files).
package worker

import (
	"context"
	cryptorand "crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"sync"
	"syscall"
	"time"

	"mother-broker/workerproto"
)

type Config struct {
	ID        string
	Root      string // worker root (mirror)
	CoordSock string
	Slots     int
	BinDir    string // where mother-run-job lives
	LibDir    string // lib/ (worker_sync.sh)
	// Secret is this worker's credential for the coordinator (proved in hello.auth). It lives in memory only:
	// it is never put in the environment of anything the daemon starts.
	Secret string
	// TermGrace is how long a fenced supervisor group gets after SIGTERM before SIGKILL (default 10s).
	TermGrace time.Duration
	// BackoffBase/BackoffMax bound the reconnect delay: base doubling to max, plus up to 20% jitter.
	BackoffBase time.Duration
	BackoffMax  time.Duration
	// CkptInterval is the checkpoint cadence (0 disables it; main reads it from `mother checkpoint interval`).
	// CkptFinalWait bounds a supervisor's final checkpoint (MOTHER_CHECKPOINT_FINAL_TIMEOUT_S, default 30 s).
	CkptInterval  time.Duration
	CkptFinalWait time.Duration
	// MotherCLI is the `mother` executable the cadence and the salvage push run (default BinDir/mother).
	MotherCLI string
	// SpawnCmd, when set, replaces the mother-run-job command line (tests run a `sleep`).
	SpawnCmd func(job string) (name string, args []string)
	Logf     func(format string, args ...any)
}

// Daemon is one worker.
type Daemon struct {
	cfg      Config
	instance string

	mu       sync.Mutex
	leases   map[string]*lease
	dedupe   *workerproto.DedupeSet
	sess     *session
	stopping bool // GracefulStop in progress: no new offers, no cadence, stopped supervisors are released
}

func New(cfg Config) (*Daemon, error) {
	if cfg.BackoffBase <= 0 {
		cfg.BackoffBase = time.Second
	}
	if cfg.BackoffMax <= 0 {
		cfg.BackoffMax = 30 * time.Second
	}
	if cfg.TermGrace <= 0 {
		cfg.TermGrace = 10 * time.Second
	}
	if cfg.Slots < 1 {
		cfg.Slots = 1
	}
	if cfg.CkptFinalWait <= 0 {
		cfg.CkptFinalWait = 30 * time.Second
	}
	if cfg.MotherCLI == "" {
		cfg.MotherCLI = filepath.Join(cfg.BinDir, "mother")
	}
	if cfg.Logf == nil {
		cfg.Logf = func(string, ...any) {}
	}
	if !workerproto.IDOK(cfg.ID) {
		return nil, fmt.Errorf("bad worker id %q", cfg.ID)
	}
	b := make([]byte, 8)
	_, _ = cryptorand.Read(b)
	d := &Daemon{cfg: cfg, instance: "i-" + hex.EncodeToString(b), leases: map[string]*lease{}}
	if err := d.initRoot(); err != nil {
		return nil, err
	}
	return d, nil
}

func (d *Daemon) logf(format string, args ...any) { d.cfg.Logf(format, args...) }

func (d *Daemon) p(parts ...string) string {
	return filepath.Join(append([]string{d.cfg.Root}, parts...)...)
}

// initRoot creates the worker root skeleton (idempotent: an existing root is kept as is).
func (d *Daemon) initRoot() error {
	for _, sub := range []string{"jobs", "events", "logs", "runner", "outbox", "metrics", "crew", "leases", "children", "checkpoints", "resume", "salvage"} {
		if err := os.MkdirAll(d.p(sub), 0o700); err != nil {
			return err
		}
	}
	marker := d.p(".mother-worker-live")
	if _, err := os.Stat(marker); err != nil {
		msg := "This directory is a Mother WORKER root (job mirror and unshipped outbox).\n" +
			"Mother refuses to recursively delete any directory that contains this file.\n"
		if err := os.WriteFile(marker, []byte(msg), 0o600); err != nil {
			return err
		}
	}
	if b, err := os.ReadFile(d.p("applied-cmds.json")); err == nil {
		if ds, err := workerproto.UnmarshalDedupeSet(b); err == nil {
			d.dedupe = ds
		}
	}
	if d.dedupe == nil {
		d.dedupe = workerproto.NewDedupeSet(0)
		d.saveDedupe()
	}
	return nil
}

func (d *Daemon) saveDedupe() {
	if b, err := d.dedupe.Marshal(); err == nil {
		if err := writeFileAtomic(d.p("applied-cmds.json"), b); err != nil {
			d.logf("persist applied-cmds: %v", err)
		}
	}
}

// RecordPID makes the daemon the leader of its own process group, so its whole tree (supervisors,
// claude) can be killed with one exact `kill -9 -<pgid>`, and records "<pid> <pgid>" in worker.pid.
func (d *Daemon) RecordPID() error {
	if err := syscall.Setpgid(0, 0); err != nil && syscall.Getpgrp() != os.Getpid() {
		d.logf("setpgid: %v", err)
	}
	return writeFileAtomic(d.p("worker.pid"), []byte(fmt.Sprintf("%d %d\n", os.Getpid(), syscall.Getpgrp())))
}

// Run supervises leases and keeps a connection to the coordinator until ctx is done. Returning does
// not touch any running supervisor.
func (d *Daemon) Run(ctx context.Context) error {
	d.loadLeases()
	d.adopt()
	go d.watchLoop(ctx)
	go d.ckptLoop(ctx)
	delay := d.cfg.BackoffBase
	for ctx.Err() == nil {
		welcomed, err := d.runSession(ctx)
		if welcomed {
			delay = d.cfg.BackoffBase
		}
		if ctx.Err() != nil {
			return nil
		}
		d.logf("coordinator connection ended: %v (retrying in %s)", err, delay)
		jitter := time.Duration(rand.Int64N(int64(delay)/5 + 1))
		select {
		case <-ctx.Done():
			return nil
		case <-time.After(delay + jitter):
		}
		delay *= 2
		if delay > d.cfg.BackoffMax {
			delay = d.cfg.BackoffMax
		}
	}
	return nil
}

func (d *Daemon) caps() []string {
	return []string{"log.stream", "artifact.chunked", "checkpoint.v1", "hold.boundary", "os." + runtime.GOOS}
}

type helloData struct {
	workerproto.Hello
	Slots int `json:"slots"`
}

func dial(sock string) (net.Conn, error) { return net.DialTimeout("unix", sock, 5*time.Second) }

// activeCount is the number of leases occupying a slot.
func (d *Daemon) activeCount() int {
	n := 0
	for _, l := range d.leases {
		if l.loc.State == stateActive {
			n++
		}
	}
	return n
}

func itoa(n int64) string { return strconv.FormatInt(n, 10) }

func writeJSON(path string, v any) error {
	b, err := json.Marshal(v)
	if err != nil {
		return err
	}
	return writeFileAtomic(path, append(b, '\n'))
}

func writeFileAtomic(path string, b []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".tmp.")
	if err != nil {
		return err
	}
	name := tmp.Name()
	if _, err := tmp.Write(b); err != nil {
		tmp.Close()
		os.Remove(name)
		return err
	}
	if err := tmp.Close(); err != nil {
		os.Remove(name)
		return err
	}
	if err := os.Rename(name, path); err != nil {
		os.Remove(name)
		return err
	}
	return nil
}
