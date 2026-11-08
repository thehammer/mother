package workerproto

import (
	"bytes"
	"encoding/json"
	"sort"
)

// The B10 field table: which job keys a worker may set or delete (WorkerKeys), which flow from the
// coordinator to the worker with sync.job (SyncDownKeys), and the special cases. Everything else is
// coordinator-owned; unknown keys are refused so a new field is a deliberate table edit, not an
// accident. P1-2's inventory of what mother-run-job writes extends WorkerKeys.
var (
	// WorkerKeys are job keys the supervisor/worker side writes during its lease.
	WorkerKeys = []string{
		"activity", "session_id", "worker_pid", "pr_url", "actual_branch", "paused_reason", "paused_at",
		"question", "final_result_at", "finished_at", "started_at", "continuation_count",
		"resume_not_yet_acted_on", "gates", "review_wave", "limiter_hold", "live_cost_usd", "live_tokens",
		"current_run", "cost_cap_breached_at", "token_alert_at", "failure_reason", "exit_code",
		"rwx_sandbox", "resume_session_id", "resume_kind", "limiter_resume_prompt", "attention", "decision",
	}
	// SyncDownKeys flow coordinator to worker with sync.job.
	SyncDownKeys = []string{"cancel_requested", "pause_requested", "pending_answer", "max_cost_usd", "force_start"}
	// StateValues are the values of "state" a worker may set within its lease.
	StateValues = []string{"running", "awaiting", "succeeded", "failed", "cancelled"}
)

// Violation is one refused key in a job.set.
type Violation struct {
	Key    string
	Reason string
}

// CheckJobSet returns every ownership violation in a job.set payload (nil when clean).
// Rules: WorkerKeys may be set or deleted; "state" may be set to a StateValues value but not
// deleted; "pending_answer" may only be set to null (or deleted: both clear it); any other key,
// including every coordinator-owned or SyncDownKeys key, is a violation.
func CheckJobSet(set map[string]json.RawMessage, del []string) []Violation {
	var vs []Violation
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if r := checkSet(k, set[k]); r != "" {
			vs = append(vs, Violation{Key: k, Reason: r})
		}
	}
	for _, k := range del {
		if r := checkDel(k); r != "" {
			vs = append(vs, Violation{Key: k, Reason: r})
		}
	}
	return vs
}

func checkSet(k string, v json.RawMessage) string {
	switch k {
	case "state":
		var s string
		if json.Unmarshal(v, &s) != nil || !contains(StateValues, s) {
			return "state must be one of running|awaiting|succeeded|failed|cancelled"
		}
		return ""
	case "pending_answer":
		if !bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
			return "pending_answer may only be set to null by a worker"
		}
		return ""
	}
	if contains(WorkerKeys, k) {
		return ""
	}
	if contains(SyncDownKeys, k) {
		return "coordinator-owned (flows down with sync.job)"
	}
	return "not worker-settable"
}

func checkDel(k string) string {
	switch k {
	case "state":
		return "state cannot be deleted"
	case "pending_answer":
		return ""
	}
	if contains(WorkerKeys, k) {
		return ""
	}
	return "not worker-deletable"
}
