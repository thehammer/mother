package main

// attention.go — typed attention reasons (HC-03), computed as a pure read.
//
// attentionReasons mirrors lib/attention.sh's mother_attention_reasons_json:
// the closed-list union of the job's own `.attention[]` and (later, via the
// progress_updated overlay) progress flags, with `acked` resolved from
// $MOTHER_ROOT/acks/<id>.json. An ack applies only while its `since` equals
// the condition's current `since`. The broker never writes the acks file and
// never shells out for this.

import (
	"encoding/json"
	"os"
	"path/filepath"
)

// attentionReasonList is the closed set of attention reasons.
var attentionReasonList = map[string]bool{
	"progress_stalled":  true,
	"burn_ahead":        true,
	"gates_incomplete":  true,
	"decision_awaiting": true,
}

type attentionReason struct {
	Reason string `json:"reason"`
	Since  string `json:"since"`
	Acked  bool   `json:"acked"`
}

// attentionReasons returns [{reason, since, acked}] for a job record. Always a
// non-nil slice so it marshals as [] rather than null.
func attentionReasons(jobRaw json.RawMessage, acksDir string) []attentionReason {
	out := []attentionReason{}
	var job struct {
		ID        string `json:"id"`
		Attention []struct {
			Reason string `json:"reason"`
			Since  string `json:"since"`
		} `json:"attention"`
	}
	if json.Unmarshal(jobRaw, &job) != nil {
		return out
	}

	acks := map[string]struct {
		Since string `json:"since"`
	}{}
	if acksDir != "" && job.ID != "" {
		if b, err := os.ReadFile(filepath.Join(acksDir, job.ID+".json")); err == nil {
			_ = json.Unmarshal(b, &acks)
		}
	}

	seen := map[string]bool{}
	for _, a := range job.Attention {
		if !attentionReasonList[a.Reason] || seen[a.Reason] {
			continue
		}
		seen[a.Reason] = true
		ack, has := acks[a.Reason]
		out = append(out, attentionReason{Reason: a.Reason, Since: a.Since, Acked: has && ack.Since == a.Since})
	}
	return out
}

// withAttentionReasons adds the derived `attention_reasons` key to a job
// record's JSON. On any decode failure the record is returned untouched.
func withAttentionReasons(raw json.RawMessage, acksDir string) json.RawMessage {
	m := map[string]json.RawMessage{}
	if json.Unmarshal(raw, &m) != nil {
		return raw
	}
	b, err := json.Marshal(attentionReasons(raw, acksDir))
	if err != nil {
		return raw
	}
	m["attention_reasons"] = b
	out, err := json.Marshal(m)
	if err != nil {
		return raw
	}
	return out
}
