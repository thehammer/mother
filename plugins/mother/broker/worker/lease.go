package worker

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

const (
	stateActive   = "active"
	stateFenced   = "fenced"
	stateReleased = "released"
)

// localLease is <root>/leases/<job>.json: the worker's own record of a lease it accepted. AckedSeq,
// AppliedSeq and LogOffset are what the coordinator last acknowledged; on every connection the welcome
// is the authority for where to resume, so these are for inspection and for a coordinator that has
// lost its own state.
type localLease struct {
	Job         string `json:"job"`
	LeaseID     string `json:"lease_id"`
	Epoch       int64  `json:"epoch"`
	Attempt     int    `json:"attempt"`
	State       string `json:"state"`
	OfferedAt   string `json:"offered_at"`
	AckedSeq    int64  `json:"acked_seq"`
	AppliedSeq  int64  `json:"applied_seq"`
	LogOffset   int64  `json:"log_offset"`
	ReleaseSent bool   `json:"release_sent,omitempty"`
	EndReason   string `json:"end_reason,omitempty"`
}

// lease is a localLease plus its runtime: the supervisor, and (while connected) the shipping state.
type lease struct {
	loc localLease

	pid         int           // supervisor pid (0 unknown)
	pidStart    string        // the pid's process start time when we took it on, to detect pid reuse
	degraded    string        // why the outbox can no longer be shipped faithfully ("" when healthy)
	done        chan struct{} // closed when an own child has been reaped (nil for an adopted one)
	adopted     bool
	exited      bool
	noHB        bool // supervisor gone without a releasable state: stop heartbeating so the coordinator decides
	adoptedDead bool

	ship *shipState // nil until the current connection's welcome rebases it
}

type childEntry struct {
	PID       int    `json:"pid"`
	JobID     string `json:"job_id"`
	StartedAt string `json:"started_at"`
}

func (d *Daemon) leasePath(job string) string { return d.p("leases", job+".json") }

func (d *Daemon) persistLease(l *lease) {
	if err := writeJSON(d.leasePath(l.loc.Job), l.loc); err != nil {
		d.logf("persist lease %s: %v", l.loc.Job, err)
	}
}

// loadLeases restores the active leases recorded on disk.
func (d *Daemon) loadLeases() {
	d.mu.Lock()
	defer d.mu.Unlock()
	ents, _ := os.ReadDir(d.p("leases"))
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") || strings.Contains(e.Name(), ".tmp.") {
			continue
		}
		var loc localLease
		b, err := os.ReadFile(d.p("leases", e.Name()))
		if err != nil || json.Unmarshal(b, &loc) != nil || loc.Job == "" {
			continue
		}
		if loc.State != stateActive {
			continue
		}
		d.leases[loc.Job] = &lease{loc: loc}
	}
}

// adopt re-attaches to supervisors that outlived a previous worker process: for every children entry whose
// pid is alive and is a mother-run-job, keep supervising it. A lease whose supervisor is gone keeps
// shipping what is left and is released once drained (see watch).
func (d *Daemon) adopt() {
	d.mu.Lock()
	defer d.mu.Unlock()
	ents, _ := os.ReadDir(d.p("children"))
	for _, e := range ents {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		var c childEntry
		b, err := os.ReadFile(d.p("children", e.Name()))
		if err != nil || json.Unmarshal(b, &c) != nil || c.PID <= 0 {
			continue
		}
		l := d.leases[c.JobID]
		if l == nil {
			if !alive(c.PID) {
				_ = os.Remove(d.p("children", e.Name()))
			}
			continue
		}
		if alive(c.PID) && d.isSupervisor(c.PID) {
			l.pid, l.adopted, l.pidStart = c.PID, true, procStart(c.PID)
			d.logf("re-adopted supervisor %d for %s", c.PID, c.JobID)
		}
	}
	for _, l := range d.leases {
		if l.pid == 0 {
			l.exited, l.adoptedDead = true, true
		}
	}
}

func alive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// isSupervisor reports whether pid is a mother-run-job process (as _supervisor_pid_for_job in
// bin/mother-runner does). When ps cannot say, the pid is trusted.
func (d *Daemon) isSupervisor(pid int) bool {
	out, err := exec.Command("ps", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil || strings.TrimSpace(string(out)) == "" {
		return alive(pid)
	}
	for _, tok := range strings.Fields(string(out)) {
		if filepath.Base(tok) == "mother-run-job" {
			return true
		}
	}
	return d.cfg.SpawnCmd != nil // a test double stands in for the supervisor
}

// scrubbedEnv is the environment for anything run against the worker root: the worker's own variables
// plus whatever it inherited, minus path variables that would point at another tree and minus the
// worker's coordinator credential. It carries none of the coordinator's credentials (the worker never
// holds any) and not this worker's secret, which is memory-only (Config.Secret): supervisors, agents and
// hooks never see it.
func (d *Daemon) scrubbedEnv(extra ...string) []string {
	drop := map[string]bool{"MOTHER_LIVE_ROOT": true, "JOBS_DIR": true, "EVENTS_DIR": true, "LOGS_DIR": true, "DRAFTS_DIR": true,
		"CURSORS_DIR": true, "RUNNER_DIR": true, "ARCHIVE_DIR": true, "TEARDOWN_DIR": true, "RESIDUE_DIR": true,
		"MOTHER_JOB_ID": true, "MOTHER_ROOT": true, "MOTHER_WORKER_MODE": true, "MOTHER_WORKER_OUTBOX_DIR": true,
		"MOTHER_LEASE_ID": true, "MOTHER_LEASE_EPOCH": true, "MOTHER_WORKER_SECRET": true, "MOTHER_WORKER_SECRET_FD": true}
	var env []string
	for _, kv := range os.Environ() {
		if i := strings.IndexByte(kv, '='); i > 0 && drop[kv[:i]] {
			continue
		}
		env = append(env, kv)
	}
	env = append(env, "MOTHER_ROOT="+d.cfg.Root, "MOTHER_WORKER_MODE=1", "MOTHER_WORKER_OUTBOX_DIR="+d.p("outbox"))
	return append(env, extra...)
}

// spawn starts the supervisor for l (the lease is already persisted) and tracks it.
func (d *Daemon) spawn(l *lease) error {
	name, args := d.cfg.BinDir+"/mother-run-job", []string{l.loc.Job}
	if d.cfg.SpawnCmd != nil {
		name, args = d.cfg.SpawnCmd(l.loc.Job)
	}
	cmd := exec.Command(name, args...)
	cmd.Env = d.scrubbedEnv("MOTHER_LEASE_ID="+l.loc.LeaseID, "MOTHER_LEASE_EPOCH="+itoa(l.loc.Epoch))
	cmd.Dir = d.cfg.Root
	// Own process group: fencing signals the whole group, so a hung claude does not outlive its supervisor.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	l.pid, l.done, l.exited = cmd.Process.Pid, make(chan struct{}), false
	l.pidStart = procStart(l.pid)
	entry, _ := json.Marshal(childEntry{PID: l.pid, JobID: l.loc.Job, StartedAt: time.Now().UTC().Format("2006-01-02T15:04:05.000Z")})
	_ = writeFileAtomic(d.p("children", strconv.Itoa(l.pid)+".json"), append(entry, '\n'))
	done, job := l.done, l.loc.Job
	go func() {
		_ = cmd.Wait()
		d.mu.Lock()
		if cur := d.leases[job]; cur != nil && cur.done == done {
			cur.exited = true
		}
		d.mu.Unlock()
		close(done)
	}()
	return nil
}

// watchLoop notices adopted supervisors that have died (own children are reaped by their Wait goroutine).
func (d *Daemon) watchLoop(ctxDone interface{ Done() <-chan struct{} }) {
	t := time.NewTicker(500 * time.Millisecond)
	defer t.Stop()
	for {
		select {
		case <-ctxDone.Done():
			return
		case <-t.C:
			d.mu.Lock()
			for _, l := range d.leases {
				if l.adopted && !l.exited && !alive(l.pid) {
					l.exited = true
				}
			}
			d.mu.Unlock()
		}
	}
}

// mirrorState is the job's state in the mirror document ("" when unreadable).
func (d *Daemon) mirrorState(job string) string {
	b, err := os.ReadFile(d.p("jobs", job+".json"))
	if err != nil {
		return ""
	}
	var j struct {
		State string `json:"state"`
	}
	_ = json.Unmarshal(b, &j)
	return j.State
}

func releasableState(s string) bool {
	switch s {
	case "succeeded", "failed", "cancelled", "awaiting":
		return true
	}
	return false
}

// procStart is the process start time of pid as ps prints it ("" when unknown): with the pid it identifies
// the process, so a reused pid is not mistaken for the supervisor.
func procStart(pid int) string {
	out, err := exec.Command("ps", "-o", "lstart=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(out))
}

// terminate stops a supervisor and everything in its process group (the supervisor leads the group):
// SIGTERM to the group (its wrapper trap forwards to claude), SIGKILL to the group after grace. An adopted
// pid is re-verified (still a mother-run-job with the start time we recorded) before any signal.
func (d *Daemon) terminate(pid int, startedAs string, done <-chan struct{}) {
	if pid <= 0 {
		return
	}
	if done == nil { // adopted: not our child, so the pid could have been reused
		if !alive(pid) || (startedAs != "" && procStart(pid) != startedAs) || !d.isSupervisor(pid) {
			return
		}
	}
	// The supervisor leads its own group when we (or the old worker) started it with Setpgid; otherwise
	// only the pid is signalled.
	group := false
	if pgid, err := syscall.Getpgid(pid); err == nil && pgid == pid {
		group = true
	}
	gone := func() bool {
		if group {
			return syscall.Kill(-pid, 0) != nil
		}
		return !alive(pid)
	}
	signal := func(sig syscall.Signal) {
		if group {
			_ = syscall.Kill(-pid, sig)
		} else {
			_ = syscall.Kill(pid, sig)
		}
	}
	signal(syscall.SIGTERM)
	deadline := time.Now().Add(d.cfg.TermGrace)
	for time.Now().Before(deadline) {
		if gone() {
			return
		}
		time.Sleep(25 * time.Millisecond)
	}
	if done == nil && startedAs != "" && procStart(pid) != startedAs {
		return
	}
	signal(syscall.SIGKILL)
}

// fence stops a job that this worker no longer holds (refuse{fenced} or lease.revoke): SIGTERM its
// supervisor, SIGKILL after 10 s, stop shipping and mark the lease fenced. Caller holds d.mu.
func (d *Daemon) fence(l *lease, why string) {
	if l.loc.State != stateActive {
		return
	}
	if l.loc.ReleaseSent {
		// The coordinator already ended this lease at our request; nothing to stop.
		d.markReleased(l, "released")
		return
	}
	d.logf("fenced %s (lease %s epoch %d): %s", l.loc.Job, l.loc.LeaseID, l.loc.Epoch, why)
	l.loc.State, l.loc.EndReason = stateFenced, why
	l.ship = nil
	d.persistLease(l)
	pid, done := l.pid, l.done
	if pid > 0 && !l.exited {
		go d.terminate(pid, l.pidStart, done)
	}
	d.onFenced(l.loc.Job)
}

// onFenced is the hook for the salvage push (P1-6): the lease is gone, the supervisor is being stopped and
// the work tree may hold unpushed commits that should land on refs/mother/wip-salvage/<job>/lease-<epoch>.
// This slice does nothing here.
func (d *Daemon) onFenced(job string) {
	d.logf("onFenced(%s): salvage push not implemented in this slice", job)
}

func (d *Daemon) markReleased(l *lease, reason string) {
	l.loc.State, l.loc.EndReason = stateReleased, reason
	l.ship = nil
	d.persistLease(l)
	if l.pid > 0 {
		_ = os.Remove(d.p("children", strconv.Itoa(l.pid)+".json"))
	}
}
