package main

// commands.go — command handlers (B4/B8).
//
// query.* are served from the in-memory jobstore. The three MUTATING commands
// (answer/cancel/retry) shell out to the existing `mother` CLI (B1): this
// routes every mutation through the one atomic state path, so the broker
// never writes job JSON and there is a single coherent ordering of changes.
// CLI exit/stderr is mapped to the closed B8 error enumeration.

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

type commandRunner struct {
	store     *jobStore
	cliPath   string // path to the `mother` executable
	eventsDir string
	extraEnv  []string // env to pass to the CLI (MOTHER_ROOT etc.)
	acksDir   string   // $MOTHER_ROOT/acks — read-only, for attention_reasons

	quotaTimeout time.Duration // bound on `quota status --json`; 0 = defaultQuotaTimeout
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
	return c.runCLIContext(context.Background(), stdin, args...)
}

// runCLIContext is runCLI with a deadline/cancellation: a timed-out CLI is
// killed and reported as a failure.
func (c *commandRunner) runCLIContext(ctx context.Context, stdin string, args ...string) (string, string, string) {
	cmd := exec.CommandContext(ctx, c.cliPath, args...)
	cmd.Env = append(os.Environ(), c.extraEnv...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var outBuf, errBuf strings.Builder
	cmd.Stdout = &outBuf
	cmd.Stderr = &errBuf
	cmd.WaitDelay = time.Second
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
	case strings.Contains(s, "no_reset_known"):
		return ErrNoResetKnown
	case strings.Contains(s, "refused"):
		return ErrUnauthorized
	case strings.Contains(s, "invalid_state:"):
		return ErrInvalidState
	case strings.Contains(s, "unknown reason"):
		return ErrMalformed
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

// answer routes to `mother resume <job> [--option <o>] --source <s> -` with
// the text (possibly empty when an option is chosen) on stdin. The source is
// forwarded only when it is "nostromo_app"; every other client is recorded as
// "broker_client". Old clients that send text only keep working: no option
// means resume_with_guidance on a decision, and plain resume otherwise.
func (c *commandRunner) answer(job, text, option, source string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "answer: job required")
	}
	if text == "" && option == "" {
		return fail(ErrMalformed, "answer: text or option required")
	}
	src := "broker_client"
	if source == "nostromo_app" {
		src = source
	}
	args := []string{"resume", job}
	if option != "" {
		args = append(args, "--option", option)
	}
	args = append(args, "--source", src, "-")
	_, stderr, code := c.runCLI(text, args...)
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

// ack routes to `mother ack <job> <reason> --source <s>`. An empty source is
// recorded as broker_client; the CLI validates the closed source list.
func (c *commandRunner) ack(job, reason, source string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "ack: job required")
	}
	if reason == "" {
		return fail(ErrMalformed, "ack: reason required")
	}
	if source == "" {
		source = "broker_client"
	}
	_, stderr, code := c.runCLI("", "ack", job, reason, "--source", source)
	if code != "" {
		return fail(code, strings.TrimSpace(stderr))
	}
	return ok(map[string]any{"job": job, "reason": reason})
}

// quotaGateStates maps the wire states to the `mother quota` subcommands.
var quotaGateStates = map[string]string{
	"on":              "on",
	"off":             "off",
	"off_until_reset": "off-until-reset",
}

// defaultQuotaTimeout bounds the `mother quota status --json` shell-out so a
// hung CLI cannot block a subscribe or the quota watcher.
const defaultQuotaTimeout = 5 * time.Second

// quotaBlock returns `mother quota status --json` (the snapshot's `quota`
// block, shape documented by tests/fixtures/quota_block.json), or nil when
// the CLI cannot produce it.
func (c *commandRunner) quotaBlock() json.RawMessage {
	timeout := c.quotaTimeout
	if timeout <= 0 {
		timeout = defaultQuotaTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, _, code := c.runCLIContext(ctx, "", "quota", "status", "--json")
	out = strings.TrimSpace(out)
	if code != "" || !json.Valid([]byte(out)) {
		return nil
	}
	return json.RawMessage(out)
}

// limiterBlock returns `mother limiter status --json` (the snapshot's `limiter`
// block, shape documented by tests/fixtures/limiter_block.json), or nil when the
// CLI cannot produce it. Bounded like quotaBlock.
func (c *commandRunner) limiterBlock() json.RawMessage {
	timeout := c.quotaTimeout
	if timeout <= 0 {
		timeout = defaultQuotaTimeout
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	out, _, code := c.runCLIContext(ctx, "", "limiter", "status", "--json")
	out = strings.TrimSpace(out)
	if code != "" || !json.Valid([]byte(out)) {
		return nil
	}
	return json.RawMessage(out)
}

// quotaGate routes to `mother quota <state> --source broker:<origin>`. The CLI
// is the single writer and audits the change (who, from, to, when); setting
// the current state again is a no-op that still replies ok.
func (c *commandRunner) quotaGate(state, origin string) cmdResult {
	sub, known := quotaGateStates[state]
	if !known {
		return fail(ErrMalformed, "quota-gate: state must be one of on, off, off_until_reset")
	}
	origin = sanitizeOrigin(origin)
	stdout, stderr, code := c.runCLI("", "quota", sub, "--source", "broker:"+origin)
	if code != "" {
		return fail(code, strings.TrimSpace(stderr))
	}
	// The ack reports the STORED state, read back, never an echo of the request.
	q := c.quotaBlock()
	if q == nil {
		return fail(ErrInternal, "quota-gate: the change was applied but the stored state could not be read back")
	}
	var blk struct {
		Gate string `json:"gate"`
	}
	if json.Unmarshal(q, &blk) != nil || blk.Gate == "" {
		return fail(ErrInternal, "quota-gate: the stored state could not be read back")
	}
	payload := map[string]any{"state": blk.Gate, "quota": q}
	// A no-op ("quota gate already off") is worth telling the client; an
	// ordinary change is already visible in the stored state.
	if note := strings.TrimSpace(stdout); strings.Contains(note, "already") || strings.Contains(note, "unchanged") {
		payload["note"] = note
	}
	return ok(payload)
}

// sanitizeOrigin keeps an audit "who" to a short, printable token.
func sanitizeOrigin(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '.' || r == '_' || r == '-' {
			b.WriteRune(r)
		}
		if b.Len() >= 64 {
			break
		}
	}
	if b.Len() == 0 {
		return "client"
	}
	return b.String()
}

// queryList serves the `mother list --format json` equivalent from memory.
func (c *commandRunner) queryList(f listFilter) cmdResult {
	c.store.pruneMissing()
	records := c.store.list(f)
	jobs := make([]json.RawMessage, len(records))
	for i, r := range records {
		jobs[i] = withAttentionReasons(r, c.acksDir)
	}
	return ok(map[string]any{"jobs": jobs})
}

// queryGet serves the `mother status --format json` equivalent: one job
// record plus its event history.
func (c *commandRunner) queryGet(job string) cmdResult {
	if job == "" {
		return fail(ErrMalformed, "query.get: job required")
	}
	c.store.pruneMissingID(job)
	raw, found := c.store.get(job)
	if !found {
		return fail(ErrNoSuchJob, "no such job: "+job)
	}
	events := c.readEvents(job)
	return ok(map[string]any{
		"job":    withAttentionReasons(raw, c.acksDir),
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
