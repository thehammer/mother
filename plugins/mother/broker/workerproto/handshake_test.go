package workerproto

import (
	"bytes"
	"encoding/json"
	"reflect"
	"testing"
)

func hello(min, max int, method string, caps ...string) Hello {
	return Hello{ProtoMin: min, ProtoMax: max, Caps: caps, WorkerID: "w", InstanceID: "i", Kind: "local", Auth: Auth{Method: method}}
}

func TestNegotiate(t *testing.T) {
	srv := []string{"log.stream", "checkpoint.v1", "hold.boundary"}
	w, r := Negotiate(hello(1, 3, "peercred", "checkpoint.v1", "log.stream", "x"), 1, 2, srv)
	if r != nil || w.Proto != 2 {
		t.Fatalf("overlap should pick the max common version 2: %+v %+v", w, r)
	}
	if !reflect.DeepEqual(w.Caps, []string{"log.stream", "checkpoint.v1"}) {
		t.Fatalf("caps must be intersected: %v", w.Caps)
	}
	if w.HbIntervalS != 10 || w.LeaseTTLS != 180 {
		t.Fatalf("welcome timing: %+v", w)
	}
	if w, _ := Negotiate(hello(1, 1, "peercred"), 1, 2, srv); w == nil || w.Proto != 1 || w.Caps == nil || len(w.Caps) != 0 {
		t.Fatalf("empty intersection should give empty (non-nil) caps: %+v", w)
	}
	if _, r := Negotiate(hello(3, 4, "peercred"), 1, 2, srv); r == nil || r.Code != CodeVersion {
		t.Fatalf("no overlap: %+v", r)
	}
	if _, r := Negotiate(hello(1, 1, "token"), 1, 2, srv); r == nil || r.Code != CodeAuthUnsupported {
		t.Fatalf("token auth: %+v", r)
	}
	// Auth is checked before version.
	if _, r := Negotiate(hello(9, 9, "token"), 1, 2, srv); r.Code != CodeAuthUnsupported {
		t.Fatalf("auth first: %+v", r)
	}
}

func TestHandshakeFixtures(t *testing.T) {
	srv := []string{"log.stream", "checkpoint.v1", "os.darwin", "hold.boundary"}
	run := func(name string) (*Welcome, *Refuse, Frame) {
		fs := decodeFixture(t, name)
		var h Hello
		if err := json.Unmarshal(fs[0].Data, &h); err != nil {
			t.Fatal(err)
		}
		w, r := Negotiate(h, 1, 1, srv)
		return w, r, fs[1]
	}
	w, r, reply := run("handshake_ok.ndjson")
	if r != nil || reply.T != TypeWelcome {
		t.Fatalf("ok: %+v %+v", w, r)
	}
	want, _ := json.Marshal(w)
	if !bytes.Equal(want, reply.Data) {
		t.Fatalf("welcome mismatch:\n%s\n%s", want, reply.Data)
	}
	_, r, reply = run("handshake_version_refused.ndjson")
	var got Refuse
	_ = json.Unmarshal(reply.Data, &got)
	if r == nil || reply.T != TypeRefuse || got.Code != r.Code || r.Code != CodeVersion {
		t.Fatalf("refused: %+v %+v", r, got)
	}
}
