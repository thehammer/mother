package workerproto

import "encoding/json"

// DefaultDedupeCap bounds the worker-side dedupe set.
const DefaultDedupeCap = 4096

// DedupeSet remembers recent cmd_ids so a redelivered command is applied at most once (MC-19).
// It is bounded: past the cap the oldest ids are forgotten. It serialises so a restarted worker
// keeps its history.
type DedupeSet struct {
	cap   int
	order []string
	set   map[string]struct{}
}

type dedupeJSON struct {
	Cap int      `json:"cap"`
	IDs []string `json:"ids"`
}

func NewDedupeSet(capacity int) *DedupeSet {
	if capacity < 1 {
		capacity = DefaultDedupeCap
	}
	return &DedupeSet{cap: capacity, set: map[string]struct{}{}}
}

// Seen reports whether id was already seen, and records it if not. The first call for an id
// returns false (apply it); later calls return true (reply cmd.ack duplicate).
func (d *DedupeSet) Seen(id string) bool {
	if _, ok := d.set[id]; ok {
		return true
	}
	d.set[id] = struct{}{}
	d.order = append(d.order, id)
	for len(d.order) > d.cap {
		delete(d.set, d.order[0])
		d.order = d.order[1:]
	}
	return false
}

// Len is the number of remembered ids.
func (d *DedupeSet) Len() int { return len(d.order) }

// Marshal serialises the set (oldest id first).
func (d *DedupeSet) Marshal() ([]byte, error) {
	return json.Marshal(dedupeJSON{Cap: d.cap, IDs: d.order})
}

// UnmarshalDedupeSet restores a set produced by Marshal.
func UnmarshalDedupeSet(b []byte) (*DedupeSet, error) {
	var j dedupeJSON
	if err := json.Unmarshal(b, &j); err != nil {
		return nil, protoErr(CodeInvalid, "dedupe set: %v", err)
	}
	d := NewDedupeSet(j.Cap)
	for _, id := range j.IDs {
		d.Seen(id)
	}
	return d, nil
}
