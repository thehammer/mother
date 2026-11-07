package main

import (
	"bytes"
	"encoding/json"
	"time"
)

// blockWatcher keeps connected clients' copy of a CLI-built block fresh. The
// block is sent on subscribe, but the CLI, the daemon and time itself change
// it with no broker involvement, so the watcher polls `fetch` every interval
// and publishes one event (category/kind) only when the block's content
// changes. The `quota` and `limiter` blocks both use it.
type blockWatcher struct {
	fetch    func() json.RawMessage // nil when the CLI cannot produce the block
	emit     func(rawEvent)
	interval time.Duration
	category string
	kind     string // also the key the block sits under in the event detail
	compare  func(json.RawMessage) json.RawMessage
	last     json.RawMessage // last block seen, minus its ticking fields; nil until primed
}

// quotaWatcher watches `mother quota status --json`.
type quotaWatcher = blockWatcher

func newQuotaWatcher(runner *commandRunner, emit func(rawEvent), interval time.Duration) *quotaWatcher {
	return &blockWatcher{fetch: runner.quotaBlock, emit: emit, interval: interval,
		category: CatQuota, kind: "quota", compare: comparable}
}

// newLimiterWatcher watches `mother limiter status --json`.
func newLimiterWatcher(runner *commandRunner, emit func(rawEvent), interval time.Duration) *blockWatcher {
	return &blockWatcher{fetch: runner.limiterBlock, emit: emit, interval: interval,
		category: CatLimiter, kind: "limiter", compare: comparableLimiter}
}

// prime records the current block as the baseline without publishing it
// (subscribers already get it in their snapshot).
func (w *blockWatcher) prime() {
	if b := w.fetch(); b != nil {
		w.last = w.compare(b)
	}
}

// run polls until done is closed.
func (w *blockWatcher) run(done <-chan struct{}) {
	t := time.NewTicker(w.interval)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
			w.tick()
		}
	}
}

// tick publishes the block if it differs from the last one seen. A CLI
// failure leaves the baseline alone (no event, no flapping).
func (w *blockWatcher) tick() {
	b := w.fetch()
	if b == nil {
		return
	}
	key := w.compare(b)
	b = compactJSON(b)
	if w.last != nil && bytes.Equal(key, w.last) {
		return
	}
	first := w.last == nil
	w.last = key
	if first {
		return
	}
	detail, _ := json.Marshal(map[string]json.RawMessage{w.kind: b})
	w.emit(rawEvent{category: w.category, kind: w.kind, detail: detail})
}

func compactJSON(b json.RawMessage) json.RawMessage {
	var buf bytes.Buffer
	if err := json.Compact(&buf, b); err != nil {
		return b
	}
	return buf.Bytes()
}

// comparable is the quota block with `feed_age_s` removed: the age grows with
// every poll, so comparing it would publish an event each interval. Everything
// that matters to a client (gate, source, stale, windows) is still compared;
// the event itself carries the current block, age included.
func comparable(b json.RawMessage) json.RawMessage {
	var m map[string]json.RawMessage
	if err := json.Unmarshal(b, &m); err != nil {
		return compactJSON(b)
	}
	delete(m, "feed_age_s")
	out, err := json.Marshal(m) // map keys marshal sorted: stable
	if err != nil {
		return compactJSON(b)
	}
	return out
}

// comparableLimiter is the limiter block with everything derived from "now"
// removed: `age_s`, `last_distress.ago_s`, the human `concurrency.detail`
// ("cut 6m ago ...") and each waiting job's `reason` (it can carry a countdown).
// State, codes, counts and the numbers themselves are still compared.
func comparableLimiter(b json.RawMessage) json.RawMessage {
	var m map[string]any
	if err := json.Unmarshal(b, &m); err != nil {
		return compactJSON(b)
	}
	delete(m, "age_s")
	if ld, ok := m["last_distress"].(map[string]any); ok {
		delete(ld, "ago_s")
	}
	if c, ok := m["concurrency"].(map[string]any); ok {
		delete(c, "detail")
	}
	if ws, ok := m["waiting"].([]any); ok {
		for _, w := range ws {
			if wm, ok := w.(map[string]any); ok {
				delete(wm, "reason")
			}
		}
	}
	out, err := json.Marshal(m)
	if err != nil {
		return compactJSON(b)
	}
	return out
}
