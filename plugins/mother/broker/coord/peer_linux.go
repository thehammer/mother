package coord

import (
	"net"

	"golang.org/x/sys/unix"
)

// peerCred reads the connecting process's uid and pid (SO_PEERCRED).
func peerCred(c *net.UnixConn) (uid uint32, pid int, err error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var gerr error
	if err := raw.Control(func(fd uintptr) {
		u, e := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		if e != nil {
			gerr = e
			return
		}
		uid, pid = u.Uid, int(u.Pid)
	}); err != nil {
		return 0, 0, err
	}
	return uid, pid, gerr
}
