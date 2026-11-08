package workerproto

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
)

// CredentialProof is the hello.auth.credential for secret: HMAC-SHA256 over HelloTranscript(h). It lives
// here (not in the coordinator package) so the worker binary does not link the coordinator.
func CredentialProof(secret string, h Hello) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write(HelloTranscript(h))
	return hex.EncodeToString(m.Sum(nil))
}
