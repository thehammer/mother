// mother-coord is the coordinator daemon of Mother's worker protocol (cluster Phase 1, P1-4): it leases
// jobs to connected workers, applies what they ship onto the canonical tree and sends canonical changes
// back down. Nothing in the runner uses it yet (P1-5).
package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"mother-broker/coord"
)

func root() string {
	for _, k := range []string{"MOTHER_ROOT", "MOTHER_LIVE_ROOT"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	home, _ := os.UserHomeDir()
	return filepath.Join(home, ".mother")
}

func libDir() string {
	if v := os.Getenv("MOTHER_LIB_DIR"); v != "" {
		return v
	}
	exe, _ := os.Executable()
	return filepath.Join(filepath.Dir(exe), "..", "..", "lib")
}

func ttl() time.Duration {
	if v := os.Getenv("MOTHER_LEASE_TTL_S"); v != "" {
		if n, err := strconv.ParseFloat(v, 64); err == nil && n > 0 {
			return time.Duration(n * float64(time.Second))
		}
		fmt.Fprintf(os.Stderr, "mother-coord: ignoring bad MOTHER_LEASE_TTL_S=%q\n", v)
	}
	return 0
}

func statusJSON(r string) int {
	var st coord.Status
	b, err := os.ReadFile(coord.StatusPath(r))
	if err != nil || json.Unmarshal(b, &st) != nil {
		st = coord.Status{Workers: []coord.StatusWorker{}, Leases: []coord.StatusLease{}}
		out, _ := json.Marshal(st)
		fmt.Println(string(out))
		return 1
	}
	pb, _ := os.ReadFile(coord.PidPath(r))
	pid, _ := strconv.Atoi(strings.TrimSpace(string(pb)))
	st.Running = pid > 0 && pid == st.PID && syscall.Kill(pid, 0) == nil
	out, _ := json.Marshal(st)
	fmt.Println(string(out))
	return 0
}

// parseRegistration parses one `worker-id=pid=secret` line. The pid is the worker daemon's real pid: a
// registration without one is refused (no binding to the first connection).
func parseRegistration(line string) (id string, pid int, secret string, err error) {
	parts := strings.SplitN(strings.TrimSpace(line), "=", 3)
	if len(parts) != 3 || parts[0] == "" {
		return "", 0, "", errors.New("want worker-id=pid=secret")
	}
	pid, err = strconv.Atoi(parts[1])
	if err != nil || pid <= 0 {
		return "", 0, "", fmt.Errorf("worker %q: pid %q is not a real pid", parts[0], parts[1])
	}
	return parts[0], pid, parts[2], nil
}

func main() {
	secretsFD := flag.Int("secrets-fd", 0, "inherited fd carrying `worker-id=pid=secret` lines (the daemon pid), read until closed")
	status := flag.Bool("status-json", false, "print connected workers, caps, slots, active leases and heartbeat ages as JSON")
	flag.Parse()
	r := root()
	if *status {
		os.Exit(statusJSON(r))
	}
	logf := func(format string, args ...any) {
		fmt.Fprintf(os.Stderr, "%s mother-coord: %s\n", time.Now().UTC().Format(time.RFC3339), fmt.Sprintf(format, args...))
	}
	release, err := coord.Lock(r)
	if err != nil {
		fmt.Fprintln(os.Stderr, "mother-coord:", err)
		os.Exit(1)
	}
	defer release()
	s, err := coord.New(coord.Config{Root: r, LibDir: libDir(), TTL: ttl(), Logf: logf})
	if err != nil {
		fmt.Fprintln(os.Stderr, "mother-coord:", err)
		release()
		os.Exit(1)
	}
	if *secretsFD > 2 {
		syscall.CloseOnExec(*secretsFD) // stays open for the daemon's life: the applier and any child must not inherit it
		f := os.NewFile(uintptr(*secretsFD), "secrets")
		// Registrations are read for as long as the launcher keeps the descriptor open, so a restarted worker
		// (a new pid) is re-registered without restarting the coordinator. Only this inherited fd registers.
		go func() {
			sc := bufio.NewScanner(f)
			for sc.Scan() {
				id, pid, secret, err := parseRegistration(sc.Text())
				if err == nil {
					err = s.RegisterWorker(id, pid, secret)
				}
				if err != nil {
					logf("refusing registration: %v", err)
				}
			}
			f.Close() // never inherited by the applier or anything else
		}()
	}
	ln, err := coord.Listen(r)
	if err != nil {
		fmt.Fprintln(os.Stderr, "mother-coord:", err)
		release()
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGTERM, syscall.SIGINT)
	defer stop()
	logf("listening on %s (pid %d)", coord.SocketPath(r), os.Getpid())
	if err := s.Serve(ctx, ln); err != nil {
		logf("serve: %v", err)
	}
	s.Close()
	_ = os.Remove(coord.SocketPath(r))
	release()
}
