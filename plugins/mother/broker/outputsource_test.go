package main

// outputsource_test.go — unit tests for parseOutputLine and renderToolResult.
//
// Tests assert on the structured rawEvent output produced by the parser,
// not on file I/O or polling mechanics. The emit callback is replaced by a
// []rawEvent collector so we can drive drainJob synchronously.

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// collectEmit is a simple emit callback that collects rawEvents into a slice.
func collectEmit(events *[]rawEvent) func(rawEvent) {
	return func(ev rawEvent) {
		*events = append(*events, ev)
	}
}

// decodeDetail unmarshals the detail field of a rawEvent into map[string]any.
func decodeDetail(t *testing.T, ev rawEvent) map[string]any {
	t.Helper()
	var m map[string]any
	if err := json.Unmarshal(ev.detail, &m); err != nil {
		t.Fatalf("decodeDetail: %v (raw: %s)", err, ev.detail)
	}
	return m
}

// =============================================================================
// parseOutputLine — per-type classification
// =============================================================================

func TestParseOutputLine_systemLine_producesSystemEvent(t *testing.T) {
	line := []byte(`{"type":"system","subtype":"init","session_id":"ses1","model":"claude-opus-4-5"}`)
	evs := parseOutputLine("job-sys", line)
	if len(evs) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evs))
	}
	ev := evs[0]
	if ev.category != CatOutput {
		t.Errorf("category = %q, want %q", ev.category, CatOutput)
	}
	if ev.kind != TypeOutput {
		t.Errorf("kind = %q, want %q", ev.kind, TypeOutput)
	}
	d := decodeDetail(t, ev)
	if d["subtype"] != OutputSubtypeSystem {
		t.Errorf("subtype = %v, want %q", d["subtype"], OutputSubtypeSystem)
	}
	if d["session"] != "ses1" {
		t.Errorf("session = %v, want \"ses1\"", d["session"])
	}
	if d["model"] != "claude-opus-4-5" {
		t.Errorf("model = %v, want \"claude-opus-4-5\"", d["model"])
	}
}

func TestParseOutputLine_textLine_producesTextEvent(t *testing.T) {
	line := []byte(`{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}`)
	evs := parseOutputLine("job-txt", line)
	if len(evs) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evs))
	}
	d := decodeDetail(t, evs[0])
	if d["subtype"] != OutputSubtypeText {
		t.Errorf("subtype = %v, want %q", d["subtype"], OutputSubtypeText)
	}
	if d["text"] != "hello" {
		t.Errorf("text = %v, want \"hello\"", d["text"])
	}
}

func TestParseOutputLine_toolUseLine_producesToolUseEvent(t *testing.T) {
	line := []byte(`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"src/lib.rs"}}]}}`)
	evs := parseOutputLine("job-tu", line)
	if len(evs) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evs))
	}
	d := decodeDetail(t, evs[0])
	if d["subtype"] != OutputSubtypeToolUse {
		t.Errorf("subtype = %v, want %q", d["subtype"], OutputSubtypeToolUse)
	}
	if d["tool"] != "Edit" {
		t.Errorf("tool = %v, want \"Edit\"", d["tool"])
	}
	brief, _ := d["brief"].(string)
	if !strings.Contains(brief, "src/lib.rs") {
		t.Errorf("brief = %q does not contain \"src/lib.rs\"", brief)
	}
}

func TestParseOutputLine_toolResultLine_producesToolResultEvent(t *testing.T) {
	line := []byte(`{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"id1","is_error":false,"content":"ok"}]}}`)
	evs := parseOutputLine("job-tr", line)
	if len(evs) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evs))
	}
	d := decodeDetail(t, evs[0])
	if d["subtype"] != OutputSubtypeToolResult {
		t.Errorf("subtype = %v, want %q", d["subtype"], OutputSubtypeToolResult)
	}
	if d["is_error"] != false {
		t.Errorf("is_error = %v, want false", d["is_error"])
	}
	size, _ := d["size"].(float64)
	if size <= 0 {
		t.Errorf("size = %v, want >0", d["size"])
	}
	preview, _ := d["preview"].(string)
	if preview == "" {
		t.Errorf("preview is empty, want non-empty")
	}
}

func TestParseOutputLine_resultLine_producesResultEvent(t *testing.T) {
	line := []byte(`{"type":"result","subtype":"success","cost_usd":0.01,"duration_ms":1234}`)
	evs := parseOutputLine("job-res", line)
	if len(evs) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evs))
	}
	d := decodeDetail(t, evs[0])
	if d["subtype"] != OutputSubtypeResult {
		t.Errorf("subtype = %v, want %q", d["subtype"], OutputSubtypeResult)
	}
	costUSD, _ := d["cost_usd"].(float64)
	if costUSD != 0.01 {
		t.Errorf("cost_usd = %v, want 0.01", d["cost_usd"])
	}
	durMS, _ := d["duration_ms"].(float64)
	if durMS != 1234 {
		t.Errorf("duration_ms = %v, want 1234", d["duration_ms"])
	}
}

func TestParseOutputLine_bannerLine_producesNoEvents(t *testing.T) {
	line := []byte(`=== mother job abc123 ===`)
	evs := parseOutputLine("job-ban", line)
	if len(evs) != 0 {
		t.Errorf("expected 0 events for banner line, got %d", len(evs))
	}
}

func TestParseOutputLine_malformedJSON_producesNoEvents(t *testing.T) {
	line := []byte(`{not valid json`)
	evs := parseOutputLine("job-bad", line)
	if len(evs) != 0 {
		t.Errorf("expected 0 events for malformed JSON, got %d", len(evs))
	}
}

func TestParseOutputLine_emptyLine_producesNoEvents(t *testing.T) {
	evs := parseOutputLine("job-empty", []byte{})
	if len(evs) != 0 {
		t.Errorf("expected 0 events for empty line, got %d", len(evs))
	}
}

// =============================================================================
// B2 — No smuggled filesystem paths in tool_use event detail top-level fields
// =============================================================================

func TestParseOutputLine_toolUseLine_noTopLevelFilesystemPathField(t *testing.T) {
	// The file_path appears in the tool input but must NOT appear as a top-level
	// keyed field in the event detail. The path may appear inside the "brief"
	// display string (which is intentional display content), but there must be
	// no JSON field keyed "file_path" or any path-typed key at the top level of
	// the detail object.
	line := []byte(`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/Users/hammer/code/repo/src/main.go"}}]}}`)
	evs := parseOutputLine("job-b2", line)
	if len(evs) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evs))
	}
	var topLevel map[string]json.RawMessage
	if err := json.Unmarshal(evs[0].detail, &topLevel); err != nil {
		t.Fatalf("unmarshal detail: %v", err)
	}
	// No top-level key name should look like a path-typed field.
	// The implementation produces: subtype, tool, brief — none of which are
	// path-typed keys. "brief" is a display summary string, not a path field.
	forbiddenKeys := []string{"file_path", "path", "dir", "work_dir", "log_path"}
	for _, bad := range forbiddenKeys {
		if _, ok := topLevel[bad]; ok {
			t.Errorf("top-level field %q must not exist in event detail (B2 — no smuggled path fields)", bad)
		}
	}
	// The detail keys must be a subset of the known output event fields.
	allowedKeys := map[string]bool{"subtype": true, "tool": true, "brief": true}
	for k := range topLevel {
		if !allowedKeys[k] {
			t.Errorf("unexpected top-level field %q in tool_use event detail (B2)", k)
		}
	}
}

// =============================================================================
// Tool-result truncation
// =============================================================================

func TestParseOutputLine_toolResultTruncation_longContentTruncatesPreview(t *testing.T) {
	longContent := strings.Repeat("a", 2000)
	// Embed as a JSON string inside the tool_result content field.
	contentJSON, _ := json.Marshal(longContent)
	lineJSON := `{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"id1","is_error":false,"content":` + string(contentJSON) + `}]}}`
	evs := parseOutputLine("job-trunc", []byte(lineJSON))
	if len(evs) != 1 {
		t.Fatalf("expected 1 event, got %d", len(evs))
	}
	d := decodeDetail(t, evs[0])
	trunc, _ := d["truncated"].(bool)
	if !trunc {
		t.Errorf("truncated = %v, want true for 2000-char content", d["truncated"])
	}
	size, _ := d["size"].(float64)
	if size < 2000 {
		t.Errorf("size = %v, want >= 2000", size)
	}
	preview, _ := d["preview"].(string)
	if len([]rune(preview)) > 512 {
		t.Errorf("preview rune count = %d, want <= 512", len([]rune(preview)))
	}
}

// =============================================================================
// Per-job ordering via drainJob
// =============================================================================

func TestDrainJob_emitsRawEventsInFileOrder(t *testing.T) {
	tmp := t.TempDir()
	logsDir := filepath.Join(tmp, "logs")
	if err := os.MkdirAll(logsDir, 0o755); err != nil {
		t.Fatalf("mkdir logs: %v", err)
	}

	jobID := "job-order"
	logPath := filepath.Join(logsDir, jobID+".log")

	lines := []string{
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"first.go"}}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"second.go"}}]}}`,
		`{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"go build"}}]}}`,
	}
	content := strings.Join(lines, "\n") + "\n"
	if err := os.WriteFile(logPath, []byte(content), 0o644); err != nil {
		t.Fatalf("write log: %v", err)
	}

	// Inject a running job.
	jobsDir := filepath.Join(tmp, "jobs")
	if err := os.MkdirAll(jobsDir, 0o755); err != nil {
		t.Fatalf("mkdir jobs: %v", err)
	}
	jobJSON, _ := json.Marshal(map[string]any{"id": jobID, "state": "running"})
	if err := os.WriteFile(filepath.Join(jobsDir, jobID+".json"), jobJSON, 0o644); err != nil {
		t.Fatalf("write job: %v", err)
	}
	store := newJobStore(jobsDir)
	store.load()

	var collected []rawEvent
	src := newOutputSource(store, logsDir, 0, collectEmit(&collected), 10000)
	src.drainJob(jobID)

	if len(collected) != 3 {
		t.Fatalf("expected 3 events, got %d", len(collected))
	}
	// Events should be in file order: Read, Edit, Bash.
	toolNames := []string{"Read", "Edit", "Bash"}
	for i, ev := range collected {
		d := decodeDetail(t, ev)
		got, _ := d["tool"].(string)
		if got != toolNames[i] {
			t.Errorf("event[%d] tool = %q, want %q", i, got, toolNames[i])
		}
	}
}

// =============================================================================
// renderToolResult
// =============================================================================

func TestRenderToolResult_plainString_returnsPreview(t *testing.T) {
	raw, _ := json.Marshal("hello world")
	preview, size, truncated := renderToolResult(raw, 512)
	if preview != "hello world" {
		t.Errorf("preview = %q, want \"hello world\"", preview)
	}
	if size != len(raw) {
		t.Errorf("size = %d, want %d", size, len(raw))
	}
	if truncated {
		t.Errorf("truncated = true, want false")
	}
}

func TestRenderToolResult_arrayContent_returnsTextPreview(t *testing.T) {
	raw, _ := json.Marshal([]map[string]any{{"type": "text", "text": "hello"}})
	preview, _, truncated := renderToolResult(raw, 512)
	if preview != "hello" {
		t.Errorf("preview = %q, want \"hello\"", preview)
	}
	if truncated {
		t.Errorf("truncated = true, want false for short content")
	}
}

func TestRenderToolResult_longContent_truncatesToMaxRunes(t *testing.T) {
	long := strings.Repeat("x", 600)
	raw, _ := json.Marshal(long)
	preview, size, truncated := renderToolResult(raw, 512)
	if !truncated {
		t.Errorf("truncated = false, want true for 600-rune content")
	}
	if len([]rune(preview)) > 512 {
		t.Errorf("preview rune count = %d, want <= 512", len([]rune(preview)))
	}
	if size != len(raw) {
		t.Errorf("size = %d, want %d", size, len(raw))
	}
}
