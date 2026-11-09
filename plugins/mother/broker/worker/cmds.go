package worker

import (
	"archive/tar"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path"
	"path/filepath"
	"strings"
	"time"

	"mother-broker/workerproto"
)

func (d *Daemon) cmdAck(s *session, f workerproto.Frame, cmdID, outcome, why string) {
	fr, err := workerproto.NewFrame(workerproto.TypeCmdAck, newFrameID(), time.Now(), workerproto.CmdAck{CmdID: cmdID, Outcome: outcome, Why: why, For: f.T})
	if err != nil {
		return
	}
	fr.Job, fr.Lease, fr.Epoch = f.Job, f.Lease, f.Epoch // nil for sync.file, which is not job-scoped
	if b, err := workerproto.Encode(fr); err == nil {
		_ = s.send(b)
	}
}

// rejectBad answers a command that failed validation, when it carries a usable cmd_id.
func (d *Daemon) rejectBad(s *session, f workerproto.Frame, cause error) {
	if !workerproto.IsCommandType(f.T) {
		return
	}
	var c struct {
		CmdID string `json:"cmd_id"`
	}
	if json.Unmarshal(f.Data, &c) != nil || !workerproto.IDOK(c.CmdID) {
		return
	}
	if (f.T != workerproto.TypeSyncFile) && (f.Job == nil || f.Lease == nil || f.Epoch == nil) {
		return
	}
	d.cmdAck(s, f, c.CmdID, workerproto.OutcomeRejected, workerproto.ErrorCode(cause))
}

// handleCommand applies one command at most once (dedupe by cmd_id, persisted) and acks it. Caller holds d.mu.
func (d *Daemon) handleCommand(s *session, f workerproto.Frame) {
	var c struct {
		CmdID string `json:"cmd_id"`
	}
	_ = json.Unmarshal(f.Data, &c)
	var l *lease
	if f.Job != nil {
		l = d.leases[*f.Job]
	}
	if d.dedupe.Seen(c.CmdID) {
		outcome := workerproto.OutcomeDuplicate
		// A redelivered offer for a lease already held is acked applied: that ack is what activates the
		// lease on a coordinator that restarted before it saw the first one.
		if f.T == workerproto.TypeLeaseOffer && l != nil && sameLease(l, f) && l.loc.State == stateActive {
			outcome = workerproto.OutcomeApplied
		}
		d.cmdAck(s, f, c.CmdID, outcome, "")
		return
	}
	outcome, why, after := d.applyCommand(s, f, l)
	d.saveDedupe()
	d.cmdAck(s, f, c.CmdID, outcome, why)
	if after != nil {
		after()
	}
}

func sameLease(l *lease, f workerproto.Frame) bool {
	return f.Lease != nil && f.Epoch != nil && l.loc.LeaseID == *f.Lease && l.loc.Epoch == *f.Epoch
}

func (d *Daemon) applyCommand(s *session, f workerproto.Frame, l *lease) (outcome, why string, after func()) {
	if f.T == workerproto.TypeSyncFile {
		if err := d.applySyncFile(f); err != nil {
			return workerproto.OutcomeRejected, "bad_sync_file", nil
		}
		return workerproto.OutcomeApplied, "", nil
	}
	if f.T == workerproto.TypeLeaseOffer {
		return d.acceptOffer(s, f, l)
	}
	if l == nil || !sameLease(l, f) || l.loc.State != stateActive {
		return workerproto.OutcomeRejected, "unknown_lease", nil
	}
	job := l.loc.Job
	switch f.T {
	case workerproto.TypeCancel:
		if err := d.syncJob(job, map[string]json.RawMessage{"cancel_requested": json.RawMessage("true")}); err != nil {
			d.logf("cancel %s: %v", job, err)
			return workerproto.OutcomeRejected, "apply_failed", nil
		}
	case workerproto.TypeHold:
		var h workerproto.Hold
		_ = json.Unmarshal(f.Data, &h)
		// The same shape bin/mother-runner's _write_hold_flag writes.
		if err := writeJSON(d.p("runner", job+".hold"), map[string]string{"code": h.Code, "reason": h.Reason, "since": workerproto.Timestamp(time.Now())}); err != nil {
			return workerproto.OutcomeRejected, "apply_failed", nil
		}
	case workerproto.TypeRelease:
		_ = os.Remove(d.p("runner", job+".hold"))
	case workerproto.TypeSyncJob:
		var sj workerproto.SyncJob
		_ = json.Unmarshal(f.Data, &sj)
		if err := d.syncJob(job, sj.Set); err != nil {
			d.logf("sync.job %s: %v", job, err)
			return workerproto.OutcomeRejected, "apply_failed", nil
		}
	case workerproto.TypeLeaseRevoke:
		return workerproto.OutcomeApplied, "", func() { d.fence(l, "revoked") }
	}
	return workerproto.OutcomeApplied, "", nil
}

// syncJob merges coordinator-sent keys into the mirror job document under the job lock, without
// emitting to the outbox (lib/worker_sync.sh).
func (d *Daemon) syncJob(job string, set map[string]json.RawMessage) error {
	patch, err := json.Marshal(set)
	if err != nil {
		return err
	}
	cmd := exec.Command("bash", filepath.Join(d.cfg.LibDir, "worker_sync.sh"), d.cfg.Root, job)
	cmd.Env = d.scrubbedEnv()
	cmd.Stdin = bytes.NewReader(patch)
	var eb bytes.Buffer
	cmd.Stderr = &eb
	done := make(chan error, 1)
	if err := cmd.Start(); err != nil {
		return err
	}
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			return fmt.Errorf("worker_sync: %v: %s", err, strings.TrimSpace(eb.String()))
		}
	case <-time.After(30 * time.Second):
		_ = cmd.Process.Kill()
		return fmt.Errorf("worker_sync timed out")
	}
	return nil
}

func (d *Daemon) applySyncFile(f workerproto.Frame) error {
	var sf workerproto.SyncFile
	if err := json.Unmarshal(f.Data, &sf); err != nil {
		return err
	}
	ok := false
	for _, p := range workerproto.SyncFilePaths() {
		ok = ok || p == sf.Path
	}
	if !ok {
		return fmt.Errorf("path not allowed")
	}
	target := d.p(sf.Path)
	if string(bytes.TrimSpace(sf.Content)) == "null" {
		if err := os.Remove(target); err != nil && !os.IsNotExist(err) {
			return err
		}
		return nil
	}
	var content string
	if err := json.Unmarshal(sf.Content, &content); err != nil {
		return err
	}
	return writeFileAtomic(target, []byte(content))
}

// acceptOffer takes a lease: mirror written, lease persisted, then (after the ack is sent) the supervisor
// is spawned.
func (d *Daemon) acceptOffer(s *session, f workerproto.Frame, existing *lease) (string, string, func()) {
	var o workerproto.LeaseOffer
	if err := json.Unmarshal(f.Data, &o); err != nil || f.Job == nil || f.Lease == nil || f.Epoch == nil {
		return workerproto.OutcomeRejected, "invalid", nil
	}
	job := *f.Job
	if existing != nil && existing.loc.State == stateActive {
		if sameLease(existing, f) {
			return workerproto.OutcomeApplied, "", nil
		}
		return workerproto.OutcomeRejected, "busy_local", nil
	}
	if d.activeCount() >= d.cfg.Slots {
		return workerproto.OutcomeRejected, "no_slot", nil
	}
	if err := d.writeMirror(job, o); err != nil {
		d.logf("offer %s: mirror: %v", job, err)
		return workerproto.OutcomeRejected, "mirror_failed", nil
	}
	l := &lease{loc: localLease{Job: job, LeaseID: *f.Lease, Epoch: *f.Epoch, Attempt: o.Attempt, State: stateActive, OfferedAt: workerproto.Timestamp(time.Now())}}
	// A fresh lease's stream starts at seq 1 with nothing applied; the welcome rebases it on a reconnect.
	l.ship = &shipState{out: workerproto.NewOutStream(), meta: map[int64]frameMeta{}, nextOseq: 1}
	d.leases[job] = l
	d.persistLease(l)
	return workerproto.OutcomeApplied, "", func() {
		if err := d.spawn(l); err != nil {
			d.logf("spawn %s: %v", job, err)
			l.exited, l.noHB = true, true
			return
		}
		d.logf("started supervisor %d for %s", l.pid, job)
	}
}

// writeMirror lays down the job document, plan and crew bundle the supervisor reads.
func (d *Daemon) writeMirror(job string, o workerproto.LeaseOffer) error {
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(o.JobDoc, &doc); err != nil {
		return err
	}
	// plan_path and log_path name canonical files; the mirror's own copies live under the worker root.
	doc["plan_path"], _ = json.Marshal(d.p("events", job+"-plan.md"))
	doc["log_path"], _ = json.Marshal(d.p("logs", job+".log"))
	b, err := json.Marshal(doc)
	if err != nil {
		return err
	}
	if err := writeFileAtomic(d.p("jobs", job+".json"), append(b, '\n')); err != nil {
		return err
	}
	if err := writeFileAtomic(d.p("events", job+"-plan.md"), []byte(o.Plan)); err != nil {
		return err
	}
	if len(o.CrewBundle) > 0 {
		var enc string
		if err := json.Unmarshal(o.CrewBundle, &enc); err != nil {
			return err
		}
		raw, err := base64.StdEncoding.DecodeString(enc)
		if err != nil {
			return err
		}
		return d.extractCrew(job, raw)
	}
	return nil
}

func (d *Daemon) extractCrew(job string, raw []byte) error {
	root := d.p("crew", job)
	if err := os.MkdirAll(root, 0o755); err != nil {
		return err
	}
	tr := tar.NewReader(bytes.NewReader(raw))
	for {
		h, err := tr.Next()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		if h.Typeflag != tar.TypeReg {
			continue
		}
		name := path.Clean(h.Name)
		if name == "." || strings.HasPrefix(name, "/") || name == ".." || strings.HasPrefix(name, "../") {
			return fmt.Errorf("crew bundle: unsafe path %q", h.Name)
		}
		body, err := io.ReadAll(io.LimitReader(tr, 64<<20))
		if err != nil {
			return err
		}
		if err := writeFileAtomic(filepath.Join(root, filepath.FromSlash(name)), body); err != nil {
			return err
		}
	}
}
