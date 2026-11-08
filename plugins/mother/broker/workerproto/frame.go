// Package workerproto implements Mother's worker protocol v1 (docs/worker-protocol.md):
// the frame envelope and codec, handshake negotiation, per-job stream state machines, the
// lease table, command dedupe and the job-field ownership table.
//
// The package is pure: no goroutines, clocks, files or sockets. Time is always a parameter.
// An AST-walking test (purity_test.go) enforces it: no I/O, randomness, sync or log imports, no go
// statements and no wall-clock calls.
package workerproto

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
	"unicode/utf8"
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

// envelopeKeys are the only top-level keys an envelope may carry, in wire order.
var envelopeKeys = []string{"v", "t", "id", "ts", "job", "lease", "epoch", "seq", "ack", "data"}

// scanObjectKeys walks the top level of one JSON object, returning its keys in order. It rejects
// anything that is not exactly one object, duplicate keys, and (when known is non-nil) any key that
// is a case-variant of a known key without being it: encoding/json matches keys case-insensitively
// and keeps the last duplicate, so a non-canonical frame could otherwise say different things to
// different parsers. Unknown keys are returned for the caller to judge.
func scanObjectKeys(b []byte, known []string) ([]string, error) {
	dec := json.NewDecoder(bytes.NewReader(b))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		return nil, protoErr(CodeInvalid, "frame must be a JSON object")
	}
	var keys []string
	seen := map[string]bool{}
	for dec.More() {
		tok, err := dec.Token()
		if err != nil {
			return nil, protoErr(CodeInvalid, "json: %v", err)
		}
		k, _ := tok.(string)
		if seen[k] {
			return nil, protoErr(CodeInvalid, "duplicate key %q", k)
		}
		seen[k] = true
		for _, kk := range known {
			if k != kk && strings.EqualFold(k, kk) {
				return nil, protoErr(CodeInvalid, "key %q is a case-variant of %q", k, kk)
			}
		}
		keys = append(keys, k)
		var skip json.RawMessage
		if err := dec.Decode(&skip); err != nil {
			return nil, protoErr(CodeInvalid, "json: %v", err)
		}
	}
	if _, err := dec.Token(); err != nil {
		return nil, protoErr(CodeInvalid, "json: %v", err)
	}
	if _, err := dec.Token(); err != io.EOF {
		return nil, protoErr(CodeInvalid, "trailing data after frame")
	}
	return keys, nil
}

// loneSurrogateEscape reports a JSON \uD800-\uDFFF escape that is not half of a valid pair: encoding/json
// silently turns it into U+FFFD, so the text a parser sees would differ from what was sent.
func loneSurrogateEscape(b []byte) bool {
	hex4 := func(i int) (rune, bool) {
		if i+6 > len(b) || b[i] != '\\' || b[i+1] != 'u' {
			return 0, false
		}
		var r rune
		for _, c := range b[i+2 : i+6] {
			switch {
			case c >= '0' && c <= '9':
				r = r<<4 | rune(c-'0')
			case c >= 'a' && c <= 'f':
				r = r<<4 | rune(c-'a'+10)
			case c >= 'A' && c <= 'F':
				r = r<<4 | rune(c-'A'+10)
			default:
				return 0, false
			}
		}
		return r, true
	}
	for i := 0; i < len(b); i++ {
		if b[i] != '\\' {
			continue
		}
		if r, ok := hex4(i); ok && r >= 0xD800 && r <= 0xDFFF {
			if r >= 0xDC00 {
				return true // low surrogate with no high before it (a valid pair is consumed below)
			}
			lo, ok := hex4(i + 6)
			if !ok || lo < 0xDC00 || lo > 0xDFFF {
				return true
			}
			i += 11
			continue
		}
		i++ // skip the escaped character, so \\ud800 (a literal backslash) is not misread
	}
	return false
}

// Decode parses one NDJSON line (trailing newline optional). It checks the envelope only: size,
// framing, valid UTF-8, strict keys (no duplicates, no case-variants, no unknown envelope keys:
// only data tolerates additive fields), v and a known t. A v other than 1 is `version`, not
// `invalid`, so a v:2 hello can be answered with refuse{version}. Use Validate for the per-type
// data checks.
func Decode(line []byte) (Frame, error) {
	var f Frame
	body := bytes.TrimSuffix(line, []byte("\n"))
	if len(body)+1 > MaxFrameBytes {
		return f, protoErr(CodeTooLarge, "frame is %d bytes, limit %d", len(body)+1, MaxFrameBytes)
	}
	if bytes.IndexByte(body, '\n') >= 0 {
		return f, protoErr(CodeInvalid, "embedded newline")
	}
	if !utf8.Valid(body) {
		return f, protoErr(CodeInvalid, "invalid UTF-8")
	}
	if loneSurrogateEscape(body) {
		return f, protoErr(CodeInvalid, "lone surrogate escape")
	}
	keys, err := scanObjectKeys(body, envelopeKeys)
	if err != nil {
		return Frame{}, err
	}
	for _, k := range keys {
		if !contains(envelopeKeys, k) {
			return Frame{}, protoErr(CodeInvalid, "unknown envelope key %q (additive fields belong in data)", k)
		}
	}
	if err := json.Unmarshal(body, &f); err != nil {
		return Frame{}, protoErr(CodeInvalid, "json: %v", err)
	}
	if f.V == 0 {
		return Frame{}, protoErr(CodeInvalid, "missing v")
	}
	if f.V != Version {
		return f, protoErr(CodeVersion, "unsupported envelope v %d", f.V)
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

// ReadFrame reads one line from r, enforcing MaxFrameBytes (newline included) while reading: a line
// that has not ended by then yields too_large after at most MaxFrameBytes plus one buffer of input is
// consumed, never the whole line. The caller must close the connection after too_large (the rest of
// the line is unread). Partial data at EOF is io.ErrUnexpectedEOF, since a frame is newline terminated.
func ReadFrame(r *bufio.Reader) ([]byte, error) {
	var buf []byte
	for {
		chunk, err := r.ReadSlice('\n')
		buf = append(buf, chunk...)
		if len(buf) > MaxFrameBytes {
			return nil, protoErr(CodeTooLarge, "frame exceeds %d bytes", MaxFrameBytes)
		}
		switch err {
		case nil:
			return buf, nil
		case bufio.ErrBufferFull:
			continue
		case io.EOF:
			if len(buf) > 0 {
				return nil, io.ErrUnexpectedEOF
			}
			return nil, io.EOF
		default:
			return nil, err
		}
	}
}

// Str, Int return pointers for building envelopes.
func Str(s string) *string { return &s }
func Int(n int64) *int64   { return &n }
