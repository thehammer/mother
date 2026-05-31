package main

// eventsource.go — tails $MOTHER_ROOT/events/<id>.jsonl and turns appended
// lines into classified protocol events (B5).
//
// The bash side keeps calling _append_event exactly as today; the broker is
// a pure consumer of a log bash already writes (B1 — no second writer). Each
// job's events come from a single append-only file written under mkdir-lock
// with monotonic timestamps, so reading each file sequentially preserves
// per-job ordering. Cross-job global ordering is deliberately NOT promised.

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/fsnotify/fsnotify"
)

// rawEvent is a single classified event, before a per-connection id is
// assigned. The detail is the original event's `detail` object, passed
// through verbatim.
type rawEvent struct {
	category string
	jobID    string
	kind     string
	ts       string
	detail   json.RawMessage
}

// classify maps an on-disk event `kind` to a protocol category (B5).
//   - the seven state names           → state
//   - awaiting_input                  → await
//   - pause_requested / auto_resumed / paused_for_quota → quota
//   - everything else                 → activity
//
// The "everything else" bucket includes (non-exhaustive):
//   escalated, resumed, retried, cancel_requested, adherence_*,
//   and the pipeline events emitted by W4/W5:
//     pipeline_review_started, pipeline_shipped, pipeline_blocked,
//     pipeline_cap_hit, pipeline_cycle_continued, pipeline_phase_advance,
//     pipeline_error,
//     phase_started, phase_completed,          (W5 additive)
//     review_cycle_started, review_cycle_completed.  (W5 additive)
//
// Pipeline-progress events are classified as activity, not state.  The job's
// `state` field already drives CatState; these events are sub-state signals
// that clients use for progress display, not for coarse job-state tracking.
// Adding explicit CatState cases for them is reserved for a future enhancement
// where a client needs to distinguish them from generic activity.
//
// current_activity and output are NOT sourced from the logs: current_activity
// is derived from the transcript (activity.go) and output ships in W2.
func classify(kind string) string {
	switch kind {
	case "queued", "ready", "running", "awaiting", "succeeded", "failed", "cancelled":
		return CatState
	case "awaiting_input":
		return CatAwait
	case "pause_requested", "auto_resumed", "paused_for_quota":
		return CatQuota
	default:
		return CatActivity
	}
}

// eventLine is the on-disk schema of one events/<id>.jsonl line.
type eventLine struct {
	Ts     string          `json:"ts"`
	Kind   string          `json:"kind"`
	Detail json.RawMessage `json:"detail"`
}

type eventSource struct {
	dir  string
	emit func(rawEvent) // called in file order for each parsed line

	mu      sync.Mutex
	offsets map[string]int64 // per-file byte offset of the last consumed newline
}

func newEventSource(eventsDir string, emit func(rawEvent)) *eventSource {
	return &eventSource{dir: eventsDir, emit: emit, offsets: map[string]int64{}}
}

// prime reads every existing events file in full, feeding each line through
// emit so the event-derived overlay reflects current state before any client
// connects, then parks each file's offset at EOF for live tailing.
func (es *eventSource) prime() {
	entries, err := os.ReadDir(es.dir)
	if err != nil {
		return
	}
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		es.drain(filepath.Join(es.dir, e.Name()))
	}
}

// drain reads any bytes appended since the last consumed newline and emits a
// rawEvent for each complete line. A trailing partial line (write not yet
// terminated by a newline) is left unconsumed and re-read next time.
func (es *eventSource) drain(path string) {
	if !strings.HasSuffix(path, ".jsonl") {
		return
	}
	id := strings.TrimSuffix(filepath.Base(path), ".jsonl")

	es.mu.Lock()
	off := es.offsets[path]
	es.mu.Unlock()

	f, err := os.Open(path)
	if err != nil {
		return
	}
	defer f.Close()

	if _, err := f.Seek(off, 0); err != nil {
		return
	}
	rest, err := io.ReadAll(f)
	if err != nil || len(rest) == 0 {
		return
	}
	lastNL := bytes.LastIndexByte(rest, '\n')
	if lastNL < 0 {
		// No complete line yet; leave the offset where it is.
		return
	}
	complete := rest[:lastNL] // excludes the trailing newline
	for _, line := range bytes.Split(complete, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		var el eventLine
		if err := json.Unmarshal(line, &el); err != nil {
			continue
		}
		detail := el.Detail
		if len(detail) == 0 {
			detail = json.RawMessage("{}")
		}
		es.emit(rawEvent{
			category: classify(el.Kind),
			jobID:    id,
			kind:     el.Kind,
			ts:       el.Ts,
			detail:   detail,
		})
	}

	es.mu.Lock()
	es.offsets[path] = off + int64(lastNL) + 1 // +1 to step past the newline
	es.mu.Unlock()
}

// watch tails the events directory for appends until done is closed.
func (es *eventSource) watch(done <-chan struct{}) {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return
	}
	defer w.Close()
	if err := w.Add(es.dir); err != nil {
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
			if ev.Op&(fsnotify.Write|fsnotify.Create) != 0 {
				es.drain(ev.Name)
			}
		case _, ok := <-w.Errors:
			if !ok {
				return
			}
		}
	}
}
