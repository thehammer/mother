package workerproto

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"path"
	"regexp"
	"strings"
)

// Payload types, one per frame type that carries data.

type Auth struct {
	Method string `json:"method"`
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

type CmdAck struct {
	CmdID   string `json:"cmd_id"`
	Outcome string `json:"outcome"`
	Why     string `json:"why,omitempty"`
}

// Frame vocabularies.
var (
	// RecordStreams lists the streams record.append may target. P1-2's inventory extends this list.
	RecordStreams = []string{"metrics/runs.jsonl"}
	// SyncFilePaths is the sync.file path allowlist (relative to $MOTHER_ROOT).
	SyncFilePaths = []string{"limiter/mode.json", "quota-gate.json", "ratelimit-until"}
)

var sha256Re = regexp.MustCompile(`^[0-9a-f]{64}$`)

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
	if err := json.Unmarshal(d, &v); err != nil {
		return v, protoErr(CodeInvalid, "%s data: %v", f.T, err)
	}
	return v, nil
}

func needEnvelope(f Frame, job, lease, epoch, seq bool) error {
	if job && (f.Job == nil || *f.Job == "") {
		return protoErr(CodeInvalid, "%s: job required", f.T)
	}
	if lease && (f.Lease == nil || *f.Lease == "") {
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
	if p == "" || strings.HasPrefix(p, "/") || strings.Contains(p, "\\") || path.Clean(p) != p {
		return false
	}
	for _, root := range []string{"crew/" + job + "/", "checkpoints/" + job + "/"} {
		if strings.HasPrefix(p, root) && len(p) > len(root) {
			return true
		}
	}
	return false
}

// Validate checks f against its type's rules: envelope fields that type requires, and the data shape.
// Errors are *ProtoError (invalid, too_large, unsupported).
func Validate(f Frame) error {
	if f.V != Version {
		return protoErr(CodeInvalid, "unsupported envelope v %d", f.V)
	}
	if !KnownType(f.T) {
		return protoErr(CodeUnsupported, "unknown frame type %q", f.T)
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
		if h.WorkerID == "" || h.InstanceID == "" || h.Kind == "" || h.Auth.Method == "" {
			return protoErr(CodeInvalid, "hello: worker_id, instance_id, kind and auth.method are required")
		}
	case TypeWelcome:
		w, err := parseData[Welcome](f)
		if err != nil {
			return err
		}
		if w.Proto < 1 {
			return protoErr(CodeInvalid, "welcome: proto required")
		}
	case TypeRefuse:
		r, err := parseData[Refuse](f)
		if err != nil {
			return err
		}
		if !errorCodes[r.Code] {
			return protoErr(CodeInvalid, "refuse: unknown code %q", r.Code)
		}
	case TypeHb:
		h, err := parseData[Hb](f)
		if err != nil {
			return err
		}
		for _, j := range h.Jobs {
			if j.Job == "" || j.Lease == "" || j.Epoch < 1 || j.LastSeq < 0 {
				return protoErr(CodeInvalid, "hb: bad job entry %+v", j)
			}
		}
	case TypeAck:
		a, err := parseData[AckData](f)
		if err != nil {
			return err
		}
		if a.Job == "" || a.Lease == "" || a.Epoch < 1 || a.Seq < 0 {
			return protoErr(CodeInvalid, "ack: job, lease, epoch and seq are required")
		}
	case TypeBye:
		b, err := parseData[Bye](f)
		if err != nil {
			return err
		}
		if b.Reason == "" {
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
		for k := range s.Set {
			if k == "" {
				return protoErr(CodeInvalid, "job.set: empty key")
			}
		}
		for _, k := range s.Del {
			if k == "" {
				return protoErr(CodeInvalid, "job.set: empty del key")
			}
		}
	case TypeEventAppend:
		e, err := parseData[EventAppend](f)
		if err != nil {
			return err
		}
		if e.Line == "" || strings.Contains(e.Line, "\n") {
			return protoErr(CodeInvalid, "event.append: line must be a single non-empty line")
		}
	case TypeRecordAppend:
		r, err := parseData[RecordAppend](f)
		if err != nil {
			return err
		}
		if !contains(RecordStreams, r.Stream) {
			return protoErr(CodeInvalid, "record.append: stream %q not allowed", r.Stream)
		}
		if r.Line == "" || strings.Contains(r.Line, "\n") {
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
			return protoErr(CodeInvalid, "artifact.put: path %q not allowed for job %s", a.Path, *f.Job)
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
		if r.Reason == "" {
			return protoErr(CodeInvalid, "lease.release: reason required")
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
		if len(o.JobDoc) == 0 || o.JobDoc[0] != '{' || o.Repo == "" || o.Attempt < 1 {
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
		if r.Reason == "" {
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
		if h.Code == "" || h.Reason == "" {
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
		if len(s.Set) == 0 {
			return protoErr(CodeInvalid, "sync.job: set required")
		}
		for k := range s.Set {
			if !contains(SyncDownKeys, k) {
				return protoErr(CodeOwnership, "sync.job: key %q does not flow down", k)
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
		if !contains(SyncFilePaths, s.Path) {
			return protoErr(CodeInvalid, "sync.file: path %q not allowed", s.Path)
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
		if a.CmdID == "" {
			return protoErr(CodeInvalid, "cmd.ack: cmd_id required")
		}
		if a.Outcome != OutcomeApplied && a.Outcome != OutcomeDuplicate && a.Outcome != OutcomeRejected {
			return protoErr(CodeInvalid, "cmd.ack: bad outcome %q", a.Outcome)
		}
	}
	return nil
}

func needCmdID(t, id string) error {
	if id == "" {
		return protoErr(CodeInvalid, "%s: cmd_id required", t)
	}
	return nil
}
