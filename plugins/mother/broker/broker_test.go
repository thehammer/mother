package main

// broker_test.go — behavioral contract tests for the IPC broker.
//
// Tests are organized around the acceptance criteria (B2–B9). Each test
// exercises the broker from the outside — through the same NDJSON interface
// a real Swift client uses — using an in-memory net.Pipe() so no actual
// socket is opened.
//
// Test naming: snake_case describing observable behavior, not implementation.

import (
	"encoding/json"
	"go/parser"
	"go/token"
	"net"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
	"time"
)

// =============================================================================
// B3 — isoNow timestamp format
// =============================================================================

// The plan said "microsecond" but the actual state.sh _iso_now function
// (and the fix commit #2) uses millisecond precision (3 fractional digits),
// required for Swift's JSONDecoder .iso8601 strategy. These tests match
// state.sh — the source of truth — not the original plan wording.

func TestIsoNowFormat_matchesMillisecondPrecision(t *testing.T) {
	// B3: every broker timestamp must have exactly 3 fractional digits and a
	// trailing Z, matching state.sh's _iso_now output.
	re := regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`)
	for i := 0; i < 10; i++ {
		ts := isoNow()
		if !re.MatchString(ts) {
			t.Errorf("isoNow() = %q, want format YYYY-MM-DDTHH:MM:SS.mmmZ", ts)
		}
	}
}

func TestIsoNowFormat_notMicrosecond(t *testing.T) {
	// 6-digit fractions break Swift .iso8601; assert we never emit them.
	reMicro := regexp.MustCompile(`\.\d{6}Z$`)
	for i := 0; i < 10; i++ {
		ts := isoNow()
		if reMicro.MatchString(ts) {
			t.Errorf("isoNow() = %q has 6-digit fractions; must be 3 (ms) for Swift compat", ts)
		}
	}
}

// =============================================================================
// B3 — Envelope fields on every outbound message
// =============================================================================

func TestEnvelope_everyOutboundMessageHasRequiredFields(t *testing.T) {
	// Every server→client message must carry v, dir, t, id, ts.
	th := newTestHub(t, 1024)
	conn := th.connect(t)

	hello, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading hello: %v", err)
	}
	if hello.V == 0 {
		t.Errorf("hello.V = 0, want %d", ProtocolVersion)
	}
	if hello.Dir == "" {
		t.Error("hello.Dir is empty")
	}
	if hello.T == "" {
		t.Error("hello.T is empty")
	}
	if hello.ID == "" {
		t.Error("hello.ID is empty")
	}
	if hello.Ts == "" {
		t.Error("hello.Ts is empty")
	}
}

func TestEnvelope_malformedLineYieldsErrMalformedNoCrash(t *testing.T) {
	// B3: a garbled inbound line must yield an ack with error.code=malformed.
	// The broker must NOT crash or disconnect the client.
	th := newTestHub(t, 1024)
	conn := th.connect(t)

	// Drain hello.
	_, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading hello: %v", err)
	}

	// Send something that cannot be parsed as a Message.
	conn.rwc.Write([]byte("this is not json at all\n")) //nolint:errcheck

	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading ack after malformed input: %v", err)
	}
	if ack.Dir != DirAck {
		t.Errorf("ack.Dir = %q, want %q", ack.Dir, DirAck)
	}
	data := mustDecodeData(t, ack)
	errObj, ok := data["error"].(map[string]any)
	if !ok {
		t.Fatalf("ack.data has no error object; got %v", data)
	}
	if got := errObj["code"]; got != ErrMalformed {
		t.Errorf("error.code = %v, want %q", got, ErrMalformed)
	}

	// Broker should still be alive — send a valid command and get a response.
	sendCmd(t, conn, CmdQueryList, "alive", map[string]any{})
	resp, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("broker appears dead after malformed input: %v", err)
	}
	if resp.T != CmdQueryList {
		t.Errorf("expected query.list ack, got %s", resp.T)
	}
}

// =============================================================================
// B8 — Handshake: hello event
// =============================================================================

func TestHandshake_firstMessageIsHello(t *testing.T) {
	th := newTestHub(t, 1024)
	conn := th.connect(t)

	hello, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading first message: %v", err)
	}
	if hello.T != TypeHello {
		t.Errorf("first message t = %q, want %q", hello.T, TypeHello)
	}
	if hello.Dir != DirEvent {
		t.Errorf("hello dir = %q, want %q", hello.Dir, DirEvent)
	}
}

func TestHandshake_helloCarriesProtocolVersionOne(t *testing.T) {
	th := newTestHub(t, 1024)
	conn := th.connect(t)

	hello, _ := readNext(t, conn)
	data := mustDecodeData(t, hello)
	pv, ok := data["protocol_version"]
	if !ok {
		t.Fatal("hello data missing protocol_version")
	}
	// JSON numbers unmarshal to float64.
	if pv.(float64) != float64(ProtocolVersion) {
		t.Errorf("protocol_version = %v, want %d", pv, ProtocolVersion)
	}
}

func TestHandshake_helloCapabilitiesIncludesW1CategoriesAndCommands(t *testing.T) {
	th := newTestHub(t, 1024)
	conn := th.connect(t)

	hello, _ := readNext(t, conn)
	data := mustDecodeData(t, hello)
	rawCaps, ok := data["capabilities"]
	if !ok {
		t.Fatal("hello data missing capabilities")
	}
	caps := rawCaps.([]any)
	capSet := map[string]bool{}
	for _, c := range caps {
		capSet[c.(string)] = true
	}

	// All W1 categories must be present.
	for _, cat := range w1Categories {
		if !capSet[cat] {
			t.Errorf("capabilities missing W1 category %q", cat)
		}
	}
	// All W1 commands must be present.
	for _, cmd := range w1Commands {
		if !capSet[cmd] {
			t.Errorf("capabilities missing W1 command %q", cmd)
		}
	}
}

func TestHandshake_helloCapabilitiesExcludesOutput(t *testing.T) {
	// "output" ships in W2 — W1 must NOT advertise it.
	th := newTestHub(t, 1024)
	conn := th.connect(t)

	hello, _ := readNext(t, conn)
	data := mustDecodeData(t, hello)
	rawCaps := data["capabilities"].([]any)
	for _, c := range rawCaps {
		if c.(string) == CatOutput {
			t.Errorf("hello capabilities includes %q, which must be absent in W1", CatOutput)
		}
	}
}

// =============================================================================
// B2 — Transport blindness: drive broker over net.Pipe()
// =============================================================================

func TestTransportBlindness_brokerRunsOverInMemoryPipe(t *testing.T) {
	// B2: the entire broker lifecycle (hello, subscribe, snapshot, live event)
	// exercises zero real socket code — it all flows through a net.Pipe().
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-pipe-1", map[string]any{"state": "running"})

	conn := th.connect(t)

	// Hello arrives without any socket.
	hello, err := readNext(t, conn)
	if err != nil || hello.T != TypeHello {
		t.Fatalf("hello over net.Pipe failed: err=%v msg.T=%s", err, hello.T)
	}

	// Subscribe and get a snapshot — entirely in-process.
	snap := subscribeSimple(t, conn, "pipe-test", []string{"all"}, []string{CatState})
	data := mustDecodeData(t, snap)
	jobs := data["jobs"].([]any)
	if len(jobs) != 1 {
		t.Errorf("snapshot jobs len = %d, want 1", len(jobs))
	}
}

// =============================================================================
// B2 — No "net" import in non-transport files
// =============================================================================

func TestNoNetImport_onlyTransportAndMainImportNet(t *testing.T) {
	// B2: only transport.go and main.go are allowed to import "net".
	brokerDir := "."
	entries, err := os.ReadDir(brokerDir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}

	fset := token.NewFileSet()
	allowed := map[string]bool{"transport.go": true, "main.go": true}

	for _, e := range entries {
		name := e.Name()
		if e.IsDir() || !strings.HasSuffix(name, ".go") || strings.HasSuffix(name, "_test.go") {
			continue
		}
		src := filepath.Join(brokerDir, name)
		f, err := parser.ParseFile(fset, src, nil, 0)
		if err != nil {
			t.Fatalf("parse %s: %v", name, err)
		}
		for _, imp := range f.Imports {
			path := strings.Trim(imp.Path.Value, `"`)
			if path == "net" && !allowed[name] {
				t.Errorf("%s imports \"net\" — only transport.go and main.go may do so (B2)", name)
			}
		}
	}
}

// =============================================================================
// B2 — No client-facing filesystem paths in snapshot or query data
// =============================================================================

func TestNoFilesystemPaths_snapshotAndQueryDataContainNone(t *testing.T) {
	// B2: broker must never expose absolute filesystem paths to clients.
	// Heuristic: any string value starting with "/" and matching the sentinel
	// (the eventsDir path) is a leak. We check snapshot job records and
	// query.get ack payloads.
	th := newTestHub(t, 1024)
	sentinel := th.eventsDir // e.g. /var/.../events
	th.injectJob(t, "job-path-1", map[string]any{
		"state":    "running",
		"work_dir": "/Users/hammer/.claude/projects/foo",
	})

	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	snap := subscribeSimple(t, conn, "path-test", []string{"all"}, []string{CatState})
	data := mustDecodeData(t, snap)
	assertNoFSPaths(t, data, sentinel)

	// Also check query.get.
	sendCmd(t, conn, CmdQueryGet, "qg1", map[string]any{"job": "job-path-1"})
	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("query.get ack: %v", err)
	}
	assertNoFSPaths(t, mustDecodeData(t, ack), sentinel)
}

// assertNoFSPaths recursively walks a JSON-decoded value and fails if any
// string value starts with "/" and contains the sentinel substring.
func assertNoFSPaths(t *testing.T, v any, sentinel string) {
	t.Helper()
	switch val := v.(type) {
	case string:
		if strings.HasPrefix(val, "/") && strings.Contains(val, sentinel) {
			t.Errorf("client-visible filesystem path leaked: %q", val)
		}
	case map[string]any:
		for _, child := range val {
			assertNoFSPaths(t, child, sentinel)
		}
	case []any:
		for _, child := range val {
			assertNoFSPaths(t, child, sentinel)
		}
	}
}

// =============================================================================
// B5 — classify()
// =============================================================================

func TestClassify_sevenStateKindsMapToState(t *testing.T) {
	stateKinds := []string{"queued", "ready", "running", "awaiting", "succeeded", "failed", "cancelled"}
	for _, kind := range stateKinds {
		if got := classify(kind); got != CatState {
			t.Errorf("classify(%q) = %q, want %q", kind, got, CatState)
		}
	}
}

func TestClassify_awaitingInputMapsToAwait(t *testing.T) {
	if got := classify("awaiting_input"); got != CatAwait {
		t.Errorf("classify(\"awaiting_input\") = %q, want %q", got, CatAwait)
	}
}

func TestClassify_quotaKindsMapToQuota(t *testing.T) {
	quotaKinds := []string{"pause_requested", "auto_resumed", "paused_for_quota"}
	for _, kind := range quotaKinds {
		if got := classify(kind); got != CatQuota {
			t.Errorf("classify(%q) = %q, want %q", kind, got, CatQuota)
		}
	}
}

func TestClassify_unknownKindsMapsToActivity(t *testing.T) {
	activityKinds := []string{
		"escalated", "resumed", "retried", "cancel_requested",
		"adherence_passed", "adherence_failed",
		"phase_started", "phase_completed",
		"review_cycle_started", "review_cycle_completed",
		"findings_routed",
		"something_totally_unknown",
	}
	for _, kind := range activityKinds {
		if got := classify(kind); got != CatActivity {
			t.Errorf("classify(%q) = %q, want %q", kind, got, CatActivity)
		}
	}
}

// =============================================================================
// B5/B7 — foldState()
// =============================================================================

func TestFoldState_sevenStateKindsFoldToThemselves(t *testing.T) {
	kinds := []string{"queued", "ready", "running", "succeeded", "failed", "cancelled"}
	for _, kind := range kinds {
		state, affecting := foldState(kind, nil)
		if !affecting {
			t.Errorf("foldState(%q) affecting=false, want true", kind)
		}
		if state != kind {
			t.Errorf("foldState(%q) = %q, want %q", kind, state, kind)
		}
	}
}

func TestFoldState_awaitingInputAndPausedForQuotaFoldToAwaiting(t *testing.T) {
	for _, kind := range []string{"awaiting_input", "paused_for_quota"} {
		state, affecting := foldState(kind, nil)
		if !affecting {
			t.Errorf("foldState(%q) affecting=false, want true", kind)
		}
		if state != "awaiting" {
			t.Errorf("foldState(%q) = %q, want \"awaiting\"", kind, state)
		}
	}
}

func TestFoldState_resumedAndAutoResumedFoldToReady(t *testing.T) {
	for _, kind := range []string{"resumed", "auto_resumed"} {
		state, affecting := foldState(kind, nil)
		if !affecting {
			t.Errorf("foldState(%q) affecting=false, want true", kind)
		}
		if state != "ready" {
			t.Errorf("foldState(%q) = %q, want \"ready\"", kind, state)
		}
	}
}

func TestFoldState_retriedAndEscalatedUseDetailToState(t *testing.T) {
	for _, kind := range []string{"retried", "escalated"} {
		detail, _ := json.Marshal(map[string]any{"to_state": "running"})
		state, affecting := foldState(kind, detail)
		if !affecting {
			t.Errorf("foldState(%q) affecting=false, want true", kind)
		}
		if state != "running" {
			t.Errorf("foldState(%q, {to_state:running}) = %q, want \"running\"", kind, state)
		}
	}
}

func TestFoldState_retriedWithoutToStateFallsBackToReady(t *testing.T) {
	state, affecting := foldState("retried", json.RawMessage(`{}`))
	if !affecting {
		t.Error("foldState(\"retried\", {}) affecting=false, want true")
	}
	if state != "ready" {
		t.Errorf("foldState(\"retried\", {}) = %q, want \"ready\"", state)
	}
}

func TestFoldState_unrelatedKindsAreNotAffecting(t *testing.T) {
	kinds := []string{"cancel_requested", "adherence_passed", "phase_started", "totally_unknown"}
	for _, kind := range kinds {
		_, affecting := foldState(kind, nil)
		if affecting {
			t.Errorf("foldState(%q) affecting=true, want false (should not change state)", kind)
		}
	}
}

// =============================================================================
// B4/B5 — Subscribe → snapshot, no gap / no dup
// =============================================================================

func TestSubscribe_yieldsAckThenSnapshot(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-snap-1", map[string]any{"state": "ready"})

	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	sendCmd(t, conn, CmdSubscribe, "sub-req-1", map[string]any{
		"sub":        "mysub",
		"jobs":       []string{"all"},
		"categories": []string{CatState},
	})

	// Must get ack first.
	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading ack: %v", err)
	}
	if ack.Dir != DirAck || ack.T != CmdSubscribe {
		t.Errorf("first reply: dir=%s t=%s, want dir=ack t=subscribe", ack.Dir, ack.T)
	}
	ackData := mustDecodeData(t, ack)
	if ackData["ok"] != true {
		t.Errorf("subscribe ack ok=%v, want true", ackData["ok"])
	}
	if ackData["sub"] != "mysub" {
		t.Errorf("subscribe ack sub=%v, want \"mysub\"", ackData["sub"])
	}

	// Then snapshot.
	snap, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading snapshot: %v", err)
	}
	if snap.T != TypeSnapshot {
		t.Errorf("second reply t=%s, want snapshot", snap.T)
	}
	snapData := mustDecodeData(t, snap)
	if snapData["sub"] != "mysub" {
		t.Errorf("snapshot sub=%v, want \"mysub\"", snapData["sub"])
	}
	jobs := snapData["jobs"].([]any)
	if len(jobs) != 1 {
		t.Errorf("snapshot jobs len=%d, want 1", len(jobs))
	}
}

func TestSubscribe_noGap_eventIngestedBeforeSubscribeAppearsOnlyInSnapshot(t *testing.T) {
	// An event ingested BEFORE subscribe must appear in the snapshot's folded
	// state but NOT arrive as a live event afterward.
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-nogap-1", map[string]any{"state": "queued"})

	// Ingest a state change before any client subscribes.
	th.hub.ingest(rawEvent{
		category: CatState,
		jobID:    "job-nogap-1",
		kind:     "running",
		ts:       isoNow(),
		detail:   json.RawMessage(`{}`),
	})

	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	snap := subscribeSimple(t, conn, "nogap-sub", []string{"all"}, []string{CatState})
	snapData := mustDecodeData(t, snap)
	jobs := snapData["jobs"].([]any)
	if len(jobs) == 0 {
		t.Fatal("snapshot has no jobs")
	}
	job0 := jobs[0].(map[string]any)
	if got := job0["state"]; got != "running" {
		t.Errorf("snapshot job state = %v, want \"running\" (pre-subscribe event must fold into snapshot)", got)
	}

	// Now ingest ANOTHER event — this one AFTER the subscribe.
	th.hub.ingest(rawEvent{
		category: CatState,
		jobID:    "job-nogap-1",
		kind:     "succeeded",
		ts:       isoNow(),
		detail:   json.RawMessage(`{}`),
	})

	// The next live message should be succeeded, not running (no dup of the first).
	live, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading live event: %v", err)
	}
	if live.T != "succeeded" {
		t.Errorf("live event t=%s, want \"succeeded\" (pre-subscribe event must not replay)", live.T)
	}
}

func TestSubscribe_eventAfterSubscribeArrivesExactlyOnce(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-once-1", map[string]any{"state": "ready"})

	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	subscribeSimple(t, conn, "once-sub", []string{"all"}, []string{CatState})

	// Ingest ONE event post-subscribe.
	th.hub.ingest(rawEvent{
		category: CatState,
		jobID:    "job-once-1",
		kind:     "running",
		ts:       isoNow(),
		detail:   json.RawMessage(`{}`),
	})

	// Receive the live event.
	live, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("reading live event: %v", err)
	}
	if live.T != "running" {
		t.Errorf("live.T = %s, want \"running\"", live.T)
	}

	// No second message should arrive (verify by timeout).
	type result struct {
		m   Message
		err error
	}
	ch := make(chan result, 1)
	go func() {
		m, err2 := readNext(t, conn)
		ch <- result{m, err2}
	}()
	select {
	case r := <-ch:
		// Could be a ping — that's fine; any other type would be a dup.
		if r.err == nil && r.m.T != TypePing {
			t.Errorf("unexpected second message t=%s (event must arrive exactly once)", r.m.T)
		}
	case <-time.After(200 * time.Millisecond):
		// Good: no extra message.
	}
}

// =============================================================================
// B5 — Per-job ordering
// =============================================================================

func TestOrdering_stateEventsArrivedInOrder(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-order-1", map[string]any{"state": "queued"})

	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	subscribeSimple(t, conn, "order-sub", []string{"all"}, []string{CatState})

	sequence := []string{"ready", "running", "succeeded"}
	for _, kind := range sequence {
		th.hub.ingest(rawEvent{
			category: CatState,
			jobID:    "job-order-1",
			kind:     kind,
			ts:       isoNow(),
			detail:   json.RawMessage(`{}`),
		})
	}

	for i, want := range sequence {
		live, err := readNext(t, conn)
		if err != nil {
			t.Fatalf("event %d: %v", i, err)
		}
		if live.T != want {
			t.Errorf("event[%d]: t=%s, want %s", i, live.T, want)
		}
	}
}

// =============================================================================
// B5/await — Snapshot overlay for awaiting
// =============================================================================

func TestSnapshot_awaitingInputSetsStateAndQuestion(t *testing.T) {
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-await-1", map[string]any{"state": "running"})

	// Prime the event log: queued → running → awaiting_input.
	th.hub.ingest(rawEvent{category: CatState, jobID: "job-await-1", kind: "queued", ts: isoNow(), detail: json.RawMessage(`{}`)})
	th.hub.ingest(rawEvent{category: CatState, jobID: "job-await-1", kind: "running", ts: isoNow(), detail: json.RawMessage(`{}`)})
	questionDetail, _ := json.Marshal(map[string]any{"question": "shall we proceed?"})
	th.hub.ingest(rawEvent{category: CatAwait, jobID: "job-await-1", kind: "awaiting_input", ts: isoNow(), detail: questionDetail})

	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	snap := subscribeSimple(t, conn, "await-sub", []string{"all"}, []string{CatState, CatAwait})
	snapData := mustDecodeData(t, snap)
	jobs := snapData["jobs"].([]any)
	if len(jobs) == 0 {
		t.Fatal("snapshot has no jobs")
	}
	job0 := jobs[0].(map[string]any)
	if got := job0["state"]; got != "awaiting" {
		t.Errorf("snapshot job state = %v, want \"awaiting\"", got)
	}
	if got := job0["question"]; got != "shall we proceed?" {
		t.Errorf("snapshot job question = %v, want \"shall we proceed?\"", got)
	}
}

// =============================================================================
// B8 — mapCLIError error code mapping
// =============================================================================

func TestMapCLIError_noSuchJobMapping(t *testing.T) {
	if got := mapCLIError("mother: no such job: abc123"); got != ErrNoSuchJob {
		t.Errorf("mapCLIError(no such job) = %q, want %q", got, ErrNoSuchJob)
	}
}

func TestMapCLIError_invalidStateMappings(t *testing.T) {
	cases := []string{
		"expected awaiting, got ready",
		"expected running",
		"cannot cancel job in state succeeded",
		"can only retry failed jobs",
		"is in state running",
	}
	for _, stderr := range cases {
		if got := mapCLIError(stderr); got != ErrInvalidState {
			t.Errorf("mapCLIError(%q) = %q, want %q", stderr, got, ErrInvalidState)
		}
	}
}

func TestMapCLIError_unknownStderrMapsToInternal(t *testing.T) {
	cases := []string{
		"some unexpected error occurred",
		"permission denied",
		"",
	}
	for _, stderr := range cases {
		if got := mapCLIError(stderr); got != ErrInternal {
			t.Errorf("mapCLIError(%q) = %q, want %q", stderr, got, ErrInternal)
		}
	}
}

// =============================================================================
// Subscribe validation — empty name and bad categories
// =============================================================================

func TestSubscribeValidation_emptyNameYieldsMalformedAck(t *testing.T) {
	th := newTestHub(t, 1024)
	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	sendCmd(t, conn, CmdSubscribe, "bad1", map[string]any{
		"sub":        "",
		"jobs":       []string{"all"},
		"categories": []string{CatState},
	})
	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("ack: %v", err)
	}
	if ack.Dir != DirAck {
		t.Errorf("dir = %s, want ack", ack.Dir)
	}
	data := mustDecodeData(t, ack)
	errObj, ok := data["error"].(map[string]any)
	if !ok {
		t.Fatalf("expected error object, got %v", data)
	}
	if errObj["code"] != ErrMalformed {
		t.Errorf("error.code = %v, want %q", errObj["code"], ErrMalformed)
	}
}

func TestSubscribeValidation_outputCategoryYieldsMalformedAck(t *testing.T) {
	// "output" is a W2 category — W1 must reject subscriptions that request it.
	th := newTestHub(t, 1024)
	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	sendCmd(t, conn, CmdSubscribe, "bad2", map[string]any{
		"sub":        "mysub",
		"jobs":       []string{"all"},
		"categories": []string{CatOutput},
	})
	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("ack: %v", err)
	}
	data := mustDecodeData(t, ack)
	errObj, _ := data["error"].(map[string]any)
	if errObj["code"] != ErrMalformed {
		t.Errorf("error.code = %v, want %q (output is absent in W1)", errObj["code"], ErrMalformed)
	}
}

func TestSubscribeValidation_emptyCategoriesYieldsMalformedAck(t *testing.T) {
	th := newTestHub(t, 1024)
	conn := th.connect(t)
	_, _ = readNext(t, conn) // hello

	sendCmd(t, conn, CmdSubscribe, "bad3", map[string]any{
		"sub":        "mysub",
		"jobs":       []string{"all"},
		"categories": []string{},
	})
	ack, err := readNext(t, conn)
	if err != nil {
		t.Fatalf("ack: %v", err)
	}
	data := mustDecodeData(t, ack)
	errObj, _ := data["error"].(map[string]any)
	if errObj["code"] != ErrMalformed {
		t.Errorf("error.code = %v, want %q (empty categories should fail)", errObj["code"], ErrMalformed)
	}
}

// =============================================================================
// B6 — current_activity rendering
// =============================================================================

func TestBrief_filePathFieldRendersCorrectly(t *testing.T) {
	input := map[string]json.RawMessage{
		"file_path": json.RawMessage(`"src/lib.rs"`),
	}
	got := brief(input)
	if got != "src/lib.rs" {
		t.Errorf("brief({file_path: src/lib.rs}) = %q, want %q", got, "src/lib.rs")
	}
}

func TestBrief_newlinesAreCollapsed(t *testing.T) {
	input := map[string]json.RawMessage{
		"description": json.RawMessage(`"line one\nline two"`),
	}
	got := brief(input)
	if !strings.Contains(got, " ⏎ ") {
		t.Errorf("brief did not collapse newlines: %q", got)
	}
}

func TestBrief_truncatesToOneHundredTenRunes(t *testing.T) {
	long := strings.Repeat("x", 200)
	input := map[string]json.RawMessage{
		"file_path": json.RawMessage(`"` + long + `"`),
	}
	got := brief(input)
	if len([]rune(got)) > 110 {
		t.Errorf("brief len=%d, want <=110 runes", len([]rune(got)))
	}
}

func TestRenderActivity_combinesToolNameAndBrief(t *testing.T) {
	input := map[string]json.RawMessage{
		"file_path": json.RawMessage(`"src/lib.rs"`),
	}
	got := renderActivity("Edit", input)
	if got != "Edit: src/lib.rs" {
		t.Errorf("renderActivity = %q, want \"Edit: src/lib.rs\"", got)
	}
}

func TestRenderActivity_toolNameOnlyWhenNoKnownField(t *testing.T) {
	input := map[string]json.RawMessage{
		"some_other_field": json.RawMessage(`"value"`),
	}
	got := renderActivity("Bash", input)
	if got != "Bash" {
		t.Errorf("renderActivity (no known field) = %q, want \"Bash\"", got)
	}
}

func TestResolveTranscript_slugsWorkDir(t *testing.T) {
	// resolveTranscript must slug the work_dir by replacing '/' and '.' with '-'
	// and locate <projectsDir>/<slug>/<session_id>.jsonl.
	tmp := t.TempDir()
	// work_dir: /Users/hammer/Code/myrepo
	// expected slug: -Users-hammer-Code-myrepo
	slug := "-Users-hammer-Code-myrepo"
	projectDir := filepath.Join(tmp, slug)
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	sessionID := "ses123"
	transcriptPath := filepath.Join(projectDir, sessionID+".jsonl")
	if err := os.WriteFile(transcriptPath, []byte("{}"), 0o644); err != nil {
		t.Fatal(err)
	}

	j := jobActivityFields{
		WorkDir:   "/Users/hammer/Code/myrepo",
		SessionID: sessionID,
	}
	got, ok := resolveTranscript(j, tmp)
	if !ok {
		t.Fatal("resolveTranscript: expected ok=true")
	}
	if got != transcriptPath {
		t.Errorf("resolveTranscript = %q, want %q", got, transcriptPath)
	}
}

func TestActivityWatcher_emitsCurrentActivityFromTranscript(t *testing.T) {
	// End-to-end: place a fake transcript with one tool_use; tick() should
	// emit a current_activity event.
	tmp := t.TempDir()
	projectsDir := filepath.Join(tmp, "projects")
	workDir := "/fake/work/dir"
	// Slug for /fake/work/dir → -fake-work-dir
	slug := "-fake-work-dir"
	projectDir := filepath.Join(projectsDir, slug)
	if err := os.MkdirAll(projectDir, 0o755); err != nil {
		t.Fatal(err)
	}
	sessionID := "sess-abc"
	transcriptPath := filepath.Join(projectDir, sessionID+".jsonl")

	// Write a transcript line with an assistant tool_use.
	transcriptLine := `{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/main.rs"}}]}}` + "\n"
	if err := os.WriteFile(transcriptPath, []byte(transcriptLine), 0o644); err != nil {
		t.Fatal(err)
	}

	// Set up jobstore with a running job.
	th := newTestHub(t, 1024)
	th.injectJob(t, "job-act-1", map[string]any{
		"state":      "running",
		"work_dir":   workDir,
		"session_id": sessionID,
	})

	var emittedEvents []rawEvent
	collect := func(ev rawEvent) { emittedEvents = append(emittedEvents, ev) }

	aw := newActivityWatcher(th.store, projectsDir, time.Second, collect)
	aw.tick()

	if len(emittedEvents) == 0 {
		t.Fatal("activityWatcher.tick() emitted no events; expected a current_activity event")
	}
	ev := emittedEvents[0]
	if ev.category != CatCurrentActivity {
		t.Errorf("event category = %q, want %q", ev.category, CatCurrentActivity)
	}
	if ev.jobID != "job-act-1" {
		t.Errorf("event jobID = %q, want \"job-act-1\"", ev.jobID)
	}
	var detail struct {
		CurrentActivity string `json:"current_activity"`
	}
	if err := json.Unmarshal(ev.detail, &detail); err != nil {
		t.Fatalf("unmarshal detail: %v", err)
	}
	if detail.CurrentActivity != "Edit: src/main.rs" {
		t.Errorf("current_activity = %q, want \"Edit: src/main.rs\"", detail.CurrentActivity)
	}
}

// =============================================================================
// B9 — Backpressure / disconnect
// =============================================================================

func TestBackpressure_slowClientDroppedHealthyClientKeepsReceiving(t *testing.T) {
	// Two SUBSCRIBED clients receive the same fan-out. One drains its read
	// side continuously (healthy); the other subscribes then stops reading
	// (slow). With a small per-client buffer, the slow client's outbound
	// buffer overflows and the broker drops it — without affecting the
	// healthy client, which keeps receiving.
	//
	// Note: a client must be subscribed to receive events at all, so the slow
	// client subscribes first (a single write, which the broker's read loop
	// consumes) and only then goes silent on its read side.
	th := newTestHub(t, 4)
	th.injectJob(t, "job-bp-1", map[string]any{"state": "ready"})

	// Healthy client: subscribe, then drain continuously in a goroutine.
	healthy := th.connect(t)
	_, _ = readNext(t, healthy) // hello
	subscribeSimple(t, healthy, "h", []string{"all"}, []string{CatState})
	healthyGot := make(chan struct{}, 4096)
	healthyStop := make(chan struct{})
	go func() {
		for {
			select {
			case <-healthyStop:
				return
			default:
			}
			line, err := healthy.readLine()
			if err != nil {
				return
			}
			m, derr := decodeMessage(line)
			if derr == nil && m.Dir == DirEvent && m.T != TypePing {
				select {
				case healthyGot <- struct{}{}:
				default:
				}
			}
		}
	}()

	// Slow client: subscribe, then never read (its write side reaches the
	// broker's read loop; its read side is left to overflow).
	srvSlow, cliSlow := net.Pipe()
	th.hub.serve(newClientConn(srvSlow))
	t.Cleanup(func() { cliSlow.Close() })
	slow := newClientConn(cliSlow)
	sendCmd(t, slow, CmdSubscribe, "s1", map[string]any{
		"sub": "s", "jobs": []string{"all"}, "categories": []string{CatState},
	})

	// Pump events. The healthy client drains them; the slow client's buffer
	// overflows.
	for i := 0; i < 50; i++ {
		th.hub.ingest(rawEvent{
			category: CatState,
			jobID:    "job-bp-1",
			kind:     "running",
			ts:       isoNow(),
			detail:   json.RawMessage(`{}`),
		})
		time.Sleep(2 * time.Millisecond)
	}

	// Slow client should be dropped (2 clients → 1).
	dropped := pollCondition(func() bool {
		return th.hub.clientCount() <= 1
	}, 3*time.Second)
	if !dropped {
		t.Errorf("slow client was not dropped within deadline; clientCount=%d", th.hub.clientCount())
	}

	// Healthy client should still receive a freshly ingested event.
	th.hub.ingest(rawEvent{
		category: CatState,
		jobID:    "job-bp-1",
		kind:     "succeeded",
		ts:       isoNow(),
		detail:   json.RawMessage(`{}`),
	})
	select {
	case <-healthyGot:
	case <-time.After(3 * time.Second):
		t.Fatal("healthy client stopped receiving after slow client was dropped")
	}
	close(healthyStop)
}

func TestBackpressure_closingClientPipeDecreasesClientCount(t *testing.T) {
	// Closing a client's pipe should cause it to be unregistered from the hub.
	th := newTestHub(t, 1024)

	srv, cli := net.Pipe()
	th.hub.serve(newClientConn(srv))

	// Wait for the client to register (hello has been buffered).
	registered := pollCondition(func() bool {
		return th.hub.clientCount() == 1
	}, 2*time.Second)
	if !registered {
		t.Fatal("client did not register within deadline")
	}

	// Close the client side — the server-side read loop sees EOF.
	cli.Close()

	dropped := pollCondition(func() bool {
		return th.hub.clientCount() == 0
	}, 3*time.Second)
	if !dropped {
		t.Errorf("client was not unregistered after pipe close; count=%d", th.hub.clientCount())
	}
}
