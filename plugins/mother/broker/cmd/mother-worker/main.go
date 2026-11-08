// mother-worker is the worker daemon of Mother's worker protocol (cluster Phase 1, P1-4): it accepts
// leased jobs from the coordinator, runs `mother-run-job` for each against its own worker root, and
// ships the supervisor's outbox and log back. Nothing in the runner uses it yet (P1-5).
package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"syscall"
	"time"

	"mother-broker/worker"
)

func envDur(name string) time.Duration {
	if v := os.Getenv(name); v != "" {
		if n, err := strconv.ParseFloat(v, 64); err == nil && n > 0 {
			return time.Duration(n * float64(time.Second))
		}
		fmt.Fprintf(os.Stderr, "mother-worker: ignoring bad %s=%q\n", name, v)
	}
	return 0
}

func main() {
	id := flag.String("id", "", "worker id (required)")
	root := flag.String("root", "", "worker root directory (required)")
	sock := flag.String("coord-sock", "", "coordinator socket (default $MOTHER_ROOT/runner/worker.sock)")
	slots := flag.Int("slots", 1, "jobs this worker runs at once")
	flag.Parse()
	if *id == "" || *root == "" {
		fmt.Fprintln(os.Stderr, "usage: mother-worker --id <name> --root <worker-root> [--coord-sock <path>] [--slots N]")
		os.Exit(2)
	}
	if *sock == "" {
		base := os.Getenv("MOTHER_ROOT")
		if base == "" {
			base = os.Getenv("MOTHER_LIVE_ROOT")
		}
		if base == "" {
			fmt.Fprintln(os.Stderr, "mother-worker: --coord-sock or MOTHER_ROOT is required")
			os.Exit(2)
		}
		*sock = filepath.Join(base, "runner", "worker.sock")
	}
	absRoot, err := filepath.Abs(*root)
	if err != nil {
		fmt.Fprintln(os.Stderr, "mother-worker:", err)
		os.Exit(1)
	}
	exe, _ := os.Executable()
	binDir := os.Getenv("MOTHER_BIN_DIR")
	if binDir == "" {
		binDir = filepath.Join(filepath.Dir(exe), "..", "..", "bin")
	}
	libDir := os.Getenv("MOTHER_LIB_DIR")
	if libDir == "" {
		libDir = filepath.Join(filepath.Dir(exe), "..", "..", "lib")
	}
	logf := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "%s mother-worker[%s]: %s\n", time.Now().UTC().Format(time.RFC3339), *id, fmt.Sprintf(format, args...))
	}
	d, err := worker.New(worker.Config{
		ID: *id, Root: absRoot, CoordSock: *sock, Slots: *slots, BinDir: binDir, LibDir: libDir,
		BackoffMax: envDur("MOTHER_WORKER_BACKOFF_MAX_S"), Logf: logf,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "mother-worker:", err)
		os.Exit(1)
	}
	if err := d.RecordPID(); err != nil {
		fmt.Fprintln(os.Stderr, "mother-worker:", err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	logf("started (root %s, coordinator %s, slots %d)", absRoot, *sock, *slots)
	_ = d.Run(ctx)
	// Exiting leaves every supervisor running: they are re-adopted by the next start.
}
