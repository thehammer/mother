package main

// activity.go — derives the `current_activity` signal (B6) by tailing a
// running worker's Claude transcript, the same file `mother peek` parses.
//
// This is a straight port of cmd_peek's transcript resolution (slug the
// work_dir, find ~/.claude/projects/<slug>/<session_id>.jsonl) and its
// tool-trail brief. On each new tool_use the broker emits a current_activity
// event carrying the rendered string (e.g. "Edit: src/lib.rs") — a PUSHED
// value, retiring the polled worker-current-activity FR with no client-side
// file I/O.

import (
	"bytes"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

// jobActivityFields are the job-record fields needed to locate a transcript.
type jobActivityFields struct {
	State     string `json:"state"`
	WorkDir   string `json:"work_dir"`
	RepoPath  string `json:"repo_path"`
	Branch    string `json:"branch"`
	Isolation string `json:"isolation"`
	SessionID string `json:"session_id"`
}

// resolveWorkDir mirrors cmd_peek: prefer the recorded work_dir, else derive
// it from repo_path/branch/isolation. Returns "" if unresolvable.
func resolveWorkDir(j jobActivityFields) string {
	if j.WorkDir != "" {
		return j.WorkDir
	}
	if j.Isolation == "main-dir" && j.RepoPath != "" {
		return j.RepoPath
	}
	if j.RepoPath != "" && j.Branch != "" {
		return j.RepoPath + "-" + strings.ReplaceAll(j.Branch, "/", "-")
	}
	return ""
}

// resolveTranscript returns the transcript path for a job, or ("", false).
// Claude slugs a path by replacing both '/' and '.' with '-'.
func resolveTranscript(j jobActivityFields, projectsDir string) (string, bool) {
	workDir := resolveWorkDir(j)
	if workDir == "" {
		return "", false
	}
	slug := strings.ReplaceAll(workDir, "/", "-")
	slug = strings.ReplaceAll(slug, ".", "-")
	projectDir := filepath.Join(projectsDir, slug)
	if j.SessionID != "" {
		t := filepath.Join(projectDir, j.SessionID+".jsonl")
		if fileExists(t) {
			return t, true
		}
		return "", false
	}
	// Legacy fallback: newest .jsonl in the project dir.
	entries, err := os.ReadDir(projectDir)
	if err != nil {
		return "", false
	}
	var newest string
	var newestMod time.Time
	for _, e := range entries {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".jsonl") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if newest == "" || info.ModTime().After(newestMod) {
			newest = filepath.Join(projectDir, e.Name())
			newestMod = info.ModTime()
		}
	}
	if newest == "" {
		return "", false
	}
	return newest, true
}

func fileExists(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

// brief renders a one-line summary of a tool_use input, matching cmd_peek:
// first present of file_path/path/pattern/command/description, newlines
// collapsed, trimmed to 110 chars.
func brief(input map[string]json.RawMessage) string {
	for _, k := range []string{"file_path", "path", "pattern", "command", "description"} {
		raw, ok := input[k]
		if !ok {
			continue
		}
		var v string
		if json.Unmarshal(raw, &v) != nil || v == "" {
			continue
		}
		v = strings.ReplaceAll(v, "\n", " ⏎ ")
		return truncateRunes(v, 110)
	}
	return ""
}

func truncateRunes(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n])
}

// render turns a tool name + input into the current_activity string.
func renderActivity(tool string, input map[string]json.RawMessage) string {
	b := brief(input)
	if b == "" {
		return tool
	}
	return tool + ": " + b
}

// transcriptLine is the minimal schema of a Claude transcript JSONL line.
type transcriptLine struct {
	Type    string `json:"type"`
	Message struct {
		Content []struct {
			Type  string                     `json:"type"`
			Name  string                     `json:"name"`
			Input map[string]json.RawMessage `json:"input"`
		} `json:"content"`
	} `json:"message"`
}

// activityWatcher polls running jobs' transcripts and emits current_activity.
type activityWatcher struct {
	store       *jobStore
	projectsDir string
	interval    time.Duration
	emit        func(rawEvent)

	mu      sync.Mutex
	offsets map[string]int64 // transcript path → consumed byte offset
}

func newActivityWatcher(store *jobStore, projectsDir string, interval time.Duration, emit func(rawEvent)) *activityWatcher {
	return &activityWatcher{
		store:       store,
		projectsDir: projectsDir,
		interval:    interval,
		emit:        emit,
		offsets:     map[string]int64{},
	}
}

// run polls until done is closed.
func (a *activityWatcher) run(done <-chan struct{}) {
	t := time.NewTicker(a.interval)
	defer t.Stop()
	for {
		select {
		case <-done:
			return
		case <-t.C:
			a.tick()
		}
	}
}

// tick scans running jobs and emits a current_activity event for any whose
// transcript has a new tool_use since the last scan.
func (a *activityWatcher) tick() {
	for _, raw := range a.store.list(listFilter{state: "running"}) {
		var j jobActivityFields
		if json.Unmarshal(raw, &j) != nil {
			continue
		}
		var id struct {
			ID string `json:"id"`
		}
		_ = json.Unmarshal(raw, &id)
		path, ok := resolveTranscript(j, a.projectsDir)
		if !ok {
			continue
		}
		if act, ok := a.latestActivity(path); ok && act != "" {
			detail, _ := json.Marshal(map[string]any{"current_activity": act})
			a.emit(rawEvent{
				category: CatCurrentActivity,
				jobID:    id.ID,
				kind:     TypeCurrentActivity,
				ts:       isoNow(),
				detail:   detail,
			})
		}
	}
}

// latestActivity reads transcript bytes appended since the last scan and, if
// any new assistant tool_use appears, returns the rendered string for the
// most recent one.
func (a *activityWatcher) latestActivity(path string) (string, bool) {
	a.mu.Lock()
	off := a.offsets[path]
	a.mu.Unlock()

	f, err := os.Open(path)
	if err != nil {
		return "", false
	}
	defer f.Close()
	if _, err := f.Seek(off, 0); err != nil {
		return "", false
	}
	rest, err := io.ReadAll(f)
	if err != nil || len(rest) == 0 {
		return "", false
	}
	lastNL := bytes.LastIndexByte(rest, '\n')
	if lastNL < 0 {
		return "", false
	}
	complete := rest[:lastNL]

	var latest string
	var found bool
	for _, line := range bytes.Split(complete, []byte{'\n'}) {
		line = bytes.TrimSpace(line)
		if len(line) == 0 {
			continue
		}
		var tl transcriptLine
		if json.Unmarshal(line, &tl) != nil {
			continue
		}
		if tl.Type != "assistant" {
			continue
		}
		for _, c := range tl.Message.Content {
			if c.Type == "tool_use" {
				name := c.Name
				if name == "" {
					name = "?"
				}
				latest = renderActivity(name, c.Input)
				found = true
			}
		}
	}

	a.mu.Lock()
	a.offsets[path] = off + int64(lastNL) + 1
	a.mu.Unlock()

	return latest, found
}
