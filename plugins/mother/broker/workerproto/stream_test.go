package workerproto

import (
	"encoding/json"
	"reflect"
	"testing"
)

func TestOutStreamWindow(t *testing.T) {
	s := NewOutStream()
	for i := 1; i <= 4; i++ {
		if p := s.Append(TypeEventAppend, nil); p.Seq != int64(i) {
			t.Fatalf("seq starts at 1 and increments: got %d", p.Seq)
		}
	}
	if err := s.Ack(2); err != nil || s.Unacked() != 2 {
		t.Fatalf("ack trims the window: %v %d", err, s.Unacked())
	}
	r := s.Resend()
	if len(r) != 2 || r[0].Seq != 3 || r[1].Seq != 4 {
		t.Fatalf("resend starts at first unacked: %+v", r)
	}
	if got := s.ResendFrom(4); len(got) != 1 || got[0].Seq != 4 {
		t.Fatalf("ResendFrom: %+v", got)
	}
	if err := s.Ack(2); err != nil || s.Unacked() != 2 {
		t.Fatal("repeating an ack is harmless")
	}
	if ErrorCode(s.Ack(9)) != CodeInvalid {
		t.Fatal("ack beyond last sent must be refused")
	}
	s.Ack(4)
	if len(s.Resend()) != 0 || s.Append(TypeEventAppend, nil).Seq != 5 {
		t.Fatal("empty window resends nothing; seq continues")
	}
}

// step is Accept plus, for Apply, the caller's apply-persist-Commit.
func step(t *testing.T, s *InStream, seq int64) Verdict {
	t.Helper()
	v := s.Accept(seq, 0)
	if v == Apply {
		if err := s.Commit(seq); err != nil {
			t.Fatal(err)
		}
	}
	return v
}

func TestInStream(t *testing.T) {
	s := NewInStream(0)
	if step(t, s, 1) != Apply || step(t, s, 2) != Apply {
		t.Fatal("in order applies")
	}
	if step(t, s, 2) != Duplicate || step(t, s, 1) != Duplicate {
		t.Fatal("already applied is a duplicate")
	}
	if step(t, s, 5) != Gap || !s.HasGap() || s.ResendFrom() != 3 {
		t.Fatal("ahead of applied+1 is a gap; resend from applied+1")
	}
	if step(t, s, 5) != Duplicate {
		t.Fatal("a buffered seq seen again is a duplicate")
	}
	if step(t, s, 3) != Apply {
		t.Fatal("gap filler applies")
	}
	if len(s.Ready()) != 0 || s.Applied() != 3 {
		t.Fatal("seq 4 still missing: nothing is ready")
	}
	if step(t, s, 4) != Apply {
		t.Fatal()
	}
	got := s.Ready()
	if !reflect.DeepEqual(got, []int64{5}) || s.Applied() != 4 {
		t.Fatalf("ready is buffered 5, not yet applied: %v applied=%d", got, s.Applied())
	}
	if err := s.Commit(5); err != nil || s.Applied() != 5 || s.HasGap() || s.BufferedBytes() != 0 {
		t.Fatalf("commit 5: applied=%d gap=%v", s.Applied(), s.HasGap())
	}
	// Restore from a persisted applied_seq.
	if r := NewInStream(5); r.Accept(5, 0) != Duplicate || r.Accept(6, 0) != Apply {
		t.Fatal("restored stream")
	}
}

// MC-18 at the state-machine level: a worker redelivers after a lost ack; the fixture holds a
// duplicate and a gap, and the end state applies each line exactly once and in order.
func TestStreamRedeliveryFixture(t *testing.T) {
	in := NewInStream(0)
	buffered := map[int64]string{}
	var applied []string
	var verdicts []Verdict
	for _, f := range decodeFixture(t, "stream_redelivery.ndjson") {
		var d EventAppend
		_ = json.Unmarshal(f.Data, &d)
		v := in.Accept(*f.Seq, len(f.Data))
		verdicts = append(verdicts, v)
		switch v {
		case Apply:
			applied = append(applied, d.Line)
			if err := in.Commit(*f.Seq); err != nil {
				t.Fatal(err)
			}
			for _, seq := range in.Ready() {
				applied = append(applied, buffered[seq])
				if err := in.Commit(seq); err != nil {
					t.Fatal(err)
				}
			}
		case Gap:
			buffered[*f.Seq] = d.Line
			if in.ResendFrom() != 3 {
				t.Fatalf("gap must ask for resend from 3, got %d", in.ResendFrom())
			}
		}
	}
	if !reflect.DeepEqual(verdicts, []Verdict{Apply, Apply, Duplicate, Gap, Apply}) {
		t.Fatalf("verdicts %v", verdicts)
	}
	want := []string{`{"kind":"started"}`, `{"kind":"tool"}`, `{"kind":"pr"}`, `{"kind":"gate"}`}
	if !reflect.DeepEqual(applied, want) || in.Applied() != 4 {
		t.Fatalf("applied %v (applied_seq %d)", applied, in.Applied())
	}
}
