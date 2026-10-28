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
//
// INVARIANT: a record exists only while its job file does. fsnotify is a
// hint, not a guarantee (kqueue drops/coalesces events under bursts, the
// watcher can fail to start or report errors), so the invariant is enforced
// by reconciling against the directory rather than trusting events alone:
//   - reconcile() lists the directory every reconcileEvery (30s) from the
//     watch goroutine, dropping records whose file is gone and (re)loading
//     files that are new or changed. It also runs on every watcher error.
//   - if the watcher cannot be created/attached (or dies), watch falls back
//     to calling reconcile() every pollEvery (5s) instead of freezing.
//   - pruneMissing() stats each record's file; query.list, query.get and
//     subscribe snapshots call it first, so a lost event never surfaces a
//     job whose file is gone.
// No protocol event is published for a reconcile drop: the contract has no
// removal/archived kind, so clients converge via query.list.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/fsnotify/fsnotify"
)

const (
	defaultReconcileEvery = 30 * time.Second
	defaultPollEvery      = 5 * time.Second
)

// fileSig identifies a version of a job file, so reconcile can spot content
// changes whose fs event was lost without re-reading every file each pass.
type fileSig struct {
	mtime time.Time
	size  int64
}

// jobRecord holds a job's raw JSON plus the few fields the broker filters on.
type jobRecord struct {
	raw   json.RawMessage
	id    string
	file  string // base name of the backing file in the jobs dir
	sig   fileSig
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

	// Cadences and the watcher factory; set by newJobStore, overridable in tests.
	reconcileEvery time.Duration // directory reconcile while the watcher is healthy
	pollEvery      time.Duration // reconcile cadence when the watcher is unavailable
	openWatcher    func(dir string) (*fsnotify.Watcher, error)
}

func newJobStore(jobsDir string) *jobStore {
	return &jobStore{
		dir:            jobsDir,
		jobs:           map[string]*jobRecord{},
		progress:       map[string]json.RawMessage{},
		reconcileEvery: defaultReconcileEvery,
		pollEvery:      defaultPollEvery,
		openWatcher:    openDirWatcher,
	}
}

func openDirWatcher(dir string) (*fsnotify.Watcher, error) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return nil, err
	}
	if err := w.Add(dir); err != nil {
		w.Close()
		return nil, err
	}
	return w, nil
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
	// Stat before reading: a write landing in between leaves a stale sig, so
	// the next reconcile re-reads rather than missing it.
	var sig fileSig
	if fi, err := os.Stat(path); err == nil {
		sig = fileSig{mtime: fi.ModTime(), size: fi.Size()}
	}
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
		file:  filepath.Base(path),
		sig:   sig,
		state: light.State,
		repo:  light.Repo,
	}
	s.mu.Lock()
	s.jobs[light.ID] = rec
	s.mu.Unlock()
}

// reconcile brings the store in line with the jobs directory: records whose
// file is gone are dropped (with their progress entry), files present but
// unknown are loaded, and files whose mtime/size changed are re-read (a lost
// modify event). If the directory cannot be listed nothing is dropped.
func (s *jobStore) reconcile() {
	entries, err := os.ReadDir(s.dir)
	if err != nil {
		return
	}
	present := make(map[string]fileSig, len(entries))
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		var sig fileSig
		if fi, err := e.Info(); err == nil {
			sig = fileSig{mtime: fi.ModTime(), size: fi.Size()}
		}
		present[e.Name()] = sig
	}

	s.mu.Lock()
	fresh := make(map[string]bool, len(s.jobs))
	for id, rec := range s.jobs {
		sig, ok := present[rec.file]
		if !ok {
			delete(s.jobs, id)
			delete(s.progress, id)
			continue
		}
		if sig == rec.sig {
			fresh[rec.file] = true
		}
	}
	s.mu.Unlock()

	for name := range present {
		if !fresh[name] {
			s.refresh(filepath.Join(s.dir, name))
		}
	}
}

// pruneMissing stats every record's file and drops those that are gone, so
// callers never see a job whose file was archived behind a lost fs event.
func (s *jobStore) pruneMissing() {
	s.mu.RLock()
	recs := make([]*jobRecord, 0, len(s.jobs))
	for _, rec := range s.jobs {
		recs = append(recs, rec)
	}
	s.mu.RUnlock()

	var gone []*jobRecord
	for _, rec := range recs {
		if _, err := os.Stat(filepath.Join(s.dir, rec.file)); errors.Is(err, os.ErrNotExist) {
			gone = append(gone, rec)
		}
	}
	s.dropRecords(gone)
}

// pruneMissingID is pruneMissing for a single job (query.get).
func (s *jobStore) pruneMissingID(id string) {
	s.mu.RLock()
	rec := s.jobs[id]
	s.mu.RUnlock()
	if rec == nil {
		return
	}
	if _, err := os.Stat(filepath.Join(s.dir, rec.file)); errors.Is(err, os.ErrNotExist) {
		s.dropRecords([]*jobRecord{rec})
	}
}

// dropRecords deletes the given records unless a refresh has replaced them
// since they were observed (the file may have reappeared).
func (s *jobStore) dropRecords(recs []*jobRecord) {
	if len(recs) == 0 {
		return
	}
	s.mu.Lock()
	for _, rec := range recs {
		if s.jobs[rec.id] == rec {
			delete(s.jobs, rec.id)
			delete(s.progress, rec.id)
		}
	}
	s.mu.Unlock()
}

// watch blocks, applying fsnotify changes to the store until the done channel
// closes, and reconciling against the directory on a timer and on watcher
// errors. If the watcher cannot start or dies, it polls instead. Runs in its
// own goroutine.
func (s *jobStore) watch(done <-chan struct{}) {
	w, err := s.openWatcher(s.dir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mother-broker: job watcher unavailable (%v); polling %s every %s\n", err, s.dir, s.pollEvery)
		s.poll(done)
		return
	}
	defer w.Close()
	// Catch anything that changed between load() and the watcher attaching.
	s.reconcile()
	tick := time.NewTicker(s.reconcileEvery)
	defer tick.Stop()
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			s.reconcile()
		case ev, ok := <-w.Events:
			if !ok {
				fmt.Fprintf(os.Stderr, "mother-broker: job watcher closed; polling %s every %s\n", s.dir, s.pollEvery)
				s.poll(done)
				return
			}
			if !strings.HasSuffix(ev.Name, ".json") {
				continue
			}
			s.refresh(ev.Name)
		case err, ok := <-w.Errors:
			if !ok {
				fmt.Fprintf(os.Stderr, "mother-broker: job watcher closed; polling %s every %s\n", s.dir, s.pollEvery)
				s.poll(done)
				return
			}
			fmt.Fprintf(os.Stderr, "mother-broker: job watcher error: %v; reconciling\n", err)
			s.reconcile()
		}
	}
}

// poll reconciles every pollEvery until done closes (fallback when there is
// no working watcher). It reconciles once immediately to catch anything
// missed while the watcher was failing.
func (s *jobStore) poll(done <-chan struct{}) {
	s.reconcile()
	tick := time.NewTicker(s.pollEvery)
	defer tick.Stop()
	for {
		select {
		case <-done:
			return
		case <-tick.C:
			s.reconcile()
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
