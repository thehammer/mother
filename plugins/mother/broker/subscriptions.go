package main

// subscriptions.go — the per-connection subscription model (B4).
//
// A single connection may hold multiple independent named subscriptions
// (e.g. Nostromo's "queue view" + "focused job detail"). Each subscription
// has a client-chosen name and a selector: which jobs and which categories.
// Selection is server-side from day one — never a firehose (the floor the
// remote case needs).

import (
	"encoding/json"
	"sort"
)

// subscription is one named view on one connection.
type subscription struct {
	name       string
	allJobs    bool            // true when jobs includes "all" (or is empty)
	jobs       map[string]bool // explicit job-id allow-set
	categories map[string]bool // category allow-set
}

// subscribeArgs is the data payload of a `subscribe` command.
type subscribeArgs struct {
	Sub        string   `json:"sub"`
	Jobs       []string `json:"jobs"`
	Categories []string `json:"categories"`
}

// unsubscribeArgs is the data payload of an `unsubscribe` command.
type unsubscribeArgs struct {
	Sub string `json:"sub"`
}

// newSubscription builds a subscription from a subscribe command's args.
// An empty or ["all"] jobs list means all jobs. An empty categories list is
// rejected by the caller (a subscription with no categories is meaningless).
func newSubscription(a subscribeArgs) *subscription {
	s := &subscription{
		name:       a.Sub,
		jobs:       map[string]bool{},
		categories: map[string]bool{},
	}
	if len(a.Jobs) == 0 {
		s.allJobs = true
	}
	for _, j := range a.Jobs {
		if j == "all" {
			s.allJobs = true
			continue
		}
		s.jobs[j] = true
	}
	for _, c := range a.Categories {
		s.categories[c] = true
	}
	return s
}

// matches reports whether an event should be delivered to this subscription.
func (s *subscription) matches(ev rawEvent) bool {
	if !s.categories[ev.category] {
		return false
	}
	if s.allJobs {
		return true
	}
	return s.jobs[ev.jobID]
}

// selectedJobIDs returns the explicit job ids for snapshot scoping, or nil
// when the subscription covers all jobs (caller enumerates the store).
func (s *subscription) selectedJobIDs() []string {
	if s.allJobs {
		return nil
	}
	out := make([]string, 0, len(s.jobs))
	for id := range s.jobs {
		out = append(out, id)
	}
	sort.Strings(out)
	return out
}

// validCategories reports whether every requested category is one this W1
// broker can deliver. Unknown/absent categories (e.g. "output" in W1) make
// the subscribe a malformed request.
func validCategories(cats []string) bool {
	if len(cats) == 0 {
		return false
	}
	allowed := map[string]bool{}
	for _, c := range w1Categories {
		allowed[c] = true
	}
	for _, c := range cats {
		if !allowed[c] {
			return false
		}
	}
	return true
}

// mergeData builds an event/snapshot data object: the original event detail
// with `job` and `category` injected. Detail must be a JSON object (or empty).
func mergeData(detail json.RawMessage, fields map[string]any) json.RawMessage {
	m := map[string]json.RawMessage{}
	if len(detail) > 0 {
		_ = json.Unmarshal(detail, &m)
	}
	for k, v := range fields {
		b, _ := json.Marshal(v)
		m[k] = b
	}
	out, _ := json.Marshal(m)
	return out
}
