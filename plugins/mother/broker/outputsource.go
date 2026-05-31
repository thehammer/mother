package main

// outputsource.go — tails each running job's $MOTHER_ROOT/logs/<id>.log,
// parses appended stream-json lines into structured `output` rawEvents, and
// feeds them to the hub via the emit callback (W2).
//
// Design notes:
//
//   - The log file is written by the mother-run-job wrapper via
//     `exec > >(tee -a "$log_path") 2>&1` followed by
//     `claude … --output-format stream-json --verbose`. Every line is a
//     complete stream-json object (or a plain-text banner echo). The broker
//     is a pure consumer — it never writes the file (B1).
//
//   - Offset is updated BEFORE emit so the hub's subscribe replay path can
//     read offsetForJob() under h.mu and get the boundary past which the live
//     tail will deliver. This makes replay-then-attach atomic with no gap and
//     no dup: replay covers [srcOffset-replayBytes, srcOffset]; live events
//     start at srcOffset (the offset already committed when the tick unblocks).
//
//   - Tool-result content is truncated to ≤ 512 runes (bounded payload, B9).
//     A truncated field carries truncated:true and size:<original bytes>.
//
//   - Banner lines (=== mother job … ===) and blank/malformed/partial lines
//     are silently skipped.

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	// toolResultPreviewRunes is the maximum rune count for tool_result preview.
	toolResultPreviewRunes = 512
)

// outputSource polls running jobs' log files and emits output events.
type outputSource struct {
	store    *jobStore
	logsDir  string
	interval time.Duration
	emit     func(rawEvent)
	maxGap   int // hard-drop ceiling for per-subscription gap counters

	mu      sync.Mutex
	offsets map[string]int64 // jobID → committed byte offset (updated before emit)
}

func newOutputSource(store *jobStore, logsDir string, interval time.Duration, emit func(rawEvent), maxGap int) *outputSource {
	return &outputSource{
		store:    store,
		logsDir:  logsDir,
		interval: interval,
		emit:     emit,
		maxGap:   maxGap,
		offsets:  map[string]int64{},
	}
}

// run polls until done is closed.
func (os *outputSource) run(done <-chan struct{}) {
	t := time.NewTicker(os.interval)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
			os.tick()
		}
	}
}

// tick scans running jobs and emits output events for any log bytes not yet
// consumed.
func (os *outputSource) tick() {
	for _, raw := range os.store.list(listFilter{state: "running"}) {
		var j struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(raw, &j) != nil || j.ID == "" {
			continue
		}
		os.drainJob(j.ID)
	}
}

// drainJob reads bytes appended since the last committed offset, parses
// complete stream-json lines, updates the offset (BEFORE emitting), then
// emits one rawEvent per renderable line in file order.
func (os *outputSource) drainJob(jobID string) {
	logPath := filepath.Join(os.logsDir, jobID+".log")

	os.mu.Lock()
	off := os.offsets[jobID]
	os.mu.Unlock()

	f, err := openFile(logPath)
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
	complete := rest[:lastNL]

	// Parse all complete lines into events before updating the offset.
	var events []rawEvent
	for _, line := range bytes.Split(complete, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		evs := parseOutputLine(jobID, line)
		events = append(events, evs...)
	}

	// Update offset BEFORE calling emit. This ensures that if the hub's
	// subscribe path calls offsetForJob() while an emit is blocked on h.mu,
	// it sees the already-committed boundary and replays [boundary-N, boundary].
	// The blocked emits will then be live events starting exactly at boundary,
	// producing no gap and no dup at the replay/live seam.
	os.mu.Lock()
	os.offsets[jobID] = off + int64(lastNL) + 1
	os.mu.Unlock()

	for _, ev := range events {
		os.emit(ev)
	}
}

// offsetForJob returns the byte offset up to which events have been committed
// for this job. Called by the hub's subscribe replay path under h.mu to
// determine the replay/live boundary.
func (os *outputSource) offsetForJob(jobID string) int64 {
	os.mu.Lock()
	defer os.mu.Unlock()
	return os.offsets[jobID]
}

// replayJob reads the last replayBytes bytes of the job's log (up to
// srcOffset, the committed boundary) and returns parsed output events. Called
// by the hub under h.mu to build the best-effort replay for a late subscriber.
// Returns nil if the log does not exist or has no parseable lines in the window.
func (os *outputSource) replayJob(jobID string, replayBytes int64) []rawEvent {
	srcOffset := os.offsetForJob(jobID)
	if srcOffset == 0 {
		return nil
	}

	logPath := filepath.Join(os.logsDir, jobID+".log")
	f, err := openFile(logPath)
	if err != nil {
		return nil
	}
	defer f.Close()

	replayStart := srcOffset - replayBytes
	if replayStart < 0 {
		replayStart = 0
	}

	if _, err := f.Seek(replayStart, 0); err != nil {
		return nil
	}
	toRead := srcOffset - replayStart
	chunk := make([]byte, toRead)
	n, _ := io.ReadFull(f, chunk)
	chunk = chunk[:n]

	// If we started mid-file, skip the partial line at the beginning.
	if replayStart > 0 {
		idx := bytes.IndexByte(chunk, '\n')
		if idx < 0 {
			return nil // no complete line in window
		}
		chunk = chunk[idx+1:]
	}

	// Trim to the last complete line.
	lastNL := bytes.LastIndexByte(chunk, '\n')
	if lastNL < 0 {
		return nil
	}
	chunk = chunk[:lastNL]

	var events []rawEvent
	for _, line := range bytes.Split(chunk, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		events = append(events, parseOutputLine(jobID, line)...)
	}
	return events
}

// openFile is a thin wrapper so tests can intercept file opens if needed.
var openFile = func(path string) (*os.File, error) { return os.Open(path) }

// ---------------------------------------------------------------------------
// Stream-json line classification
// ---------------------------------------------------------------------------

// streamLine is the minimal envelope common to all stream-json lines.
type streamLine struct {
	Type    string `json:"type"`
	Subtype string `json:"subtype"`
}

// assistantMsg extracts content parts from an assistant stream-json line.
type assistantMsg struct {
	Message struct {
		Content []json.RawMessage `json:"content"`
	} `json:"message"`
}

// contentPart is the shape of a single content block inside a message.
type contentPart struct {
	Type      string                     `json:"type"`
	Text      string                     `json:"text"`
	Name      string                     `json:"name"`
	Input     map[string]json.RawMessage `json:"input"`
	ToolUseID string                     `json:"tool_use_id"`
	IsError   bool                       `json:"is_error"`
	Content   json.RawMessage            `json:"content"`
}

// userMsg extracts content parts from a user stream-json line.
type userMsg struct {
	Message struct {
		Content []json.RawMessage `json:"content"`
	} `json:"message"`
}

// resultLine is the shape of a stream-json type=result line.
type resultLine struct {
	Subtype  string  `json:"subtype"`
	CostUSD  float64 `json:"cost_usd"`
	Duration int64   `json:"duration_ms"`
}

// systemLine is the shape of a stream-json type=system subtype=init line.
type systemLine struct {
	SessionID string `json:"session_id"`
	Model     string `json:"model"`
}

// parseOutputLine classifies one log line (which must be a complete,
// newline-terminated stream-json object). Banner lines (=== … ===),
// blank lines, and malformed JSON are silently skipped. Returns zero or more
// rawEvents (one per renderable content part for assistant/user messages).
func parseOutputLine(jobID string, line []byte) []rawEvent {
	if len(line) == 0 || line[0] != '{' {
		// Banner lines (=== mother job … ===), blank lines.
		return nil
	}

	var sl streamLine
	if json.Unmarshal(line, &sl) != nil {
		return nil
	}

	switch sl.Type {
	case "system":
		return parseSystemLine(jobID, line, &sl)
	case "assistant":
		return parseAssistantLine(jobID, line)
	case "user":
		return parseUserLine(jobID, line)
	case "result":
		return parseResultLine(jobID, line)
	}
	return nil
}

func parseSystemLine(jobID string, line []byte, sl *streamLine) []rawEvent {
	if sl.Subtype != "init" {
		return nil
	}
	var sys systemLine
	_ = json.Unmarshal(line, &sys)
	detail, _ := json.Marshal(map[string]any{
		"subtype": OutputSubtypeSystem,
		"session": sys.SessionID,
		"model":   sys.Model,
	})
	return []rawEvent{outputEvent(jobID, detail)}
}

func parseAssistantLine(jobID string, line []byte) []rawEvent {
	var msg assistantMsg
	if json.Unmarshal(line, &msg) != nil {
		return nil
	}
	var events []rawEvent
	for _, raw := range msg.Message.Content {
		var cp contentPart
		if json.Unmarshal(raw, &cp) != nil {
			continue
		}
		switch cp.Type {
		case "text":
			if cp.Text == "" {
				continue
			}
			detail, _ := json.Marshal(map[string]any{
				"subtype": OutputSubtypeText,
				"text":    cp.Text,
			})
			events = append(events, outputEvent(jobID, detail))
		case "tool_use":
			name := cp.Name
			if name == "" {
				name = "?"
			}
			b := brief(cp.Input)
			detail, _ := json.Marshal(map[string]any{
				"subtype": OutputSubtypeToolUse,
				"tool":    name,
				"brief":   b,
			})
			events = append(events, outputEvent(jobID, detail))
		}
	}
	return events
}

func parseUserLine(jobID string, line []byte) []rawEvent {
	var msg userMsg
	if json.Unmarshal(line, &msg) != nil {
		return nil
	}
	var events []rawEvent
	for _, raw := range msg.Message.Content {
		var cp contentPart
		if json.Unmarshal(raw, &cp) != nil {
			continue
		}
		if cp.Type != "tool_result" {
			continue
		}
		// Render content: it may be a string or a JSON array.
		preview, size, truncated := renderToolResult(cp.Content, toolResultPreviewRunes)
		d := map[string]any{
			"subtype":  OutputSubtypeToolResult,
			"is_error": cp.IsError,
			"size":     size,
			"preview":  preview,
		}
		if truncated {
			d["truncated"] = true
		}
		detail, _ := json.Marshal(d)
		events = append(events, outputEvent(jobID, detail))
	}
	return events
}

func parseResultLine(jobID string, line []byte) []rawEvent {
	var rl resultLine
	if json.Unmarshal(line, &rl) != nil {
		return nil
	}
	detail, _ := json.Marshal(map[string]any{
		"subtype":     OutputSubtypeResult,
		"subtype_val": rl.Subtype,
		"cost_usd":    rl.CostUSD,
		"duration_ms": rl.Duration,
	})
	return []rawEvent{outputEvent(jobID, detail)}
}

// outputEvent constructs a rawEvent for the output category.
func outputEvent(jobID string, detail json.RawMessage) rawEvent {
	return rawEvent{
		category: CatOutput,
		jobID:    jobID,
		kind:     TypeOutput,
		ts:       isoNow(),
		detail:   detail,
	}
}

// renderToolResult extracts a UTF-8 preview of tool_result content (which may
// be a JSON string or a JSON array of content blocks). Returns the preview,
// total byte size of the raw content, and whether truncation occurred.
func renderToolResult(raw json.RawMessage, maxRunes int) (preview string, size int, truncated bool) {
	size = len(raw)
	if len(raw) == 0 {
		return "", 0, false
	}

	// Try plain string first.
	var s string
	if json.Unmarshal(raw, &s) == nil {
		r := []rune(s)
		if len(r) <= maxRunes {
			return s, size, false
		}
		return string(r[:maxRunes]), size, true
	}

	// Try array of content blocks (e.g. [{type:"text",text:"..."},...]).
	var blocks []struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if json.Unmarshal(raw, &blocks) == nil {
		var combined []rune
		for _, b := range blocks {
			if b.Type == "text" {
				combined = append(combined, []rune(b.Text)...)
			}
		}
		if len(combined) <= maxRunes {
			return string(combined), size, false
		}
		return string(combined[:maxRunes]), size, true
	}

	// Fallback: raw JSON bytes as preview (truncated).
	r := []rune(string(raw))
	if len(r) <= maxRunes {
		return string(r), size, false
	}
	return string(r[:maxRunes]), size, true
}
