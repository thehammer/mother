package main

// server.go — the connection hub, per-client lifecycle, fan-out, handshake,
// and command dispatch (B8/B9). Transport-blind: it operates only on
// *clientConn, so it can be driven by an in-memory net.Pipe() in tests.
//
// Concurrency model:
//   - Each client owns three goroutines: read (commands), write (drains the
//     bounded send channel), and ping (heartbeat + half-open detection).
//   - The hub serializes overlay updates + fan-out (ingest) and snapshot+
//     attach (subscribe) under one mutex, which is what makes a subscribe
//     see current state then every subsequent change with no gap and no dup.
//   - A slow client that overflows its bounded channel is dropped — it never
//     blocks the fan-out or starves another client.

import (
	"encoding/json"
	"path/filepath"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

// derivedState is the event-derived authoritative view of a job's dynamic
// fields. The snapshot overlays these onto the static job JSON so the
// snapshot is consistent with the live event stream (no-gap/no-dup).
type derivedState struct {
	state           string
	question        string
	pausedReason    string
	currentActivity string
}

type hub struct {
	store       *jobStore
	runner      *commandRunner
	pingSeconds int
	clientBuf   int

	// W2: output category support. outputSrc is nil when output is disabled.
	outputSrc    *outputSource
	replayBytes  int64 // MOTHER_BROKER_OUTPUT_REPLAY_BYTES
	outputMaxGap int   // MOTHER_BROKER_OUTPUT_MAX_GAP

	mu       sync.Mutex
	clients  map[*client]bool
	jobState map[string]*derivedState
}

func newHub(store *jobStore, runner *commandRunner, pingSeconds, clientBuf int) *hub {
	return &hub{
		store:       store,
		runner:      runner,
		pingSeconds: pingSeconds,
		clientBuf:   clientBuf,
		clients:     map[*client]bool{},
		jobState:    map[string]*derivedState{},
	}
}

// ingest applies an event to the overlay and fans it out to matching
// subscriptions. This is the emit callback handed to the event source and
// the activity watcher. Serialized against subscribe via h.mu.
func (h *hub) ingest(ev rawEvent) {
	h.mu.Lock()
	h.applyOverlayLocked(ev)

	// For "queued" events, replace the detail with the full overlaid job
	// snapshot so that subscribers already connected when this job was
	// created can construct a complete MotherJob without a reconnect or
	// round-trip. Without this, clients only receive {"title":"..."} and
	// must ignore the event because they lack the fields to build a job.
	//
	// fsnotify delivery ordering: both the jobs/*.json write and the
	// events/*.jsonl write trigger fsnotify callbacks, but the jobs watcher
	// may not have fired yet when ingest runs. Call refresh synchronously
	// under the hub mutex (different lock from store.mu — no deadlock) so
	// the record is available before we embed it.
	if ev.kind == "queued" {
		raw, ok := h.store.get(ev.jobID)
		if !ok {
			h.store.refresh(filepath.Join(h.store.dir, ev.jobID+".json"))
			raw, ok = h.store.get(ev.jobID)
		}
		if ok {
			ev.detail = h.overlayJobLocked(ev.jobID, raw)
		}
	}

	for cl := range h.clients {
		if atomic.LoadInt32(&cl.dead) == 1 {
			continue
		}
		h.deliverLocked(cl, ev)
	}
	h.mu.Unlock()
}

func (h *hub) applyOverlayLocked(ev rawEvent) {
	ds := h.jobState[ev.jobID]
	if ds == nil {
		ds = &derivedState{}
		h.jobState[ev.jobID] = ds
	}

	// State fold: derive the job's current state from the same ordered event
	// stream the live events come from, so the snapshot and the live tail
	// never disagree (the no-gap/no-dup contract).
	if newState, affecting := foldState(ev.kind, ev.detail); affecting {
		ds.state = newState
		// Leaving the awaiting state clears the operator-facing prompt so a
		// later snapshot doesn't render a stale reply affordance.
		if newState != "awaiting" {
			ds.question = ""
			ds.pausedReason = ""
		}
	}

	// Entering awaiting carries the question/paused_reason for the snapshot.
	switch ev.kind {
	case "awaiting_input", "paused_for_quota":
		var d struct {
			Question     string `json:"question"`
			PausedReason string `json:"paused_reason"`
		}
		_ = json.Unmarshal(ev.detail, &d)
		if d.Question != "" {
			ds.question = d.Question
		}
		if d.PausedReason != "" {
			ds.pausedReason = d.PausedReason
		}
	}

	if ev.category == CatCurrentActivity {
		var d struct {
			CurrentActivity string `json:"current_activity"`
		}
		_ = json.Unmarshal(ev.detail, &d)
		ds.currentActivity = d.CurrentActivity
	}
}

// foldState is the canonical event→state vocabulary (B7). It returns the
// state implied by an event and whether the event is state-affecting. The
// awaiting transition has no dedicated state-kind event in the bash layer —
// it is implied by awaiting_input / paused_for_quota — and the return from
// awaiting is implied by resumed / auto_resumed, so those are folded here.
// retried / escalated carry the resulting state in detail.to_state.
func foldState(kind string, detail json.RawMessage) (string, bool) {
	switch kind {
	case "queued", "ready", "running", "succeeded", "failed", "cancelled":
		return kind, true
	case "awaiting_input", "paused_for_quota":
		return "awaiting", true
	case "resumed", "auto_resumed":
		return "ready", true
	case "retried", "escalated":
		var d struct {
			ToState string `json:"to_state"`
		}
		if json.Unmarshal(detail, &d) == nil && d.ToState != "" {
			return d.ToState, true
		}
		return "ready", true
	}
	return "", false
}

func (h *hub) deliverLocked(cl *client, ev rawEvent) {
	// Find the first subscription that matches this event. A client rarely
	// has multiple overlapping output subscriptions, so using the first match
	// for gap tracking is correct in the common case.
	var matchedSub *subscription
	for _, s := range cl.subs {
		if s.matches(ev) {
			matchedSub = s
			break
		}
	}
	if matchedSub == nil {
		return
	}

	if ev.category == CatOutput {
		// Output has a softer backpressure policy: drop events with a gap
		// marker rather than disconnecting the client on overflow.
		h.deliverOutputLocked(cl, matchedSub, ev)
	} else {
		// Non-output categories retain the W1 hard drop-the-client policy:
		// losing a state/await event corrupts the client's view.
		data := mergeData(ev.detail, map[string]any{"job": ev.jobID, "category": ev.category})
		if !cl.enqueue(newEvent(ev.kind, "", data)) {
			go cl.drop("slow client: outbound buffer overflow")
		}
	}
}

// deliverOutputLocked implements the output-specific backpressure policy
// (B9, W2). On buffer overflow it drops the event and records a gap rather
// than disconnecting the client. On recovery it prepends a gap marker so the
// client knows content was elided. Falls back to hard drop only when the gap
// counter exceeds h.outputMaxGap (durable stall).
//
// Must be called under h.mu.
func (h *hub) deliverOutputLocked(cl *client, s *subscription, ev rawEvent) {
	data := mergeData(ev.detail, map[string]any{"job": ev.jobID, "category": ev.category})
	msg := newEvent(ev.kind, "", data)

	if s.pendingGap {
		// Prepend a gap marker before the next successful delivery so the
		// client knows how many output events it missed.
		gapDetail, _ := json.Marshal(map[string]any{
			"subtype": OutputSubtypeGap,
			"dropped": s.gapCount,
		})
		gapData := mergeData(gapDetail, map[string]any{"job": ev.jobID, "category": CatOutput})
		gapMsg := newEvent(TypeOutput, "", gapData)
		if !cl.enqueue(gapMsg) {
			// Still no room — increment gap counter and bail.
			s.gapCount++
			if s.gapCount > h.outputMaxGap {
				go cl.drop("output gap ceiling exceeded")
			}
			return
		}
		// Gap marker sent; reset gap state.
		s.pendingGap = false
		s.gapCount = 0
	}

	if !cl.enqueue(msg) {
		s.gapCount++
		s.pendingGap = true
		if s.gapCount > h.outputMaxGap {
			go cl.drop("output gap ceiling exceeded")
		}
	}
}

// subscribe registers a subscription and atomically emits its snapshot, so no
// live event for the subscription is delivered before the snapshot and none
// is missed after it.
//
// For output subscriptions (W2): after the snapshot, a best-effort bounded
// replay of each matching running job's log is enqueued under the same lock.
// This ensures the replay/live boundary has no gap and no dup: the outputSource
// updates its offset before calling emit (which blocks on h.mu), so the offset
// we read here reflects exactly the bytes the live tail will start from.
func (h *hub) subscribe(cl *client, sub *subscription) {
	h.mu.Lock()
	defer h.mu.Unlock()
	cl.subs[sub.name] = sub
	jobs := h.snapshotJobsLocked(sub)
	data, _ := json.Marshal(map[string]any{"sub": sub.name, "jobs": jobs})
	if !cl.enqueue(newEvent(TypeSnapshot, "", data)) {
		go cl.drop("slow client: outbound buffer overflow")
		return
	}

	// Output replay (W2): enqueue best-effort historical output for running
	// jobs before releasing the lock so the live tail picks up exactly where
	// the replay ends.
	if sub.categories[CatOutput] && h.outputSrc != nil && h.replayBytes > 0 {
		h.replayOutputLocked(cl, sub)
	}
}

// replayOutputLocked enqueues a bounded tail of output events for each
// running job that matches the subscription. Called under h.mu. Best-effort:
// failed enqueues are silently skipped (the replay is not guaranteed).
func (h *hub) replayOutputLocked(cl *client, sub *subscription) {
	for _, raw := range h.store.list(listFilter{state: "running"}) {
		var j struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(raw, &j) != nil || j.ID == "" {
			continue
		}
		if !sub.matchesJob(j.ID) {
			continue
		}
		events := h.outputSrc.replayJob(j.ID, h.replayBytes)
		for _, ev := range events {
			data := mergeData(ev.detail, map[string]any{"job": ev.jobID, "category": ev.category})
			_ = cl.enqueue(newEvent(ev.kind, "", data)) // best-effort
		}
	}
}

func (h *hub) unsubscribe(cl *client, name string) {
	h.mu.Lock()
	delete(cl.subs, name)
	h.mu.Unlock()
}

func (h *hub) snapshotJobsLocked(sub *subscription) []json.RawMessage {
	var ids []string
	if sub.allJobs {
		ids = h.store.allIDs()
	} else {
		ids = sub.selectedJobIDs()
	}
	out := []json.RawMessage{}
	for _, id := range ids {
		raw, ok := h.store.get(id)
		if !ok {
			continue
		}
		out = append(out, h.overlayJobLocked(id, raw))
	}
	return out
}

// overlayJobLocked merges the event-derived dynamic fields onto a job's raw
// JSON for the snapshot.
func (h *hub) overlayJobLocked(id string, raw json.RawMessage) json.RawMessage {
	m := map[string]json.RawMessage{}
	if json.Unmarshal(raw, &m) != nil {
		return raw
	}
	ds := h.jobState[id]
	if ds != nil {
		if ds.state != "" {
			m["state"] = jstr(ds.state)
		}
		if ds.question != "" {
			m["question"] = jstr(ds.question)
		}
		if ds.pausedReason != "" {
			m["paused_reason"] = jstr(ds.pausedReason)
		}
		if ds.currentActivity != "" {
			m["current_activity"] = jstr(ds.currentActivity)
		}
	}
	out, err := json.Marshal(m)
	if err != nil {
		return raw
	}
	return out
}

func jstr(s string) json.RawMessage {
	b, _ := json.Marshal(s)
	return b
}

func (h *hub) register(cl *client)   { h.mu.Lock(); h.clients[cl] = true; h.mu.Unlock() }
func (h *hub) unregister(cl *client) { h.mu.Lock(); delete(h.clients, cl); h.mu.Unlock() }

func (h *hub) clientCount() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.clients)
}

// ---------- client ----------

type client struct {
	hub  *hub
	conn *clientConn
	send chan Message
	done chan struct{}
	subs map[string]*subscription // guarded by hub.mu

	sendMu   sync.Mutex // serializes id-assignment + channel send
	eventSeq int64

	closeOnce sync.Once
	dead      int32
}

func newClient(h *hub, conn *clientConn) *client {
	return &client{
		hub:  h,
		conn: conn,
		send: make(chan Message, h.clientBuf),
		done: make(chan struct{}),
		subs: map[string]*subscription{},
	}
}

// serve wires up the client: register, start the writer, send the hello
// handshake, then start the reader and ping loops. Returns immediately; the
// goroutines run until the client is dropped.
func (h *hub) serve(conn *clientConn) *client {
	cl := newClient(h, conn)
	h.register(cl)
	go cl.writeLoop()
	cl.sendHello()
	go cl.readLoop()
	go cl.pingLoop()
	return cl
}

func (cl *client) sendHello() {
	// Use liveCategories (the runtime-active set) so the advertised
	// capabilities and validCategories() validation always agree. When
	// MOTHER_BROKER_OUTPUT_ENABLED=0, liveCategories excludes CatOutput
	// and this hello will not advertise it.
	caps := make([]string, 0, len(liveCategories)+len(w1Commands))
	caps = append(caps, liveCategories...)
	caps = append(caps, w1Commands...)
	data, _ := json.Marshal(map[string]any{
		"protocol_version": ProtocolVersion,
		"capabilities":     caps,
	})
	if !cl.enqueue(newEvent(TypeHello, "", data)) {
		go cl.drop("could not send hello")
	}
}

// enqueue assigns a monotonic per-connection id to events and performs a
// non-blocking send. Returns false when the outbound buffer is full.
func (cl *client) enqueue(m Message) bool {
	cl.sendMu.Lock()
	defer cl.sendMu.Unlock()
	if m.Dir == DirEvent {
		cl.eventSeq++
		m.ID = strconv.FormatInt(cl.eventSeq, 10)
	}
	select {
	case cl.send <- m:
		return true
	default:
		return false
	}
}

func (cl *client) writeLoop() {
	for {
		select {
		case <-cl.done:
			return
		case m := <-cl.send:
			if err := cl.conn.writeMessage(m); err != nil {
				go cl.drop("write error")
				return
			}
		}
	}
}

func (cl *client) readLoop() {
	for {
		line, err := cl.conn.readLine()
		if err != nil {
			go cl.drop("read error / eof")
			return
		}
		cl.handleLine(line)
	}
}

// pingLoop emits a periodic heartbeat. The ping doubles as a liveness probe:
// a dead or half-open peer makes the writer's send fail, which drops the
// client. Crucially this does NOT drop clients for inbound silence — a pure
// subscriber that only listens (never sends a command) is legitimate and
// must stay connected. A genuinely wedged client (alive, not draining) is
// instead caught by the bounded-buffer overflow path.
func (cl *client) pingLoop() {
	interval := time.Duration(cl.hub.pingSeconds) * time.Second
	t := time.NewTicker(interval)
	defer t.Stop()
	for {
		select {
		case <-cl.done:
			return
		case <-t.C:
			if !cl.enqueue(newEvent(TypePing, "", json.RawMessage(`{}`))) {
				go cl.drop("slow client: outbound buffer overflow")
				return
			}
		}
	}
}

// drop tears the client down exactly once: signal the writer/ping loops to
// stop, close the conn (which unblocks any in-flight write and makes the
// reader's next read fail), and unregister from the hub.
//
// We deliberately do NOT attempt an in-band "unavailable" notice here: a
// dropped client is, by definition, one we may be unable to write to (a
// stalled peer's write is blocked holding the write lock). Trying to send a
// final message would deadlock against that blocked write. Closing the conn
// surfaces an EOF to the client, which is the standard reconnect signal; the
// `unavailable` error code remains available on acks for the transient /
// broker-restart cases where a write CAN still succeed.
func (cl *client) drop(reason string) {
	cl.closeOnce.Do(func() {
		atomic.StoreInt32(&cl.dead, 1)
		close(cl.done)
		_ = cl.conn.close()
		cl.hub.unregister(cl)
	})
}

// ---------- command dispatch ----------

func (cl *client) handleLine(line []byte) {
	m, err := decodeMessage(line)
	if err != nil {
		cl.ack(errAck("", "", ErrMalformed, "could not parse message"))
		return
	}
	if m.Dir != DirCmd {
		cl.ack(errAck(m.T, m.ID, ErrMalformed, "expected dir=cmd"))
		return
	}
	switch m.T {
	case CmdSubscribe:
		cl.handleSubscribe(m)
	case CmdUnsubscribe:
		cl.handleUnsubscribe(m)
	case CmdQueryList:
		cl.handleQueryList(m)
	case CmdQueryGet:
		cl.handleQueryGet(m)
	case CmdAnswer:
		cl.handleAnswer(m)
	case CmdCancel:
		cl.handleCancel(m)
	case CmdRetry:
		cl.handleRetry(m)
	default:
		cl.ack(errAck(m.T, m.ID, ErrMalformed, "unknown command: "+m.T))
	}
}

// ack enqueues an ack; if the buffer is full the client is dropped.
func (cl *client) ack(m Message) {
	if !cl.enqueue(m) {
		go cl.drop("slow client: outbound buffer overflow")
	}
}

func (cl *client) handleSubscribe(m Message) {
	var a subscribeArgs
	if err := json.Unmarshal(m.Data, &a); err != nil {
		cl.ack(errAck(m.T, m.ID, ErrMalformed, "subscribe: bad data"))
		return
	}
	if a.Sub == "" {
		cl.ack(errAck(m.T, m.ID, ErrMalformed, "subscribe: sub name required"))
		return
	}
	if !validCategories(a.Categories) {
		cl.ack(errAck(m.T, m.ID, ErrMalformed, "subscribe: unknown or empty categories"))
		return
	}
	cl.ack(okAck(m.T, m.ID, map[string]any{"sub": a.Sub}))
	cl.hub.subscribe(cl, newSubscription(a))
}

func (cl *client) handleUnsubscribe(m Message) {
	var a unsubscribeArgs
	if err := json.Unmarshal(m.Data, &a); err != nil || a.Sub == "" {
		cl.ack(errAck(m.T, m.ID, ErrMalformed, "unsubscribe: sub name required"))
		return
	}
	cl.hub.unsubscribe(cl, a.Sub)
	cl.ack(okAck(m.T, m.ID, map[string]any{"sub": a.Sub}))
}

func (cl *client) handleQueryList(m Message) {
	var a struct {
		Jobs  []string `json:"jobs"`
		State string   `json:"state"`
		Repo  string   `json:"repo"`
	}
	_ = json.Unmarshal(m.Data, &a)
	res := cl.hub.runner.queryList(listFilter{jobs: a.Jobs, state: a.State, repo: a.Repo})
	cl.respond(m, res)
}

func (cl *client) handleQueryGet(m Message) {
	var a struct {
		Job string `json:"job"`
	}
	_ = json.Unmarshal(m.Data, &a)
	cl.respond(m, cl.hub.runner.queryGet(a.Job))
}

func (cl *client) handleAnswer(m Message) {
	var a struct {
		Job  string `json:"job"`
		Text string `json:"text"`
	}
	_ = json.Unmarshal(m.Data, &a)
	cl.respond(m, cl.hub.runner.answer(a.Job, a.Text))
}

func (cl *client) handleCancel(m Message) {
	var a struct {
		Job string `json:"job"`
	}
	_ = json.Unmarshal(m.Data, &a)
	cl.respond(m, cl.hub.runner.cancel(a.Job))
}

func (cl *client) handleRetry(m Message) {
	var a struct {
		Job string `json:"job"`
	}
	_ = json.Unmarshal(m.Data, &a)
	cl.respond(m, cl.hub.runner.retry(a.Job))
}

// respond turns a cmdResult into the correlated ack.
func (cl *client) respond(m Message, res cmdResult) {
	if res.code != "" {
		cl.ack(errAck(m.T, m.ID, res.code, res.msg))
		return
	}
	cl.ack(okAck(m.T, m.ID, res.payload))
}
