package main

// peerguard_quota_test.go — the quota gate's strict worker check.
//
// `answer` keeps its fail-open peer check (the CLI guard still covers the path
// that mutates state). `quota-gate` fails CLOSED: a peer that is a worker, whose
// pid cannot be read, or whose ancestry cannot be looked up is refused with
// unauthorized, and the switch is left untouched.
//
// In these tests the hub's connections are net.Pipe pairs, which have no peer
// credentials: that is exactly the "pid cannot be read" situation.

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"testing"
)

func TestQuotaGate_deniedWhenThePeerPidCannotBeReadAndTheSwitchIsUntouched(t *testing.T) {
	th, rec, _ := newQuotaHub(t, "")
	th.hub.guard = newProcessGuard() // real guard; net.Pipe has no peer pid
	ack := quotaGateAck(t, th, "g1", map[string]any{"state": "off", "origin": "nostromo"})
	data := mustDecodeData(t, ack)
	if data["ok"] != false {
		t.Fatalf("ack = %v, want ok:false for an unidentifiable peer", data)
	}
	if code := ackErrCode(t, data); code != ErrUnauthorized {
		t.Errorf("error.code = %q, want %q", code, ErrUnauthorized)
	}
	if calls := quotaCalls(t, rec); len(calls) != 0 {
		t.Errorf("an unidentifiable peer changed the gate: %q", calls)
	}
}

func TestQuotaGate_deniedForAGuardThatReportsAnUnknownPeer(t *testing.T) {
	th, rec, _ := newQuotaHub(t, "")
	th.hub.guard = fakeGuard{unknown: true}
	ack := quotaGateAck(t, th, "g2", map[string]any{"state": "on", "origin": "nostromo"})
	if code := ackErrCode(t, mustDecodeData(t, ack)); code != ErrUnauthorized {
		t.Errorf("error.code = %q, want %q", code, ErrUnauthorized)
	}
	if calls := quotaCalls(t, rec); len(calls) != 0 {
		t.Errorf("the gate was changed: %q", calls)
	}
}

func TestAnswer_stillAllowedWhenThePeerPidCannotBeRead(t *testing.T) {
	th, rec := newHubWithRecordingCLI(t, "", 0)
	th.hub.guard = newProcessGuard() // same unreadable-pid situation as above
	data := answerAck(t, th, map[string]any{"job": "j", "option": "cancel"})
	if data["ok"] != true {
		t.Fatalf("answer with an unreadable peer pid = %v, want ok:true (fail-open)", data)
	}
	if got := recordedArgs(t, rec); len(got) == 0 {
		t.Error("CLI was not invoked for the answer")
	}
}

func TestAnswer_allowedForAGuardThatReportsAnUnknownPeer(t *testing.T) {
	th, _ := newHubWithRecordingCLI(t, "", 0)
	th.hub.guard = fakeGuard{unknown: true}
	if data := answerAck(t, th, map[string]any{"job": "j", "option": "cancel"}); data["ok"] != true {
		t.Fatalf("answer = %v, want ok:true", data)
	}
}

func TestQuotaGate_aNilGuardAllowsBothQuotaGateAndAnswer(t *testing.T) {
	// MOTHER_BROKER_ANSWER_GUARD=0 sets the guard to nil.
	th, rec, _ := newQuotaHub(t, "")
	th.hub.guard = nil
	ack := quotaGateAck(t, th, "g3", map[string]any{"state": "off", "origin": "nostromo"})
	if mustDecodeData(t, ack)["ok"] != true {
		t.Errorf("quota-gate with a nil guard = %s, want ok:true", ack.Data)
	}
	if len(quotaCalls(t, rec)) != 1 {
		t.Errorf("CLI gate calls = %q, want 1", quotaCalls(t, rec))
	}

	th2, _ := newHubWithRecordingCLI(t, "", 0)
	th2.hub.guard = nil
	if data := answerAck(t, th2, map[string]any{"job": "j", "option": "cancel"}); data["ok"] != true {
		t.Errorf("answer with a nil guard = %v, want ok:true", data)
	}
}

// strictGuard is the quota-gate check every production guard must offer.
type strictGuard interface {
	fromWorkerOrUnknown(conn *clientConn) bool
}

// unixPeer returns the accepted end of a real unix-socket connection to this
// process, so the peer pid is readable on platforms that support it.
func unixPeer(t *testing.T) *clientConn {
	t.Helper()
	dir, err := os.MkdirTemp("/tmp", "rq")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { os.RemoveAll(dir) })
	sock := filepath.Join(dir, "s")
	ln, err := net.Listen("unix", sock)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	cli, err := net.Dial("unix", sock)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { cli.Close() })
	srv, err := ln.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	t.Cleanup(func() { srv.Close() })
	return newClientConn(srv)
}

func TestProcessGuard_strictCheckDeniesWhenTheAncestryLookupFails(t *testing.T) {
	conn := unixPeer(t)
	g := processGuard{lookup: func(pid int) (int, string, error) { return 0, "", errors.New("ps failed") }}
	sg, ok := any(g).(strictGuard)
	if !ok {
		t.Fatal("processGuard has no fromWorkerOrUnknown(conn) bool")
	}
	if !sg.fromWorkerOrUnknown(conn) {
		t.Error("fromWorkerOrUnknown = false, want true when the ancestry lookup errors (fail closed)")
	}
	// `answer` keeps the fail-open check: the same lookup failure does not make the peer a worker.
	if runtime.GOOS == "darwin" && g.fromWorker(conn) {
		t.Error("fromWorker = true on a lookup error, want false (answer stays fail-open)")
	}
}

func TestProcessGuard_strictCheckAllowsAnIdentifiedNonWorkerPeer(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("peer pid is only readable on darwin; elsewhere the strict check always denies")
	}
	conn := unixPeer(t)
	g := processGuard{lookup: func(pid int) (int, string, error) { return 1, "/usr/bin/some-operator-tool", nil }}
	sg, ok := any(g).(strictGuard)
	if !ok {
		t.Fatal("processGuard has no fromWorkerOrUnknown(conn) bool")
	}
	if sg.fromWorkerOrUnknown(conn) {
		t.Error("fromWorkerOrUnknown = true for an identified peer with no mother-run-job ancestor, want false")
	}
}

func TestProcessGuard_strictCheckDeniesAWorkerPeer(t *testing.T) {
	conn := unixPeer(t)
	g := processGuard{lookup: func(pid int) (int, string, error) { return 1, "bash /x/bin/mother-run-job job-1", nil }}
	sg, ok := any(g).(strictGuard)
	if !ok {
		t.Fatal("processGuard has no fromWorkerOrUnknown(conn) bool")
	}
	if !sg.fromWorkerOrUnknown(conn) {
		t.Error("fromWorkerOrUnknown = false for a peer under mother-run-job, want true")
	}
}
