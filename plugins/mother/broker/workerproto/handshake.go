package workerproto

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
		return nil, &Refuse{Code: CodeAuthUnsupported, Msg: "auth method " + h.Auth.Method + " is not supported"}
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
