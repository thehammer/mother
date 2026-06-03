package main

// envelope.go — the wire format (B3) and error vocabulary (B8).
//
// Every message in both directions is a single JSON object, one per line
// (NDJSON). This file owns the on-wire shape and is transport-blind: it
// never imports net and never touches a socket. The same encoding is used
// by the on-disk event logs (events/<id>.jsonl), so the broker's input and
// output share one format.

import (
	"encoding/json"
	"time"
)

// ProtocolVersion is the envelope version this broker speaks. It is reported
// in the connect-time `hello` and stamped on every message's `v` field.
const ProtocolVersion = 1

// Message direction tags (the `dir` field).
const (
	DirEvent = "event" // server→client, unsolicited
	DirCmd   = "cmd"   // client→server
	DirAck   = "ack"   // server→client, correlated reply to a cmd
)

// Error codes — a closed enumeration (B8). Clients switch on the code and
// never pattern-match the human-readable message.
const (
	ErrNoSuchJob       = "no_such_job"      // command names a job that does not exist
	ErrInvalidState    = "invalid_state"    // command invalid for the job's current state
	ErrMalformed       = "malformed"        // envelope/command failed to parse or validate
	ErrUnavailable     = "unavailable"      // broker transiently unable to serve; back off + retry
	ErrVersionMismatch = "version_mismatch" // client/broker protocol version incompatible
	ErrUnauthorized    = "unauthorized"     // reserved for the future network-auth path (W4); never returned by W1's local transport
	ErrInternal        = "internal"         // broker-side failure (e.g. CLI shell-out errored)
)

// Event/command/ack type tags (the `t` field).
const (
	// Server→client event types.
	TypeHello           = "hello"
	TypePing            = "ping"
	TypeSnapshot        = "snapshot"
	TypeCurrentActivity = "current_activity"
	TypeOutput          = "output" // W2 — carries a structured output sub-event

	// Client→server command names.
	CmdSubscribe   = "subscribe"
	CmdUnsubscribe = "unsubscribe"
	CmdQueryList   = "query.list"
	CmdQueryGet    = "query.get"
	CmdAnswer      = "answer"
	CmdCancel      = "cancel"
	CmdRetry       = "retry"
	CmdForceStart  = "force-start"
)

// Output event sub-types (data.subtype on TypeOutput events). These mirror
// the taxonomy mother-stream-pretty parses so the broker and pretty-printer
// agree on shape.
const (
	OutputSubtypeSystem     = "system"      // stream-json type=system subtype=init
	OutputSubtypeText       = "text"        // assistant content part type=text
	OutputSubtypeToolUse    = "tool_use"    // assistant content part type=tool_use
	OutputSubtypeToolResult = "tool_result" // user content part type=tool_result
	OutputSubtypeResult     = "result"      // stream-json type=result
	OutputSubtypeGap        = "gap"         // synthetic gap marker (slow client)
)

// Event categories (B4/B5). A subscription selects a subset of these.
const (
	CatState           = "state"
	CatActivity        = "activity"
	CatAwait           = "await"
	CatCurrentActivity = "current_activity"
	CatQuota           = "quota"
	CatOutput          = "output" // W2 — advertised as absent in W1's hello
)

// w1Categories is the full set of categories this broker knows about,
// including CatOutput (added in W2). The runtime-active set may be a subset
// when MOTHER_BROKER_OUTPUT_ENABLED=0; see liveCategories.
var w1Categories = []string{
	CatState, CatActivity, CatAwait, CatCurrentActivity, CatQuota, CatOutput,
}

// liveCategories is the runtime-active subset of w1Categories. Populated by
// main() based on config; defaults to w1Categories so tests get the full set
// without needing to call loadConfig. Both sendHello and validCategories read
// this variable, so they always agree.
var liveCategories = w1Categories

// w1Commands is the set of commands this W1 broker accepts.
var w1Commands = []string{
	CmdSubscribe, CmdUnsubscribe, CmdQueryList, CmdQueryGet,
	CmdAnswer, CmdCancel, CmdRetry, CmdForceStart,
}

// Message is the single envelope used in both directions.
type Message struct {
	V    int             `json:"v"`
	Dir  string          `json:"dir"`
	T    string          `json:"t"`
	ID   string          `json:"id"`
	Ts   string          `json:"ts"`
	Data json.RawMessage `json:"data,omitempty"`
}

// errorBody is the structured error carried by a failed ack's data.error.
type errorBody struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// isoNow returns a UTC timestamp in exactly the format lib/state.sh's
// _iso_now emits: millisecond precision, e.g. 2026-05-30T09:30:56.510Z.
//
// Matching that format is load-bearing: protocol events must sort
// lexicographically alongside the on-disk event logs, and Nostromo's Swift
// JSONDecoder .iso8601 strategy rejects 6-digit (microsecond) fractions.
func isoNow() string {
	return time.Now().UTC().Format("2006-01-02T15:04:05.000") + "Z"
}

// encode serializes a Message to a single NDJSON line (no trailing newline;
// the transport adds the framing newline). Any newline inside a string value
// is JSON-escaped by encoding/json, satisfying the no-embedded-newline rule.
func (m Message) encode() ([]byte, error) {
	return json.Marshal(m)
}

// decodeMessage parses one NDJSON line into a Message.
func decodeMessage(line []byte) (Message, error) {
	var m Message
	err := json.Unmarshal(line, &m)
	return m, err
}

// newEvent builds a server→client event message. The caller (per-connection
// writer) assigns the monotonic id.
func newEvent(t, id string, data json.RawMessage) Message {
	return Message{V: ProtocolVersion, Dir: DirEvent, T: t, ID: id, Ts: isoNow(), Data: data}
}

// newAck builds a correlated reply to a command. id mirrors the cmd's id.
func newAck(t, id string, data json.RawMessage) Message {
	return Message{V: ProtocolVersion, Dir: DirAck, T: t, ID: id, Ts: isoNow(), Data: data}
}

// okAck is a successful ack with an arbitrary data payload merged with ok:true.
func okAck(t, id string, payload map[string]any) Message {
	if payload == nil {
		payload = map[string]any{}
	}
	payload["ok"] = true
	data, _ := json.Marshal(payload)
	return newAck(t, id, data)
}

// errAck is a failed ack carrying a structured, machine-distinguishable error.
func errAck(t, id, code, msg string) Message {
	data, _ := json.Marshal(map[string]any{
		"ok":    false,
		"error": errorBody{Code: code, Message: msg},
	})
	return newAck(t, id, data)
}
