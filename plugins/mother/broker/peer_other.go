//go:build !darwin

package main

import "errors"

// socketPeerPID is only implemented on darwin. Elsewhere the answer guard allows
// (the CLI guard still applies) but `quota-gate` is DENIED, because an unreadable
// peer pid fails closed (see processGuard.fromWorkerOrUnknown). The broker is
// macOS-only, so on Linux (CI) quota-gate is simply always denied.
func socketPeerPID(fd uintptr) (int, error) {
	return 0, errors.New("peer pid not supported on this platform")
}
