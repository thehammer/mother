package main

import (
	"bytes"
	"encoding/json"
	"time"
)

// quotaWatcher keeps connected clients' quota block fresh. The block is sent
// on subscribe and in the quota-gate ack, but the CLI, the automatic
// off_until_reset expiry and the feed going stale all change it with no
// broker involvement, so it polls `mother quota status --json` every interval
// and publishes a `quota` event only when the block's content changes.
type quotaWatcher struct {
	runner   *commandRunner
	emit     func(rawEvent)
	interval time.Duration
	last     json.RawMessage // last block seen, minus the ticking age; nil until primed
}

func newQuotaWatcher(runner *commandRunner, emit func(rawEvent), interval time.Duration) *quotaWatcher {
	return &quotaWatcher{runner: runner, emit: emit, interval: interval}
}

// prime records the current block as the baseline without publishing it
// (subscribers already get it in their snapshot).
func (q *quotaWatcher) prime() {
	if b := q.runner.quotaBlock(); b != nil {
		q.last = comparable(b)
	}
}

// run polls until done is closed.
func (q *quotaWatcher) run(done <-chan struct{}) {
	t := time.NewTicker(q.interval)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
			q.tick()
		}
	}
}

// tick publishes the block if it differs from the last one seen. A CLI
// failure leaves the baseline alone (no event, no flapping).
func (q *quotaWatcher) tick() {
	b := q.runner.quotaBlock()
	if b == nil {
		return
	}
	key := comparable(b)
	b = compactJSON(b)
	if q.last != nil && bytes.Equal(key, q.last) {
		return
	}
	first := q.last == nil
	q.last = key
	if first {
		return
	}
	detail, _ := json.Marshal(map[string]json.RawMessage{"quota": b})
	q.emit(rawEvent{category: CatQuota, kind: "quota", detail: detail})
}

func compactJSON(b json.RawMessage) json.RawMessage {
	var buf bytes.Buffer
	if err := json.Compact(&buf, b); err != nil {
		return b
	}
	return buf.Bytes()
}

// comparable is the block with `feed_age_s` removed: the age grows with every
// poll, so comparing it would publish an event each interval. Everything that
// matters to a client (gate, source, stale, windows) is still compared; the
// event itself carries the current block, age included.
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
