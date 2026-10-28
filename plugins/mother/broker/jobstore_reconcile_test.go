package main

// jobstore_reconcile_test.go — invariant: a jobStore record exists only while
// its jobs/<file>.json exists. fsnotify can drop events (burst, overflow,
// watcher death), so a job file moved to archive/ must not linger in
// query.list / query.get, and the store must self-heal without events.
//
// Requires: jobStore.reconcile, jobStore.pruneMissing, jobStore.pruneMissingID,
// jobStore.reconcileEvery, jobStore.pollEvery, jobStore.openWatcher, and the
// test hook jobStore.afterListHook (runs inside reconcile() right after the
// directory snapshot, before the store is examined; nil in production). See
// jobstore.go.
//
// Invariant added alongside the hook: a record is dropped only on positive
// evidence that its own file is gone (ENOENT on that file), never because a
// snapshot, a listing, or a missing/unreadable jobs directory said so.

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/fsnotify/fsnotify"
)

const reconcileDeadline = 3 * time.Second

// writeJobFile writes jobs/<file> containing a job with the given id, without
// telling the store (simulates a file appearing with no fsnotify event).
func writeJobFile(t testing.TB, dir, file, id, state string) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"id": id, "state": state, "repo": "testrepo"})
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	path := filepath.Join(dir, file)
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
	return path
}

// archiveJobFile moves jobs/<id>.json into a sibling archive/ dir, as
// `mother archive` does, again without telling the store.
func archiveJobFile(t testing.TB, jobsDir, id string) {
	t.Helper()
	archive := filepath.Join(filepath.Dir(jobsDir), "archive")
	if err := os.MkdirAll(archive, 0o755); err != nil {
		t.Fatalf("mkdir archive: %v", err)
	}
	if err := os.Rename(filepath.Join(jobsDir, id+".json"), filepath.Join(archive, id+".json")); err != nil {
		t.Fatalf("archive %s: %v", id, err)
	}
}

// listedIDs returns the ids query.list reports.
func listedIDs(t testing.TB, r *commandRunner) []string {
	t.Helper()
	res := r.queryList(listFilter{})
	if res.code != "" {
		t.Fatalf("queryList failed: %s %s", res.code, res.msg)
	}
	jobs, _ := res.payload["jobs"].([]json.RawMessage)
	ids := make([]string, 0, len(jobs))
	for _, j := range jobs {
		var m struct {
			ID string `json:"id"`
		}
		if err := json.Unmarshal(j, &m); err != nil {
			t.Fatalf("decode listed job: %v", err)
		}
		ids = append(ids, m.ID)
	}
	return ids
}

func contains(ids []string, id string) bool {
	for _, x := range ids {
		if x == id {
			return true
		}
	}
	return false
}

// runWatch runs store.watch in a goroutine and stops it (waiting for return)
// on test cleanup. Returns the stop func so tests can also assert prompt exit.
func runWatch(t *testing.T, s *jobStore) (stop func()) {
	t.Helper()
	done := make(chan struct{})
	returned := make(chan struct{})
	go func() {
		defer close(returned)
		s.watch(done)
	}()
	var once sync.Once
	stop = func() {
		once.Do(func() { close(done) })
		select {
		case <-returned:
		case <-time.After(reconcileDeadline):
			t.Errorf("watch did not return after done was closed")
		}
	}
	t.Cleanup(stop)
	return stop
}

// --- 1. Dropped event: archived file must vanish from queries -------------

func TestQueryList_OmitsJobWhoseFileWasArchivedWithoutAnEvent(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "keep", nil)
	th.injectJob(t, "gone", nil)
	if ids := listedIDs(t, th.runner); !contains(ids, "gone") || !contains(ids, "keep") {
		t.Fatalf("precondition: want both jobs listed, got %v", ids)
	}

	archiveJobFile(t, th.jobsDir, "gone") // no watcher running: event "dropped"

	for i := 1; i <= 2; i++ { // second list must not resurrect it
		ids := listedIDs(t, th.runner)
		if contains(ids, "gone") {
			t.Errorf("list #%d still returns archived job: %v", i, ids)
		}
		if !contains(ids, "keep") {
			t.Errorf("list #%d lost the job whose file still exists: %v", i, ids)
		}
	}
}

func TestQueryGet_ReportsNoSuchJobWhenFileWasArchivedWithoutAnEvent(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "gone", nil)
	if res := th.runner.queryGet("gone"); res.code != "" {
		t.Fatalf("precondition: queryGet failed: %s", res.code)
	}

	archiveJobFile(t, th.jobsDir, "gone")

	res := th.runner.queryGet("gone")
	if res.code != ErrNoSuchJob {
		t.Errorf("queryGet(archived) code = %q, want %q", res.code, ErrNoSuchJob)
	}
	if th.store.exists("gone") {
		t.Errorf("store still holds a record for an archived job")
	}
}

func TestSubscribeSnapshot_OmitsJobWhoseFileWasArchivedWithoutAnEvent(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "keep", nil)
	th.injectJob(t, "gone", nil)
	archiveJobFile(t, th.jobsDir, "gone")

	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello
	snap := subscribeSimple(t, conn, "s", []string{"all"}, []string{CatState})

	raw, _ := json.Marshal(mustDecodeData(t, snap))
	var d struct {
		Jobs []struct {
			ID string `json:"id"`
		} `json:"jobs"`
	}
	if err := json.Unmarshal(raw, &d); err != nil {
		t.Fatalf("decode snapshot: %v", err)
	}
	for _, j := range d.Jobs {
		if j.ID == "gone" {
			t.Errorf("snapshot includes archived job %q", j.ID)
		}
	}
}

func TestReconcile_DropsArchivedJobAndItsProgress(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "gone", nil)
	th.store.setProgress("gone", json.RawMessage(`{"pct":40}`))
	archiveJobFile(t, th.jobsDir, "gone")

	th.store.reconcile()

	if _, ok := th.store.get("gone"); ok {
		t.Errorf("get(gone) still found after reconcile")
	}
	if th.store.exists("gone") {
		t.Errorf("exists(gone) true after reconcile")
	}
	// A later file with the same id must not inherit the stale progress.
	th.injectJob(t, "gone", nil)
	raw, ok := th.store.get("gone")
	if !ok {
		t.Fatalf("re-created job not found")
	}
	var m map[string]json.RawMessage
	_ = json.Unmarshal(raw, &m)
	if _, has := m["progress"]; has {
		t.Errorf("stale progress survived reconcile: %s", raw)
	}
}

func TestPruneMissing_DropsOnlyRecordsWhoseFileIsGone(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "keep", nil)
	th.injectJob(t, "gone", nil)
	th.store.setProgress("gone", json.RawMessage(`{"pct":10}`))
	archiveJobFile(t, th.jobsDir, "gone")

	th.store.pruneMissing()

	if th.store.exists("gone") {
		t.Errorf("pruneMissing kept a record whose file is gone")
	}
	if !th.store.exists("keep") {
		t.Errorf("pruneMissing dropped a record whose file exists")
	}
}

// --- 2. reconcile picks up new files and drops missing ones ---------------

func TestReconcile_PicksUpFileThatAppearedWithoutAnEvent(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "old", nil)
	archiveJobFile(t, th.jobsDir, "old")
	writeJobFile(t, th.jobsDir, "fresh.json", "fresh", "running")

	th.store.reconcile()

	if th.store.exists("old") {
		t.Errorf("reconcile kept the missing job")
	}
	if _, ok := th.store.get("fresh"); !ok {
		t.Fatalf("reconcile did not pick up the new file")
	}
	if ids := listedIDs(t, th.runner); !contains(ids, "fresh") || contains(ids, "old") {
		t.Errorf("list after reconcile = %v, want fresh and not old", ids)
	}
}

// --- 3. Watcher cannot start: polling fallback -----------------------------

func TestWatch_FallsBackToPollingWhenWatcherCannotStart(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "gone", nil)
	th.store.pollEvery = 20 * time.Millisecond
	th.store.reconcileEvery = time.Hour
	th.store.openWatcher = func(string) (*fsnotify.Watcher, error) {
		return nil, errors.New("inotify limit reached")
	}
	stop := runWatch(t, th.store)

	archiveJobFile(t, th.jobsDir, "gone")
	writeJobFile(t, th.jobsDir, "fresh.json", "fresh", "ready")

	if !pollCondition(func() bool {
		return !th.store.exists("gone") && th.store.exists("fresh")
	}, reconcileDeadline) {
		t.Fatalf("polling fallback did not converge: gone=%v fresh=%v",
			th.store.exists("gone"), th.store.exists("fresh"))
	}
	stop() // returns promptly once done is closed
}

func TestWatch_FallsBackToPollingWhenJobsDirDoesNotExistYet(t *testing.T) {
	tmp := t.TempDir()
	jobsDir := filepath.Join(tmp, "jobs") // not created: default watcher Add fails
	store := newJobStore(jobsDir)
	store.pollEvery = 20 * time.Millisecond
	store.reconcileEvery = time.Hour
	runWatch(t, store)

	if err := os.MkdirAll(jobsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	writeJobFile(t, jobsDir, "late.json", "late", "ready")

	if !pollCondition(func() bool { return store.exists("late") }, reconcileDeadline) {
		t.Fatalf("job written after the dir appeared was never picked up")
	}
}

func TestWatch_FallsBackToPollingWhenWatcherDies(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "gone", nil)
	th.store.pollEvery = 20 * time.Millisecond
	th.store.reconcileEvery = time.Hour

	created := make(chan *fsnotify.Watcher, 1)
	th.store.openWatcher = func(dir string) (*fsnotify.Watcher, error) {
		w, err := fsnotify.NewWatcher()
		if err != nil {
			return nil, err
		}
		if err := w.Add(dir); err != nil {
			w.Close()
			return nil, err
		}
		created <- w
		return w, nil
	}
	runWatch(t, th.store)

	var w *fsnotify.Watcher
	select {
	case w = <-created:
	case <-time.After(reconcileDeadline):
		t.Fatalf("watch never opened a watcher")
	}
	w.Close() // watcher dies: its Events/Errors channels close

	archiveJobFile(t, th.jobsDir, "gone")
	writeJobFile(t, th.jobsDir, "fresh.json", "fresh", "ready")

	if !pollCondition(func() bool {
		return !th.store.exists("gone") && th.store.exists("fresh")
	}, reconcileDeadline) {
		t.Fatalf("store did not converge after watcher died: gone=%v fresh=%v",
			th.store.exists("gone"), th.store.exists("fresh"))
	}
}

// --- 4. Deaf watcher: periodic reconcile ticker heals the store ------------

func TestWatch_PeriodicReconcileHealsStoreWhenWatcherDeliversNoEvents(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "gone", nil)
	th.store.reconcileEvery = 20 * time.Millisecond
	th.store.pollEvery = time.Hour
	th.store.openWatcher = func(string) (*fsnotify.Watcher, error) {
		return fsnotify.NewWatcher() // never Add: no events will ever arrive
	}
	runWatch(t, th.store)

	archiveJobFile(t, th.jobsDir, "gone")
	writeJobFile(t, th.jobsDir, "fresh.json", "fresh", "ready")

	if !pollCondition(func() bool {
		return !th.store.exists("gone") && th.store.exists("fresh")
	}, reconcileDeadline) {
		t.Fatalf("reconcile ticker did not converge: gone=%v fresh=%v",
			th.store.exists("gone"), th.store.exists("fresh"))
	}
}

func TestWatch_StillAppliesNormalEventsWithRealWatcher(t *testing.T) {
	th := newTestHub(t, 1024)
	th.store.reconcileEvery = time.Hour
	th.store.pollEvery = time.Hour
	runWatch(t, th.store)

	// Give the watcher a moment to register, then write via a real fs event.
	if !pollCondition(func() bool {
		writeJobFile(t, th.jobsDir, "live.json", "live", "ready")
		return th.store.exists("live")
	}, reconcileDeadline) {
		t.Fatalf("real fsnotify event never reached the store")
	}
	archiveJobFile(t, th.jobsDir, "live")
	if !pollCondition(func() bool { return !th.store.exists("live") }, reconcileDeadline) {
		t.Fatalf("archive (rename) event did not drop the record")
	}
}

// --- 6. Partially written file must not clobber the known record -----------

func TestInvalidJSONForKnownJobLeavesPreviousRecord(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "j", map[string]any{"state": "running"})
	path := filepath.Join(th.jobsDir, "j.json")
	if err := os.WriteFile(path, []byte(`{"id":"j","state":"runn`), 0o644); err != nil {
		t.Fatal(err)
	}

	th.store.refresh(path)
	assertStillRunning(t, th, "after refresh")

	th.store.reconcile()
	assertStillRunning(t, th, "after reconcile")

	th.store.pruneMissing()
	assertStillRunning(t, th, "after pruneMissing")
}

func assertStillRunning(t *testing.T, th *testHub, when string) {
	t.Helper()
	raw, ok := th.store.get("j")
	if !ok {
		t.Fatalf("%s: record dropped by an unparseable file", when)
	}
	var m struct {
		State string `json:"state"`
	}
	if err := json.Unmarshal(raw, &m); err != nil || m.State != "running" {
		t.Errorf("%s: record = %s, want previous running record", when, raw)
	}
}

func TestReconcile_UnreadableJobsDirDropsNothing(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "j", nil)
	// Point the store at a directory that cannot be listed.
	th.store.dir = filepath.Join(th.tmpRoot, "does-not-exist")

	th.store.reconcile()

	if !th.store.exists("j") {
		t.Errorf("reconcile dropped records although ReadDir failed")
	}
}

// --- 8. File name differs from embedded id ---------------------------------

func TestReconcile_KeepsJobWhoseFileNameDiffersFromItsEmbeddedID(t *testing.T) {
	th := newTestHub(t, 1024)
	path := writeJobFile(t, th.jobsDir, "a.json", "b", "ready")
	th.store.refresh(path)
	if !th.store.exists("b") {
		t.Fatalf("precondition: record keyed by embedded id b")
	}

	th.store.reconcile()
	th.store.pruneMissing()
	if !th.store.exists("b") {
		t.Errorf("record dropped while its file a.json still exists")
	}
	if ids := listedIDs(t, th.runner); !contains(ids, "b") {
		t.Errorf("list = %v, want b while a.json exists", ids)
	}
	if res := th.runner.queryGet("b"); res.code != "" {
		t.Errorf("queryGet(b) = %q while a.json exists", res.code)
	}

	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if ids := listedIDs(t, th.runner); contains(ids, "b") {
		t.Errorf("list = %v, want b gone after a.json removed", ids)
	}
}

// --- 7. Concurrency (run with -race) ---------------------------------------

func TestJobStore_ConcurrentQueriesAndReconcileWhileFilesChurn(t *testing.T) {
	th := newTestHub(t, 1024)
	for i := 0; i < 20; i++ {
		th.injectJob(t, fmt.Sprintf("stable-%d", i), nil)
	}
	th.store.reconcileEvery = 5 * time.Millisecond
	th.store.pollEvery = 5 * time.Millisecond
	stopWatch := runWatch(t, th.store)

	stop := make(chan struct{})
	var wg sync.WaitGroup
	spin := func(fn func()) {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				select {
				case <-stop:
					return
				default:
					fn()
				}
			}
		}()
	}
	// Completed-iteration counters: the test waits for real progress from the
	// churn writer and the reconcile spinner rather than sleeping.
	var churnIters, reconcilePasses, pruneIters atomic.Int64
	const minIters = 20

	spin(func() { th.runner.queryList(listFilter{}) })
	spin(func() { th.runner.queryList(listFilter{state: "ready"}) })
	spin(func() { th.runner.queryGet("stable-3") })
	spin(func() { th.store.get("churn-1"); th.store.allIDs() })
	spin(func() { th.store.setProgress("churn-1", json.RawMessage(`{"pct":1}`)) })
	spin(func() { th.store.reconcile(); reconcilePasses.Add(1) })
	spin(func() { th.store.pruneMissing(); pruneIters.Add(1) })
	spin(func() {
		for i := 0; i < 5; i++ {
			id := fmt.Sprintf("churn-%d", i)
			path := writeJobFile(t, th.jobsDir, id+".json", id, "ready")
			th.store.refresh(path)
			_ = os.Remove(path)
		}
		churnIters.Add(1)
	})

	// Let the goroutines interleave under -race until each spinner has done a
	// minimum amount of real work (bounded by a deadline, no fixed sleep).
	interleaved := pollCondition(func() bool {
		return churnIters.Load() >= minIters &&
			reconcilePasses.Load() >= minIters &&
			pruneIters.Load() >= minIters
	}, reconcileDeadline)
	close(stop)
	wg.Wait()
	if !interleaved {
		t.Errorf("spinners made too little progress before the deadline: churn=%d reconcile=%d prune=%d (want >= %d each)",
			churnIters.Load(), reconcilePasses.Load(), pruneIters.Load(), minIters)
	}
	stopWatch() // a late fs event must not re-add a churn file after the checks below

	// Quiescent end state: stable jobs survive, churn files (all removed) don't.
	th.store.reconcile()
	ids := listedIDs(t, th.runner)
	for i := 0; i < 20; i++ {
		if id := fmt.Sprintf("stable-%d", i); !contains(ids, id) {
			t.Errorf("stable job %s lost during churn", id)
		}
	}
	for i := 0; i < 5; i++ {
		if id := fmt.Sprintf("churn-%d", i); contains(ids, id) {
			t.Errorf("removed job %s still listed", id)
		}
	}
}

// --- 10. Snapshot race: a file created after the listing must survive ------

// reconcile lists the directory outside the store lock. A file created (and
// picked up by the watcher's refresh) after that listing is absent from the
// snapshot but its file exists, so reconcile must not drop its record.
func TestReconcile_KeepsRecordCreatedAfterSnapshot(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "keep", nil)
	th.injectJob(t, "gone", nil)
	archiveJobFile(t, th.jobsDir, "gone") // genuinely gone before reconcile

	var once sync.Once
	th.store.afterListHook = func() {
		once.Do(func() {
			path := writeJobFile(t, th.jobsDir, "late.json", "late", "running")
			th.store.refresh(path) // the watcher wins the race against reconcile
		})
	}

	th.store.reconcile()
	th.store.afterListHook = nil

	if !th.store.exists("late") {
		t.Errorf("reconcile dropped a record created after its snapshot although its file exists")
	}
	if _, ok := th.store.get("late"); !ok {
		t.Errorf("get(late) not found after reconcile")
	}
	if !th.store.exists("keep") {
		t.Errorf("reconcile dropped a pre-existing record whose file exists")
	}
	if th.store.exists("gone") {
		t.Errorf("reconcile kept a record whose file is genuinely gone")
	}
	ids := listedIDs(t, th.runner)
	if !contains(ids, "late") || !contains(ids, "keep") || contains(ids, "gone") {
		t.Errorf("list = %v, want late and keep, not gone", ids)
	}
}

// Same race under load: one goroutine creates files and refreshes them, as the
// watcher does, while another reconciles continuously. No created file may
// ever be missing afterwards. (Deliberately no final reconcile: that would
// re-load a wrongly dropped file and mask the bug.)
func TestReconcile_ConcurrentCreatesAreNeverDropped(t *testing.T) {
	th := newTestHub(t, 1024)
	total := 3000
	if testing.Short() {
		total = 500
	}

	stop := make(chan struct{})
	var passes atomic.Int64
	var rwg sync.WaitGroup
	rwg.Add(1)
	go func() {
		defer rwg.Done()
		for {
			select {
			case <-stop:
				return
			default:
				th.store.reconcile()
				passes.Add(1)
			}
		}
	}()

	for i := 0; i < total; i++ {
		id := fmt.Sprintf("late-%04d", i)
		path := filepath.Join(th.jobsDir, id+".json")
		body := fmt.Sprintf(`{"id":%q,"state":"running","repo":"testrepo"}`, id)
		if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
		th.store.refresh(path)
	}
	close(stop)
	rwg.Wait()

	var missing []string
	for i := 0; i < total; i++ {
		id := fmt.Sprintf("late-%04d", i)
		if !th.store.exists(id) {
			missing = append(missing, id)
		}
	}
	if len(missing) > 0 {
		show := missing
		if len(show) > 5 {
			show = show[:5]
		}
		t.Errorf("%d of %d created jobs missing from the store after %d concurrent reconciles (first: %v)",
			len(missing), total, passes.Load(), show)
	}
}

// --- 11. Jobs directory missing or unreadable: never drop anything ---------

// threeJobHub returns a hub holding jobs a, b and c, all with files.
func threeJobHub(t *testing.T) *testHub {
	t.Helper()
	th := newTestHub(t, 1024)
	for _, id := range []string{"a", "b", "c"} {
		th.injectJob(t, id, nil)
	}
	return th
}

func assertAllThreePresent(t *testing.T, th *testHub, when string) {
	t.Helper()
	for _, id := range []string{"a", "b", "c"} {
		if !th.store.exists(id) {
			t.Errorf("%s: record %q was dropped", when, id)
		}
	}
}

// The real jobs directory vanishes (ENOENT on the directory itself): that is
// an outage, not evidence that every job was archived.
func TestReconcile_MissingJobsDirDropsNothing(t *testing.T) {
	th := threeJobHub(t)
	if err := os.RemoveAll(th.jobsDir); err != nil {
		t.Fatal(err)
	}

	th.store.reconcile()

	assertAllThreePresent(t, th, "reconcile with jobs dir removed")
}

func TestPruneMissing_MissingJobsDirDropsNothing(t *testing.T) {
	cases := []struct {
		name string
		run  func(t *testing.T, th *testHub)
	}{
		{"pruneMissing", func(t *testing.T, th *testHub) { th.store.pruneMissing() }},
		{"pruneMissingID", func(t *testing.T, th *testHub) {
			for _, id := range []string{"a", "b", "c"} {
				th.store.pruneMissingID(id)
			}
		}},
		{"queryList", func(t *testing.T, th *testHub) {
			if res := th.runner.queryList(listFilter{}); res.code != "" {
				t.Errorf("queryList failed: %s %s", res.code, res.msg)
			}
		}},
		{"queryGet", func(t *testing.T, th *testHub) {
			for _, id := range []string{"a", "b", "c"} {
				if res := th.runner.queryGet(id); res.code != "" {
					t.Errorf("queryGet(%s) = %q while only the jobs dir is missing", id, res.code)
				}
			}
		}},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			th := threeJobHub(t)
			if err := os.RemoveAll(th.jobsDir); err != nil {
				t.Fatal(err)
			}
			tc.run(t, th)
			assertAllThreePresent(t, th, tc.name+" with jobs dir removed")
		})
	}
}

// After the outage ends and the files are back, the store serves the same
// records, still tracks new files, and again drops genuinely archived ones.
func TestJobStore_RecoversWhenJobsDirReappears(t *testing.T) {
	th := threeJobHub(t)
	if err := os.RemoveAll(th.jobsDir); err != nil {
		t.Fatal(err)
	}
	th.store.reconcile()
	th.store.pruneMissing()
	_ = th.runner.queryList(listFilter{})

	if err := os.MkdirAll(th.jobsDir, 0o755); err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"a", "b", "c"} {
		writeJobFile(t, th.jobsDir, id+".json", id, "ready")
	}

	ids := listedIDs(t, th.runner)
	for _, id := range []string{"a", "b", "c"} {
		if !contains(ids, id) {
			t.Errorf("after recovery list = %v, missing %q", ids, id)
		}
		if res := th.runner.queryGet(id); res.code != "" {
			t.Errorf("after recovery queryGet(%s) = %q", id, res.code)
		}
	}

	writeJobFile(t, th.jobsDir, "d.json", "d", "ready")
	th.store.reconcile()
	if !th.store.exists("d") {
		t.Errorf("reconcile did not pick up a new file after recovery")
	}
	archiveJobFile(t, th.jobsDir, "b")
	if ids := listedIDs(t, th.runner); contains(ids, "b") {
		t.Errorf("after recovery list = %v, still returns archived b", ids)
	}
}

// chmod 000 on the jobs directory: listing and stat both fail with EACCES,
// which is not "file gone". Nothing may be dropped.
func TestJobStore_UnreadableJobsDirDropsNothing(t *testing.T) {
	if os.Getuid() == 0 {
		t.Skip("running as root: permission bits are not enforced")
	}
	th := threeJobHub(t)
	// Registered before the chmod so TempDir cleanup can always remove the dir.
	t.Cleanup(func() { _ = os.Chmod(th.jobsDir, 0o755) })
	if err := os.Chmod(th.jobsDir, 0o000); err != nil {
		t.Fatal(err)
	}
	if _, err := os.ReadDir(th.jobsDir); err == nil {
		t.Skip("chmod 000 did not make the jobs dir unreadable on this platform")
	}

	th.store.reconcile()
	assertAllThreePresent(t, th, "reconcile with unreadable jobs dir")

	th.store.pruneMissing()
	assertAllThreePresent(t, th, "pruneMissing with unreadable jobs dir")

	for _, id := range []string{"a", "b", "c"} {
		th.store.pruneMissingID(id)
	}
	assertAllThreePresent(t, th, "pruneMissingID with unreadable jobs dir")

	_ = th.runner.queryList(listFilter{})
	for _, id := range []string{"a", "b", "c"} {
		_ = th.runner.queryGet(id)
	}
	assertAllThreePresent(t, th, "queries with unreadable jobs dir")
}

// --- 9. Benchmark ----------------------------------------------------------

func BenchmarkQueryList300Jobs(b *testing.B) {
	tmp := b.TempDir()
	jobsDir := filepath.Join(tmp, "jobs")
	if err := os.MkdirAll(jobsDir, 0o755); err != nil {
		b.Fatal(err)
	}
	store := newJobStore(jobsDir)
	for i := 0; i < 300; i++ {
		id := fmt.Sprintf("job-%03d", i)
		writeJobFile(b, jobsDir, id+".json", id, "running")
	}
	store.load()
	runner := &commandRunner{store: store, cliPath: "false", eventsDir: filepath.Join(tmp, "events")}

	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		res := runner.queryList(listFilter{})
		if res.code != "" {
			b.Fatalf("queryList: %s", res.code)
		}
	}
}

// A modify event lost for a known file: reconcile re-reads it when its
// mtime/size changed.
func TestReconcile_RefreshesChangedContentOfKnownFile(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "j", map[string]any{"state": "ready"})
	path := writeJobFile(t, th.jobsDir, "j.json", "j", "running") // changed, no event
	future := time.Now().Add(time.Minute)
	if err := os.Chtimes(path, future, future); err != nil {
		t.Fatal(err)
	}

	th.store.reconcile()

	res := th.runner.queryList(listFilter{state: "running"})
	jobs, _ := res.payload["jobs"].([]json.RawMessage)
	if len(jobs) != 1 {
		t.Errorf("state=running list has %d jobs after reconcile, want 1", len(jobs))
	}
}
