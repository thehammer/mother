package workerproto

import (
	"encoding/json"
	"sort"
)

// The coordinator's supported envelope/protocol range. These are where Negotiate's serverMin and
// serverMax come from in production: the constants below, never a value taken from the peer or the
// environment. (Negotiate takes them as parameters so tests can model a newer coordinator.)
const (
	ProtoMin = 1
	ProtoMax = 1
)

// Handshake timing advertised in welcome.
const (
	HeartbeatIntervalS = 10
	LeaseTTLSeconds    = 180
)

// Capability flags in v1.
var KnownCaps = []string{"log.stream", "artifact.chunked", "checkpoint.v1", "hold.boundary", "os.darwin", "os.linux"}

// AuthMethodPeercred is the only auth method in Phase 1.
const AuthMethodPeercred = "peercred"

// Negotiate answers a hello. Exactly one of the returns is non-nil. Auth is checked before version.
// The welcome carries the highest common version and the intersection of caps (in server order).
func Negotiate(h Hello, serverMin, serverMax int, serverCaps []string) (*Welcome, *Refuse) {
	if h.Auth.Method != AuthMethodPeercred {
		return nil, &Refuse{Code: CodeAuthUnsupported, Msg: "auth method is not supported"}
	}
	hi := min(h.ProtoMax, serverMax)
	lo := max(h.ProtoMin, serverMin)
	if hi < lo {
		return nil, &Refuse{Code: CodeVersion, Msg: "no common protocol version"}
	}
	caps := []string{}
	for _, c := range serverCaps {
		if contains(h.Caps, c) {
			caps = append(caps, c)
		}
	}
	return &Welcome{Proto: hi, Caps: caps, HbIntervalS: HeartbeatIntervalS, LeaseTTLS: LeaseTTLSeconds}, nil
}

// RefuseFor turns a Decode/Validate error into the refuse the receiver should send: the error's
// protocol code (a v:2 envelope is `version`, not `invalid`) with a fixed message, so peer-supplied
// text is never echoed. Errors without a code answer `invalid`.
func RefuseFor(err error) Refuse {
	code := ErrorCode(err)
	if code == "" {
		code = CodeInvalid
	}
	msg := "frame refused"
	if code == CodeVersion {
		msg = "no common protocol version"
	}
	return Refuse{Code: code, Msg: msg}
}

// HelloTranscript is the canonical byte string a non-peercred credential must sign or MAC (spec
// section 5): protocol range, worker_id, instance_id, kind, auth.method, auth.nonce and the caps
// sorted. Because caps are inside it, a carrier without its own integrity (plain ws, or a relay that
// terminates TLS) cannot strip or add a capability without invalidating the proof. The coordinator
// must also check hello.worker_id against the identity the credential authenticates (Admitter.Admit does
// this for the identity it is given) and sign welcome the same way over the negotiated caps.
func HelloTranscript(h Hello) []byte {
	caps := append([]string{}, h.Caps...)
	sort.Strings(caps)
	b, _ := json.Marshal(struct {
		Min      int      `json:"proto_min"`
		Max      int      `json:"proto_max"`
		Caps     []string `json:"caps"`
		WorkerID string   `json:"worker_id"`
		Instance string   `json:"instance_id"`
		Kind     string   `json:"kind"`
		Method   string   `json:"method"`
		Nonce    string   `json:"nonce"`
	}{h.ProtoMin, h.ProtoMax, caps, h.WorkerID, h.InstanceID, h.Kind, h.Auth.Method, h.Auth.Nonce})
	return b
}
