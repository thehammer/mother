package coord

import (
	"crypto/hmac"
	"crypto/rand"
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
// The secret is memory-only on both ends, handed over an inherited fd only (never the environment: the
// initial environment block stays readable by a same-uid process).

// MinNonce is the shortest hello nonce accepted.
const MinNonce = 16

type workerCred struct {
	secret []byte
	pid    int // the worker daemon's pid; the only peer pid that may authenticate as this worker
}

// NewSecret returns a fresh random worker secret (hex).
func NewSecret() string {
	b := make([]byte, 32)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// RegisterWorker makes id a known worker bound to pid, the real pid of the worker daemon the caller
// launched. A pid <= 0 is refused: binding to "the first authenticated connection" would let any process
// that learns the secret win the id. Re-registering replaces the credential and pid and drops any live
// connection of that id.
//
// Trust notes: a pid reused by an unrelated process after the worker died makes that worker refuse
// (pid_mismatch) until it is re-registered or the coordinator restarts. The hello proof has no coordinator
// challenge; replay of a captured proof is blocked by the pid binding. Same-uid ptrace/debugger access to
// the worker or coordinator is out of scope for the local carrier.
func (s *Server) RegisterWorker(id string, pid int, secret string) error {
	if !workerproto.IDOK(id) {
		return fmt.Errorf("bad worker id %q", id)
	}
	if pid <= 0 {
		return errors.New("worker pid must be the launched daemon's real pid")
	}
	if len(secret) < 16 {
		return errors.New("worker secret too short")
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	s.creds[id] = &workerCred{secret: []byte(secret), pid: pid}
	s.connMu.Lock()
	if s.pidSet == nil {
		s.pidSet = map[int]struct{}{}
	}
	s.pidSet[pid] = struct{}{}
	s.connMu.Unlock()
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
	want := workerproto.CredentialProof(string(cred.secret), h)
	if !hmac.Equal([]byte(want), []byte(h.Auth.Credential)) {
		return "bad_credential"
	}
	if cred.pid != peerPID {
		return "pid_mismatch"
	}
	if old := s.workers[h.WorkerID]; old != nil && !old.closed() && old.instance != h.InstanceID {
		return "already_connected"
	}
	return ""
}
