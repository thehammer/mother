package coord

import (
	"fmt"
	"net"
	"os"

	"golang.org/x/sys/unix"
)

// peerUIDOK refuses a connection whose peer uid is not ours. Any failure to read the credential is a
// refusal (fail closed): an unknown peer is never admitted on the worker socket.
func peerUIDOK(c *net.UnixConn) error {
	raw, err := c.SyscallConn()
	if err != nil {
		return err
	}
	var uid uint32
	var gerr error
	if err := raw.Control(func(fd uintptr) {
		x, e := unix.GetsockoptXucred(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERCRED)
		if e != nil {
			gerr = e
			return
		}
		uid = x.Uid
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
