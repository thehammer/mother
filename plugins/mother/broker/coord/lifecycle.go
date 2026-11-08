package coord

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"

	"mother-broker/workerproto"
)

func (s *Server) revokeDir() string { return s.path("runner", "revoke") }

func (s *Server) degradedPath(job string) string {
	return filepath.Join(s.leasesDir(), job+".degraded")
}

// revokePass turns runner/revoke/<job>.json ({"reason": "..."}) requests into RevokeLease calls. This is the
// operator-revoke and runner-side (cancel escalation, limiter hold ordering) entry point. A graceful cancel
// is NOT a revoke: it travels as cancel_requested (sync.job) and the worker finishes and releases, so its
// last ops and log still land; the runner asks for a revoke only when that has not happened in time.
// A request for a job with no live lease is dropped.
func (s *Server) revokePass() {
	if ents, err := os.ReadDir(s.revokeDir()); err == nil {
		for _, e := range ents {
			name := e.Name()
			if e.IsDir() || !strings.HasSuffix(name, ".json") || strings.Contains(name, ".tmp.") {
				continue
			}
			job := strings.TrimSuffix(name, ".json")
			if !workerproto.IDOK(job) {
				continue
			}
			var req struct {
				Reason string `json:"reason"`
			}
			if b, err := os.ReadFile(filepath.Join(s.revokeDir(), name)); err == nil {
				_ = json.Unmarshal(b, &req)
			}
			reason := sanitizeReason(req.Reason, "operator_revoke")
			if err := s.revokeLocked(job, reason); err != nil {
				s.logf("revoke %s: %v", job, err)
			}
			_ = os.Remove(filepath.Join(s.revokeDir(), name))
		}
	}
}

func sanitizeReason(r, def string) string {
	var b strings.Builder
	for _, c := range r {
		switch {
		case c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '_' || c == '-' || c == ':' || c == '.':
			b.WriteRune(c)
		case c == ' ':
			b.WriteRune('_')
		}
	}
	out := b.String()
	if out == "" {
		return def
	}
	if len(out) > 64 { // the protocol's reason pattern is ^[A-Za-z0-9._:-]{1,64}$
		out = out[:64]
	}
	return out
}

// pruneStaleCmds drops commands still queued on a lease that ended more than revokeRetain ago (a revoke
// whose worker never came back).
func (s *Server) pruneStaleCmds() {
	for _, jl := range s.jobs {
		if live(jl.rec.State) || len(jl.cmds) == 0 {
			continue
		}
		if t, err := parseTime(jl.rec.EndedAt); err == nil && s.now().Sub(t) > revokeRetain {
			jl.cmds = nil
			s.persistCmds(jl)
		}
	}
}

// rejectOffer: the worker rejected lease.offer (no_slot, mirror_failed, ...). The lease is ended at once so
// the slot is free and the job is not "busy" for a TTL, and the dispatch request stays so the next pass
// re-offers it; after maxOfferRejects rejections it is held with the reason instead.
func (s *Server) rejectOffer(jl *jobLease, why string) {
	why = sanitizeReason(why, "rejected")
	if l, ok := s.leases.Get(jl.job); ok && l.ID == jl.rec.LeaseID {
		_ = s.leases.Revoke(jl.job, l.ID, l.Epoch)
	}
	s.endLease(jl, workerproto.LeaseRevoked, "offer_rejected:"+why)
	raw, err := os.ReadFile(s.dispatchPath(jl.job))
	if err != nil {
		return
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	var n int
	_ = json.Unmarshal(m["rejects"], &n)
	n++
	m["rejects"], _ = json.Marshal(n)
	reason := "offer_rejected:" + why
	if n >= maxOfferRejects {
		m["held"], _ = json.Marshal(reason)
		reason = "held:" + reason
	}
	m["wait_reason"], _ = json.Marshal(reason)
	if b, err := json.Marshal(m); err == nil {
		_ = writeFileAtomic(s.dispatchPath(jl.job), append(b, '\n'), false)
	}
	select {
	case s.kick <- struct{}{}:
	default:
	}
}

// noteDegraded records a worker-reported outbox loss once per lease: audit, a marker the runner's hold
// reads (runner/leases/<job>.degraded) and an attention item in coord-status.json.
func (s *Server) noteDegraded(jl *jobLease, why string) {
	if jl.rec.Degraded != "" {
		return
	}
	why = sanitizeReason(why, "outbox_degraded")
	jl.rec.Degraded = why
	s.audit(jl.rec.WorkerID, jl.job, jl.rec.LeaseID, jl.rec.Epoch, "outbox_degraded")
	note, _ := json.Marshal(map[string]any{"job": jl.job, "lease_id": jl.rec.LeaseID, "epoch": jl.rec.Epoch,
		"worker_id": jl.rec.WorkerID, "why": why, "at": fmtTime(s.now())})
	_ = writeFileAtomic(s.degradedPath(jl.job), append(note, '\n'), false)
	s.persistRec(jl)
}
