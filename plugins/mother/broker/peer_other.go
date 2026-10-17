//go:build !darwin

package main

import "errors"

// socketPeerPID is only implemented on darwin; elsewhere the peer guard is
// fail-open (the CLI guard still applies).
func socketPeerPID(fd uintptr) (int, error) {
	return 0, errors.New("peer pid not supported on this platform")
}
