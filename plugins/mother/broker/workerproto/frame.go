// Package workerproto implements Mother's worker protocol v1 (docs/worker-protocol.md):
// the frame envelope and codec, handshake negotiation, per-job stream state machines, the
// lease table, command dedupe and the job-field ownership table.
//
// The package is pure: no goroutines, clocks, files or sockets. Time is always a parameter.
// A test enforces that no non-test file reaches for os, net, os/exec, io/ioutil or time.Now.
package workerproto

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"time"
)

const (
	// Version is the envelope version this package speaks.
	Version = 1
	// MaxFrameBytes is the frame size limit, newline included.
	MaxFrameBytes = 1 << 20
	// MaxChunkBytes is the raw-byte limit of one log.append / artifact.put payload.
	MaxChunkBytes = 256 << 10
)

// Frame types.
const (
	TypeHello   = "hello"
	TypeWelcome = "welcome"
	TypeRefuse  = "refuse"
	TypeHb      = "hb"
	TypeAck     = "ack"
	TypeBye     = "bye"

	TypeJobSet          = "job.set"
	TypeEventAppend     = "event.append"
	TypeRecordAppend    = "record.append"
	TypeLogAppend       = "log.append"
	TypeArtifactPut     = "artifact.put"
	TypeCheckpointTaken = "checkpoint.taken"
	TypeLeaseRelease    = "lease.release"

	TypeLeaseOffer  = "lease.offer"
	TypeLeaseRevoke = "lease.revoke"
	TypeCancel      = "cancel"
	TypeHold        = "hold"
	TypeRelease     = "release"
	TypeSyncJob     = "sync.job"
	TypeSyncFile    = "sync.file"

	TypeCmdAck = "cmd.ack"
)

// Error codes (spec section 10).
const (
	CodeVersion         = "version"
	CodeAuthUnsupported = "auth_unsupported"
	CodeAuthFailed      = "auth_failed"
	CodeFenced          = "fenced"
	CodeUnknownJob      = "unknown_job"
	CodeNotLeased       = "not_leased"
	CodeGap             = "gap"
	CodeTooLarge        = "too_large"
	CodeInvalid         = "invalid"
	CodeUnsupported     = "unsupported"
	CodeOwnership       = "ownership"
	CodeBusy            = "busy"
)

var errorCodes = map[string]bool{
	CodeVersion: true, CodeAuthUnsupported: true, CodeAuthFailed: true, CodeFenced: true,
	CodeUnknownJob: true, CodeNotLeased: true, CodeGap: true, CodeTooLarge: true,
	CodeInvalid: true, CodeUnsupported: true, CodeOwnership: true, CodeBusy: true,
}

// ProtoError is an error carrying a protocol error code.
type ProtoError struct {
	Code string
	Msg  string
}

func (e *ProtoError) Error() string { return e.Code + ": " + e.Msg }

func protoErr(code, format string, args ...any) *ProtoError {
	return &ProtoError{Code: code, Msg: fmt.Sprintf(format, args...)}
}

// ErrorCode returns the protocol code of err, or "" if err is not a *ProtoError.
func ErrorCode(err error) string {
	var pe *ProtoError
	if errors.As(err, &pe) {
		return pe.Code
	}
	return ""
}

// Frame is the v1 envelope. Field order is the wire key order; Data stays raw so re-encoding a
// decoded frame is byte-identical.
type Frame struct {
	V     int             `json:"v"`
	T     string          `json:"t"`
	ID    string          `json:"id"`
	TS    string          `json:"ts"`
	Job   *string         `json:"job"`
	Lease *string         `json:"lease"`
	Epoch *int64          `json:"epoch"`
	Seq   *int64          `json:"seq"`
	Ack   *int64          `json:"ack"`
	Data  json.RawMessage `json:"data"`
}

// Frame-type classification.
var (
	streamTypes = map[string]bool{
		TypeJobSet: true, TypeEventAppend: true, TypeRecordAppend: true, TypeLogAppend: true,
		TypeArtifactPut: true, TypeCheckpointTaken: true, TypeLeaseRelease: true,
	}
	commandTypes = map[string]bool{
		TypeLeaseOffer: true, TypeLeaseRevoke: true, TypeCancel: true, TypeHold: true,
		TypeRelease: true, TypeSyncJob: true, TypeSyncFile: true,
	}
	controlTypes = map[string]bool{
		TypeHello: true, TypeWelcome: true, TypeRefuse: true, TypeHb: true, TypeAck: true,
		TypeBye: true, TypeCmdAck: true,
	}
)

// IsStreamType reports whether t is a worker-to-coordinator, seq-numbered stream frame.
func IsStreamType(t string) bool { return streamTypes[t] }

// IsCommandType reports whether t is a coordinator-to-worker command (carries cmd_id).
func IsCommandType(t string) bool { return commandTypes[t] }

// KnownType reports whether t is a v1 frame type.
func KnownType(t string) bool { return streamTypes[t] || commandTypes[t] || controlTypes[t] }

// Timestamp formats t like _iso_now in lib/state.sh: UTC, exactly 3 fractional digits.
func Timestamp(t time.Time) string { return t.UTC().Format("2006-01-02T15:04:05.000Z") }

// Encode renders f as one NDJSON line (newline terminated). It refuses frames over MaxFrameBytes.
func Encode(f Frame) ([]byte, error) {
	b, err := json.Marshal(f)
	if err != nil {
		return nil, protoErr(CodeInvalid, "encode: %v", err)
	}
	b = append(b, '\n')
	if len(b) > MaxFrameBytes {
		return nil, protoErr(CodeTooLarge, "frame is %d bytes, limit %d", len(b), MaxFrameBytes)
	}
	return b, nil
}

// Decode parses one NDJSON line (trailing newline optional). It checks the envelope only: size,
// framing, v and a known t. Use Validate for the per-type data checks.
func Decode(line []byte) (Frame, error) {
	var f Frame
	body := bytes.TrimSuffix(line, []byte("\n"))
	if len(body)+1 > MaxFrameBytes {
		return f, protoErr(CodeTooLarge, "frame is %d bytes, limit %d", len(body)+1, MaxFrameBytes)
	}
	if bytes.IndexByte(body, '\n') >= 0 {
		return f, protoErr(CodeInvalid, "embedded newline")
	}
	if err := json.Unmarshal(body, &f); err != nil {
		return Frame{}, protoErr(CodeInvalid, "json: %v", err)
	}
	if f.V == 0 {
		return Frame{}, protoErr(CodeInvalid, "missing v")
	}
	if f.V != Version {
		return Frame{}, protoErr(CodeInvalid, "unsupported envelope v %d", f.V)
	}
	if f.T == "" {
		return Frame{}, protoErr(CodeInvalid, "missing t")
	}
	if !KnownType(f.T) {
		return f, protoErr(CodeUnsupported, "unknown frame type %q", f.T)
	}
	return f, nil
}

// NewFrame builds an envelope with a payload marshalled from data (nil data encodes as null).
func NewFrame(t, id string, ts time.Time, data any) (Frame, error) {
	f := Frame{V: Version, T: t, ID: id, TS: Timestamp(ts)}
	if data != nil {
		b, err := json.Marshal(data)
		if err != nil {
			return Frame{}, protoErr(CodeInvalid, "marshal data: %v", err)
		}
		f.Data = b
	}
	return f, nil
}

// Str, Int return pointers for building envelopes.
func Str(s string) *string { return &s }
func Int(n int64) *int64   { return &n }
