package workerproto

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"strings"
	"testing"
	"time"
)

func sets(kv ...string) map[string]json.RawMessage {
	m := map[string]json.RawMessage{}
	for i := 0; i < len(kv); i += 2 {
		m[kv[i]] = json.RawMessage(kv[i+1])
	}
	return m
}

// --- 1. a worker cannot mark itself succeeded or claim completion evidence ---

func TestWorkerCannotSucceed(t *testing.T) {
	for _, cur := range []JobState{{}, {State: "running"}, {State: "awaiting"}} {
		v := CheckJobSet(cur, sets("state", `"succeeded"`), nil)
		if len(v) != 1 || v[0].Key != "state" || v[0].Code != CodeOwnership {
			t.Fatalf("from %q: %+v", cur.State, v)
		}
	}
	// Refused at the door too, with no job state.
	f := streamFrame(t, TypeJobSet, JobSet{Set: sets("state", `"succeeded"`)})
	if ErrorCode(Validate(f)) != CodeOwnership {
		t.Fatalf("Validate must apply the ownership table: %v", Validate(f))
	}
}

func TestCompletionEvidenceIsCoordinatorDerived(t *testing.T) {
	for _, k := range []string{"pr_url", "actual_branch", "finished_at", "exit_code", "failure_reason"} {
		if contains(WorkerKeys, k) {
			t.Errorf("%s must not be worker-settable", k)
		}
		v := CheckJobSet(JobState{State: "running"}, sets(k, `"x"`), nil)
		if len(v) != 1 || v[0].Code != CodeOwnership {
			t.Errorf("%s set: %+v", k, v)
		}
		if v := CheckJobSet(JobState{State: "running"}, nil, []string{k}); len(v) != 1 {
			t.Errorf("%s delete: %+v", k, v)
		}
		f := streamFrame(t, TypeJobSet, JobSet{Set: sets(k, `"x"`)})
		if ErrorCode(Validate(f)) != CodeOwnership {
			t.Errorf("%s: Validate must refuse", k)
		}
	}
}

func TestStateTransitions(t *testing.T) {
	for _, term := range []string{"succeeded", "failed", "cancelled"} {
		for _, to := range []string{"running", "awaiting", "failed", "cancelled"} {
			if to == term {
				continue
			}
			if v := CheckJobSet(JobState{State: term}, sets("state", `"`+to+`"`), nil); len(v) != 1 {
				t.Errorf("%s -> %s must be refused: %+v", term, to, v)
			}
		}
	}
	if v := CheckJobSet(JobState{State: "failed"}, sets("state", `"failed"`), nil); len(v) != 0 {
		t.Errorf("an idempotent replay of the same terminal state is allowed: %+v", v)
	}
	if v := CheckJobSet(JobState{State: "running", CancelRequested: true}, sets("state", `"running"`), nil); len(v) != 1 {
		t.Errorf("running after a cancel request: %+v", v)
	}
	if v := CheckJobSet(JobState{State: "running", CancelRequested: true}, sets("state", `"cancelled"`), nil); len(v) != 0 {
		t.Errorf("acknowledging a cancel is fine: %+v", v)
	}
	if v := CheckJobSet(JobState{State: "running"}, sets("state", `"awaiting"`), nil); len(v) != 0 {
		t.Errorf("%+v", v)
	}
}

func TestJobSetKindsAndLengths(t *testing.T) {
	bad := map[string]string{
		"exit code string": `"x"`,
	}
	_ = bad
	cases := []struct{ key, val string }{
		{"worker_pid", `"1"`}, {"worker_pid", `-1`}, {"continuation_count", `1.5`}, {"live_cost_usd", `"1"`},
		{"resume_not_yet_acted_on", `"yes"`}, {"gates", `[]`}, {"attention", `{}`}, {"session_id", `"../x"`},
		{"resume_session_id", `"a b"`}, {"activity", `"x y"`}, {"paused_at", `""`},
		{"question", `"` + strings.Repeat("a", MaxTextLen+1) + `"`},
		{"question", `"bell\u0007"`}, {"limiter_resume_prompt", `"nul\u0000"`},
		{"gates", `{"x":"` + strings.Repeat("a", MaxStructBytes) + `"}`},
	}
	for _, c := range cases {
		v := CheckJobSet(JobState{State: "running"}, sets(c.key, c.val), nil)
		if len(v) != 1 || v[0].Code != CodeInvalid {
			t.Errorf("%s=%.40s: want one invalid violation, got %+v", c.key, c.val, v)
		}
	}
	for _, c := range []struct{ key, val string }{
		{"worker_pid", `42`}, {"gates", `null`}, {"question", `"why?\nreally"`}, {"attention", `[]`},
		{"session_id", `"sess-1"`}, {"live_cost_usd", `1.25`}, {"decision", `{}`},
	} {
		if v := CheckJobSet(JobState{State: "running"}, sets(c.key, c.val), nil); len(v) != 0 {
			t.Errorf("%s=%s: %+v", c.key, c.val, v)
		}
	}
	// too many keys
	many := map[string]json.RawMessage{}
	for i := 0; i <= MaxKeys; i++ {
		many[fmt.Sprintf("k%d", i)] = json.RawMessage(`1`)
	}
	if err := Validate(streamFrame(t, TypeJobSet, JobSet{Set: many})); ErrorCode(err) != CodeInvalid {
		t.Fatalf("more than MaxKeys keys: %v", err)
	}
}

// --- 2. checkpoint manifest ---

func TestValidateManifestHostile(t *testing.T) {
	if err := ValidateManifest(goodManifest("job-1")); err != nil {
		t.Fatal(err)
	}
	if err := ValidateManifest(func() Manifest { m := goodManifest("job-1"); m.HeadSHA = strings.Repeat("f", 64); return m }()); err != nil {
		t.Fatalf("64-hex SHAs are valid: %v", err)
	}
	mut := map[string]func(*Manifest){
		"head_sha upload-pack": func(m *Manifest) { m.HeadSHA = "--upload-pack=x" },
		"head_sha uppercase":   func(m *Manifest) { m.HeadSHA = strings.Repeat("A", 40) },
		"head_sha short":       func(m *Manifest) { m.HeadSHA = "abc" },
		"base_sha ref":         func(m *Manifest) { m.BaseSHA = "refs/heads/main" },
		"wip_sha 41":           func(m *Manifest) { m.WipSHA = strings.Repeat("a", 41) },
		"wip_sha empty":        func(m *Manifest) { m.WipSHA = "" },
		"branch option":        func(m *Manifest) { m.Branch = "--upload-pack=x" },
		"branch dotdot":        func(m *Manifest) { m.Branch = "feature/../../x" },
		"branch wip dotdot":    func(m *Manifest) { m.Branch = "refs/mother/wip/x/../.." },
		"branch control":       func(m *Manifest) { m.Branch = "a\x01b" },
		"branch newline":       func(m *Manifest) { m.Branch = "a\nb" },
		"branch space":         func(m *Manifest) { m.Branch = "a b" },
		"branch long":          func(m *Manifest) { m.Branch = strings.Repeat("a", 201) },
		"branch .lock":         func(m *Manifest) { m.Branch = "x.lock" },
		"branch at-brace":      func(m *Manifest) { m.Branch = "a@{1}" },
		"transcript dotdot":    func(m *Manifest) { m.Transcript.PathRel = "checkpoints/" + m.Job + "/../../etc/passwd" },
		"transcript passwd":    func(m *Manifest) { m.Transcript.PathRel = "../../etc/passwd" },
		"transcript absolute":  func(m *Manifest) { m.Transcript.PathRel = "/etc/passwd" },
		"transcript nul":       func(m *Manifest) { m.Transcript.PathRel = "checkpoints/" + m.Job + "/a\x00b" },
		"transcript other job": func(m *Manifest) { m.Transcript.PathRel = "checkpoints/other/t.jsonl" },
		"transcript bytes < 0": func(m *Manifest) { m.Transcript.Bytes = -1 },
		"job dotdot":           func(m *Manifest) { m.Job = "refs/mother/wip/x/../.."; m.WipRef = WipRef(m.Job) },
		"job slash":            func(m *Manifest) { m.Job = "a/b"; m.WipRef = WipRef(m.Job) },
		"job dots":             func(m *Manifest) { m.Job = "a..b"; m.WipRef = WipRef(m.Job) },
		"job option":           func(m *Manifest) { m.Job = "x y"; m.WipRef = WipRef(m.Job) },
		"job too long":         func(m *Manifest) { m.Job = strings.Repeat("a", 129); m.WipRef = WipRef(m.Job) },
		"wip_ref other":        func(m *Manifest) { m.WipRef = "refs/heads/x" },
		"session_id path":      func(m *Manifest) { m.SessionID = "../x" },
		"at garbage":           func(m *Manifest) { m.At = "yesterday" },
		"skipped dotdot":       func(m *Manifest) { m.UntrackedSkipped = []SkippedFile{{Path: "../../etc/passwd", Bytes: 1}} },
		"skipped absolute":     func(m *Manifest) { m.UntrackedSkipped = []SkippedFile{{Path: "/etc/passwd", Bytes: 1}} },
		"skipped nul":          func(m *Manifest) { m.UntrackedSkipped = []SkippedFile{{Path: "a\x00", Bytes: 1}} },
		"skipped bad reason":   func(m *Manifest) { m.UntrackedSkipped = []SkippedFile{{Path: "a", Bytes: 1, Reason: "x;rm"}} },
		"skipped negative":     func(m *Manifest) { m.UntrackedSkipped = []SkippedFile{{Path: "a", Bytes: -5}} },
		"skipped too many":     func(m *Manifest) { m.UntrackedSkipped = make([]SkippedFile, MaxUntrackedSkipped+1); fill(m) },
		"push_error control":   func(m *Manifest) { m.PushError = "token\x1b[31m" },
		"push_error utf8":      func(m *Manifest) { m.PushError = "\xff\xfe" },
	}
	for name, f := range mut {
		m := goodManifest("job-1")
		f(&m)
		if err := ValidateManifest(m); err == nil {
			t.Errorf("%s: hostile manifest accepted", name)
		}
	}
	m := goodManifest("job-1")
	m.PushError = strings.Repeat("e", MaxMsgLen)
	if err := ValidateManifest(m); err != nil {
		t.Fatalf("512-byte push_error is the limit: %v", err)
	}
	m.PushError += "e"
	if ErrorCode(ValidateManifest(m)) != CodeTooLarge {
		t.Fatal("push_error over 512 bytes must be too_large")
	}
}

func fill(m *Manifest) {
	for i := range m.UntrackedSkipped {
		m.UntrackedSkipped[i] = SkippedFile{Path: fmt.Sprintf("f%d", i), Bytes: 1}
	}
}

func TestManifestHasNoWorkDirOnTheWire(t *testing.T) {
	b, _ := json.Marshal(goodManifest("job-1"))
	if strings.Contains(string(b), "work_dir_at_capture") {
		t.Fatalf("worker-local path leaked onto the wire: %s", b)
	}
}

// --- 3. bounded InStream ---

func TestInStreamWindowBounded(t *testing.T) {
	s := NewInStream(0)
	var gaps, far int
	for seq := int64(2); seq < 100000; seq++ {
		switch s.Accept(seq, 100) {
		case Gap:
			gaps++
		case TooFar:
			far++
		default:
			t.Fatalf("seq %d: unexpected verdict", seq)
		}
	}
	if gaps != MaxWindow-1 {
		t.Fatalf("exactly the window (seq 2..%d) is buffered, got %d", MaxWindow, gaps)
	}
	if far == 0 || s.BufferedBytes() > MaxBufferedBytes || len(s.buffered) > MaxWindow {
		t.Fatalf("memory not bounded: far=%d bytes=%d entries=%d", far, s.BufferedBytes(), len(s.buffered))
	}
	if s.Accept(MaxWindow+1, 0) != TooFar || s.Accept(MaxWindow, 0) != Duplicate {
		t.Fatal("window edge is applied+MaxWindow")
	}
	if s.Accept(1, 0) != Apply {
		t.Fatal("seq 1 still applies")
	}
}

func TestInStreamBytesCap(t *testing.T) {
	s := NewInStream(0)
	big := MaxBufferedBytes / 4
	for seq := int64(2); seq <= 5; seq++ {
		if s.Accept(seq, big) != Gap {
			t.Fatalf("seq %d should buffer", seq)
		}
	}
	if s.Accept(6, 1) != TooFar {
		t.Fatal("past the byte cap the verdict is TooFar")
	}
	if s.BufferedBytes() != MaxBufferedBytes {
		t.Fatalf("bytes %d", s.BufferedBytes())
	}
	if s.Accept(1, 0) != Apply || s.Commit(1) != nil {
		t.Fatal()
	}
	for _, n := range s.Ready() {
		if err := s.Commit(n); err != nil {
			t.Fatal(err)
		}
	}
	if s.BufferedBytes() != 0 || s.Applied() != 5 {
		t.Fatalf("bytes released on commit: %d applied %d", s.BufferedBytes(), s.Applied())
	}
}

func TestInStreamInvalidSeq(t *testing.T) {
	s := NewInStream(0)
	for _, seq := range []int64{0, -1, -1 << 62} {
		if s.Accept(seq, 0) != Invalid {
			t.Errorf("seq %d must be Invalid", seq)
		}
	}
	if s.HasGap() || s.Applied() != 0 {
		t.Fatal("invalid seqs change nothing")
	}
}

func TestOutStreamFull(t *testing.T) {
	o := NewOutStream()
	for i := 0; i < MaxWindow; i++ {
		if o.Full() {
			t.Fatal("not full yet")
		}
		o.Append(TypeEventAppend, nil)
	}
	if !o.Full() {
		t.Fatal("window of MaxWindow unacked frames is full")
	}
	o.Ack(1)
	if o.Full() {
		t.Fatal("an ack frees a slot")
	}
}

// --- 14. exactly-once order: Accept must not report applied before Commit ---

func TestAcceptDoesNotAdvanceUntilCommit(t *testing.T) {
	s := NewInStream(0)
	if s.Accept(1, 0) != Apply || s.Applied() != 0 {
		t.Fatalf("Accept(1) must not advance applied (got %d)", s.Applied())
	}
	if s.Commit(2) == nil {
		t.Fatal("commit must be applied+1")
	}
	if s.Commit(1) != nil || s.Applied() != 1 {
		t.Fatal("commit advances")
	}
}

// Crash between apply and persist: applied_seq on disk is still n-1, so the restarted stream judges the
// same frame Apply again (idempotent apply absorbs it) and buffered frames come back via resend.
func TestRestartReplaysWindowFromPersisted(t *testing.T) {
	s := NewInStream(0)
	for seq := int64(1); seq <= 3; seq++ {
		if s.Accept(seq, 0) != Apply {
			t.Fatal()
		}
		s.Commit(seq)
	}
	s.Accept(5, 10)       // buffered, never persisted
	persisted := int64(2) // crash after applying 3 but before persisting it
	r := NewInStream(persisted)
	if r.HasGap() {
		t.Fatal("buffered frames do not survive a restart")
	}
	if r.ResendFrom() != 3 {
		t.Fatalf("resend_from %d", r.ResendFrom())
	}
	for seq := int64(3); seq <= 5; seq++ {
		if r.Accept(seq, 0) != Apply {
			t.Fatalf("seq %d replays as Apply", seq)
		}
		r.Commit(seq)
	}
}

func TestDedupeHorizon(t *testing.T) {
	d := NewDedupeSet(DedupeHorizon)
	d.Seen("old")
	for i := 0; i < DedupeHorizon; i++ {
		d.Seen(fmt.Sprintf("c%d", i))
	}
	if d.Seen("old") {
		t.Fatal("an id older than the horizon is forgotten: this is why it must never be redelivered")
	}
	if d.Len() != DedupeHorizon {
		t.Fatal(d.Len())
	}
}

func TestCmdOutboxHorizon(t *testing.T) {
	o := NewCmdOutbox()
	o.Issue("first")
	o.Issue("second")
	o.Ack("second")
	if !o.Redeliverable("first") || o.Redeliverable("second") {
		t.Fatal("unacked is redeliverable, acked is not")
	}
	for i := 0; i < DedupeHorizon-1; i++ {
		o.Issue(fmt.Sprintf("c%d", i))
	}
	if o.Redeliverable("first") {
		t.Fatal("a command older than the dedupe horizon must not be redelivered")
	}
	if got := o.Expire(); len(got) != 1 || got[0] != "first" {
		t.Fatalf("expire: %v", got)
	}
}

// --- 4. lease persistence ---

func TestLeaseSnapshotRestartMonotonic(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0)
	tb.Revoke("j", "L1", 1)
	tb.Offer("j", "L2", "w", t0)
	tb.AcceptFor("w", "j", "L2", 2, t0)
	activeLease(t, tb, "k", "K1", t0)
	b, err := json.Marshal(tb.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	var snap LeaseSnapshot
	if err := json.Unmarshal(b, &snap); err != nil {
		t.Fatal(err)
	}
	r, err := RestoreLeaseTable(snap)
	if err != nil {
		t.Fatal(err)
	}
	if err := r.CheckFenceFor("w", "j", "L2", 2); err != nil {
		t.Fatalf("active lease survives the restart: %v", err)
	}
	for _, c := range []struct {
		lease string
		epoch int64
	}{{"L1", 1}, {"L2", 1}, {"L1", 2}} {
		if ErrorCode(r.CheckFenceFor("w", "j", c.lease, c.epoch)) != CodeFenced {
			t.Errorf("stale (%s, %d) must be fenced after restart", c.lease, c.epoch)
		}
	}
	r.Revoke("j", "L2", 2)
	l3, err := r.Offer("j", "L3", "w", t0)
	if err != nil || l3.Epoch != 3 {
		t.Fatalf("next epoch is previous+1: %+v %v", l3, err)
	}
	// A job whose lease ended before the snapshot keeps its epoch history: a stale holder is fenced.
	tb2 := NewLeaseTable()
	activeLease(t, tb2, "z", "Z1", t0)
	tb2.Revoke("z", "Z1", 1)
	r2, _ := RestoreLeaseTable(tb2.Snapshot())
	if ErrorCode(r2.checkFence("z", "Z1", 1)) != CodeFenced {
		t.Fatal("stale worker after restart must be fenced, not unknown_job")
	}
	if l, _ := r2.Offer("z", "Z2", "w", t0); l.Epoch != 2 {
		t.Fatalf("epoch must continue: %+v", l)
	}
}

func TestSnapshotIsADeepCopy(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0)
	s := tb.Snapshot()
	s.Epochs["j"] = 99
	s.Leases[0].ID = "mutated"
	if l, _ := tb.Get("j"); l.ID != "L1" {
		t.Fatal("snapshot aliases the table")
	}
	if tb.Snapshot().Epochs["j"] != 1 {
		t.Fatal("snapshot aliases epochs")
	}
}

func TestRestoreRejectsCorruptSnapshot(t *testing.T) {
	good := LeaseRecord{ID: "L", Job: "j", Epoch: 2, Worker: "w", State: LeaseActive, LastHB: t0}
	bad := []LeaseSnapshot{
		{Epochs: map[string]int64{"j": 1}, Leases: []LeaseRecord{good}},                                                         // epoch beyond history
		{Epochs: map[string]int64{"j": 2}, Leases: []LeaseRecord{good, good}},                                                   // duplicate
		{Epochs: map[string]int64{"j": 2}, Leases: []LeaseRecord{{ID: "L", Job: "j", Epoch: 2, Worker: "w", State: LeaseLost}}}, // terminal
		{Epochs: map[string]int64{"../x": 2}},
		{Epochs: map[string]int64{"j": -1}},
		{Epochs: map[string]int64{}, Leases: []LeaseRecord{good}},
	}
	for i, s := range bad {
		if _, err := RestoreLeaseTable(s); err == nil {
			t.Errorf("case %d accepted", i)
		}
	}
	if _, err := RestoreLeaseTable(LeaseSnapshot{Epochs: map[string]int64{"j": 2}, Leases: []LeaseRecord{good}}); err != nil {
		t.Fatal(err)
	}
}

// --- 5. direction ---

func TestFrameDirection(t *testing.T) {
	coordOnly := []string{TypeLeaseOffer, TypeLeaseRevoke, TypeCancel, TypeHold, TypeRelease, TypeSyncJob, TypeSyncFile, TypeWelcome, TypeRefuse, TypeAck}
	workerOnly := []string{TypeHello, TypeHb, TypeCmdAck, TypeJobSet, TypeEventAppend, TypeRecordAppend, TypeLogAppend, TypeArtifactPut, TypeCheckpointTaken, TypeLeaseRelease}
	for _, ty := range coordOnly {
		if AllowedFromWorker(ty) || !AllowedFromCoordinator(ty) {
			t.Errorf("%s is coordinator-only", ty)
		}
	}
	for _, ty := range workerOnly {
		if !AllowedFromWorker(ty) || AllowedFromCoordinator(ty) {
			t.Errorf("%s is worker-only", ty)
		}
	}
	if !AllowedFromWorker(TypeBye) || !AllowedFromCoordinator(TypeBye) {
		t.Error("bye goes both ways")
	}
	offer := cmdFrame(t, TypeLeaseOffer, LeaseOffer{CmdID: "c", JobDoc: raw(`{}`), Repo: "r", Attempt: 1})
	if err := ValidateFrom(FromCoordinator, offer); err != nil {
		t.Fatal(err)
	}
	if ErrorCode(ValidateFrom(FromWorker, offer)) != CodeInvalid {
		t.Fatal("a worker must not send lease.offer")
	}
	for _, f := range []Frame{
		mustFrame(t, TypeSyncFile, SyncFile{CmdID: "c", Path: "ratelimit-until", Content: raw("null")}),
		mustFrame(t, TypeWelcome, Welcome{Proto: 1}),
		mustFrame(t, TypeRefuse, Refuse{Code: CodeFenced}),
		cmdFrame(t, TypeLeaseRevoke, LeaseRevoke{CmdID: "c", Reason: "x"}),
	} {
		if ErrorCode(ValidateFrom(FromWorker, f)) != CodeInvalid {
			t.Errorf("worker sent %s", f.T)
		}
	}
	ev := streamFrame(t, TypeEventAppend, EventAppend{Line: "x"})
	if ErrorCode(ValidateFrom(FromCoordinator, ev)) != CodeInvalid {
		t.Fatal("the coordinator must not send stream frames")
	}
	if err := ValidateFrom(FromWorker, ev); err != nil {
		t.Fatal(err)
	}
}

// --- 6 & 7. cmd.ack envelope + fence, worker identity, Admit ---

func ackFrame(t *testing.T, job, lease string, epoch int64, outcome, forType string) []byte {
	f := mustFrame(t, TypeCmdAck, CmdAck{CmdID: "c1", Outcome: outcome, For: forType})
	if job != "" {
		f.Job, f.Lease, f.Epoch = Str(job), Str(lease), Int(epoch)
	}
	b, err := Encode(f)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func newAdmitter() (*Admitter, *LeaseTable) {
	tb := NewLeaseTable()
	return NewAdmitter(tb, func(string) JobState { return JobState{State: "running"} }), tb
}

func TestCmdAckNeedsEnvelope(t *testing.T) {
	f := mustFrame(t, TypeCmdAck, CmdAck{CmdID: "c", Outcome: OutcomeApplied})
	if ErrorCode(Validate(f)) != CodeInvalid {
		t.Fatal("cmd.ack without job/lease/epoch is invalid")
	}
	f = mustFrame(t, TypeCmdAck, CmdAck{CmdID: "c", Outcome: OutcomeApplied, For: TypeSyncFile})
	if err := Validate(f); err != nil {
		t.Fatalf("sync.file is the one non-job-scoped command: %v", err)
	}
	f = mustFrame(t, TypeCmdAck, CmdAck{CmdID: "c", Outcome: OutcomeApplied, For: "bogus"})
	if Validate(f) == nil {
		t.Fatal("unknown for")
	}
}

func TestStaleWorkerCannotAckCommands(t *testing.T) {
	a, tb := newAdmitter()
	tb.Offer("j", "L1", "w1", t0)
	if _, err := a.Admit("w1", ackFrame(t, "j", "L1", 1, OutcomeApplied, TypeLeaseOffer), t0); err != nil {
		t.Fatalf("offer ack activates: %v", err)
	}
	if err := tb.CheckFenceFor("w1", "j", "L1", 1); err != nil {
		t.Fatal("lease active after the offer ack")
	}
	tb.Revoke("j", "L1", 1)
	tb.Offer("j", "L2", "w2", t0)
	if _, err := a.Admit("w1", ackFrame(t, "j", "L1", 1, OutcomeApplied, TypeHold), t0); ErrorCode(err) != CodeFenced {
		t.Fatalf("stale worker ack: want fenced, got %v", err)
	}
	if _, err := a.Admit("w1", ackFrame(t, "j", "L2", 2, OutcomeApplied, TypeHold), t0); ErrorCode(err) != CodeNotLeased {
		t.Fatalf("another worker's lease: want not_leased, got %v", err)
	}
	if _, err := a.Admit("w1", ackFrame(t, "nope", "L", 1, OutcomeApplied, ""), t0); ErrorCode(err) != CodeUnknownJob {
		t.Fatalf("unknown job: %v", err)
	}
	if _, err := a.Admit("w1", ackFrame(t, "", "", 0, OutcomeApplied, TypeSyncFile), t0); ErrorCode(err) != CodeInvalid {
		t.Fatalf("a worker's own `for: sync.file` must not exempt an ack the coordinator never issued: %v", err)
	}
	a.Issued(mustFrame(t, TypeSyncFile, SyncFile{CmdID: "c1", Path: "ratelimit-until", Content: raw("null")}))
	if _, err := a.Admit("w1", ackFrame(t, "", "", 0, OutcomeApplied, TypeSyncFile), t0); err != nil {
		t.Fatalf("an ack for an issued sync.file is exempt: %v", err)
	}
	// An issued non-sync.file command is fenced even if the worker labels the ack sync.file.
	a.Issued(cmdFrame(t, TypeHold, Hold{CmdID: "c2", Code: "x", Reason: "y"}))
	forged := mustFrame(t, TypeCmdAck, CmdAck{CmdID: "c2", Outcome: OutcomeApplied, For: TypeSyncFile})
	if _, err := a.Admit("w1", mustEncode(t, forged), t0); ErrorCode(err) != CodeInvalid {
		t.Fatalf("forged for: %v", err)
	}
}

func TestRejectedOfferAckDoesNotActivate(t *testing.T) {
	a, tb := newAdmitter()
	tb.Offer("j", "L1", "w", t0)
	if _, err := a.Admit("w", ackFrame(t, "j", "L1", 1, OutcomeRejected, TypeLeaseOffer), t0); err != nil {
		t.Fatal(err)
	}
	if l, _ := tb.Get("j"); l.State != LeaseOffered {
		t.Fatalf("rejected offer must not activate: %s", l.State)
	}
}

func TestLeaseCallsCheckWorkerIdentity(t *testing.T) {
	tb := NewLeaseTable()
	tb.Offer("j", "L1", "w", t0)
	if ErrorCode(tb.AcceptFor("evil", "j", "L1", 1, t0)) != CodeNotLeased {
		t.Fatal("AcceptFor must check the worker")
	}
	tb.AcceptFor("w", "j", "L1", 1, t0)
	if ErrorCode(tb.HeartbeatFor("evil", "j", "L1", 1, t0.Add(time.Second))) != CodeNotLeased {
		t.Fatal("HeartbeatFor must check the worker")
	}
	if ErrorCode(tb.ReleaseFor("evil", "j", "L1", 1)) != CodeNotLeased {
		t.Fatal("ReleaseFor must check the worker")
	}
	if l, _ := tb.Get("j"); l.State != LeaseActive {
		t.Fatal("a foreign release must not end the lease")
	}
	if err := tb.ReleaseFor("w", "j", "L1", 1); err != nil {
		t.Fatal(err)
	}
}

func TestHeartbeatNeverMovesBackwards(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0)
	tb.HeartbeatFor("w", "j", "L1", 1, t0.Add(100*time.Second))
	tb.HeartbeatFor("w", "j", "L1", 1, t0.Add(50*time.Second))
	if l, _ := tb.Get("j"); !l.LastHB.Equal(t0.Add(100 * time.Second)) {
		t.Fatalf("LastHB moved backwards: %v", l.LastHB)
	}
}

func encodeStream(t *testing.T, typ string, seq int64, data any) []byte {
	f := streamFrame(t, typ, data)
	f.Seq = Int(seq)
	b, err := Encode(f)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestAdmitPipeline(t *testing.T) {
	a, tb := newAdmitter()
	activeLease(t, tb, "job1", "lease1", t0) // worker "w"
	ev := func(seq int64) []byte { return encodeStream(t, TypeEventAppend, seq, EventAppend{Line: "x"}) }

	adm, err := a.Admit("w", ev(1), t0)
	if err != nil || adm.Verdict != Apply {
		t.Fatalf("%+v %v", adm, err)
	}
	if _, err := a.Admit("intruder", ev(2), t0); ErrorCode(err) != CodeNotLeased {
		t.Fatalf("wrong worker: %v", err)
	}
	gapAdm, _ := a.Admit("w", ev(3), t0)
	if gapAdm.Verdict != Gap {
		t.Fatal("seq 3 is a gap")
	}
	if err := a.Commit("w", gapAdm.Frame); err == nil {
		t.Fatal("committing a gap frame out of order must fail")
	}
	first, _ := Decode(ev(1))
	if err := a.Commit("w", first); err != nil {
		t.Fatal(err)
	}
	if ack, _ := a.AckFor(first); ack.Seq != 1 || ack.ResendFrom == nil || *ack.ResendFrom != 2 {
		t.Fatalf("ack %+v", ack)
	}
	if _, err := a.Admit("w", encodeStream(t, TypeEventAppend, MaxWindow+5, EventAppend{Line: "x"}), t0); ErrorCode(err) != CodeTooLarge {
		t.Fatalf("beyond the window: %v", err)
	}
	// Direction is enforced in Admit.
	if _, err := a.Admit("w", mustEncode(t, cmdFrame(t, TypeCancel, Cancel{CmdID: "c"})), t0); ErrorCode(err) != CodeInvalid {
		t.Fatalf("worker sent cancel: %v", err)
	}
	// job.set ownership uses current job state.
	set := encodeStream(t, TypeJobSet, 2, JobSet{Set: sets("state", `"succeeded"`)})
	if _, err := a.Admit("w", set, t0); ErrorCode(err) != CodeOwnership {
		t.Fatalf("succeeded: %v", err)
	}
	a2 := NewAdmitter(tb, func(string) JobState { return JobState{State: "cancelled"} })
	if _, err := a2.Admit("w", encodeStream(t, TypeJobSet, 1, JobSet{Set: sets("state", `"running"`)}), t0); ErrorCode(err) != CodeOwnership {
		t.Fatalf("leaving cancelled: %v", err)
	}
	// Release ends the lease only when committed.
	rel := encodeStream(t, TypeLeaseRelease, 2, LeaseRelease{Reason: "finished"})
	adm, err = a.Admit("w", rel, t0)
	if err != nil || adm.Verdict != Apply {
		t.Fatalf("%+v %v", adm, err)
	}
	if l, _ := tb.Get("job1"); l.State != LeaseActive {
		t.Fatal("admit alone must not end the lease")
	}
	if err := a.Commit("w", adm.Frame); err != nil {
		t.Fatal(err)
	}
	if l, _ := tb.Get("job1"); l.State != LeaseReleased {
		t.Fatalf("commit of lease.release ends it: %s", l.State)
	}
}

func mustEncode(t *testing.T, f Frame) []byte {
	b, err := Encode(f)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestAdmitHelloBindsWorkerID(t *testing.T) {
	a, _ := newAdmitter()
	h := mustEncode(t, mustFrame(t, TypeHello, Hello{ProtoMin: 1, ProtoMax: 1, WorkerID: "w", InstanceID: "i", Kind: "local", Auth: Auth{Method: "peercred"}}))
	if _, err := a.Admit("w", h, t0); err != nil {
		t.Fatal(err)
	}
	if _, err := a.Admit("someone-else", h, t0); ErrorCode(err) != CodeAuthFailed {
		t.Fatalf("hello must name the authenticated worker: %v", err)
	}
}

func TestAdmitHeartbeatReportsRefusedEntries(t *testing.T) {
	a, tb := newAdmitter()
	activeLease(t, tb, "j1", "L1", t0)
	hb := mustEncode(t, mustFrame(t, TypeHb, Hb{Jobs: []HbJob{{Job: "j1", Lease: "L1", Epoch: 1}, {Job: "j1", Lease: "L1", Epoch: 9}, {Job: "zz", Lease: "L", Epoch: 1}}}))
	adm, err := a.Admit("w", hb, t0.Add(time.Second))
	if err != nil || len(adm.HbRefused) != 2 || adm.HbRefused[0].Code != CodeFenced || adm.HbRefused[1].Code != CodeUnknownJob {
		t.Fatalf("%+v %v", adm, err)
	}
}

func TestStaleWorkerRefusedAfterRestart(t *testing.T) {
	a, tb := newAdmitter()
	activeLease(t, tb, "job1", "lease1", t0)
	tb.Expire(t0.Add(time.Hour), t0)
	snap := tb.Snapshot()
	restored, err := RestoreLeaseTable(snap)
	if err != nil {
		t.Fatal(err)
	}
	a = NewAdmitter(restored, func(string) JobState { return JobState{} })
	if _, err := a.Admit("w", encodeStream(t, TypeEventAppend, 1, EventAppend{Line: "x"}), t0); ErrorCode(err) != CodeFenced {
		t.Fatalf("stale worker after restart: %v", err)
	}
}

// --- 10. handshake ---

func TestHelloV2AnswersVersion(t *testing.T) {
	line := []byte(`{"v":2,"t":"hello","id":"i","ts":"2026-11-08T15:04:05.001Z","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":{"future":true}}`)
	_, err := Decode(line)
	if ErrorCode(err) != CodeVersion {
		t.Fatalf("v:2 hello must answer version, got %v", err)
	}
	if r := RefuseFor(err); r.Code != CodeVersion {
		t.Fatalf("%+v", r)
	}
	if _, err := Decode([]byte(`{"t":"hello"}`)); ErrorCode(err) != CodeInvalid {
		t.Fatal("a missing v stays invalid")
	}
}

func TestHelloAuthCredentialFields(t *testing.T) {
	h := Hello{ProtoMin: 1, ProtoMax: 1, WorkerID: "w", InstanceID: "i", Kind: "kobe", Auth: Auth{Method: "token", Credential: "abc", Nonce: "n-1"}}
	b, _ := json.Marshal(h)
	if !strings.Contains(string(b), `"credential":"abc"`) || !strings.Contains(string(b), `"nonce":"n-1"`) {
		t.Fatalf("%s", b)
	}
	if err := Validate(mustFrame(t, TypeHello, h)); err != nil {
		t.Fatal(err)
	}
	h.Auth.Credential = strings.Repeat("a", 5000)
	if Validate(mustFrame(t, TypeHello, h)) == nil {
		t.Fatal("credential is bounded")
	}
	if ProtoMin != 1 || ProtoMax != 1 {
		t.Fatal("the coordinator's range is the package constants")
	}
}

func TestHelloTranscriptCoversCaps(t *testing.T) {
	h := Hello{ProtoMin: 1, ProtoMax: 1, Caps: []string{"b", "a"}, WorkerID: "w", InstanceID: "i", Kind: "k", Auth: Auth{Method: "token", Nonce: "n"}}
	base := string(HelloTranscript(h))
	h2 := h
	h2.Caps = []string{"a", "b"}
	if string(HelloTranscript(h2)) != base {
		t.Fatal("cap order must not matter")
	}
	h2.Caps = []string{"a"}
	if string(HelloTranscript(h2)) == base {
		t.Fatal("stripping a cap must change the transcript (downgrade protection)")
	}
	h3 := h
	h3.Auth.Nonce = "other"
	if string(HelloTranscript(h3)) == base {
		t.Fatal("nonce is covered")
	}
}

func TestNegotiateDoesNotEchoPeerText(t *testing.T) {
	_, r := Negotiate(Hello{ProtoMin: 1, ProtoMax: 1, Auth: Auth{Method: strings.Repeat("x", 100000)}}, 1, 1, nil)
	if r == nil || len(r.Msg) > MaxMsgLen {
		t.Fatal("refuse msg must stay bounded")
	}
}

// --- 11. strict decoding ---

func TestStrictDecoding(t *testing.T) {
	const tail = `"id":"i","ts":"2026-11-08T15:04:05.001Z","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":{"reason":"x"}}`
	bad := map[string]string{
		"duplicate t":       `{"v":1,"t":"bye","t":"hb",` + tail,
		"duplicate v":       `{"v":1,"v":1,"t":"bye",` + tail,
		"case variant T":    `{"v":1,"T":"hb","t":"bye",` + tail,
		"case variant Data": `{"v":1,"t":"bye","id":"i","ts":"2026-11-08T15:04:05.001Z","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"Data":{"reason":"x"}}`,
		"only variant":      `{"V":1,"t":"bye",` + tail,
		"dup data key":      `{"v":1,"t":"bye","id":"i","ts":"2026-11-08T15:04:05.001Z","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":{"reason":"x","reason":"y"}}`,
		"variant data key":  `{"v":1,"t":"bye","id":"i","ts":"2026-11-08T15:04:05.001Z","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":{"Reason":"x"}}`,
		"trailing garbage":  `{"v":1,"t":"bye",` + tail + ` {}`,
		"array":             `[1]`,
		"unknown envelope":  `{"v":1,"t":"bye","zzz":1,` + tail,
		"invalid utf8":      "{\"v\":1,\"t\":\"bye\",\"id\":\"\xff\"," + tail[strings.Index(tail, `"ts"`):],
	}
	for name, line := range bad {
		f, err := Decode([]byte(line))
		if err == nil {
			err = Validate(f)
		}
		if err == nil {
			t.Errorf("%s: non-canonical frame accepted", name)
		}
	}
	// Golden frames still round-trip byte for byte (TestFixturesRoundTripByteIdentical); spot check one.
	good := `{"v":1,"t":"bye",` + tail + "\n"
	f, err := Decode([]byte(good))
	if err != nil || Validate(f) != nil {
		t.Fatalf("%v %v", err, Validate(f))
	}
	if out, _ := Encode(f); string(out) != good {
		t.Fatalf("round trip: %s", out)
	}
}

func TestIDAndTimestampShapes(t *testing.T) {
	for _, s := range []string{"", "a b", "a/b", "a..b", "..", strings.Repeat("a", 129), "a\x00", "é"} {
		if IDOK(s) {
			t.Errorf("IDOK(%q)", s)
		}
	}
	for _, s := range []string{"job-1", "0000-4000", "a.b_c:d", strings.Repeat("a", 128)} {
		if !IDOK(s) {
			t.Errorf("IDOK(%q)", s)
		}
	}
	for _, s := range []string{"", "t", "2026-11-08T15:04:05Z", "2026-11-08T15:04:05.000000Z", "2026-13-08T15:04:05.000Z", "2026-11-08 15:04:05.000Z"} {
		if TimestampOK(s) {
			t.Errorf("TimestampOK(%q)", s)
		}
	}
	if !TimestampOK(Timestamp(t0)) {
		t.Fatal("Timestamp output must pass")
	}
	f := streamFrame(t, TypeEventAppend, EventAppend{Line: "x"})
	f.TS = "yesterday"
	if Validate(f) == nil {
		t.Fatal("bad ts")
	}
	f = streamFrame(t, TypeEventAppend, EventAppend{Line: "x"})
	f.ID = ""
	if Validate(f) == nil {
		t.Fatal("empty id")
	}
}

func TestVocabulariesAreCopies(t *testing.T) {
	r := RecordStreams()
	r[0] = "evil"
	s := SyncFilePaths()
	s[0] = "evil"
	if RecordStreams()[0] == "evil" || SyncFilePaths()[0] == "evil" {
		t.Fatal("callers must not be able to widen the vocabularies")
	}
}

func TestBoundedHelloKindAndRefuseMsg(t *testing.T) {
	h := Hello{ProtoMin: 1, ProtoMax: 1, WorkerID: "w", InstanceID: "i", Kind: strings.Repeat("k", 65), Auth: Auth{Method: "peercred"}}
	if Validate(mustFrame(t, TypeHello, h)) == nil {
		t.Fatal("hello.kind is bounded")
	}
	if Validate(mustFrame(t, TypeRefuse, Refuse{Code: CodeBusy, Msg: strings.Repeat("m", MaxMsgLen+1)})) == nil {
		t.Fatal("refuse.msg is bounded")
	}
	if err := Validate(mustFrame(t, TypeRefuse, Refuse{Code: CodeBusy, Msg: strings.Repeat("m", MaxMsgLen)})); err != nil {
		t.Fatal(err)
	}
}

// --- 12. bounded line reader ---

type countingReader struct {
	r io.Reader
	n int
}

func (c *countingReader) Read(p []byte) (int, error) { n, err := c.r.Read(p); c.n += n; return n, err }

func TestReadFrameBoundsUnterminatedLine(t *testing.T) {
	cr := &countingReader{r: io.LimitReader(endless('a'), 200<<20)}
	_, err := ReadFrame(bufio.NewReader(cr))
	if ErrorCode(err) != CodeTooLarge {
		t.Fatalf("want too_large, got %v", err)
	}
	if cr.n > MaxFrameBytes+(128<<10) {
		t.Fatalf("read %d bytes of an endless line; must stop near %d", cr.n, MaxFrameBytes)
	}
}

type endless byte

func (e endless) Read(p []byte) (int, error) {
	for i := range p {
		p[i] = byte(e)
	}
	return len(p), nil
}

func TestReadFrame(t *testing.T) {
	line1 := `{"v":1}` + "\n"
	big := strings.Repeat("x", MaxFrameBytes-1) + "\n" // exactly MaxFrameBytes with the newline
	r := bufio.NewReaderSize(strings.NewReader(line1+big+"tail"), 4096)
	got, err := ReadFrame(r)
	if err != nil || string(got) != line1 {
		t.Fatalf("%q %v", got, err)
	}
	got, err = ReadFrame(r)
	if err != nil || len(got) != MaxFrameBytes {
		t.Fatalf("a line of exactly MaxFrameBytes is allowed: %d %v", len(got), err)
	}
	if _, err := ReadFrame(r); err != io.ErrUnexpectedEOF {
		t.Fatalf("partial line at EOF: %v", err)
	}
	if _, err := ReadFrame(r); err != io.EOF {
		t.Fatalf("%v", err)
	}
	over := strings.Repeat("x", MaxFrameBytes) + "\n"
	if _, err := ReadFrame(bufio.NewReader(strings.NewReader(over))); ErrorCode(err) != CodeTooLarge {
		t.Fatalf("MaxFrameBytes+1 with newline: %v", err)
	}
}

// --- 9. limits and hostile input ---

func TestHostileInputTable(t *testing.T) {
	env := func(typ, data string) string {
		return `{"v":1,"t":"` + typ + `","id":"i","ts":"2026-11-08T15:04:05.001Z","job":"j","lease":"l","epoch":1,"seq":1,"ack":null,"data":` + data + `}`
	}
	hbEnv := func(data string) string {
		return `{"v":1,"t":"hb","id":"i","ts":"2026-11-08T15:04:05.001Z","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":` + data + `}`
	}
	helloEnv := func(data string) string {
		return `{"v":1,"t":"hello","id":"i","ts":"2026-11-08T15:04:05.001Z","job":null,"lease":null,"epoch":null,"seq":null,"ack":null,"data":` + data + `}`
	}
	deep := strings.Repeat("[", 20000) + strings.Repeat("]", 20000)
	million := "[" + strings.Repeat("0,", 450000) + "0]"
	hugeID := strings.Repeat("a", 500000)
	hello := func(extra string) string {
		return helloEnv(`{"proto_min":1,"proto_max":1,` + extra + `"worker_id":"w","instance_id":"i","kind":"k","auth":{"method":"peercred"}}`)
	}
	cases := map[string]string{
		"deep nesting in data":  env("job.set", `{"set":{"gates":`+deep+`}}`),
		"deep nesting envelope": `{"v":1,"t":"bye","id":` + deep + `}`,
		"million-element caps":  hello(`"caps":` + million + `,`),
		"million-element del":   env("job.set", `{"del":`+million+`}`),
		"million hb jobs":       hbEnv(`{"jobs":` + million + `}`),
		"huge job id":           `{"v":1,"t":"event.append","id":"i","ts":"2026-11-08T15:04:05.001Z","job":"` + hugeID + `","lease":"l","epoch":1,"seq":1,"ack":null,"data":{"line":"x"}}`,
		"huge worker id":        helloEnv(`{"proto_min":1,"proto_max":1,"worker_id":"` + hugeID + `","instance_id":"i","kind":"k","auth":{"method":"peercred"}}`),
		"invalid utf8 line":     env("event.append", "{\"line\":\"\xff\xfe\"}"),
		"invalid utf8 key":      "{\"v\":1,\"\xff\":1}",
		"surrogate escape":      env("event.append", `{"line":"\ud800"}`),
		"duplicate keys":        `{"v":1,"v":2,"t":"bye"}`,
		"case variant keys":     `{"V":1,"T":"bye"}`,
		"huge int":              env("log.append", `{"offset":99999999999999999999999,"b64":""}`),
		"negative epoch":        `{"v":1,"t":"event.append","id":"i","ts":"2026-11-08T15:04:05.001Z","job":"j","lease":"l","epoch":-5,"seq":1,"ack":null,"data":{"line":"x"}}`,
		"nul in line":           env("event.append", `{"line":"a\u0000b"}`),
		"too many caps":         hello(`"caps":[` + strings.Repeat(`"a",`, MaxCaps) + `"a"],`),
		"cap with newline":      hello(`"caps":["a\nb"],`),
		"null bytes everywhere": "\x00\x00\x00",
		"empty":                 "",
		"just newline":          "\n",
		"nested type confusion": env("job.set", `{"set":[1,2,3]}`),
		"data is a string":      env("event.append", `"line"`),
		"hb jobs object":        hbEnv(`{"jobs":{"a":1}}`),
	}
	for name, line := range cases {
		f, err := Decode([]byte(line))
		if err == nil {
			err = ValidateFrom(FromWorker, f)
		}
		if err == nil {
			t.Errorf("%s: hostile frame accepted", name)
		}
	}
}

func TestLimitsConstantsAreSane(t *testing.T) {
	if MaxIDLen != 128 || MaxKeys < 1 || MaxListLen < 1 || MaxCaps < 1 || MaxHbJobs < 1 || MaxUntrackedSkipped < 1 {
		t.Fatal("limits")
	}
	long := strings.Repeat("a", MaxIDLen+1)
	f := streamFrame(t, TypeEventAppend, EventAppend{Line: "x"})
	f.Job = Str(long)
	if Validate(f) == nil {
		t.Fatal("MaxIDLen")
	}
	var many []HbJob
	for i := 0; i <= MaxHbJobs; i++ {
		many = append(many, HbJob{Job: "j", Lease: "l", Epoch: 1})
	}
	if Validate(mustFrame(t, TypeHb, Hb{Jobs: many})) == nil {
		t.Fatal("MaxHbJobs")
	}
	caps := make([]string, MaxCaps+1)
	for i := range caps {
		caps[i] = "c"
	}
	if Validate(mustFrame(t, TypeHello, Hello{ProtoMin: 1, ProtoMax: 1, Caps: caps, WorkerID: "w", InstanceID: "i", Kind: "k", Auth: Auth{Method: "peercred"}})) == nil {
		t.Fatal("MaxCaps")
	}
}

// Fuzz seeds run as ordinary tests in `go test`, so CI exercises them; `go test -fuzz` explores further.
func fuzzSeeds(f interface{ Add(...any) }) {
	for _, name := range []string{"handshake_ok.ndjson", "command_dedupe.ndjson", "fenced_after_requeue.ndjson", "stream_redelivery.ndjson", "handshake_version_refused.ndjson"} {
		b, err := readFixtureBytes(name)
		if err != nil {
			continue
		}
		for _, line := range bytes.SplitAfter(b, []byte("\n")) {
			if len(line) > 0 {
				f.Add(line)
			}
		}
	}
	for _, s := range []string{"", "{}", "[]", `{"v":1}`, `{"v":1,"v":1}`, `{"V":1,"t":"bye"}`, "\xff", strings.Repeat("[", 1000)} {
		f.Add([]byte(s))
	}
}

func FuzzDecode(f *testing.F) {
	fuzzSeeds(f)
	f.Fuzz(func(t *testing.T, line []byte) {
		fr, err := Decode(line)
		if err != nil {
			if ErrorCode(err) == "" {
				t.Fatalf("Decode returned an uncoded error: %v", err)
			}
			return
		}
		// A decoded frame re-encodes, and what it re-encodes decodes to the same frame.
		out, err := Encode(fr)
		if err != nil {
			return // e.g. a newline-less oversized re-encode; refusing is fine
		}
		again, err := Decode(out)
		if err != nil {
			t.Fatalf("re-encoded frame no longer decodes: %v\n%s", err, out)
		}
		if again.T != fr.T || again.ID != fr.ID || again.TS != fr.TS {
			t.Fatalf("round trip changed the frame")
		}
	})
}

func FuzzValidate(f *testing.F) {
	fuzzSeeds(f)
	f.Fuzz(func(t *testing.T, line []byte) {
		fr, err := Decode(line)
		if err != nil {
			return
		}
		for _, dir := range []Direction{FromWorker, FromCoordinator} {
			if err := ValidateFrom(dir, fr); err != nil && ErrorCode(err) == "" {
				t.Fatalf("Validate returned an uncoded error: %v", err)
			}
		}
		if err := Validate(fr); err == nil && fr.T == TypeJobSet {
			var s JobSet
			if json.Unmarshal(fr.Data, &s) == nil && len(s.Set) > MaxKeys {
				t.Fatal("validated job.set beyond MaxKeys")
			}
		}
	})
}

func TestSurrogateEscapes(t *testing.T) {
	mk := func(line string) []byte {
		return []byte(`{"v":1,"t":"event.append","id":"i","ts":"2026-11-08T15:04:05.001Z","job":"j","lease":"l","epoch":1,"seq":1,"ack":null,"data":{"line":"` + line + `"}}`)
	}
	for _, ok := range []string{`\ud83d\ude00`, `\\ud800`, `plain`} {
		if _, err := Decode(mk(ok)); err != nil {
			t.Errorf("%s: %v", ok, err)
		}
	}
	for _, bad := range []string{`\ud800`, `\udc00`, `\ud800x`, `\ud800\u0041`} {
		if _, err := Decode(mk(bad)); err == nil {
			t.Errorf("%s accepted", bad)
		}
	}
}

func TestTextOKRejectsControlAndBidi(t *testing.T) {
	for _, s := range []string{"a\u0085b", "a\u009fb", "a\u202eb", "a\u2066b", "a\u200fb", "a\x1bb", "a\x7fb", "a\x00b", "a\rb"} {
		if textOK(s, 100) {
			t.Errorf("textOK(%q)", s)
		}
	}
	if !textOK("why?\nline two\tok é 日本", 100) {
		t.Fatal("ordinary text")
	}
	// Event lines carry arbitrary worker output: bidi and C1 are allowed there, NUL and ESC are not.
	if !lineOK("a\u202eb\u0085", 100) || lineOK("a\x00b", 100) || lineOK("a\x1bb", 100) {
		t.Fatal("lineOK is the lax C0-only filter")
	}
	if Validate(streamFrame(t, TypeJobSet, JobSet{Set: sets("question", `"a\u202eb"`)})) == nil {
		t.Fatal("a bidi control in a displayed field must be refused")
	}
}
