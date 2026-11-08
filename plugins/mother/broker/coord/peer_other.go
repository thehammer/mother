//go:build !darwin && !linux

package coord

import (
	"errors"
	"net"
)

// peerCred fails closed on platforms where the peer credential cannot be read.
func peerCred(*net.UnixConn) (uint32, int, error) {
	return 0, 0, errors.New("peer credentials not supported on this platform")
}
