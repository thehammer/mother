package workerproto

import (
	"encoding/json"
	"sort"
)

// Pending is one sent-but-unacknowledged stream frame.
type Pending struct {
	Seq  int64           `json:"seq"`
	Type string          `json:"t"`
	Data json.RawMessage `json:"data"`
}

// OutStream is the worker's outbound side of one (job, lease) stream.
type OutStream struct {
	last   int64
	window []Pending
}

// NewOutStream starts a stream; the first frame gets seq 1.
func NewOutStream() *OutStream { return &OutStream{} }

// Append assigns the next seq and keeps the frame in the unacked window.
func (s *OutStream) Append(t string, data json.RawMessage) Pending {
	s.last++
	p := Pending{Seq: s.last, Type: t, Data: data}
	s.window = append(s.window, p)
	return p
}

// Ack trims every frame with seq <= n. An ack beyond the last sent seq is refused.
func (s *OutStream) Ack(n int64) error {
	if n > s.last {
		return protoErr(CodeInvalid, "ack %d beyond last sent seq %d", n, s.last)
	}
	i := 0
	for i < len(s.window) && s.window[i].Seq <= n {
		i++
	}
	s.window = s.window[i:]
	return nil
}

// Resend returns the whole unacked window, starting at the first unacked frame.
func (s *OutStream) Resend() []Pending { return append([]Pending(nil), s.window...) }

// ResendFrom returns the unacked frames with seq >= from (a coordinator gap request).
func (s *OutStream) ResendFrom(from int64) []Pending {
	i := sort.Search(len(s.window), func(i int) bool { return s.window[i].Seq >= from })
	return append([]Pending(nil), s.window[i:]...)
}

// Unacked is the number of frames in the window; Last is the last assigned seq.
func (s *OutStream) Unacked() int { return len(s.window) }
func (s *OutStream) Last() int64  { return s.last }

// Verdict is the inbound side's decision for a seq.
type Verdict int

const (
	// Apply: seq is exactly applied+1; the caller applies it.
	Apply Verdict = iota
	// Duplicate: seq was already applied or is already buffered; drop it.
	Duplicate
	// Gap: seq is ahead of applied+1; the caller buffers the payload and asks for ResendFrom.
	Gap
)

func (v Verdict) String() string {
	switch v {
	case Apply:
		return "apply"
	case Duplicate:
		return "duplicate"
	}
	return "gap"
}

// InStream is the coordinator's inbound side of one (job, lease) stream. It tracks seqs only; the
// caller holds buffered payloads. Persist Applied after each applied batch and restore with
// NewInStream.
type InStream struct {
	applied  int64
	buffered map[int64]bool
}

func NewInStream(applied int64) *InStream {
	return &InStream{applied: applied, buffered: map[int64]bool{}}
}

// Accept judges seq. On Apply it advances applied; on Gap it records seq as buffered.
func (s *InStream) Accept(seq int64) Verdict {
	switch {
	case seq <= s.applied:
		return Duplicate
	case seq == s.applied+1:
		s.applied = seq
		return Apply
	case s.buffered[seq]:
		return Duplicate
	}
	s.buffered[seq] = true
	return Gap
}

// Drain advances over buffered seqs that have become contiguous and returns them in order; the
// caller applies their payloads. Call it after an Apply.
func (s *InStream) Drain() []int64 {
	var out []int64
	for s.buffered[s.applied+1] {
		s.applied++
		delete(s.buffered, s.applied)
		out = append(out, s.applied)
	}
	return out
}

// Applied is the highest in-order seq applied (the value the next ack carries).
func (s *InStream) Applied() int64 { return s.applied }

// ResendFrom is the seq to request from the worker: applied+1.
func (s *InStream) ResendFrom() int64 { return s.applied + 1 }

// HasGap reports whether out-of-order frames are buffered.
func (s *InStream) HasGap() bool { return len(s.buffered) > 0 }
