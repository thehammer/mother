package workerproto

import "encoding/json"

// DefaultDedupeCap bounds the worker-side dedupe set. It is the dedupe horizon: DedupeSet forgets ids
// older than the most recent DedupeHorizon. A command redelivered after that would be applied twice,
// so the coordinator never redelivers one that old (CmdOutbox enforces it) and a worker must treat a
// command it can no longer dedupe as undeliverable, not as new.
const (
	DefaultDedupeCap = 4096
	DedupeHorizon    = DefaultDedupeCap
)

// CmdOutbox is the coordinator's per-worker record of commands it issued and has not seen acked. It
// enforces the horizon: a command is redeliverable only while fewer than DedupeHorizon newer commands
// have been issued to that worker; older ones are dropped (the coordinator applies the effect directly
// when the job's lease moves).
type CmdOutbox struct {
	n       int64
	pending map[string]int64
}

func NewCmdOutbox() *CmdOutbox { return &CmdOutbox{pending: map[string]int64{}} }

// Issue records a newly sent command.
func (o *CmdOutbox) Issue(id string) { o.n++; o.pending[id] = o.n }

// Ack forgets a command the worker acknowledged.
func (o *CmdOutbox) Ack(id string) { delete(o.pending, id) }

// Redeliverable reports whether id is unacked and still inside the dedupe horizon.
func (o *CmdOutbox) Redeliverable(id string) bool {
	at, ok := o.pending[id]
	return ok && o.n-at < DedupeHorizon
}

// Expire drops unacked commands that fell out of the horizon and returns their ids (oldest first
// is not guaranteed). Call it before redelivering on reconnect.
func (o *CmdOutbox) Expire() []string {
	var out []string
	for id, at := range o.pending {
		if o.n-at >= DedupeHorizon {
			out = append(out, id)
			delete(o.pending, id)
		}
	}
	return out
}

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
