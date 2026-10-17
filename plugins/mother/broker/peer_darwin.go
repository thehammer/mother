package main

import "golang.org/x/sys/unix"

// socketPeerPID returns the pid of the process at the other end of a Unix
// socket (LOCAL_PEERPID).
func socketPeerPID(fd uintptr) (int, error) {
	return unix.GetsockoptInt(int(fd), unix.SOL_LOCAL, unix.LOCAL_PEERPID)
}
