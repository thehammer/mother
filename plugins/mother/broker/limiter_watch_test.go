package main

// limiter_watch_test.go — the limiter block in the snapshot, the hello category, and the
// watcher that publishes `limiter` events only when the block's content changes.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

const limiterBlockT0 = `{"v":1,"mode":"observe","age_s":4,"stale":false,"fault":null,` +
	`"concurrency":{"ceiling":5,"allowed":3,"effective":4,"state":"backoff","detail":"cut 6m ago after 429; +1 in 9m"},` +
	`"last_distress":{"at":"2026-11-06T22:10:03Z","ago_s":360,"kind":"api_retry","status":429,"job_id":"j1"},` +
	`"distress_24h":1,"waiting":[{"id":"j2","code":"next","reason":"starts in 2m","source":"dispatch","advisory":false,"since":"2026-11-06T22:12:00Z"}]}`

// newLimiterHub installs a fake `mother` CLI whose `limiter status --json` prints <rec>/limiter.json
// (absent file = exit 1) and whose `quota status --json` fails.
func newLimiterHub(t *testing.T, initial string) (*testHub, string) {
	t.Helper()
	th := newTestHub(t, 1024)
	rec := t.TempDir()
	block := filepath.Join(rec, "limiter.json")
	if initial != "" {
		if err := os.WriteFile(block, []byte(initial), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	script := "#!/bin/sh\nif [ \"$1\" = limiter ] && [ \"$2\" = status ] && [ -f '" + block + "' ]; then cat '" + block + "'; exit 0; fi\nexit 1\n"
	cli := filepath.Join(rec, "fake-mother")
	if err := os.WriteFile(cli, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	th.runner.cliPath = cli
	return th, block
}

func setLimiterBlock(t *testing.T, path, body string) {
	t.Helper()
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
}

func TestLimiterSnapshot_carriesTheBlockWhenTheCLISucceeds(t *testing.T) {
	th, _ := newLimiterHub(t, limiterBlockT0)
	conn := th.connect(t)
	_, _ = readNext(t, conn)
	snap := subscribeSimple(t, conn, "main", []string{"all"}, []string{CatState})
	var d map[string]json.RawMessage
	_ = json.Unmarshal(snap.Data, &d)
	if d["limiter"] == nil {
		t.Fatalf("snapshot has no limiter key: %s", snap.Data)
	}
	if !jsonEqual(t, d["limiter"], json.RawMessage(limiterBlockT0)) {
		t.Errorf("snapshot limiter = %s, want %s", d["limiter"], limiterBlockT0)
	}
}

func TestLimiterSnapshot_omitsTheBlockWhenTheCLIFails(t *testing.T) {
	th, _ := newLimiterHub(t, "")
	conn := th.connect(t)
	_, _ = readNext(t, conn)
	snap := subscribeSimple(t, conn, "main", []string{"all"}, []string{CatState})
	var d map[string]json.RawMessage
	_ = json.Unmarshal(snap.Data, &d)
	if _, has := d["limiter"]; has {
		t.Errorf("snapshot has a limiter key although the CLI failed: %s", d["limiter"])
	}
}

func TestLimiterHello_advertisesTheCategory(t *testing.T) {
	th := newTestHub(t, 1024)
	conn := th.connect(t)
	hello, err := readNext(t, conn)
	if err != nil {
		t.Fatal(err)
	}
	data := mustDecodeData(t, hello)
	found := false
	for _, c := range data["capabilities"].([]any) {
		if c == CatLimiter {
			found = true
		}
	}
	if !found {
		t.Errorf("hello capabilities missing %q: %v", CatLimiter, data["capabilities"])
	}
}

func TestLimiterWatcher_publishesOneEventPerContentChangeAndNoneWhileOnlyTimeTicks(t *testing.T) {
	th, block := newLimiterHub(t, limiterBlockT0)
	var events []rawEvent
	lw := newLimiterWatcher(th.runner, func(e rawEvent) { events = append(events, e) }, time.Second)
	lw.prime()
	if lw.last == nil {
		t.Fatal("prime could not read the limiter block")
	}

	// Only now-derived fields move: age_s, last_distress.ago_s, concurrency.detail, a waiting reason countdown.
	ticking := `{"v":1,"mode":"observe","age_s":9,"stale":false,"fault":null,` +
		`"concurrency":{"ceiling":5,"allowed":3,"effective":4,"state":"backoff","detail":"cut 7m ago after 429; +1 in 8m"},` +
		`"last_distress":{"at":"2026-11-06T22:10:03Z","ago_s":420,"kind":"api_retry","status":429,"job_id":"j1"},` +
		`"distress_24h":1,"waiting":[{"id":"j2","code":"next","reason":"starts in 1m","source":"dispatch","advisory":false,"since":"2026-11-06T22:12:00Z"}]}`
	for i := 0; i < 3; i++ {
		setLimiterBlock(t, block, ticking)
		lw.tick()
	}
	if len(events) != 0 {
		t.Fatalf("%d events while only age_s/ago_s ticked, want 0", len(events))
	}

	// A real change (effective 4 -> 5): exactly one event, carrying the current block.
	changed := ticking
	changed = replaceOnce(changed, `"effective":4`, `"effective":5`)
	setLimiterBlock(t, block, changed)
	lw.tick()
	lw.tick()
	if len(events) != 1 {
		t.Fatalf("%d events after one real change, want 1", len(events))
	}
	if events[0].category != CatLimiter || events[0].kind != "limiter" {
		t.Errorf("event category=%q kind=%q, want limiter/limiter", events[0].category, events[0].kind)
	}
	var d map[string]json.RawMessage
	_ = json.Unmarshal(events[0].detail, &d)
	if !jsonEqual(t, d["limiter"], json.RawMessage(changed)) {
		t.Errorf("event limiter = %s, want %s", d["limiter"], changed)
	}

	// A CLI failure publishes nothing and keeps the baseline.
	if err := os.Remove(block); err != nil {
		t.Fatal(err)
	}
	lw.tick()
	setLimiterBlock(t, block, changed)
	lw.tick()
	if len(events) != 1 {
		t.Fatalf("%d events after a CLI blip, want still 1", len(events))
	}
}

func TestLimiterWatcher_onlyLimiterSubscribersReceiveTheEvent(t *testing.T) {
	th, block := newLimiterHub(t, limiterBlockT0)
	with, without := th.connect(t), th.connect(t)
	_, _ = readNext(t, with)
	_, _ = readNext(t, without)
	subscribeSimple(t, with, "a", []string{"all"}, []string{CatLimiter})
	subscribeSimple(t, without, "b", []string{"all"}, []string{CatQuota})

	lw := newLimiterWatcher(th.runner, th.hub.ingest, time.Second)
	lw.prime()
	setLimiterBlock(t, block, replaceOnce(limiterBlockT0, `"allowed":3`, `"allowed":2`))
	lw.tick()

	ev, err := readNext(t, with)
	if err != nil || ev.T != "limiter" {
		t.Fatalf("limiter subscriber got %v (err %v), want a limiter event", ev.T, err)
	}
	done := make(chan Message, 1)
	go func() {
		m, err := readNext(t, without)
		if err == nil {
			done <- m
		}
	}()
	select {
	case m := <-done:
		t.Errorf("subscriber without the limiter category received %s", m.T)
	case <-time.After(400 * time.Millisecond):
	}
}

func replaceOnce(s, old, repl string) string {
	for i := 0; i+len(old) <= len(s); i++ {
		if s[i:i+len(old)] == old {
			return s[:i] + repl + s[i+len(old):]
		}
	}
	return s
}
