package workerproto

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"path"
	"reflect"
	"regexp"
	"strings"
	"time"
	"unicode/utf8"
)

// Explicit limits. Every list, map and string a peer controls is bounded here, so no frame under
// MaxFrameBytes can make the coordinator allocate or loop unreasonably.
const (
	MaxIDLen            = 128      // job, lease, session, frame, command and worker ids
	MaxListLen          = 256      // generic list length (hello.caps, job.set del)
	MaxKeys             = 128      // keys in one job.set / sync.job set
	MaxCaps             = 64       // hello.caps entries
	MaxCapLen           = 64       // one capability flag
	MaxHbJobs           = 256      // entries in one hb
	MaxUntrackedSkipped = 1024     // manifest.untracked_skipped entries
	MaxKindLen          = 64       // hello.kind, reasons, codes
	MaxMsgLen           = 512      // refuse.msg, push_error
	MaxTextLen          = 8192     // question, limiter_resume_prompt
	MaxPathLen          = 1024     // any path-like field
	MaxStructBytes      = 64 << 10 // an object/array-valued job key
	MaxURLLen           = 2048
)

// Payload types, one per frame type that carries data.

// Auth is the hello.auth object, the extension point for non-peercred credentials (spec section 5).
// Phase 1 (peercred) sends only Method. A wss carrier adds a per-worker Credential and a worker-chosen
// Nonce; the credential's proof must cover HelloTranscript (which includes caps and the nonce), so a
// non-TLS carrier cannot downgrade the negotiated caps without invalidating it.
type Auth struct {
	Method     string `json:"method"`
	Credential string `json:"credential,omitempty"`
	Nonce      string `json:"nonce,omitempty"`
}

type Hello struct {
	ProtoMin   int      `json:"proto_min"`
	ProtoMax   int      `json:"proto_max"`
	Caps       []string `json:"caps"`
	WorkerID   string   `json:"worker_id"`
	InstanceID string   `json:"instance_id"`
	Kind       string   `json:"kind"`
	Auth       Auth     `json:"auth"`
}

type Welcome struct {
	Proto       int      `json:"proto"`
	Caps        []string `json:"caps"`
	HbIntervalS int      `json:"hb_interval_s"`
	LeaseTTLS   int      `json:"lease_ttl_s"`
}

type Refuse struct {
	Code        string `json:"code"`
	RetryAfterS *int   `json:"retry_after_s,omitempty"`
	Msg         string `json:"msg,omitempty"`
}

type HbJob struct {
	Job     string `json:"job"`
	Lease   string `json:"lease"`
	Epoch   int64  `json:"epoch"`
	LastSeq int64  `json:"last_seq"`
}

type Hb struct {
	Jobs []HbJob `json:"jobs"`
}

// AckData acknowledges a stream: Seq is the coordinator's applied_seq. ResendFrom, when set,
// asks the worker to resend from that seq (a gap was seen).
type AckData struct {
	Job        string `json:"job"`
	Lease      string `json:"lease"`
	Epoch      int64  `json:"epoch"`
	Seq        int64  `json:"seq"`
	ResendFrom *int64 `json:"resend_from,omitempty"`
}

type Bye struct {
	Reason string `json:"reason"`
}

type JobSet struct {
	Set map[string]json.RawMessage `json:"set"`
	Del []string                   `json:"del"`
}

type EventAppend struct {
	Line string `json:"line"`
}

type RecordAppend struct {
	Stream string `json:"stream"`
	Line   string `json:"line"`
}

type LogAppend struct {
	Offset int64  `json:"offset"`
	B64    string `json:"b64"`
}

type ArtifactPut struct {
	Path   string `json:"path"`
	Offset int64  `json:"offset"`
	B64    string `json:"b64"`
	Final  bool   `json:"final"`
	SHA256 string `json:"sha256,omitempty"`
}

type CheckpointTaken struct {
	Manifest Manifest `json:"manifest"`
}

type LeaseRelease struct {
	Reason   string `json:"reason"`
	FinalSHA string `json:"final_sha,omitempty"`
}

// Commands: every command payload carries CmdID.

type LeaseOffer struct {
	CmdID      string          `json:"cmd_id"`
	JobDoc     json.RawMessage `json:"job_doc"`
	Plan       string          `json:"plan"`
	CrewBundle json.RawMessage `json:"crew_bundle,omitempty"`
	Checkpoint json.RawMessage `json:"checkpoint,omitempty"`
	Repo       string          `json:"repo"`
	Attempt    int             `json:"attempt"`
}

type LeaseRevoke struct {
	CmdID  string `json:"cmd_id"`
	Reason string `json:"reason"`
}

type Cancel struct {
	CmdID string `json:"cmd_id"`
}

type Hold struct {
	CmdID  string `json:"cmd_id"`
	Code   string `json:"code"`
	Reason string `json:"reason"`
}

type ReleaseCmd struct {
	CmdID string `json:"cmd_id"`
}

type SyncJob struct {
	CmdID string                     `json:"cmd_id"`
	Set   map[string]json.RawMessage `json:"set"`
}

// SyncFile: Content is a JSON string, or JSON null to delete the file. It must be present.
type SyncFile struct {
	CmdID   string          `json:"cmd_id"`
	Path    string          `json:"path"`
	Content json.RawMessage `json:"content"`
}

const (
	OutcomeApplied   = "applied"
	OutcomeDuplicate = "duplicate"
	OutcomeRejected  = "rejected"
)

// CmdAck acknowledges one command. It carries the job/lease/epoch envelope of the command it
// answers and is fence-checked like a stream frame. The one exemption is For == "sync.file": that
// command is not job-scoped, so its ack has a null job/lease/epoch and is bound only to the
// authenticated connection.
type CmdAck struct {
	CmdID   string `json:"cmd_id"`
	Outcome string `json:"outcome"`
	Why     string `json:"why,omitempty"`
	For     string `json:"for,omitempty"`
}

// Frame vocabularies. Unexported so a caller cannot widen them at run time; read copies through
// RecordStreams and SyncFilePaths.
var (
	recordStreams = []string{"metrics/runs.jsonl"}
	syncFilePaths = []string{"limiter/mode.json", "quota-gate.json", "ratelimit-until"}
)

// RecordStreams lists the streams record.append may target (a copy). P1-2's inventory extends it.
func RecordStreams() []string { return append([]string(nil), recordStreams...) }

// SyncFilePaths is the sync.file path allowlist, relative to $MOTHER_ROOT (a copy).
func SyncFilePaths() []string { return append([]string(nil), syncFilePaths...) }

var (
	sha256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)
	idRe     = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,128}$`)
	tokenRe  = regexp.MustCompile(`^[A-Za-z0-9._:-]{1,64}$`)
	tsRe     = regexp.MustCompile(`^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$`)
)

// IDOK reports whether s is a well-formed id (job, lease, session, frame or command id): 1..128 of
// [A-Za-z0-9._:-] with no "..". The job id is interpolated into ref names and paths, so this is the
// gate before any WipRef(job) or artifact path.
func IDOK(s string) bool { return idRe.MatchString(s) && !strings.Contains(s, "..") }

// TimestampOK reports whether s is a protocol timestamp (UTC, exactly 3 fractional digits).
func TimestampOK(s string) bool {
	if !tsRe.MatchString(s) {
		return false
	}
	_, err := time.Parse("2006-01-02T15:04:05.000Z", s)
	return err == nil
}

// textOK reports whether s is valid UTF-8 within max bytes with no control characters other than
// \n and \t (so no NUL, ESC or CR).
func textOK(s string, max int) bool {
	if len(s) > max || !utf8.ValidString(s) {
		return false
	}
	for _, r := range s {
		if r < 0x20 && r != '\n' && r != '\t' || r == 0x7f {
			return false
		}
	}
	return true
}

func contains(list []string, s string) bool {
	for _, x := range list {
		if x == s {
			return true
		}
	}
	return false
}

// parseData unmarshals f.Data into T; absent or null data is treated as an empty object.
func parseData[T any](f Frame) (T, error) {
	var v T
	d := bytes.TrimSpace(f.Data)
	if len(d) == 0 || string(d) == "null" {
		d = []byte("{}")
	}
	if d[0] == '{' {
		if _, err := scanObjectKeys(d, jsonKeys(reflect.TypeOf(v))); err != nil {
			return v, protoErr(CodeInvalid, "%s data: %v", f.T, err)
		}
	}
	if err := json.Unmarshal(d, &v); err != nil {
		return v, protoErr(CodeInvalid, "%s data: %v", f.T, err)
	}
	return v, nil
}

// jsonKeys lists the wire names of a payload struct, so parseData can refuse duplicate and
// case-variant keys inside data too (unknown, non-variant keys stay tolerated there).
func jsonKeys(t reflect.Type) []string {
	var out []string
	for i := 0; i < t.NumField(); i++ {
		name, _, _ := strings.Cut(t.Field(i).Tag.Get("json"), ",")
		if name != "" && name != "-" {
			out = append(out, name)
		}
	}
	return out
}

func needEnvelope(f Frame, job, lease, epoch, seq bool) error {
	if job && (f.Job == nil || !IDOK(*f.Job)) {
		return protoErr(CodeInvalid, "%s: job required", f.T)
	}
	if lease && (f.Lease == nil || !IDOK(*f.Lease)) {
		return protoErr(CodeInvalid, "%s: lease required", f.T)
	}
	if epoch && (f.Epoch == nil || *f.Epoch < 1) {
		return protoErr(CodeInvalid, "%s: epoch >= 1 required", f.T)
	}
	if seq && (f.Seq == nil || *f.Seq < 1) {
		return protoErr(CodeInvalid, "%s: seq >= 1 required", f.T)
	}
	return nil
}

func decodeChunk(b64 string) (int, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return 0, protoErr(CodeInvalid, "b64: %v", err)
	}
	if len(raw) > MaxChunkBytes {
		return 0, protoErr(CodeTooLarge, "chunk is %d raw bytes, limit %d", len(raw), MaxChunkBytes)
	}
	return len(raw), nil
}

// ArtifactPathOK reports whether p is a relative, clean path confined to crew/<job>/ or
// checkpoints/<job>/ (and names something below that directory).
func ArtifactPathOK(job, p string) bool {
	if !IDOK(job) {
		return false
	}
	if p == "" || len(p) > MaxPathLen || !textOK(p, MaxPathLen) || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") || path.Clean(p) != p {
		return false
	}
	for _, root := range []string{"crew/" + job + "/", "checkpoints/" + job + "/"} {
		if strings.HasPrefix(p, root) && len(p) > len(root) {
			return true
		}
	}
	return false
}

// Direction is which side sent a frame.
type Direction int

const (
	FromWorker Direction = iota
	FromCoordinator
)

// AllowedFromWorker reports whether a worker may send frame type t: its hello, heartbeats, command
// acks, bye and the seq-numbered stream frames. Everything else (lease.offer, lease.revoke, cancel,
// hold, release, sync.job, sync.file, welcome, refuse, ack) is coordinator-only.
func AllowedFromWorker(t string) bool {
	return streamTypes[t] || t == TypeHello || t == TypeHb || t == TypeCmdAck || t == TypeBye
}

// AllowedFromCoordinator reports whether the coordinator may send t: welcome, refuse, ack, bye and the
// commands. Worker-only types (hello, hb, cmd.ack, every stream type) are refused.
func AllowedFromCoordinator(t string) bool {
	return commandTypes[t] || t == TypeWelcome || t == TypeRefuse || t == TypeAck || t == TypeBye
}

// ValidateFrom is Validate plus the direction rule: a frame type the sender may not send is invalid.
func ValidateFrom(dir Direction, f Frame) error {
	if f.V != Version {
		return protoErr(CodeVersion, "unsupported envelope v %d", f.V)
	}
	if !KnownType(f.T) {
		return protoErr(CodeUnsupported, "unknown frame type %q", f.T)
	}
	if dir == FromWorker && !AllowedFromWorker(f.T) {
		return protoErr(CodeInvalid, "%s may not be sent by a worker", f.T)
	}
	if dir == FromCoordinator && !AllowedFromCoordinator(f.T) {
		return protoErr(CodeInvalid, "%s may not be sent by the coordinator", f.T)
	}
	return Validate(f)
}

func capsOK(caps []string) error {
	if len(caps) > MaxCaps {
		return protoErr(CodeInvalid, "caps: %d entries, limit %d", len(caps), MaxCaps)
	}
	for _, c := range caps {
		if !tokenRe.MatchString(c) || len(c) > MaxCapLen {
			return protoErr(CodeInvalid, "caps: bad capability flag")
		}
	}
	return nil
}

// Validate checks f's shape: envelope field shapes, the fields the type requires, and its data
// (bounds, charsets, ownership of job.set keys). It is direction-agnostic; use ValidateFrom (or
// Admitter.Admit) at a trust boundary. Errors are *ProtoError.
func Validate(f Frame) error {
	if f.V != Version {
		return protoErr(CodeVersion, "unsupported envelope v %d", f.V)
	}
	if !KnownType(f.T) {
		return protoErr(CodeUnsupported, "unknown frame type %q", f.T)
	}
	if !IDOK(f.ID) {
		return protoErr(CodeInvalid, "bad frame id")
	}
	if !TimestampOK(f.TS) {
		return protoErr(CodeInvalid, "bad ts (want UTC with 3 fractional digits)")
	}
	if f.Job != nil && !IDOK(*f.Job) || f.Lease != nil && !IDOK(*f.Lease) {
		return protoErr(CodeInvalid, "bad job or lease id")
	}
	if f.Epoch != nil && *f.Epoch < 1 || f.Seq != nil && *f.Seq < 1 || f.Ack != nil && *f.Ack < 0 {
		return protoErr(CodeInvalid, "bad epoch, seq or ack")
	}
	if streamTypes[f.T] {
		if err := needEnvelope(f, true, true, true, true); err != nil {
			return err
		}
	}
	switch f.T {
	case TypeHello:
		h, err := parseData[Hello](f)
		if err != nil {
			return err
		}
		if h.ProtoMin < 1 || h.ProtoMax < h.ProtoMin {
			return protoErr(CodeInvalid, "hello: bad proto range %d..%d", h.ProtoMin, h.ProtoMax)
		}
		if !IDOK(h.WorkerID) || !IDOK(h.InstanceID) || !tokenRe.MatchString(h.Kind) || !tokenRe.MatchString(h.Auth.Method) {
			return protoErr(CodeInvalid, "hello: worker_id, instance_id, kind and auth.method must be well-formed")
		}
		if len(h.Auth.Credential) > 4096 || !textOK(h.Auth.Credential, 4096) || len(h.Auth.Nonce) > MaxIDLen || !textOK(h.Auth.Nonce, MaxIDLen) {
			return protoErr(CodeInvalid, "hello: bad auth credential or nonce")
		}
		return capsOK(h.Caps)
	case TypeWelcome:
		w, err := parseData[Welcome](f)
		if err != nil {
			return err
		}
		if w.Proto < 1 {
			return protoErr(CodeInvalid, "welcome: proto required")
		}
		return capsOK(w.Caps)
	case TypeRefuse:
		r, err := parseData[Refuse](f)
		if err != nil {
			return err
		}
		if !errorCodes[r.Code] {
			return protoErr(CodeInvalid, "refuse: unknown code %q", r.Code)
		}
		if !textOK(r.Msg, MaxMsgLen) || r.RetryAfterS != nil && *r.RetryAfterS < 0 {
			return protoErr(CodeInvalid, "refuse: bad msg or retry_after_s")
		}
	case TypeHb:
		h, err := parseData[Hb](f)
		if err != nil {
			return err
		}
		if len(h.Jobs) > MaxHbJobs {
			return protoErr(CodeInvalid, "hb: %d jobs, limit %d", len(h.Jobs), MaxHbJobs)
		}
		for _, j := range h.Jobs {
			if !IDOK(j.Job) || !IDOK(j.Lease) || j.Epoch < 1 || j.LastSeq < 0 {
				return protoErr(CodeInvalid, "hb: bad job entry")
			}
		}
	case TypeAck:
		a, err := parseData[AckData](f)
		if err != nil {
			return err
		}
		if !IDOK(a.Job) || !IDOK(a.Lease) || a.Epoch < 1 || a.Seq < 0 {
			return protoErr(CodeInvalid, "ack: job, lease, epoch and seq are required")
		}
	case TypeBye:
		b, err := parseData[Bye](f)
		if err != nil {
			return err
		}
		if b.Reason == "" || !textOK(b.Reason, MaxMsgLen) {
			return protoErr(CodeInvalid, "bye: reason required")
		}
	case TypeJobSet:
		s, err := parseData[JobSet](f)
		if err != nil {
			return err
		}
		if len(s.Set) == 0 && len(s.Del) == 0 {
			return protoErr(CodeInvalid, "job.set: set or del required")
		}
		if len(s.Set) > MaxKeys || len(s.Del) > MaxKeys {
			return protoErr(CodeInvalid, "job.set: more than %d keys", MaxKeys)
		}
		if vs := checkJobSetStatic(s.Set, s.Del); len(vs) > 0 {
			return protoErr(vs[0].Code, "job.set: %s: %s", vs[0].Key, vs[0].Reason)
		}
	case TypeEventAppend:
		e, err := parseData[EventAppend](f)
		if err != nil {
			return err
		}
		if e.Line == "" || strings.Contains(e.Line, "\n") || !textOK(e.Line, MaxFrameBytes) {
			return protoErr(CodeInvalid, "event.append: line must be a single non-empty line")
		}
	case TypeRecordAppend:
		r, err := parseData[RecordAppend](f)
		if err != nil {
			return err
		}
		if !contains(recordStreams, r.Stream) {
			return protoErr(CodeInvalid, "record.append: stream %q not allowed", r.Stream)
		}
		if r.Line == "" || strings.Contains(r.Line, "\n") || !textOK(r.Line, MaxFrameBytes) {
			return protoErr(CodeInvalid, "record.append: line must be a single non-empty line")
		}
	case TypeLogAppend:
		l, err := parseData[LogAppend](f)
		if err != nil {
			return err
		}
		if l.Offset < 0 {
			return protoErr(CodeInvalid, "log.append: negative offset")
		}
		if _, err := decodeChunk(l.B64); err != nil {
			return err
		}
	case TypeArtifactPut:
		a, err := parseData[ArtifactPut](f)
		if err != nil {
			return err
		}
		if !ArtifactPathOK(*f.Job, a.Path) {
			return protoErr(CodeInvalid, "artifact.put: path not allowed for job %s", *f.Job)
		}
		if a.Offset < 0 {
			return protoErr(CodeInvalid, "artifact.put: negative offset")
		}
		if a.SHA256 != "" && !sha256Re.MatchString(a.SHA256) {
			return protoErr(CodeInvalid, "artifact.put: bad sha256")
		}
		if _, err := decodeChunk(a.B64); err != nil {
			return err
		}
	case TypeCheckpointTaken:
		c, err := parseData[CheckpointTaken](f)
		if err != nil {
			return err
		}
		if err := ValidateManifest(c.Manifest); err != nil {
			return err
		}
		if c.Manifest.Job != *f.Job || c.Manifest.Lease != *f.Lease || c.Manifest.Epoch != *f.Epoch {
			return protoErr(CodeInvalid, "checkpoint.taken: manifest job/lease/epoch must match the envelope")
		}
	case TypeLeaseRelease:
		r, err := parseData[LeaseRelease](f)
		if err != nil {
			return err
		}
		if !tokenRe.MatchString(r.Reason) {
			return protoErr(CodeInvalid, "lease.release: reason required")
		}
		if r.FinalSHA != "" && !shaOK(r.FinalSHA) {
			return protoErr(CodeInvalid, "lease.release: bad final_sha")
		}
	case TypeLeaseOffer:
		if err := needEnvelope(f, true, true, true, false); err != nil {
			return err
		}
		o, err := parseData[LeaseOffer](f)
		if err != nil {
			return err
		}
		if err := needCmdID(f.T, o.CmdID); err != nil {
			return err
		}
		if len(o.JobDoc) == 0 || o.JobDoc[0] != '{' || !textOK(o.Repo, 256) || o.Repo == "" || o.Attempt < 1 {
			return protoErr(CodeInvalid, "lease.offer: job_doc object, repo and attempt >= 1 required")
		}
	case TypeLeaseRevoke:
		if err := needEnvelope(f, true, true, true, false); err != nil {
			return err
		}
		r, err := parseData[LeaseRevoke](f)
		if err != nil {
			return err
		}
		if err := needCmdID(f.T, r.CmdID); err != nil {
			return err
		}
		if !tokenRe.MatchString(r.Reason) {
			return protoErr(CodeInvalid, "lease.revoke: reason required")
		}
	case TypeCancel:
		if err := needEnvelope(f, true, true, true, false); err != nil {
			return err
		}
		c, err := parseData[Cancel](f)
		if err != nil {
			return err
		}
		return needCmdID(f.T, c.CmdID)
	case TypeRelease:
		if err := needEnvelope(f, true, true, true, false); err != nil {
			return err
		}
		c, err := parseData[ReleaseCmd](f)
		if err != nil {
			return err
		}
		return needCmdID(f.T, c.CmdID)
	case TypeHold:
		if err := needEnvelope(f, true, true, true, false); err != nil {
			return err
		}
		h, err := parseData[Hold](f)
		if err != nil {
			return err
		}
		if err := needCmdID(f.T, h.CmdID); err != nil {
			return err
		}
		if !tokenRe.MatchString(h.Code) || !textOK(h.Reason, MaxMsgLen) || h.Reason == "" {
			return protoErr(CodeInvalid, "hold: code and reason required")
		}
	case TypeSyncJob:
		if err := needEnvelope(f, true, true, true, false); err != nil {
			return err
		}
		s, err := parseData[SyncJob](f)
		if err != nil {
			return err
		}
		if err := needCmdID(f.T, s.CmdID); err != nil {
			return err
		}
		if len(s.Set) == 0 || len(s.Set) > MaxKeys {
			return protoErr(CodeInvalid, "sync.job: set required, at most %d keys", MaxKeys)
		}
		for k, v := range s.Set {
			if !contains(SyncDownKeys, k) {
				return protoErr(CodeOwnership, "sync.job: key %q does not flow down", k)
			}
			if len(v) > MaxStructBytes {
				return protoErr(CodeTooLarge, "sync.job: value for %q is too large", k)
			}
		}
	case TypeSyncFile:
		s, err := parseData[SyncFile](f)
		if err != nil {
			return err
		}
		if err := needCmdID(f.T, s.CmdID); err != nil {
			return err
		}
		if !contains(syncFilePaths, s.Path) {
			return protoErr(CodeInvalid, "sync.file: path not allowed")
		}
		c := bytes.TrimSpace(s.Content)
		if len(c) == 0 || (string(c) != "null" && c[0] != '"') {
			return protoErr(CodeInvalid, "sync.file: content must be a string or null")
		}
	case TypeCmdAck:
		a, err := parseData[CmdAck](f)
		if err != nil {
			return err
		}
		if err := needCmdID(f.T, a.CmdID); err != nil {
			return err
		}
		if a.Outcome != OutcomeApplied && a.Outcome != OutcomeDuplicate && a.Outcome != OutcomeRejected {
			return protoErr(CodeInvalid, "cmd.ack: bad outcome %q", a.Outcome)
		}
		if !textOK(a.Why, MaxMsgLen) || a.For != "" && !commandTypes[a.For] {
			return protoErr(CodeInvalid, "cmd.ack: bad why or for")
		}
		if a.For != TypeSyncFile {
			return needEnvelope(f, true, true, true, false)
		}
	}
	return nil
}

func shaOK(s string) bool { return len(s) == 40 && hexRe.MatchString(s) || sha256Re.MatchString(s) }

var hexRe = regexp.MustCompile(`^[0-9a-f]+$`)

func needCmdID(t, id string) error {
	if !IDOK(id) {
		return protoErr(CodeInvalid, "%s: cmd_id required", t)
	}
	return nil
}
