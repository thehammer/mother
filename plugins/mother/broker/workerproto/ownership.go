package workerproto

import (
	"bytes"
	"encoding/json"
	"math"
	"sort"
)

// The B10 field table: which job keys a worker may set or delete (WorkerKeys), which are derived by
// the coordinator from evidence and so refused from a worker (CoordinatorDerivedKeys), which flow from
// the coordinator to the worker with sync.job (SyncDownKeys), and the special cases. Everything else
// is coordinator-owned; unknown keys are refused so a new field is a deliberate table edit, not an
// accident. P1-2's inventory of what mother-run-job writes extends WorkerKeys.
var (
	// WorkerKeys are job keys the supervisor/worker side writes during its lease. Each has a kind and
	// bound in keyKinds.
	WorkerKeys = []string{
		"activity", "session_id", "worker_pid", "paused_reason", "paused_at",
		"question", "final_result_at", "started_at", "continuation_count",
		"resume_not_yet_acted_on", "gates", "review_wave", "limiter_hold", "live_cost_usd", "live_tokens",
		"current_run", "cost_cap_breached_at", "token_alert_at",
		"rwx_sandbox", "resume_session_id", "resume_kind", "limiter_resume_prompt", "attention", "decision",
		"attempt_run",
		// The pre-ready adherence review (`mother adherence-review --pre-ready`, run by the wave under the worker's
		// supervisor) records its verdict on the job: a legacy run leaves these on the job, so a worker run must too.
		"adherence_status", "adherence_attempts", "adherence_pending", "adherence_notes", "adherence_sha_runs", "adherence_reviewed_sha",
	}
	// CoordinatorDerivedKeys are completion evidence. A worker can claim anything here, so none of it is
	// accepted from job.set: the coordinator writes these itself, after its own remote-commit/PR check
	// (P1-5), from the pushed head the worker reports in lease.release{final_sha}. A worker that sends
	// one gets refuse{ownership}.
	CoordinatorDerivedKeys = []string{"pr_url", "actual_branch", "finished_at", "exit_code", "failure_reason"}
	// SyncDownKeys flow coordinator to worker with sync.job.
	SyncDownKeys = []string{"cancel_requested", "pause_requested", "pending_answer", "max_cost_usd", "force_start"}
	// StateValues are the values of "state" a worker may set within its lease. "succeeded" is absent
	// on purpose: the coordinator derives it (P1-5) and a worker can never claim it.
	StateValues = []string{"running", "awaiting", "failed", "cancelled"}
)

// JobState is what the coordinator knows of the job now, so a transition can be judged.
type JobState struct {
	State           string // the job's current "state" ("" when unknown)
	CancelRequested bool
}

func terminalState(s string) bool { return s == "succeeded" || s == "failed" || s == "cancelled" }

// Violation is one refused key in a job.set. Code is ownership (the key or transition is not the
// worker's) or invalid (the value's kind or size is wrong).
type Violation struct {
	Key    string
	Reason string
	Code   string
}

type valKind int

const (
	kText valKind = iota // bounded text
	kToken
	kID
	kTS
	kUint // non-negative integer
	kNum  // non-negative number
	kBool
	kObject
	kArray
)

var keyKinds = map[string]valKind{
	"activity": kToken, "session_id": kID, "worker_pid": kUint, "paused_reason": kToken, "paused_at": kTS,
	"question": kText, "final_result_at": kTS, "started_at": kTS, "continuation_count": kUint,
	"resume_not_yet_acted_on": kBool, "gates": kObject, "review_wave": kObject, "limiter_hold": kObject,
	"live_cost_usd": kNum, "live_tokens": kUint, "current_run": kObject, "cost_cap_breached_at": kTS,
	"token_alert_at": kTS, "rwx_sandbox": kObject, "resume_session_id": kID, "resume_kind": kToken,
	"limiter_resume_prompt": kText, "attention": kArray, "decision": kObject,
	"attempt_run":      kObject,
	"adherence_status": kToken, "adherence_attempts": kUint, "adherence_pending": kBool, "adherence_notes": kText,
	"adherence_sha_runs": kUint, "adherence_reviewed_sha": kID,
}

// CheckJobSet returns every violation in a job.set payload (nil when clean), judged against the job's
// current state: the static rules of Validate plus the transition rules.
// Rules: WorkerKeys may be set (null clears) or deleted, within their kind and size bounds; "state" may
// be set to running, awaiting, failed or cancelled but never deleted, never to succeeded (coordinator
// derived), never out of a terminal state, and never to running once a cancel is requested;
// CoordinatorDerivedKeys, SyncDownKeys and unknown keys are refused; "pending_answer" may only be set
// to null (or deleted).
func CheckJobSet(cur JobState, set map[string]json.RawMessage, del []string) []Violation {
	vs := checkJobSetStatic(set, del)
	if v, ok := set["state"]; ok {
		var s string
		if json.Unmarshal(v, &s) == nil && contains(StateValues, s) {
			switch {
			case terminalState(cur.State) && s != cur.State:
				vs = append(vs, Violation{"state", "cannot leave terminal state " + cur.State, CodeOwnership})
			case s == "running" && (cur.CancelRequested || cur.State == "cancelled"):
				vs = append(vs, Violation{"state", "cannot resume running after a cancel", CodeOwnership})
			}
		}
	}
	sort.SliceStable(vs, func(i, j int) bool { return vs[i].Key < vs[j].Key })
	return vs
}

// checkJobSetStatic is the part of the ownership check that needs no job state; Validate applies it so
// a job.set that could never be accepted is refused at the door.
func checkJobSetStatic(set map[string]json.RawMessage, del []string) []Violation {
	var vs []Violation
	keys := make([]string, 0, len(set))
	for k := range set {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if code, r := checkSet(k, set[k]); r != "" {
			vs = append(vs, Violation{Key: k, Reason: r, Code: code})
		}
	}
	for _, k := range del {
		if r := checkDel(k); r != "" {
			vs = append(vs, Violation{Key: k, Reason: r, Code: CodeOwnership})
		}
	}
	return vs
}

func checkSet(k string, v json.RawMessage) (code, reason string) {
	switch k {
	case "state":
		var s string
		if json.Unmarshal(v, &s) != nil || !contains(StateValues, s) {
			return CodeOwnership, "state must be one of running|awaiting|failed|cancelled (succeeded is coordinator-derived)"
		}
		return "", ""
	case "pending_answer":
		if !bytes.Equal(bytes.TrimSpace(v), []byte("null")) {
			return CodeOwnership, "pending_answer may only be set to null by a worker"
		}
		return "", ""
	}
	if contains(WorkerKeys, k) {
		if r := checkKind(keyKinds[k], v); r != "" {
			return CodeInvalid, r
		}
		return "", ""
	}
	if contains(CoordinatorDerivedKeys, k) {
		return CodeOwnership, "coordinator-derived completion evidence"
	}
	if contains(SyncDownKeys, k) {
		return CodeOwnership, "coordinator-owned (flows down with sync.job)"
	}
	return CodeOwnership, "not worker-settable"
}

func checkKind(kind valKind, v json.RawMessage) string {
	t := bytes.TrimSpace(v)
	if string(t) == "null" {
		return ""
	}
	if len(t) == 0 {
		return "empty value"
	}
	switch kind {
	case kText, kToken, kID, kTS:
		var s string
		if json.Unmarshal(t, &s) != nil {
			return "must be a string"
		}
		ok := false
		switch kind {
		case kText:
			ok = textOK(s, MaxTextLen)
		case kToken:
			ok = tokenRe.MatchString(s)
		case kID:
			ok = IDOK(s)
		case kTS:
			ok = len(s) <= 64 && textOK(s, 64) && s != ""
		}
		if !ok {
			return "string is malformed or too long"
		}
	case kUint:
		var n int64
		if json.Unmarshal(t, &n) != nil || n < 0 {
			return "must be a non-negative integer"
		}
	case kNum:
		var n float64
		if json.Unmarshal(t, &n) != nil || n < 0 || math.IsNaN(n) || math.IsInf(n, 0) {
			return "must be a non-negative number"
		}
	case kBool:
		if string(t) != "true" && string(t) != "false" {
			return "must be a boolean"
		}
	case kObject, kArray:
		open := byte('{')
		if kind == kArray {
			open = '['
		}
		if t[0] != open || len(t) > MaxStructBytes {
			return "must be an object/array of at most 64 KiB"
		}
	}
	return ""
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
