package coord

import (
	"fmt"
	"net"
	"os"
)

// peerIdentity refuses a connection whose peer uid is not ours (any failure to read the credential is a
// refusal) and returns the peer's pid.
func peerIdentity(c *net.UnixConn) (int, error) {
	uid, pid, err := peerCred(c)
	if err != nil {
		return 0, err
	}
	if int(uid) != os.Getuid() {
		return 0, fmt.Errorf("peer uid %d is not %d", uid, os.Getuid())
	}
	if pid <= 0 {
		return 0, fmt.Errorf("peer pid unknown")
	}
	return pid, nil
}
