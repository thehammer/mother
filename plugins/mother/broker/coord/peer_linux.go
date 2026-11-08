package coord

import (
	"fmt"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// peerUIDOK refuses a connection whose peer uid is not ours; an unreadable credential is a refusal.
func peerUIDOK(c *net.UnixConn) error {
	raw, err := c.SyscallConn()
	if err != nil {
		return err
	}
	var uid uint32
	var gerr error
	if err := raw.Control(func(fd uintptr) {
		u, e := unix.GetsockoptUcred(int(fd), unix.SOL_SOCKET, unix.SO_PEERCRED)
		if e != nil {
			gerr = e
			return
		}
		uid = u.Uid
	}); err != nil {
		return err
	}
	if gerr != nil {
		return gerr
	}
	if int(uid) != os.Getuid() {
		return fmt.Errorf("peer uid %d is not %d", uid, os.Getuid())
	}
	return nil
}
