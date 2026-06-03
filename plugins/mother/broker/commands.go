package main

// commands.go — command handlers (B4/B8).
//
// query.* are served from the in-memory jobstore. The three MUTATING commands
// (answer/cancel/retry) shell out to the existing `mother` CLI (B1): this
// routes every mutation through the one atomic state path, so the broker
// never writes job JSON and there is a single coherent ordering of changes.
// CLI exit/stderr is mapped to the closed B8 error enumeration.

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

type commandRunner struct {
	store     *jobStore
	cliPath   string // path to the `mother` executable
	eventsDir string
	extraEnv  []string // env to pass to the CLI (MOTHER_ROOT etc.)
}

// cmdResult is what a handler returns: on success payload is the ack data
// (ok:true is added by the caller); on failure code/msg describe the error.
type cmdResult struct {
	payload map[string]any
	code    string
	msg     string
}

func ok(payload map[string]any) cmdResult { return cmdResult{payload: payload} }
func fail(code, msg string) cmdResult     { return cmdResult{code: code, msg: msg} }

// runCLI executes `mother <args...>` with optional stdin, returning stdout,
// combined stderr, and the mapped error code ("" on success).
func (c *commandRunner) runCLI(stdin string, args ...string) (string, string, string) {
	cmd := exec.Command(c.cliPath, args...)
	cmd.Env = append(os.Environ(), c.extraEnv...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	err := cmd.Run()
	stderr := errBuf.String()
	if err != nil {
		return outBuf.String(), stderr, mapCLIError(stderr)
	}
	return outBuf.String(), stderr, ""
}

// mapCLIError translates a `mother` CLI stderr string into a B8 error code.
// The CLI exits 1 for all _die paths, so the code is inferred from the
// message text — but only against the closed enum, never surfaced raw.
func mapCLIError(stderr string) string {
	s := strings.ToLower(stderr)
	switch {
	case strings.Contains(s, "no such job"):
		return ErrNoSuchJob
	case strings.Contains(s, "expected awaiting"),
		strings.Contains(s, "expected running"),
		strings.Contains(s, "cannot cancel job in state"),
		strings.Contains(s, "can only retry"),
		strings.Contains(s, "is in state"),
		strings.Contains(s, "must be ready or queued"):
		return ErrInvalidState
	default:
		return ErrInternal
	}
}

// answer routes to `mother resume <job> -` with the text on stdin.
func (c *commandRunner) answer(job, text string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "answer: job required")
	}
	if text == "" {
		return fail(ErrMalformed, "answer: text required")
	}
	_, stderr, code := c.runCLI(text, "resume", job, "-")
	if code != "" {
		return fail(code, strings.TrimSpace(stderr))
	}
	return ok(map[string]any{"job": job})
}

// cancel routes to `mother cancel <job>`.
func (c *commandRunner) cancel(job string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "cancel: job required")
	}
	_, stderr, code := c.runCLI("", "cancel", job)
	if code != "" {
		return fail(code, strings.TrimSpace(stderr))
	}
	return ok(map[string]any{"job": job})
}

// forceStart routes to `mother force-start <job> --yes`.
func (c *commandRunner) forceStart(job string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "force-start: job required")
	}
	_, stderr, code := c.runCLI("", "force-start", job, "--yes")
	if code != "" {
		return fail(code, strings.TrimSpace(stderr))
	}
	return ok(map[string]any{"job": job})
}

// retry routes to `mother retry <job>`.
func (c *commandRunner) retry(job string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "retry: job required")
	}
	_, stderr, code := c.runCLI("", "retry", job)
	if code != "" {
		return fail(code, strings.TrimSpace(stderr))
	}
	return ok(map[string]any{"job": job})
}

// queryList serves the `mother list --format json` equivalent from memory.
func (c *commandRunner) queryList(f listFilter) cmdResult {
	records := c.store.list(f)
	jobs := make([]json.RawMessage, len(records))
	copy(jobs, records)
	return ok(map[string]any{"jobs": jobs})
}

// queryGet serves the `mother status --format json` equivalent: one job
// record plus its event history.
func (c *commandRunner) queryGet(job string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "query.get: job required")
	}
	raw, found := c.store.get(job)
	if !found {
		return fail(ErrNoSuchJob, "no such job: "+job)
	}
	events := c.readEvents(job)
	return ok(map[string]any{
		"job":    json.RawMessage(raw),
		"events": events,
	})
}

// readEvents loads a job's event history (in-band, as data — never a path).
func (c *commandRunner) readEvents(job string) []json.RawMessage {
	path := filepath.Join(c.eventsDir, job+".jsonl")
	b, err := os.ReadFile(path)
	if err != nil {
		return []json.RawMessage{}
	}
	out := []json.RawMessage{}
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if json.Valid([]byte(line)) {
			out = append(out, json.RawMessage(line))
		}
	}
	return out
}
