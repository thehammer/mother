// mother-worker is the worker daemon of Mother's worker protocol (cluster Phase 1, P1-4): it accepts
// leased jobs from the coordinator, runs `mother-run-job` for each against its own worker root, and
// ships the supervisor's outbox and log back. Nothing in the runner uses it yet (P1-5).
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
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

// readSecret takes the worker's coordinator secret from an inherited fd (read once, then closed so no
// child inherits it) or the environment, and removes it from the environment either way.
func readSecret(fd int) string {
	if fd == 0 {
		if v := os.Getenv("MOTHER_WORKER_SECRET_FD"); v != "" {
			fd, _ = strconv.Atoi(v)
		}
	}
	env := os.Getenv("MOTHER_WORKER_SECRET")
	os.Unsetenv("MOTHER_WORKER_SECRET")
	os.Unsetenv("MOTHER_WORKER_SECRET_FD")
	if fd > 2 {
		f := os.NewFile(uintptr(fd), "secret")
		if f != nil {
			b, _ := io.ReadAll(io.LimitReader(f, 4096))
			f.Close()
			if v := strings.TrimSpace(string(b)); v != "" {
				return v
			}
		}
	}
	return strings.TrimSpace(env)
}

func main() {
	id := flag.String("id", "", "worker id (required)")
	root := flag.String("root", "", "worker root directory (required)")
	sock := flag.String("coord-sock", "", "coordinator socket (default $MOTHER_ROOT/runner/worker.sock)")
	slots := flag.Int("slots", 1, "jobs this worker runs at once")
	secretFD := flag.Int("secret-fd", 0, "inherited fd to read this worker's coordinator secret from (else $MOTHER_WORKER_SECRET_FD, else $MOTHER_WORKER_SECRET)")
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
		*sock = filepath.Join(base, "runner", "coord", "worker.sock")
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
	secret := readSecret(*secretFD)
	d, err := worker.New(worker.Config{
		Secret: secret, ID: *id, Root: absRoot, CoordSock: *sock, Slots: *slots, BinDir: binDir, LibDir: libDir,
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
