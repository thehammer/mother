package coord

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"syscall"

	"mother-broker/workerproto"
)

// Worker identity. Same-uid peercred only proves "some process of ours"; a job's agent is exactly that.
// So a worker id is bound twice: to a per-worker secret (proved in hello.auth.credential, an HMAC over
// the hello transcript with the worker's nonce) and to the worker daemon's pid (SO_PEERCRED/LOCAL_PEERPID).
// The secret is memory-only on both ends, handed over an inherited fd (or env var that scrubbedEnv drops).

// MinNonce is the shortest hello nonce accepted.
const MinNonce = 16

type workerCred struct {
	secret   []byte
	pid      int  // expected peer pid; 0 = not bound yet
	explicit bool // pid was registered (launch), not learned: never rebinds while registered
}

// NewSecret returns a fresh random worker secret (hex).
func NewSecret() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// CredentialProof is the hello.auth.credential for secret: HMAC-SHA256 over HelloTranscript(h).
func CredentialProof(secret string, h workerproto.Hello) string {
	m := hmac.New(sha256.New, []byte(secret))
	m.Write(workerproto.HelloTranscript(h))
	return hex.EncodeToString(m.Sum(nil))
}

// RegisterWorker makes id a known worker. pid is the worker daemon's pid when the caller launched it, or 0
// to bind to the first authenticated connection. Re-registering replaces the credential and drops any
// live connection of that id.
func (s *Server) RegisterWorker(id string, pid int, secret string) error {
	if !workerproto.IDOK(id) {
		return fmt.Errorf("bad worker id %q", id)
	}
	if len(secret) < 16 {
		return errors.New("worker secret too short")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.creds[id] = &workerCred{secret: []byte(secret), pid: pid, explicit: pid > 0}
	if old := s.workers[id]; old != nil {
		old.close()
	}
	return nil
}

// LaunchWorker starts cmd as the worker daemon for id: a fresh secret goes to it over an inherited pipe
// (fd 3, MOTHER_WORKER_SECRET_FD=3) and its pid is registered. The caller configures cmd otherwise.
func (s *Server) LaunchWorker(id string, cmd *exec.Cmd) error {
	secret := NewSecret()
	r, w, err := os.Pipe()
	if err != nil {
		return err
	}
	if _, err := w.WriteString(secret + "\n"); err != nil {
		r.Close()
		w.Close()
		return err
	}
	w.Close()
	defer r.Close()
	cmd.ExtraFiles = append(cmd.ExtraFiles, r)
	fd := 2 + len(cmd.ExtraFiles)
	cmd.Env = append(append([]string{}, envOrCurrent(cmd.Env)...), fmt.Sprintf("MOTHER_WORKER_SECRET_FD=%d", fd))
	if cmd.SysProcAttr == nil {
		cmd.SysProcAttr = &syscall.SysProcAttr{}
	}
	cmd.SysProcAttr.Setpgid = true
	if err := cmd.Start(); err != nil {
		return err
	}
	return s.RegisterWorker(id, cmd.Process.Pid, secret)
}

func envOrCurrent(e []string) []string {
	if e == nil {
		return os.Environ()
	}
	return e
}

// authenticate judges a hello (after Negotiate) from a peer with the given pid. Caller holds s.mu.
// It returns a short audit reason on failure.
func (s *Server) authenticate(h workerproto.Hello, peerPID int) string {
	cred := s.creds[h.WorkerID]
	if cred == nil {
		return "unknown_worker"
	}
	if len(h.Auth.Nonce) < MinNonce || h.Auth.Credential == "" {
		return "no_credential"
	}
	want := CredentialProof(string(cred.secret), h)
	if !hmac.Equal([]byte(want), []byte(h.Auth.Credential)) {
		return "bad_credential"
	}
	if cred.pid != 0 && cred.pid != peerPID {
		if cred.explicit || pidAlive(cred.pid) {
			return "pid_mismatch"
		}
	}
	if old := s.workers[h.WorkerID]; old != nil && !old.closed() && old.instance != h.InstanceID {
		return "already_connected"
	}
	cred.pid = peerPID
	return ""
}
