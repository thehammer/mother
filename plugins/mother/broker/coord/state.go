package coord

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"mother-broker/workerproto"
)

// LeaseRec is runner/leases/<job>.json, the coordinator's durable record of a job's current lease.
// The first block is the file the runner and tests read; the rest is the coordinator's own resume
// state (extra keys are fine: readers ignore them).
type LeaseRec struct {
	Job        string `json:"job"`
	LeaseID    string `json:"lease_id"`
	Epoch      int64  `json:"epoch"`
	WorkerID   string `json:"worker_id"`
	State      string `json:"state"`
	OfferedAt  string `json:"offered_at"`
	AppliedSeq int64  `json:"applied_seq"` // last outbox op applied (coord_apply's seq)
	LogOffset  int64  `json:"log_offset"`
	LastHB     string `json:"last_hb"`
	EndedAt    string `json:"ended_at,omitempty"`
	EndReason  string `json:"end_reason,omitempty"`

	WireSeq    int64                      `json:"wire_seq"` // last stream seq committed
	Synced     map[string]json.RawMessage `json:"synced,omitempty"`
	HoldSent   string                     `json:"hold_sent,omitempty"`
	HoldActive bool                       `json:"hold_active,omitempty"`
	Degraded   string                     `json:"degraded,omitempty"` // worker-reported outbox loss
}

type cmdEntry struct {
	ID    string
	Type  string
	Frame []byte // the encoded frame, no newline
}

// jobLease is the in-memory state for a job's current lease.
type jobLease struct {
	job         string
	rec         LeaseRec
	pending     map[int64]workerproto.Frame
	cmds        []cmdEntry
	dirty       bool
	applying    bool
	session     int                // bumped when the worker is welcomed again: wire seqs of an older session mean other frames
	ackAnchor   *workerproto.Frame // a duplicate/gap frame is owed one coalesced re-ack (sent on the next flush tick)
	lastPersist time.Time
}

func (s *Server) path(parts ...string) string {
	return filepath.Join(append([]string{s.cfg.Root}, parts...)...)
}
func (s *Server) leasesDir() string          { return s.path("runner", "leases") }
func (s *Server) recPath(job string) string  { return filepath.Join(s.leasesDir(), job+".json") }
func (s *Server) cmdsPath(job string) string { return filepath.Join(s.leasesDir(), job+".cmds.jsonl") }
func (s *Server) lostPath(job string) string { return filepath.Join(s.leasesDir(), job+".lost") }
func (s *Server) auditPath() string          { return filepath.Join(s.leasesDir(), "audit.jsonl") }
func (s *Server) historyPath(job string) string {
	return filepath.Join(s.leasesDir(), job+".history.jsonl")
}
func (s *Server) tablePath() string         { return filepath.Join(s.leasesDir(), "table.json") }
func (s *Server) dispatchDir() string       { return s.path("runner", "dispatch") }
func (s *Server) jobPath(job string) string { return s.path("jobs", job+".json") }
func (s *Server) logPath(job string) string { return s.path("logs", job+".log") }

// appliedSeqFile is where lib/coord_apply.sh persists a job's applied op seq.
func (s *Server) appliedSeqFile(job string) string {
	return s.path("runner", "leases", "applied", job+".seq")
}

// truthApplied is the applied op seq according to coord_apply's own file (the authority), never lower
// than what the lease record says.
func (s *Server) truthApplied(jl *jobLease) int64 {
	n := jl.rec.AppliedSeq
	if b, err := os.ReadFile(s.appliedSeqFile(jl.job)); err == nil {
		if v, err := strconv.ParseInt(strings.TrimSpace(string(b)), 10, 64); err == nil && v > n {
			n = v
		}
	}
	return n
}

func (s *Server) logSize(job string) int64 {
	if fi, err := os.Stat(s.logPath(job)); err == nil {
		return fi.Size()
	}
	return 0
}

func (s *Server) now() time.Time { return s.cfg.Now() }

func (s *Server) persistRec(jl *jobLease) {
	if err := writeJSONAtomic(s.recPath(jl.job), jl.rec, false); err != nil {
		s.logf("persist lease %s: %v", jl.job, err)
	}
	jl.lastPersist = s.now()
}

// persistTable writes the lease table snapshot durably. It must happen before a lease.offer carrying a
// new epoch leaves the coordinator (spec section 7).
func (s *Server) persistTable() error {
	return writeJSONAtomic(s.tablePath(), s.leases.Snapshot(), true)
}

func (s *Server) persistCmds(jl *jobLease) {
	if len(jl.cmds) == 0 {
		_ = os.Remove(s.cmdsPath(jl.job))
		return
	}
	var b []byte
	for _, c := range jl.cmds {
		b = append(b, c.Frame...)
		b = append(b, '\n')
	}
	if err := writeFileAtomic(s.cmdsPath(jl.job), b, false); err != nil {
		s.logf("persist cmds %s: %v", jl.job, err)
	}
}

func (s *Server) loadCmds(jl *jobLease) {
	b, err := os.ReadFile(s.cmdsPath(jl.job))
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.TrimSpace(line) == "" {
			continue
		}
		f, err := workerproto.Decode([]byte(line))
		if err != nil {
			continue
		}
		var c struct {
			CmdID string `json:"cmd_id"`
		}
		_ = json.Unmarshal(f.Data, &c)
		jl.cmds = append(jl.cmds, cmdEntry{ID: c.CmdID, Type: f.T, Frame: []byte(line)})
	}
}

func (s *Server) audit(worker, job, lease string, epoch int64, code string) {
	s.auditWith(worker, job, lease, epoch, code, 0)
}

func (s *Server) auditWith(worker, job, lease string, epoch int64, code string, suppressed int) {
	m := map[string]any{
		"ts": workerproto.Timestamp(s.now()), "worker_id": worker, "job": job, "lease": lease, "epoch": epoch, "code": code,
	}
	if suppressed > 0 {
		m["suppressed"] = suppressed
	}
	b, _ := json.Marshal(m)
	// Rotate rather than grow without bound: one previous generation is kept.
	if fi, err := os.Stat(s.auditPath()); err == nil && fi.Size() >= s.cfg.AuditMaxBytes {
		_ = os.Rename(s.auditPath(), s.auditPath()+".1")
	}
	if err := appendLine(s.auditPath(), b); err != nil {
		s.logf("audit: %v", err)
	}
}

// auditRefusal is audit for refusals a peer can provoke at will: at most one line per (worker, code) per
// auditThrottle window, the lines in between counted into the next one.
func (s *Server) auditRefusal(worker, job, lease string, epoch int64, code string) {
	key := worker + "\x00" + code
	now := s.now()
	e, ok := s.auditAt[key]
	if ok && now.Sub(e.at) < auditThrottle && !now.Before(e.at) {
		e.suppressed++
		s.auditAt[key] = e
		return
	}
	if len(s.auditAt) > 1024 {
		for k, v := range s.auditAt {
			if now.Sub(v.at) >= auditThrottle {
				delete(s.auditAt, k)
			}
		}
	}
	s.auditAt[key] = auditEntry{at: now}
	s.auditWith(worker, job, lease, epoch, code, e.suppressed)
}

// jobState is what Admitter needs to judge a job.set transition.
func (s *Server) jobState(job string) workerproto.JobState {
	var d struct {
		State           string `json:"state"`
		CancelRequested bool   `json:"cancel_requested"`
	}
	_ = readJSON(s.jobPath(job), &d)
	return workerproto.JobState{State: d.State, CancelRequested: d.CancelRequested}
}

func fmtTime(t time.Time) string { return workerproto.Timestamp(t) }

func parseTime(v string) (time.Time, error) { return time.Parse("2006-01-02T15:04:05.000Z", v) }

// Lease history is bounded: past historyMaxLines the file is rewritten to its newest historyKeepLines. Epochs only ever grow,
// so what is dropped is the oldest grants (a job would need hundreds of leases to reach this); a salvage or a manifest naming a
// dropped epoch is refused as unknown, which is the safe direction.
const (
	historyMaxLines  = 256
	historyKeepLines = 128
)

// leaseHistoryAppend records a granted lease (job, epoch, id, worker) in runner/leases/<job>.history.jsonl.
// The lease table keeps only each job's latest lease, so this is the coordinator's own record of who
// held which epoch: salvage frames and checkpoint manifests are checked against it, never against what the worker claims.
func (s *Server) leaseHistoryAppend(l workerproto.Lease) {
	line, _ := json.Marshal(map[string]any{"job": l.Job, "epoch": l.Epoch, "id": l.ID, "worker": l.Worker})
	if err := appendLine(s.historyPath(l.Job), line); err != nil {
		s.logf("lease history %s: %v", l.Job, err)
		return
	}
	b, err := os.ReadFile(s.historyPath(l.Job))
	if err != nil || strings.Count(string(b), "\n") <= historyMaxLines {
		return
	}
	lines := strings.Split(strings.TrimRight(string(b), "\n"), "\n")
	keep := strings.Join(lines[len(lines)-historyKeepLines:], "\n") + "\n"
	if err := writeFileAtomic(s.historyPath(l.Job), []byte(keep), false); err != nil {
		s.logf("lease history %s: prune: %v", l.Job, err)
	}
}

// leaseHistoryLookup returns the lease the coordinator granted for (job, epoch). If an epoch ever appears twice the LAST grant
// wins (a later grant supersedes an earlier one); it is never the first match.
func (s *Server) leaseHistoryLookup(job string, epoch int64) (workerproto.Lease, bool) {
	b, err := os.ReadFile(s.historyPath(job))
	if err != nil {
		return workerproto.Lease{}, false
	}
	var found workerproto.Lease
	ok := false
	for _, ln := range strings.Split(string(b), "\n") {
		var r struct {
			Job    string `json:"job"`
			Epoch  int64  `json:"epoch"`
			ID     string `json:"id"`
			Worker string `json:"worker"`
		}
		if json.Unmarshal([]byte(ln), &r) == nil && r.Job == job && r.Epoch == epoch && r.ID != "" {
			found, ok = workerproto.Lease{Job: job, Epoch: epoch, ID: r.ID, Worker: r.Worker}, true
		}
	}
	return found, ok
}
