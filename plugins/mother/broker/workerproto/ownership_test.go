package workerproto

import (
	"encoding/json"
	"testing"
)

func raw(s string) json.RawMessage { return json.RawMessage(s) }

func TestCheckJobSet(t *testing.T) {
	ok := []struct {
		name string
		set  map[string]json.RawMessage
		del  []string
	}{
		{"pending_answer null", map[string]json.RawMessage{"pending_answer": raw("null")}, nil},
		{"worker keys", map[string]json.RawMessage{"pr_url": raw(`"u"`), "activity": raw(`"gating"`), "gates": raw(`{}`)}, []string{"limiter_hold"}},
		{"state running->awaiting", map[string]json.RawMessage{"state": raw(`"awaiting"`)}, nil},
		{"pending_answer delete", nil, []string{"pending_answer"}},
	}
	for _, c := range ok {
		if v := CheckJobSet(c.set, c.del); len(v) != 0 {
			t.Errorf("%s: unexpected %+v", c.name, v)
		}
	}
	bad := []struct {
		name string
		set  map[string]json.RawMessage
		del  []string
		key  string
	}{
		{"repo_path", map[string]json.RawMessage{"repo_path": raw(`"/x"`)}, nil, "repo_path"},
		{"cancel_requested", map[string]json.RawMessage{"cancel_requested": raw("true")}, nil, "cancel_requested"},
		{"pending_answer string", map[string]json.RawMessage{"pending_answer": raw(`"x"`)}, nil, "pending_answer"},
		{"state bogus", map[string]json.RawMessage{"state": raw(`"queued"`)}, nil, "state"},
		{"state non-string", map[string]json.RawMessage{"state": raw(`1`)}, nil, "state"},
		{"state delete", nil, []string{"state"}, "state"},
		{"tier", map[string]json.RawMessage{"current_tier": raw(`"tier_3"`)}, nil, "current_tier"},
		{"unknown", map[string]json.RawMessage{"zzz": raw("1")}, nil, "zzz"},
		{"delete coordinator key", nil, []string{"escalation_count"}, "escalation_count"},
	}
	for _, c := range bad {
		v := CheckJobSet(c.set, c.del)
		if len(v) != 1 || v[0].Key != c.key || v[0].Reason == "" {
			t.Errorf("%s: want one violation on %s, got %+v", c.name, c.key, v)
		}
	}
	if v := CheckJobSet(map[string]json.RawMessage{"repo_path": raw(`"x"`), "branch": raw(`"y"`)}, []string{"state"}); len(v) != 3 {
		t.Fatalf("all violations are reported: %+v", v)
	}
}

func TestTablesDoNotOverlap(t *testing.T) {
	for _, k := range SyncDownKeys {
		if contains(WorkerKeys, k) {
			t.Errorf("%s is both worker-owned and coordinator-owned", k)
		}
	}
	if contains(WorkerKeys, "state") || contains(WorkerKeys, "pending_answer") {
		t.Error("state and pending_answer are special-cased, not plain worker keys")
	}
}
