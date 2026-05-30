package main

// main.go — broker entrypoint. Parses env config, wires the read side
// (jobstore + event source + activity watcher) to the hub, binds the
// listener (Unix socket in W1; one-line change to TCP in W4), and serves
// until SIGTERM.
//
// Along with transport.go this is the only file that imports net.

import (
	"fmt"
	"net"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"
)

type config struct {
	root         string
	sock         string
	cli          string
	projectsDir  string
	pingSeconds  int
	clientBuf    int
	activitySecs int
}

func envOr(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func envInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			return n
		}
	}
	return def
}

func loadConfig() config {
	home, _ := os.UserHomeDir()
	root := envOr("MOTHER_ROOT", filepath.Join(home, ".mother"))
	return config{
		root:         root,
		sock:         envOr("MOTHER_BROKER_SOCK", filepath.Join(root, "broker.sock")),
		cli:          envOr("MOTHER_CLI", "mother"),
		projectsDir:  envOr("MOTHER_CLAUDE_PROJECTS_DIR", filepath.Join(home, ".claude", "projects")),
		pingSeconds:  envInt("MOTHER_BROKER_PING_SEC", 15),
		clientBuf:    envInt("MOTHER_BROKER_CLIENT_BUF", 1024),
		activitySecs: envInt("MOTHER_BROKER_ACTIVITY_SEC", 1),
	}
}

func main() {
	cfg := loadConfig()

	jobsDir := filepath.Join(cfg.root, "jobs")
	eventsDir := filepath.Join(cfg.root, "events")
	// The broker is a reader; ensure the dirs exist so watchers attach
	// cleanly even on a cold MOTHER_ROOT.
	_ = os.MkdirAll(jobsDir, 0o755)
	_ = os.MkdirAll(eventsDir, 0o755)

	store := newJobStore(jobsDir)
	runner := &commandRunner{
		store:     store,
		cliPath:   cfg.cli,
		eventsDir: eventsDir,
		extraEnv:  []string{"MOTHER_ROOT=" + cfg.root},
	}
	h := newHub(store, runner, cfg.pingSeconds, cfg.clientBuf)

	es := newEventSource(eventsDir, h.ingest)
	aw := newActivityWatcher(store, cfg.projectsDir, time.Duration(cfg.activitySecs)*time.Second, h.ingest)

	// Build the initial world from disk before accepting connections so the
	// first snapshot is authoritative. The broker holds no durable state —
	// a restart simply rebuilds from the event logs (B9).
	store.load()
	es.prime()

	done := make(chan struct{})
	go store.watch(done)
	go es.watch(done)
	go aw.run(done)

	ln, err := listen("unix", cfg.sock)
	if err != nil {
		fmt.Fprintf(os.Stderr, "mother-broker: cannot bind %s: %v\n", cfg.sock, err)
		os.Exit(1)
	}
	fmt.Fprintf(os.Stderr, "mother-broker: listening on %s (pid %d)\n", cfg.sock, os.Getpid())

	// Graceful shutdown on SIGTERM/SIGINT: stop watchers, close the listener
	// (unblocks Accept), remove the socket file.
	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigs
		close(done)
		_ = ln.Close()
	}()

	acceptLoop(h, ln)

	_ = os.Remove(cfg.sock)
	fmt.Fprintln(os.Stderr, "mother-broker: exited")
}

// acceptLoop accepts connections until the listener is closed.
func acceptLoop(h *hub, ln net.Listener) {
	for {
		conn, err := ln.Accept()
		if err != nil {
			// Listener closed during shutdown, or a transient accept error.
			return
		}
		h.serve(newClientConn(conn))
	}
}
