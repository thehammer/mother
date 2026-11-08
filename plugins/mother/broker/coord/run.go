package coord

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
)

// SocketPath and PidPath are the coordinator's well-known files under $MOTHER_ROOT/runner.
func SocketPath(root string) string { return filepath.Join(root, "runner", "worker.sock") }
func PidPath(root string) string    { return filepath.Join(root, "runner", "coord.pid") }
func StatusPath(root string) string { return filepath.Join(root, "runner", "coord-status.json") }

func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// Lock makes this process the singleton coordinator for root: it refuses when the pidfile names a live
// process (like _singleton_guard in bin/mother-runner) and reclaims a stale one. The returned release
// removes the pidfile only if it is still ours.
func Lock(root string) (release func(), err error) {
	if err := os.MkdirAll(filepath.Join(root, "runner"), 0o755); err != nil {
		return nil, err
	}
	pf := PidPath(root)
	if b, err := os.ReadFile(pf); err == nil {
		if pid, err := strconv.Atoi(strings.TrimSpace(string(b))); err == nil && pid != os.Getpid() && pidAlive(pid) {
			return nil, fmt.Errorf("mother-coord already running as pid %d (%s)", pid, pf)
		}
	}
	if err := writeFileAtomic(pf, []byte(strconv.Itoa(os.Getpid())+"\n"), false); err != nil {
		return nil, err
	}
	return func() {
		if b, err := os.ReadFile(pf); err == nil && strings.TrimSpace(string(b)) == strconv.Itoa(os.Getpid()) {
			_ = os.Remove(pf)
		}
	}, nil
}

// Listen creates the worker socket with mode 0600. A leftover socket is removed here, which is only
// safe because Lock has already established that no live coordinator exists.
func Listen(root string) (net.Listener, error) {
	sock := SocketPath(root)
	_ = os.Remove(sock)
	old := syscall.Umask(0o177)
	ln, err := net.Listen("unix", sock)
	syscall.Umask(old)
	if err != nil {
		return nil, err
	}
	if err := os.Chmod(sock, 0o600); err != nil {
		ln.Close()
		return nil, err
	}
	return ln, nil
}
