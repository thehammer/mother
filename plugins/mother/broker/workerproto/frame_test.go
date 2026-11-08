package workerproto

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const fixtureDir = "../../tests/fixtures/worker-proto"

// readFixture returns the NDJSON lines (each with its trailing newline) of a fixture file.
func readFixture(t *testing.T, name string) [][]byte {
	t.Helper()
	f, err := os.Open(filepath.Join(fixtureDir, name))
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	var out [][]byte
	r := bufio.NewReader(f)
	for {
		line, err := r.ReadBytes('\n')
		if len(line) > 0 {
			out = append(out, line)
		}
		if err != nil {
			break
		}
	}
	return out
}

func decodeFixture(t *testing.T, name string) []Frame {
	t.Helper()
	var fs []Frame
	for i, line := range readFixture(t, name) {
		f, err := Decode(line)
		if err != nil {
			t.Fatalf("%s line %d: %v", name, i+1, err)
		}
		if err := Validate(f); err != nil {
			t.Fatalf("%s line %d: validate: %v", name, i+1, err)
		}
		fs = append(fs, f)
	}
	return fs
}

func TestRoundTrip(t *testing.T) {
	f, _ := NewFrame(TypeEventAppend, "id-1", time.Date(2026, 11, 8, 1, 2, 3, 4_000_000, time.UTC), EventAppend{Line: "x"})
	f.Job, f.Lease, f.Epoch, f.Seq = Str("j"), Str("l"), Int(1), Int(1)
	b, err := Encode(f)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.HasSuffix(b, []byte("\n")) || bytes.Count(b, []byte("\n")) != 1 {
		t.Fatalf("want exactly one trailing newline: %q", b)
	}
	if !strings.Contains(string(b), `"ts":"2026-11-08T01:02:03.004Z"`) {
		t.Fatalf("ts must have 3 fractional digits: %s", b)
	}
	g, err := Decode(b)
	if err != nil {
		t.Fatal(err)
	}
	b2, _ := Encode(g)
	if !bytes.Equal(b, b2) {
		t.Fatalf("re-encode differs:\n%s\n%s", b, b2)
	}
}

func TestEncodeKeyOrder(t *testing.T) {
	b, _ := Encode(Frame{V: 1, T: TypeBye, ID: "i", TS: "t", Data: []byte(`{"reason":"x"}`)})
	want := `{"v":1,"t":"bye","id":"i","ts":"t","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":{"reason":"x"}}` + "\n"
	if string(b) != want {
		t.Fatalf("got %s", b)
	}
}

func TestFrameSizeLimit(t *testing.T) {
	// Build a frame whose encoded length, newline included, is exactly limit+1.
	mk := func(total int) []byte {
		base := `{"v":1,"t":"bye","id":"i","ts":"t","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":{"reason":""}}` + "\n"
		return []byte(strings.Replace(base, `"reason":""`, `"reason":"`+strings.Repeat("a", total-len(base))+`"`, 1))
	}
	ok := mk(MaxFrameBytes)
	if _, err := Decode(ok); err != nil {
		t.Fatalf("exactly 1 MiB must decode: %v", err)
	}
	big := mk(MaxFrameBytes + 1)
	if _, err := Decode(big); ErrorCode(err) != CodeTooLarge {
		t.Fatalf("1 MiB + 1 decode: want too_large, got %v", err)
	}
	f := Frame{V: 1, T: TypeBye, ID: "i", TS: "t", Data: []byte(`{"reason":"` + strings.Repeat("a", MaxFrameBytes) + `"}`)}
	if _, err := Encode(f); ErrorCode(err) != CodeTooLarge {
		t.Fatalf("encode: want too_large, got %v", err)
	}
}

func TestDecodeRejects(t *testing.T) {
	cases := []struct{ name, line, code string }{
		{"unknown type", `{"v":1,"t":"nope","id":"i","ts":"t"}`, CodeUnsupported},
		{"missing v", `{"t":"bye","id":"i","ts":"t"}`, CodeInvalid},
		{"wrong v", `{"v":2,"t":"bye","id":"i","ts":"t"}`, CodeInvalid},
		{"missing t", `{"v":1,"id":"i","ts":"t"}`, CodeInvalid},
		{"not json", `{"v":1,`, CodeInvalid},
		{"embedded newline", "{\"v\":1,\n\"t\":\"bye\"}", CodeInvalid},
	}
	for _, c := range cases {
		if _, err := Decode([]byte(c.line)); ErrorCode(err) != c.code {
			t.Errorf("%s: want %s, got %v", c.name, c.code, err)
		}
	}
}

func TestAdditiveEnvelopeFieldsAllowed(t *testing.T) {
	if _, err := Decode([]byte(`{"v":1,"t":"bye","id":"i","ts":"t","future":1,"data":{"reason":"x"}}`)); err != nil {
		t.Fatal(err)
	}
}

func mustFrame(t *testing.T, typ string, data any) Frame {
	t.Helper()
	f, err := NewFrame(typ, "id", time.Unix(0, 0), data)
	if err != nil {
		t.Fatal(err)
	}
	return f
}

func streamFrame(t *testing.T, typ string, data any) Frame {
	f := mustFrame(t, typ, data)
	f.Job, f.Lease, f.Epoch, f.Seq = Str("job1"), Str("lease1"), Int(1), Int(1)
	return f
}

func cmdFrame(t *testing.T, typ string, data any) Frame {
	f := mustFrame(t, typ, data)
	f.Job, f.Lease, f.Epoch = Str("job1"), Str("lease1"), Int(1)
	return f
}

func TestValidate(t *testing.T) {
	b64 := func(n int) string { return base64.StdEncoding.EncodeToString(bytes.Repeat([]byte("x"), n)) }
	noSeq := streamFrame(t, TypeEventAppend, EventAppend{Line: "x"})
	noSeq.Seq = nil
	zeroEpoch := streamFrame(t, TypeEventAppend, EventAppend{Line: "x"})
	zeroEpoch.Epoch = Int(0)
	noCmd := cmdFrame(t, TypeCancel, map[string]any{})
	noLeaseCmd := cmdFrame(t, TypeHold, Hold{CmdID: "c", Code: "a", Reason: "b"})
	noLeaseCmd.Lease = nil

	good := map[string]Frame{
		"event":     streamFrame(t, TypeEventAppend, EventAppend{Line: `{"a":1}`}),
		"record":    streamFrame(t, TypeRecordAppend, RecordAppend{Stream: "metrics/runs.jsonl", Line: "{}"}),
		"log max":   streamFrame(t, TypeLogAppend, LogAppend{Offset: 0, B64: b64(MaxChunkBytes)}),
		"artifact":  streamFrame(t, TypeArtifactPut, ArtifactPut{Path: "crew/job1/gates/1/x.log", B64: b64(3), Final: true}),
		"artifact2": streamFrame(t, TypeArtifactPut, ArtifactPut{Path: "checkpoints/job1/wip.bundle", B64: b64(3)}),
		"release":   streamFrame(t, TypeLeaseRelease, LeaseRelease{Reason: "finished"}),
		"cancel":    cmdFrame(t, TypeCancel, Cancel{CmdID: "c"}),
		"sync.file": mustFrame(t, TypeSyncFile, SyncFile{CmdID: "c", Path: "ratelimit-until", Content: []byte("null")}),
		"hb":        mustFrame(t, TypeHb, Hb{Jobs: []HbJob{{Job: "j", Lease: "l", Epoch: 1}}}),
	}
	for n, f := range good {
		if err := Validate(f); err != nil {
			t.Errorf("%s: %v", n, err)
		}
	}
	bad := map[string]struct {
		f    Frame
		code string
	}{
		"missing seq":        {noSeq, CodeInvalid},
		"epoch 0":            {zeroEpoch, CodeInvalid},
		"missing cmd_id":     {noCmd, CodeInvalid},
		"command w/o lease":  {noLeaseCmd, CodeInvalid},
		"empty event line":   {streamFrame(t, TypeEventAppend, EventAppend{}), CodeInvalid},
		"newline in line":    {streamFrame(t, TypeEventAppend, EventAppend{Line: "a\nb"}), CodeInvalid},
		"stream not allowed": {streamFrame(t, TypeRecordAppend, RecordAppend{Stream: "../x", Line: "{}"}), CodeInvalid},
		"chunk too big":      {streamFrame(t, TypeLogAppend, LogAppend{B64: b64(MaxChunkBytes + 1)}), CodeTooLarge},
		"bad b64":            {streamFrame(t, TypeLogAppend, LogAppend{B64: "!!"}), CodeInvalid},
		"artifact dotdot":    {streamFrame(t, TypeArtifactPut, ArtifactPut{Path: "crew/job1/../job2/x", B64: ""}), CodeInvalid},
		"artifact other job": {streamFrame(t, TypeArtifactPut, ArtifactPut{Path: "crew/job2/x", B64: ""}), CodeInvalid},
		"artifact absolute":  {streamFrame(t, TypeArtifactPut, ArtifactPut{Path: "/etc/passwd", B64: ""}), CodeInvalid},
		"artifact bad sha":   {streamFrame(t, TypeArtifactPut, ArtifactPut{Path: "crew/job1/x", SHA256: "zz"}), CodeInvalid},
		"sync.file path":     {mustFrame(t, TypeSyncFile, SyncFile{CmdID: "c", Path: "jobs/x.json", Content: []byte(`"x"`)}), CodeInvalid},
		"sync.file absent":   {mustFrame(t, TypeSyncFile, map[string]any{"cmd_id": "c", "path": "ratelimit-until"}), CodeInvalid},
		"sync.job key":       {cmdFrame(t, TypeSyncJob, SyncJob{CmdID: "c", Set: map[string]json.RawMessage{"repo_path": []byte(`"x"`)}}), CodeOwnership},
		"refuse bad code":    {mustFrame(t, TypeRefuse, Refuse{Code: "bogus"}), CodeInvalid},
		"hello no auth":      {mustFrame(t, TypeHello, Hello{ProtoMin: 1, ProtoMax: 1, WorkerID: "w", InstanceID: "i", Kind: "local"}), CodeInvalid},
		"hello bad range":    {mustFrame(t, TypeHello, Hello{ProtoMin: 2, ProtoMax: 1, WorkerID: "w", InstanceID: "i", Kind: "local", Auth: Auth{"peercred"}}), CodeInvalid},
		"manifest other job": {streamFrame(t, TypeCheckpointTaken, CheckpointTaken{Manifest: otherJobManifest()}), CodeInvalid},
		"cmd.ack outcome":    {mustFrame(t, TypeCmdAck, CmdAck{CmdID: "c", Outcome: "maybe"}), CodeInvalid},
	}
	for n, c := range bad {
		if err := Validate(c.f); ErrorCode(err) != c.code {
			t.Errorf("%s: want %s, got %v", n, c.code, err)
		}
	}
}

func TestFixturesRoundTripByteIdentical(t *testing.T) {
	files, _ := filepath.Glob(filepath.Join(fixtureDir, "*.ndjson"))
	if len(files) < 5 {
		t.Fatalf("expected the golden ndjson fixtures, found %d", len(files))
	}
	for _, p := range files {
		for i, line := range readFixture(t, filepath.Base(p)) {
			f, err := Decode(line)
			if err != nil {
				t.Fatalf("%s:%d %v", p, i+1, err)
			}
			if err := Validate(f); err != nil {
				t.Fatalf("%s:%d validate: %v", p, i+1, err)
			}
			out, err := Encode(f)
			if err != nil || !bytes.Equal(out, line) {
				t.Fatalf("%s:%d re-encode differs:\n%s\n%s (%v)", p, i+1, line, out, err)
			}
		}
	}
}

func otherJobManifest() Manifest {
	return Manifest{V: 1, Job: "job2", Lease: "lease1", Epoch: 1, N: 1, At: "t", HeadSHA: "a", Branch: "b", BaseSHA: "c", WipSHA: "d",
		WipRef: WipRef("job2"), SessionID: "s", Transcript: Transcript{PathRel: "p", SHA256: strings.Repeat("d", 64)}, WorkDirAtCapture: "/w"}
}
