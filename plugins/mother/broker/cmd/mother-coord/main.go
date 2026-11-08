// mother-coord is the coordinator daemon of Mother's worker protocol (cluster Phase 1, P1-4): it leases
// jobs to connected workers, applies what they ship onto the canonical tree and sends canonical changes
// back down. Nothing in the runner uses it yet (P1-5).
package main

import (
	"bufio"
	"context"
	"encoding/json"
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

func main() {
	secretsFD := flag.Int("secrets-fd", 0, "inherited fd carrying one `worker-id=secret` line per worker this coordinator accepts")
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
		f := os.NewFile(uintptr(*secretsFD), "secrets")
		sc := bufio.NewScanner(f)
		for sc.Scan() {
			id, secret, ok := strings.Cut(strings.TrimSpace(sc.Text()), "=")
			if !ok || id == "" {
				continue
			}
			if err := s.RegisterWorker(id, 0, secret); err != nil {
				fmt.Fprintln(os.Stderr, "mother-coord:", err)
				release()
				os.Exit(1)
			}
		}
		f.Close() // never inherited by the applier or anything else
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
