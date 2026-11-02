package main

// quota_watch_test.go — the quota block stays fresh for connected clients, and
// the CLI shell-out behind it cannot hang a subscribe.

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"testing"
	"time"
)

// realCLIEnv builds an isolated MOTHER_ROOT for the real `mother` CLI and points
// the runner at it. Returns the env the CLI sees, the Bishop feed path and the
// path of the CLI. The surrounding process's job/live-root variables are scrubbed
// so a test run inside a Mother worker can neither be refused nor touch live state.
func realCLIEnv(t *testing.T, th *testHub) (env []string, feed string, cli string) {
	t.Helper()
	cli, err := filepath.Abs("../bin/mother")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(cli); err != nil {
		t.Fatalf("real CLI not found: %v", err)
	}
	for _, k := range []string{"MOTHER_JOB_ID", "MOTHER_LIVE_ROOT", "MOTHER_ROOT"} {
		t.Setenv(k, "") // registers the restore
		os.Unsetenv(k)
	}
	base := t.TempDir()
	root := filepath.Join(base, "root")
	for _, d := range []string{"jobs", "events", "logs", "drafts", "cursors", "runner", "archive", "teardown-pending", "home"} {
		if err := os.MkdirAll(filepath.Join(root, d), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	feed = filepath.Join(base, "budget-posture.json")
	env = []string{
		"MOTHER_ROOT=" + root,
		"_MOTHER_TEST_ROOT=" + root,
		"MOTHER_TEST_ROOT=1",
		"HOME=" + filepath.Join(root, "home"),
		"MOTHER_BISHOP_POSTURE_FILE=" + feed,
		"MOTHER_RATE_LIMIT_CACHE=" + filepath.Join(base, "rate-limits.json"),
		"MOTHER_NOTIFY_TRANSPORT=none",
	}
	th.runner.cliPath = cli
	th.runner.extraEnv = env
	th.runner.quotaTimeout = 20 * time.Second
	return env, feed, cli
}

func runRealCLI(t *testing.T, cli string, env []string, args ...string) {
	t.Helper()
	cmd := exec.Command(cli, args...)
	cmd.Env = append(os.Environ(), env...)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("mother %v: %v\n%s", args, err, out)
	}
}

// feedResets are fixed for the whole test so the only thing that varies between
// reads of an unchanged feed is its age.
var feedResets = [2]int64{time.Now().Add(time.Hour).Unix(), time.Now().Add(24 * time.Hour).Unix()}

// writeFeed writes a Bishop-shaped file (same content every time) whose mtime is ageS seconds old.
func writeFeed(t *testing.T, path string, ageS int) {
	t.Helper()
	body := fmt.Sprintf(`{"posture":"Cruise","stale_input":false,"five_hour":{"used_pct":23,"resets_at":%d},"seven_day":{"used_pct":40,"resets_at":%d}}`,
		feedResets[0], feedResets[1])
	if err := os.WriteFile(path, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	mt := time.Now().Add(-time.Duration(ageS) * time.Second)
	if err := os.Chtimes(path, mt, mt); err != nil {
		t.Fatal(err)
	}
}

func TestQuotaWatcher_onlyARealChangeOfTheBlockIsPublishedNotTheFeedGettingOlder(t *testing.T) {
	th := newTestHub(t, 1024)
	env, feed, cli := realCLIEnv(t, th)
	writeFeed(t, feed, 30)

	var events []rawEvent
	qw := newQuotaWatcher(th.runner, func(e rawEvent) { events = append(events, e) }, time.Second)
	qw.prime()
	if qw.last == nil {
		t.Fatal("prime could not read the quota block from the real CLI")
	}

	// The feed is re-written every minute or so by Bishop: feed_age_s moves on every
	// read, but nothing the operator cares about changed.
	for i, age := range []int{44, 91, 140, 205} {
		writeFeed(t, feed, age)
		qw.tick()
		if len(events) != 0 {
			t.Fatalf("tick %d (feed age %ds): %d quota events for a block that only aged: %s", i+1, age, len(events), events[0].detail)
		}
	}

	// The operator flips the switch through the real CLI: exactly one event.
	runRealCLI(t, cli, env, "quota", "off")
	writeFeed(t, feed, 500)
	qw.tick()
	if len(events) != 1 {
		t.Fatalf("after `mother quota off`: %d events, want exactly 1", len(events))
	}
	ev := events[0]
	if ev.category != CatQuota || ev.kind != "quota" {
		t.Errorf("event category=%q kind=%q, want %q/quota", ev.category, ev.kind, CatQuota)
	}
	var d struct {
		Quota struct {
			Gate     string   `json:"gate"`
			FeedAgeS *float64 `json:"feed_age_s"`
		} `json:"quota"`
	}
	if err := json.Unmarshal(ev.detail, &d); err != nil {
		t.Fatalf("decode event detail: %v (%s)", err, ev.detail)
	}
	if d.Quota.Gate != "off" {
		t.Errorf("event gate = %q, want off", d.Quota.Gate)
	}
	// The emitted block still carries the CURRENT feed age (the comparison ignores it, the payload does not).
	if d.Quota.FeedAgeS == nil || *d.Quota.FeedAgeS < 495 || *d.Quota.FeedAgeS > 540 {
		t.Errorf("event feed_age_s = %v, want about 500 (the current age)", d.Quota.FeedAgeS)
	}

	// Aging again publishes nothing more.
	for _, age := range []int{510, 560, 600} {
		writeFeed(t, feed, age)
		qw.tick()
	}
	if len(events) != 1 {
		t.Fatalf("after unchanged ticks: %d events, want still 1", len(events))
	}

	// Turning it back on is one more.
	runRealCLI(t, cli, env, "quota", "on")
	writeFeed(t, feed, 650)
	qw.tick()
	if len(events) != 2 {
		t.Fatalf("after `mother quota on`: %d events, want exactly 2 in total", len(events))
	}
	_ = json.Unmarshal(events[1].detail, &d)
	if d.Quota.Gate != "on" {
		t.Errorf("second event gate = %q, want on", d.Quota.Gate)
	}
}

func TestQuotaWatcher_aRealChangeReachesSubscribersAsAQuotaEvent(t *testing.T) {
	th, rec, fx := newQuotaHub(t, "")
	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello
	subscribeSimple(t, conn, "main", []string{"all"}, []string{CatQuota})

	qw := newQuotaWatcher(th.runner, th.hub.ingest, time.Second)
	qw.prime()
	qw.tick() // unchanged: nothing is published

	nb := quotaBlockWithGate(t, fx, "off")
	if err := os.WriteFile(filepath.Join(rec, "block.json"), nb, 0o644); err != nil {
		t.Fatal(err)
	}
	qw.tick()

	ev, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("no quota event after the block changed: %v", err)
	}
	if ev.Dir != DirEvent || ev.T != "quota" {
		t.Fatalf("got dir=%s t=%s, want event quota", ev.Dir, ev.T)
	}
	var d map[string]json.RawMessage
	_ = json.Unmarshal(ev.Data, &d)
	if !jsonEqual(t, d["quota"], nb) {
		t.Errorf("event quota = %s, want %s", d["quota"], nb)
	}
}

func TestQuotaBlock_aHungCLIIsCutOffAndSubscribeStillCompletes(t *testing.T) {
	th := newTestHub(t, 1024)
	cli := filepath.Join(t.TempDir(), "slow-mother")
	if err := os.WriteFile(cli, []byte("#!/bin/sh\nexec sleep 30\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	th.runner.cliPath = cli
	th.runner.quotaTimeout = 300 * time.Millisecond

	start := time.Now()
	conn := th.connect(t)
	_, _ = readNext(t, conn)
	subscribeSimple(t, conn, "main", []string{"all"}, []string{CatState})
	if el := time.Since(start); el > 2500*time.Millisecond {
		t.Fatalf("subscribe took %v with a hung CLI", el)
	}
}
