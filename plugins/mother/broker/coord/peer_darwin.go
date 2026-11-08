package coord

import (
	"net"

	"golang.org/x/sys/unix"
)

// peerCred reads the connecting process's uid (LOCAL_PEERCRED) and pid (LOCAL_PEERPID).
func peerCred(c *net.UnixConn) (uid uint32, pid int, err error) {
	raw, err := c.SyscallConn()
	if err != nil {
		return 0, 0, err
	}
	var gerr error
	if err := raw.Control(func(fd uintptr) {
		x, e := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if e != nil {
			gerr = e
			return
		}
		p, e := unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
		if e != nil {
			gerr = e
			return
		}
		uid, pid = x.Uid, p
	}); err != nil {
		return 0, 0, err
	}
	return uid, pid, gerr
}
