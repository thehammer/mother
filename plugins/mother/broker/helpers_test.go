package main

// helpers_test.go — shared test infrastructure for broker unit tests.
//
// Provides:
//   - newTestHub: build an in-memory hub backed by a temp jobStore and a stub commandRunner
//   - connectClient: open a net.Pipe(), serve one end, wrap the other as *clientConn
//   - readNext: read from a clientConn, skipping ping events, with a deadline
//   - injectJob: write a minimal job JSON into a jobStore from a map
//   - mustDecodeData: unmarshal a Message's Data field into map[string]any
//   - pollCondition: retry a bool function up to a deadline (avoids fixed sleeps)

import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"testing"
	"time"
)

// testHub groups all pieces needed for an in-process test.
type testHub struct {
	hub       *hub
	store     *jobStore
	runner    *commandRunner
	jobsDir   string
	eventsDir string
	tmpRoot   string
}

// newTestHub creates an isolated hub + store in a temp dir.
// clientBuf defaults to 1024 (overridden by caller for backpressure tests).
func newTestHub(t *testing.T, clientBuf int) *testHub {
	t.Helper()
	tmp := t.TempDir()
	jobsDir := filepath.Join(tmp, "jobs")
	eventsDir := filepath.Join(tmp, "events")
	if err := os.MkdirAll(jobsDir, 0o755); err != nil {
		t.Fatalf("mkdir jobs: %v", err)
	}
	if err := os.MkdirAll(eventsDir, 0o755); err != nil {
		t.Fatalf("mkdir events: %v", err)
	}
	store := newJobStore(jobsDir)
	runner := &commandRunner{store: store, cliPath: "false", eventsDir: eventsDir}
	h := newHub(store, runner, 60, clientBuf)
	return &testHub{hub: h, store: store, runner: runner, jobsDir: jobsDir, eventsDir: eventsDir, tmpRoot: tmp}
}

// connect opens a net.Pipe(), serves one end on th.hub, and returns a
// *clientConn wrapping the client end. The caller owns reading from it.
func (th *testHub) connect(t *testing.T) *clientConn {
	t.Helper()
	srv, cli := net.Pipe()
	th.hub.serve(newClientConn(srv))
	t.Cleanup(func() { cli.Close() })
	return newClientConn(cli)
}

// readNext reads the next non-ping message from conn, with a 3-second deadline.
// Returns an error if timed out or connection closed.
func readNext(t *testing.T, conn *clientConn) (Message, error) {
	t.Helper()
	type result struct {
		m   Message
		err error
	}
	ch := make(chan result, 1)
	go func() {
		for {
			line, err := conn.readLine()
			if err != nil {
				ch <- result{err: err}
				return
			}
			m, err := decodeMessage(line)
			if err != nil {
				ch <- result{err: fmt.Errorf("decode: %w", err)}
				return
			}
			if m.T == TypePing {
				continue
			}
			ch <- result{m: m}
			return
		}
	}()
	select {
	case r := <-ch:
		return r.m, r.err
	case <-time.After(3 * time.Second):
		return Message{}, fmt.Errorf("readNext: timed out after 3s")
	}
}

// mustDecodeData decodes a Message's Data field into a map. Fatal on error.
func mustDecodeData(t *testing.T, m Message) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(m.Data, &out); err != nil {
		t.Fatalf("mustDecodeData: %v (raw: %s)", err, m.Data)
	}
	return out
}

// injectJob writes a job JSON file and loads it into the store.
// fields must be a map that can be marshalled to valid job JSON.
func (th *testHub) injectJob(t *testing.T, id string, fields map[string]any) {
	t.Helper()
	if fields == nil {
		fields = map[string]any{}
	}
	if _, ok := fields["id"]; !ok {
		fields["id"] = id
	}
	if _, ok := fields["state"]; !ok {
		fields["state"] = "ready"
	}
	if _, ok := fields["repo"]; !ok {
		fields["repo"] = "testrepo"
	}
	b, err := json.Marshal(fields)
	if err != nil {
		t.Fatalf("injectJob marshal: %v", err)
	}
	path := filepath.Join(th.jobsDir, id+".json")
	if err := os.WriteFile(path, b, 0o644); err != nil {
		t.Fatalf("injectJob write: %v", err)
	}
	th.store.refresh(path)
}

// injectEvent appends a raw event line to the events/<id>.jsonl file.
func (th *testHub) injectEvent(t *testing.T, id, kind string, detail map[string]any) {
	t.Helper()
	if detail == nil {
		detail = map[string]any{}
	}
	ev := map[string]any{
		"ts":     isoNow(),
		"kind":   kind,
		"detail": detail,
	}
	b, err := json.Marshal(ev)
	if err != nil {
		t.Fatalf("injectEvent marshal: %v", err)
	}
	path := filepath.Join(th.eventsDir, id+".jsonl")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		t.Fatalf("injectEvent open: %v", err)
	}
	defer f.Close()
	if _, err := f.Write(append(b, '\n')); err != nil {
		t.Fatalf("injectEvent write: %v", err)
	}
}

// pollCondition calls fn repeatedly until it returns true or deadline elapses.
// Returns true if the condition was satisfied.
func pollCondition(fn func() bool, deadline time.Duration) bool {
	end := time.Now().Add(deadline)
	for time.Now().Before(end) {
		if fn() {
			return true
		}
		time.Sleep(10 * time.Millisecond)
	}
	return false
}

// sendCmd sends a cmd-direction message to the broker via conn.
func sendCmd(t *testing.T, conn *clientConn, typ, id string, data map[string]any) {
	t.Helper()
	raw, err := json.Marshal(data)
	if err != nil {
		t.Fatalf("sendCmd marshal: %v", err)
	}
	m := Message{
		V:    ProtocolVersion,
		Dir:  DirCmd,
		T:    typ,
		ID:   id,
		Ts:   isoNow(),
		Data: raw,
	}
	if err := conn.writeMessage(m); err != nil {
		t.Fatalf("sendCmd write: %v", err)
	}
}

// subscribeSimple sends a subscribe command and waits for both the ack and the snapshot.
// Returns the snapshot Message.
func subscribeSimple(t *testing.T, conn *clientConn, subName string, jobs []string, cats []string) Message {
	t.Helper()
	sendCmd(t, conn, CmdSubscribe, "sub1", map[string]any{
		"sub":        subName,
		"jobs":       jobs,
		"categories": cats,
	})
	// Read ack
	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("subscribeSimple: reading ack: %v", err)
	}
	if ack.Dir != DirAck || ack.T != CmdSubscribe {
		t.Fatalf("subscribeSimple: expected subscribe ack, got dir=%s t=%s", ack.Dir, ack.T)
	}
	// Read snapshot
	snap, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("subscribeSimple: reading snapshot: %v", err)
	}
	if snap.T != TypeSnapshot {
		t.Fatalf("subscribeSimple: expected snapshot, got t=%s", snap.T)
	}
	return snap
}
