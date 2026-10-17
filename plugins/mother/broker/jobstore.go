package main

// jobstore.go — an in-memory, READ-ONLY mirror of $MOTHER_ROOT/jobs/*.json.
//
// The broker never writes job JSON (B1): bash remains the sole writer, and
// all mutations route through the `mother` CLI. This store is a pure reader,
// refreshed via fsnotify, that serves the static/extra fields of each job
// record for `snapshot`, `query.list`, and `query.get`. The dynamic
// state/activity/await fields are overlaid from the event-derived mirror
// (see hub.jobState) so the snapshot is consistent with the live event
// stream — see subscriptions / hub for the no-gap/no-dup contract.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"

	"github.com/fsnotify/fsnotify"
)

// jobRecord holds a job's raw JSON plus the few fields the broker filters on.
type jobRecord struct {
	raw   json.RawMessage
	id    string
	state string
	repo  string
}

type jobStore struct {
	dir string

	mu   sync.RWMutex
	jobs map[string]*jobRecord

	// progress is the latest progress_updated detail per job (HC-09), folded
	// in from the event stream by the hub. Not job JSON: merged on read.
	progress map[string]json.RawMessage
}

func newJobStore(jobsDir string) *jobStore {
	return &jobStore{dir: jobsDir, jobs: map[string]*jobRecord{}, progress: map[string]json.RawMessage{}}
}

// load reads every jobs/*.json into memory. Called once at startup.
func (s *jobStore) load() {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		s.refresh(filepath.Join(s.dir, e.Name()))
	}
}

// refresh re-reads a single job file. A removed file drops the record.
func (s *jobStore) refresh(path string) {
	id := strings.TrimSuffix(filepath.Base(path), ".json")
	b, err := os.ReadFile(path)
	if err != nil {
		s.mu.Lock()
		delete(s.jobs, id)
		delete(s.progress, id)
		s.mu.Unlock()
		return
	}
	var light struct {
		ID    string `json:"id"`
		State string `json:"state"`
		Repo  string `json:"repo"`
	}
	if err := json.Unmarshal(b, &light); err != nil {
		// Partial/atomic-write race: leave the previous record in place.
		return
	}
	if light.ID == "" {
		light.ID = id
	}
	rec := &jobRecord{
		raw:   append(json.RawMessage(nil), b...),
		id:    light.ID,
		state: light.State,
		repo:  light.Repo,
	}
	s.mu.Lock()
	s.jobs[light.ID] = rec
	s.mu.Unlock()
}

// watch blocks, applying fsnotify changes to the store until ctx-style stop
// via the done channel. Runs in its own goroutine.
func (s *jobStore) watch(done <-chan struct{}) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return
	}
	defer w.Close()
	if err := w.Add(s.dir); err != nil {
		return
	}
	for {
		select {
		case <-done:
			return
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			if !strings.HasSuffix(ev.Name, ".json") {
				continue
			}
			s.refresh(ev.Name)
		case _, ok := <-w.Errors:
			if !ok {
				return
			}
		}
	}
}

// get returns the raw JSON for one job, or (nil, false).
func (s *jobStore) get(id string) (json.RawMessage, bool) {
	s.mu.RLock()
	defer s.mu.RUnlock()
	rec, ok := s.jobs[id]
	if !ok {
		return nil, false
	}
	return s.withProgressLocked(id, rec.raw), true
}

// setProgress records a job's latest progress object (a progress_updated detail).
func (s *jobStore) setProgress(id string, detail json.RawMessage) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.progress == nil {
		s.progress = map[string]json.RawMessage{}
	}
	s.progress[id] = append(json.RawMessage(nil), detail...)
}

// withProgressLocked adds the job's `progress` key to its raw JSON. Jobs with
// no progress are returned untouched (byte-identical).
func (s *jobStore) withProgressLocked(id string, raw json.RawMessage) json.RawMessage {
	p, ok := s.progress[id]
	if !ok || len(p) == 0 {
		return raw
	}
	m := map[string]json.RawMessage{}
	if json.Unmarshal(raw, &m) != nil {
		return raw
	}
	m["progress"] = p
	out, err := json.Marshal(m)
	if err != nil {
		return raw
	}
	return out
}

// allIDs returns every known job id, sorted, for snapshotting an all-jobs
// subscription.
func (s *jobStore) allIDs() []string {
	s.mu.RLock()
	ids := make([]string, 0, len(s.jobs))
	for id := range s.jobs {
		ids = append(ids, id)
	}
	s.mu.RUnlock()
	sort.Strings(ids)
	return ids
}

// exists reports whether a job record is present.
func (s *jobStore) exists(id string) bool {
	s.mu.RLock()
	defer s.mu.RUnlock()
	_, ok := s.jobs[id]
	return ok
}

// listFilter selects job records for query.list.
type listFilter struct {
	jobs  []string // empty or contains "all" → no job filter
	state string   // empty → any state
	repo  string   // empty → any repo
}

func (f listFilter) jobAllowed(id string) bool {
	if len(f.jobs) == 0 {
		return true
	}
	for _, j := range f.jobs {
		if j == "all" || j == id {
			return true
		}
	}
	return false
}

// list returns the raw JSON of all jobs matching the filter, sorted by id for
// determinism.
func (s *jobStore) list(f listFilter) []json.RawMessage {
	s.mu.RLock()
	defer s.mu.RUnlock()

	ids := make([]string, 0, len(s.jobs))
	for id := range s.jobs {
		ids = append(ids, id)
	}
	sort.Strings(ids)

	out := make([]json.RawMessage, 0, len(ids))
	for _, id := range ids {
		rec := s.jobs[id]
		if !f.jobAllowed(id) {
			continue
		}
		if f.state != "" && rec.state != f.state {
			continue
		}
		if f.repo != "" && rec.repo != f.repo {
			continue
		}
		out = append(out, s.withProgressLocked(id, rec.raw))
	}
	return out
}
