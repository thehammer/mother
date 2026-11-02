package main

// quota_watch_test.go — the quota block stays fresh for connected clients, and
// the CLI shell-out behind it cannot hang a subscribe.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestQuotaWatcher_publishesAQuotaEventWhenTheBlockChanges(t *testing.T) {
	th, rec, fx := newQuotaHub(t, "")
	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello
	subscribeSimple(t, conn, "main", []string{"all"}, []string{CatQuota})

	qw := newQuotaWatcher(th.runner, th.hub.ingest, time.Second)
	qw.prime()

	// Unchanged block: nothing is published.
	qw.tick()

	// The operator changes the switch through the CLI.
	var blk map[string]any
	_ = json.Unmarshal(fx.QuotaBlock, &blk)
	blk["gate"] = "off"
	blk["until"] = nil
	nb, _ := json.Marshal(blk)
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

	// A further identical tick publishes nothing (the next read would block).
	qw.tick()
	if m, err := readNext(t, conn); err == nil {
		t.Fatalf("unexpected duplicate event: %+v", m)
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
