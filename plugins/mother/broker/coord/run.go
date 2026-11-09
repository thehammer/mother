package coord

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
)

// The coordinator's private directory, $MOTHER_ROOT/runner/coord (mode 0700, ours, never a symlink),
// holds the socket, the pidfile and the lock.
func CoordDir(root string) string   { return filepath.Join(root, "runner", "coord") }
func SocketPath(root string) string { return filepath.Join(CoordDir(root), "worker.sock") }
func PidPath(root string) string    { return filepath.Join(CoordDir(root), "coord.pid") }
func LockPath(root string) string   { return filepath.Join(CoordDir(root), "coord.lock") }
func StatusPath(root string) string { return filepath.Join(root, "runner", "coord-status.json") }

func pidAlive(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || err == syscall.EPERM
}

// secureDir creates dir (0700) or verifies an existing one: a real directory (Lstat, not a symlink),
// owned by this uid, with no group/other permission bits. Checked on every start.
func secureDir(dir string) error {
	if err := os.MkdirAll(filepath.Dir(dir), 0o755); err != nil {
		return err
	}
	if _, err := os.Lstat(dir); errors.Is(err, os.ErrNotExist) {
		if err := os.Mkdir(dir, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
			return err
		}
		if err := os.Chmod(dir, 0o700); err != nil {
			return err
		}
	}
	fi, err := os.Lstat(dir)
	if err != nil {
		return err
	}
	if fi.Mode()&os.ModeSymlink != 0 || !fi.IsDir() {
		return fmt.Errorf("%s is not a plain directory", dir)
	}
	if st, ok := fi.Sys().(*syscall.Stat_t); !ok || int(st.Uid) != os.Getuid() {
		return fmt.Errorf("%s is not owned by this user", dir)
	}
	if fi.Mode().Perm()&0o077 != 0 {
		return fmt.Errorf("%s has mode %o; it must be 0700", dir, fi.Mode().Perm())
	}
	return nil
}

var (
	heldMu    sync.Mutex
	heldRoots = map[string]bool{}
)

// Lock makes this process the singleton coordinator for root: it holds flock(LOCK_EX|LOCK_NB) on
// coord.lock for its whole lifetime, so two starts racing can never both proceed. The returned release is
// idempotent and removes the pidfile only if it is still ours.
func Lock(root string) (release func(), err error) {
	dir := CoordDir(root)
	if err := secureDir(dir); err != nil {
		return nil, err
	}
	f, err := os.OpenFile(LockPath(root), os.O_CREATE|os.O_RDWR|syscall.O_NOFOLLOW, 0o600)
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		other := ""
		if b, e := os.ReadFile(PidPath(root)); e == nil {
			other = " (pid " + strings.TrimSpace(string(b)) + ")"
		}
		return nil, fmt.Errorf("mother-coord already running%s: %s is locked", other, LockPath(root))
	}
	pf := PidPath(root)
	if err := writeFileAtomic(pf, []byte(strconv.Itoa(os.Getpid())+"\n"), false); err != nil {
		f.Close()
		return nil, err
	}
	heldMu.Lock()
	heldRoots[root] = true
	heldMu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			if b, err := os.ReadFile(pf); err == nil && strings.TrimSpace(string(b)) == strconv.Itoa(os.Getpid()) {
				_ = os.Remove(pf)
			}
			heldMu.Lock()
			delete(heldRoots, root)
			heldMu.Unlock()
			f.Close() // drops the flock
		})
	}, nil
}

// Listen creates the worker socket (0600) in the private directory. It refuses unless this process holds
// the Lock for root: only the lock holder may unlink and bind.
func Listen(root string) (net.Listener, error) {
	heldMu.Lock()
	ok := heldRoots[root]
	heldMu.Unlock()
	if !ok {
		return nil, errors.New("Listen requires the coordinator lock (call Lock first)")
	}
	if err := secureDir(CoordDir(root)); err != nil {
		return nil, err
	}
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
