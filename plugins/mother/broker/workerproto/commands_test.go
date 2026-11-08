package workerproto

import (
	"encoding/json"
	"fmt"
	"testing"
)

// MC-19: a command redelivered after a reconnect is applied at most once.
func TestDedupeSetSeen(t *testing.T) {
	d := NewDedupeSet(10)
	if d.Seen("c1") {
		t.Fatal("first sight is not a duplicate")
	}
	if !d.Seen("c1") || !d.Seen("c1") {
		t.Fatal("the same cmd_id again is a duplicate")
	}
	if d.Seen("c2") {
		t.Fatal("a different id is new")
	}
}

func TestDedupeSetBounded(t *testing.T) {
	d := NewDedupeSet(3)
	for i := 0; i < 5; i++ {
		d.Seen(fmt.Sprint("c", i))
	}
	if d.Len() != 3 {
		t.Fatalf("len %d", d.Len())
	}
	if d.Seen("c4") != true || d.Seen("c2") != true {
		t.Fatal("recent ids are kept")
	}
	if d.Seen("c0") {
		t.Fatal("the oldest id was evicted")
	}
}

func TestDedupeSetSerialises(t *testing.T) {
	d := NewDedupeSet(3)
	for _, id := range []string{"a", "b", "c", "d"} {
		d.Seen(id)
	}
	b, err := d.Marshal()
	if err != nil {
		t.Fatal(err)
	}
	r, err := UnmarshalDedupeSet(b)
	if err != nil {
		t.Fatal(err)
	}
	for _, id := range []string{"b", "c", "d"} {
		if !r.Seen(id) {
			t.Fatalf("%s lost across serialise/deserialise", id)
		}
	}
	if r.Len() != 3 {
		t.Fatal("cap must survive")
	}
	r.Seen("e") // evicts the oldest (b), proving order survived
	if r.Seen("b") {
		t.Fatal("order must survive: b was oldest")
	}
	if _, err := UnmarshalDedupeSet([]byte("{")); ErrorCode(err) != CodeInvalid {
		t.Fatal("garbage must be refused")
	}
}

func TestCommandDedupeFixture(t *testing.T) {
	d := NewDedupeSet(0)
	applied := 0
	var outcomes []string
	for _, f := range decodeFixture(t, "command_dedupe.ndjson") {
		if !IsCommandType(f.T) {
			continue
		}
		id := cmdID(t, f)
		if d.Seen(id) {
			outcomes = append(outcomes, id+":duplicate")
			continue
		}
		applied++
		outcomes = append(outcomes, id+":applied")
	}
	want := []string{"cmd-10:applied", "cmd-10:duplicate", "cmd-11:applied"}
	if fmt.Sprint(outcomes) != fmt.Sprint(want) || applied != 2 {
		t.Fatalf("%v applied=%d", outcomes, applied)
	}
}

func cmdID(t *testing.T, f Frame) string {
	t.Helper()
	var d struct {
		CmdID string `json:"cmd_id"`
	}
	if err := json.Unmarshal(f.Data, &d); err != nil {
		t.Fatal(err)
	}
	return d.CmdID
}
