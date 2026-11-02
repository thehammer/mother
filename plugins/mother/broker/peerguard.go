package main

// peerguard.go — keep workers inside Mother jobs from answering holds.
//
// `answer` is the one broker command a worker must never issue: the operator
// (or an agent session acting for them) answers a hold, not the job that
// raised it. The CLI refuses when MOTHER_JOB_ID is set; this is the same rule
// for the socket, enforced by looking at who is on the other end: if any
// ancestor of the connecting process is a `mother-run-job` supervisor, the
// peer is a worker. It applies to `answer` only.
//
// Fail-open by design: when the peer pid cannot be read (non-darwin build,
// non-unix transport, lookup error) the answer is allowed and the reason is
// logged, because the CLI guard still applies to the path that ultimately
// mutates state.

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	workerSupervisorName = "mother-run-job"
	maxAncestryDepth     = 32
)

// workerGuard decides whether the peer of a connection is a Mother worker.
// A small interface so tests can inject a fake ancestry.
type workerGuard interface {
	fromWorker(conn *clientConn) bool
	// fromWorkerOrUnknown is the strict form used for `quota-gate` only: true
	// when the peer is a worker OR cannot be identified (unreadable pid, failed
	// ancestry lookup). A safety switch fails closed.
	fromWorkerOrUnknown(conn *clientConn) bool
}

// processGuard is the production guard: peer pid from the socket, ancestry
// from the process table.
type processGuard struct {
	lookup func(pid int) (ppid int, command string, err error)
}

func newProcessGuard() workerGuard { return processGuard{lookup: psLookup} }

func (g processGuard) fromWorker(conn *clientConn) bool {
	pid, err := conn.peerPID()
	if err != nil {
		fmt.Fprintf(os.Stderr, "mother-broker: answer peer check skipped (allowing): %v\n", err)
		return false
	}
	return ancestryHasWorker(pid, g.lookup)
}

func (g processGuard) fromWorkerOrUnknown(conn *clientConn) bool {
	pid, err := conn.peerPID()
	if err != nil {
		fmt.Fprintf(os.Stderr, "mother-broker: quota-gate peer check failed (denying): %v\n", err)
		return true
	}
	found, ok := ancestryWalk(pid, g.lookup)
	if !ok {
		fmt.Fprintf(os.Stderr, "mother-broker: quota-gate peer ancestry unreadable (denying)\n")
		return true
	}
	return found
}

// ancestryHasWorker walks pid's parent chain (at most maxAncestryDepth
// levels) and reports whether any process on it is a `mother-run-job`
// supervisor. A script's `comm` is its interpreter ("bash"), so the match is
// on the basename of any token of the command line. Lookup errors, loops and
// reaching pid 1 end the walk with false.
func ancestryHasWorker(pid int, lookup func(pid int) (int, string, error)) bool {
	found, _ := ancestryWalk(pid, lookup)
	return found
}

// ancestryWalk is ancestryHasWorker plus whether the walk completed: ok is
// false when a lookup failed before the chain ended.
func ancestryWalk(pid int, lookup func(pid int) (int, string, error)) (found, ok bool) {
	seen := map[int]bool{}
	for depth := 0; depth < maxAncestryDepth && pid > 1 && !seen[pid]; depth++ {
		seen[pid] = true
		ppid, command, err := lookup(pid)
		if err != nil {
			fmt.Fprintf(os.Stderr, "mother-broker: peer check: pid %d lookup failed: %v\n", pid, err)
			return false, false
		}
		for _, tok := range strings.Fields(command) {
			if filepath.Base(tok) == workerSupervisorName {
				return true, true
			}
		}
		pid = ppid
	}
	return false, true
}

// psLookup reads a process's parent pid and full command line via ps(1).
func psLookup(pid int) (int, string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ps", "-o", "ppid=,command=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return 0, "", err
	}
	fields := strings.Fields(string(out))
	if len(fields) == 0 {
		return 0, "", fmt.Errorf("no such process")
	}
	ppid, err := strconv.Atoi(fields[0])
	if err != nil {
		return 0, "", err
	}
	return ppid, strings.Join(fields[1:], " "), nil
}
