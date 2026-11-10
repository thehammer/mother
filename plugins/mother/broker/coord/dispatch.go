package coord

import (
	"archive/tar"
	"bytes"
	"context"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"mother-broker/workerproto"
)

const (
	waitNoWorker = "no_worker_connected"
	waitBusy     = "all_workers_busy"
	waitOffer    = "offer_failed"
	waitUnknown  = "unknown_worker"
)

func (s *Server) dispatchPath(job string) string { return filepath.Join(s.dispatchDir(), job+".json") }

type dispatchReq struct {
	Job        string          `json:"job"`
	Worker     string          `json:"worker"`
	ResumeFrom json.RawMessage `json:"resume_from"`
	Attempt    int             `json:"attempt"`
	WaitReason string          `json:"wait_reason"`
	Rejects    int             `json:"rejects"`
	Held       string          `json:"held"`
}

// dispatchPass turns runner/dispatch/<job>.json requests into leases. A request whose job has a live
// lease is left alone (it is removed when the offer is accepted); one nobody can take stays, annotated
// with why.
func (s *Server) dispatchPass() {
	ents, err := os.ReadDir(s.dispatchDir())
	if err != nil {
		return
	}
	sort.Slice(ents, func(i, j int) bool { return ents[i].Name() < ents[j].Name() })
	for _, e := range ents {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".json") || strings.Contains(name, ".tmp.") {
			continue
		}
		raw, err := os.ReadFile(filepath.Join(s.dispatchDir(), name))
		if err != nil {
			continue
		}
		var req dispatchReq
		if json.Unmarshal(raw, &req) != nil {
			s.logf("dispatch %s: unreadable request", name)
			continue
		}
		job := strings.TrimSuffix(name, ".json")
		if req.Job != "" && req.Job != job {
			s.logf("dispatch %s: names job %q; ignoring", name, req.Job)
			continue
		}
		if !workerproto.IDOK(job) {
			continue
		}
		if l, ok := s.leases.Get(job); ok && (l.State == workerproto.LeaseOffered || l.State == workerproto.LeaseActive) {
			continue
		}
		if old := s.jobs[job]; old != nil && old.applying {
			continue // the previous lease's coord_apply is still running: never overlap it; retried next pass
		}
		if req.Held != "" {
			continue // offered and rejected too often: waits for the operator
		}
		if req.Worker != "" && s.creds[req.Worker] == nil {
			s.setWait(job, raw, req.WaitReason, waitUnknown)
			continue
		}
		w, reason := s.pickWorker(req.Worker)
		if w == nil {
			s.setWait(job, raw, req.WaitReason, reason)
			continue
		}
		if err := s.offer(job, req, w); err != nil {
			s.logf("offer %s: %v", job, err)
			s.setWait(job, raw, req.WaitReason, waitOffer)
		}
	}
}

func (s *Server) setWait(job string, raw []byte, cur, reason string) {
	if cur == reason {
		return
	}
	var m map[string]json.RawMessage
	if json.Unmarshal(raw, &m) != nil {
		return
	}
	m["wait_reason"], _ = json.Marshal(reason)
	b, err := json.Marshal(m)
	if err != nil {
		return
	}
	if err := writeFileAtomic(s.dispatchPath(job), append(b, '\n'), false); err != nil {
		s.logf("dispatch %s: %v", job, err)
	}
}

// pickWorker chooses the connected worker with the most free slots (the requested one only, when named).
func (s *Server) pickWorker(want string) (*workerConn, string) {
	if len(s.workers) == 0 {
		return nil, waitNoWorker
	}
	ids := make([]string, 0, len(s.workers))
	for id := range s.workers {
		ids = append(ids, id)
	}
	sort.Strings(ids)
	var best *workerConn
	bestFree := 0
	for _, id := range ids {
		if want != "" && id != want {
			continue
		}
		w := s.workers[id]
		if free := w.slots - s.liveCount(id); free > bestFree {
			best, bestFree = w, free
		}
	}
	if best != nil {
		return best, ""
	}
	if want != "" && s.workers[want] == nil {
		return nil, waitNoWorker
	}
	return nil, waitBusy
}

func (s *Server) offer(job string, req dispatchReq, w *workerConn) error {
	if old := s.jobs[job]; old != nil && old.applying {
		return fmt.Errorf("previous lease of %s is still applying", job)
	}
	jobDoc, err := os.ReadFile(s.jobPath(job))
	if err != nil {
		return fmt.Errorf("job doc: %w", err)
	}
	var doc map[string]json.RawMessage
	if err := json.Unmarshal(jobDoc, &doc); err != nil {
		return fmt.Errorf("job doc: %w", err)
	}
	plan, _ := os.ReadFile(s.path("events", job+"-plan.md"))
	bundle, err := tarDir(s.path("crew", job))
	if err != nil {
		return fmt.Errorf("crew bundle: %w", err)
	}
	var crew json.RawMessage
	if len(bundle) > 0 {
		if len(bundle) > 600<<10 {
			return fmt.Errorf("crew bundle is %d bytes; too large for one offer", len(bundle))
		}
		crew, _ = json.Marshal(base64.StdEncoding.EncodeToString(bundle))
	}
	repoPath := jsonString(doc["repo_path"])
	attempt := req.Attempt
	if attempt < 1 {
		attempt = 1 + jsonInt(doc["retry_count"]) + jsonInt(doc["escalation_count"])
	}
	var ckpt json.RawMessage
	if len(bytes.TrimSpace(req.ResumeFrom)) > 0 && string(bytes.TrimSpace(req.ResumeFrom)) != "null" {
		ckpt = req.ResumeFrom
	}
	offer := workerproto.LeaseOffer{
		CmdID: newID("c-"), JobDoc: jobDoc, Plan: string(plan), CrewBundle: crew, Checkpoint: ckpt,
		Repo: repoName(repoPath, jsonString(doc["repo"])), RepoPath: repoPath, Attempt: attempt,
		AppliedSeq: s.truthApplied(&jobLease{job: job}),
	}
	now := s.now()
	l, err := s.leases.Offer(job, newID("L-"), w.id, now)
	if err != nil {
		return err
	}
	s.leaseHistoryAppend(l)
	jl := &jobLease{job: job, pending: map[int64]workerproto.Frame{}, rec: LeaseRec{
		Job: job, LeaseID: l.ID, Epoch: l.Epoch, WorkerID: w.id, State: string(workerproto.LeaseOffered),
		OfferedAt: fmtTime(now), LastHB: fmtTime(now), Synced: map[string]json.RawMessage{},
	}}
	for _, k := range downlinkKeys {
		if v, ok := doc[k]; ok {
			jl.rec.Synced[k] = v
		} else {
			jl.rec.Synced[k] = json.RawMessage("null")
		}
	}
	jl.rec.LogOffset = s.logSize(job)
	if b, err := s.buildFrame(workerproto.TypeLeaseOffer, jl, offer); err != nil {
		return s.abandonOffer(job, l, err)
	} else if f, err := workerproto.Decode(b); err != nil {
		return s.abandonOffer(job, l, err)
	} else if err := workerproto.ValidateFrom(workerproto.FromCoordinator, f); err != nil {
		return s.abandonOffer(job, l, err)
	}
	// Durable before the offer leaves: a restart must never reissue this epoch (spec section 7).
	if err := s.persistTable(); err != nil {
		return s.abandonOffer(job, l, err)
	}
	if old := s.jobs[job]; old != nil && old.rec.WorkerID == w.id {
		for _, c := range old.cmds { // an unacked revoke of an earlier lease is still owed to its worker
			if c.Type == workerproto.TypeLeaseRevoke {
				jl.cmds = append(jl.cmds, c)
			}
		}
	}
	s.jobs[job] = jl
	s.adm.SetApplied(job, l.ID, l.Epoch, 0)
	jl.rec.AppliedSeq = s.truthApplied(jl)
	_ = os.Remove(s.lostPath(job))
	s.persistRec(jl)
	if err := s.queueCmd(jl, workerproto.TypeLeaseOffer, offer); err != nil {
		return s.abandonOffer(job, l, err)
	}
	s.logf("offered %s to %s (lease %s epoch %d)", job, w.id, l.ID, l.Epoch)
	return nil
}

// abandonOffer revokes a lease that could not be sent, so the job is not left "busy" for a TTL.
func (s *Server) abandonOffer(job string, l workerproto.Lease, cause error) error {
	_ = s.leases.Revoke(job, l.ID, l.Epoch)
	s.adm.Forget(job, l.ID, l.Epoch)
	delete(s.jobs, job)
	_ = s.persistTable()
	_ = os.Remove(s.cmdsPath(job))
	return cause
}

func jsonString(r json.RawMessage) string {
	var v string
	_ = json.Unmarshal(r, &v)
	return v
}

func jsonInt(r json.RawMessage) int {
	var v float64
	_ = json.Unmarshal(r, &v)
	return int(v)
}

// repoName is owner/name from the repo's origin URL (local paths and ssh/https URLs alike: the last
// two path components), falling back to the job's repo field or the directory name.
func repoName(repoPath, fallback string) string {
	if repoPath != "" {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if out, err := exec.CommandContext(ctx, "git", "-C", repoPath, "remote", "get-url", "origin").Output(); err == nil {
			u := strings.TrimSpace(string(out))
			u = strings.TrimSuffix(u, ".git")
			u = strings.ReplaceAll(u, ":", "/")
			parts := strings.Split(strings.Trim(u, "/"), "/")
			if n := len(parts); n >= 2 && parts[n-1] != "" && parts[n-2] != "" {
				if r := sanitizeRepo(parts[n-2] + "/" + parts[n-1]); r != "" {
					return r
				}
			}
		}
	}
	if r := sanitizeRepo(fallback); r != "" {
		return r
	}
	if r := sanitizeRepo(filepath.Base(repoPath)); r != "" {
		return r
	}
	return "unknown"
}

func sanitizeRepo(s string) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '-', r == '_', r == '/':
			b.WriteRune(r)
		}
	}
	out := b.String()
	if len(out) > 200 {
		out = out[:200]
	}
	return out
}

// tarDir returns a tar of dir's regular files (relative names), or nil when the directory is absent or empty.
func tarDir(dir string) ([]byte, error) {
	if fi, err := os.Stat(dir); err != nil || !fi.IsDir() {
		return nil, nil
	}
	var buf bytes.Buffer
	tw := tar.NewWriter(&buf)
	n := 0
	err := filepath.WalkDir(dir, func(p string, d fs.DirEntry, err error) error {
		if err != nil || d.IsDir() || !d.Type().IsRegular() || strings.Contains(filepath.Base(p), ".tmp.") {
			return err
		}
		rel, err := filepath.Rel(dir, p)
		if err != nil {
			return err
		}
		fi, err := d.Info()
		if err != nil {
			return err
		}
		if err := tw.WriteHeader(&tar.Header{Name: filepath.ToSlash(rel), Mode: 0o644, Size: fi.Size(), ModTime: fi.ModTime()}); err != nil {
			return err
		}
		f, err := os.Open(p)
		if err != nil {
			return err
		}
		defer f.Close()
		_, err = io.Copy(tw, f)
		n++
		return err
	})
	if err != nil {
		return nil, err
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if n == 0 {
		return nil, nil
	}
	return buf.Bytes(), nil
}
