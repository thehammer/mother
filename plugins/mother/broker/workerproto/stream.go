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

// Full reports whether the unacked window has reached MaxWindow: the worker must stop sending until
// an ack trims it (the coordinator answers frames beyond the window with refuse{too_large}).
func (s *OutStream) Full() bool { return len(s.window) >= MaxWindow }

// Unacked is the number of frames in the window; Last is the last assigned seq.
func (s *OutStream) Unacked() int { return len(s.window) }
func (s *OutStream) Last() int64  { return s.last }

// Inbound limits (spec section 6). A worker may have at most MaxWindow frames in flight; the
// coordinator buffers at most MaxBufferedBytes of payload ahead of applied_seq per stream.
const (
	MaxWindow        = 1024
	MaxBufferedBytes = 8 << 20
)

// Verdict is the inbound side's decision for a seq.
type Verdict int

const (
	// Apply: seq is exactly applied+1; the caller applies it, persists applied_seq, then calls Commit.
	Apply Verdict = iota
	// Duplicate: seq was already applied or is already buffered; drop it (still ack).
	Duplicate
	// Gap: seq is ahead of applied+1 within the window; the caller buffers the payload and asks for ResendFrom.
	Gap
	// TooFar: seq is beyond applied+MaxWindow, or buffering it would exceed MaxBufferedBytes. Nothing was
	// recorded; the caller answers refuse{too_large} (the worker must resend from applied+1).
	TooFar
	// Invalid: seq <= 0. Answer refuse{invalid}.
	Invalid
)

func (v Verdict) String() string {
	switch v {
	case Apply:
		return "apply"
	case Duplicate:
		return "duplicate"
	case Gap:
		return "gap"
	case TooFar:
		return "too_far"
	}
	return "invalid"
}

// InStream is the coordinator's inbound side of one (job, lease) stream. It tracks seqs and the size
// of buffered payloads; the caller holds the payloads. Exactly-once order is apply, persist, ack:
//
//	Accept(seq, size) == Apply  ->  apply the frame, persist applied_seq = seq, Commit(seq), then ack.
//
// Accept never advances applied by itself, so a frame is not reported applied before the caller
// confirms it. After a crash between apply and persist, NewInStream(persisted) simply judges the same
// seq Apply again and the idempotent apply (spec section 6) absorbs the replay; buffered out-of-order
// frames are lost on restart and come back when the worker resends from ResendFrom. One frame at a
// time per stream: do not Accept again until the previous Apply is committed.
type InStream struct {
	applied  int64
	buffered map[int64]int // seq -> payload bytes
	bytes    int
}

func NewInStream(applied int64) *InStream {
	return &InStream{applied: applied, buffered: map[int64]int{}}
}

// Accept judges seq (size is the payload length, charged against MaxBufferedBytes when buffered).
func (s *InStream) Accept(seq int64, size int) Verdict {
	switch {
	case seq <= 0:
		return Invalid
	case seq <= s.applied:
		return Duplicate
	case seq == s.applied+1:
		return Apply
	}
	if _, ok := s.buffered[seq]; ok {
		return Duplicate
	}
	if seq-s.applied > MaxWindow || s.bytes+size > MaxBufferedBytes || len(s.buffered) >= MaxWindow {
		return TooFar
	}
	s.buffered[seq] = size
	s.bytes += size
	return Gap
}

// Commit records that seq was applied and persisted. It must be applied+1; anything else is an error
// and changes nothing. A buffered copy of seq (the caller applied it from its buffer) is released.
func (s *InStream) Commit(seq int64) error {
	if seq != s.applied+1 {
		return protoErr(CodeInvalid, "commit %d: applied is %d", seq, s.applied)
	}
	s.applied = seq
	if n, ok := s.buffered[seq]; ok {
		s.bytes -= n
		delete(s.buffered, seq)
	}
	return nil
}

// Ready returns the buffered seqs that are now contiguous after applied, in order, without advancing:
// the caller applies each from its buffer, persists, and Commits it. Call it after a Commit.
func (s *InStream) Ready() []int64 {
	var out []int64
	for n := s.applied + 1; ; n++ {
		if _, ok := s.buffered[n]; !ok {
			return out
		}
		out = append(out, n)
	}
}

// Applied is the highest committed in-order seq (the value the next ack carries).
func (s *InStream) Applied() int64 { return s.applied }

// ResendFrom is the seq to request from the worker: applied+1.
func (s *InStream) ResendFrom() int64 { return s.applied + 1 }

// HasGap reports whether out-of-order frames are buffered.
func (s *InStream) HasGap() bool { return len(s.buffered) > 0 }

// BufferedBytes is the payload size currently held ahead of applied (always <= MaxBufferedBytes).
func (s *InStream) BufferedBytes() int { return s.bytes }
