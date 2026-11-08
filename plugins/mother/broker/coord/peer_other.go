//go:build !darwin && !linux

package coord

import (
	"errors"
	"net"
)

// peerUIDOK fails closed on platforms where the peer credential cannot be read.
func peerUIDOK(*net.UnixConn) error {
	return errors.New("peer credentials not supported on this platform")
}
