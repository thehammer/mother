package main

// transport.go — the transport-abstraction boundary (B2).
//
// This is the ONLY file (besides main.go's listener wiring) that imports
// net or knows about sockets. Everything above this file operates on a
// *clientConn, which wraps an io.ReadWriteCloser and exposes line-oriented
// read/write. Swapping the Unix socket for TCP later is a one-line change
// to the Listen call in main.go — nothing above this file changes.
//
// Invariant (asserted by a test): no source file other than transport.go
// and main.go imports "net". The upper layers are transport-blind and can
// be driven by an in-memory net.Pipe() in tests.

import (
	"bufio"
	"io"
	"net"
	"os"
	"sync"
)

// listen binds a listener. For Unix sockets it first removes any stale
// socket file left by an unclean shutdown. To move to TCP in W4, callers
// pass ("tcp", addr) instead of ("unix", path) — no other change required.
func listen(network, addr string) (net.Listener, error) {
	if network == "unix" {
		// A leftover socket file makes bind fail with "address already in
		// use"; remove it. (If a live broker is actually bound, the daemon
		// supervisor guarantees single-instance, so this is safe.)
		_ = os.Remove(addr)
	}
	return net.Listen(network, addr)
}

// maxLineBytes bounds a single inbound/outbound NDJSON line. Snapshots of a
// large queue are the biggest messages; 8 MiB is comfortably above any real
// payload while still capping a malicious client.
const maxLineBytes = 8 * 1024 * 1024

// clientConn wraps a transport connection in line-oriented framing. It is
// transport-blind: it only sees an io.ReadWriteCloser, so tests can hand it
// one half of a net.Pipe().
type clientConn struct {
	rwc     io.ReadWriteCloser
	scanner *bufio.Scanner
	wmu     sync.Mutex // serializes concurrent writes (writer goroutine + close notice)
}

func newClientConn(rwc io.ReadWriteCloser) *clientConn {
	sc := bufio.NewScanner(rwc)
	sc.Buffer(make([]byte, 0, 64*1024), maxLineBytes)
	return &clientConn{rwc: rwc, scanner: sc}
}

// readLine returns the next NDJSON line (without the trailing newline), or an
// error on EOF / read failure / oversize line. The caller treats any error as
// a disconnect.
func (c *clientConn) readLine() ([]byte, error) {
	if c.scanner.Scan() {
		// Copy: the scanner reuses its buffer across Scan calls.
		line := c.scanner.Bytes()
		out := make([]byte, len(line))
		copy(out, line)
		return out, nil
	}
	if err := c.scanner.Err(); err != nil {
		return nil, err
	}
	return nil, io.EOF
}

// writeMessage encodes a Message and writes it as one framed NDJSON line.
// Writes are serialized so the per-connection writer goroutine and any
// best-effort close notice never interleave bytes.
func (c *clientConn) writeMessage(m Message) error {
	b, err := m.encode()
	if err != nil {
		return err
	}
	c.wmu.Lock()
	defer c.wmu.Unlock()
	if _, err := c.rwc.Write(b); err != nil {
		return err
	}
	_, err = c.rwc.Write([]byte{'\n'})
	return err
}

func (c *clientConn) close() error {
	return c.rwc.Close()
}
