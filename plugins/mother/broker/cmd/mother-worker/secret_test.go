package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReadSecretWithoutAnFdFailsClosedEvenWithTheSecretInTheEnvironment(t *testing.T) {
	t.Setenv("MOTHER_WORKER_SECRET", "env-secret-must-not-be-used")
	t.Setenv("MOTHER_WORKER_SECRET_FD", "")
	if v, err := readSecret(0); err == nil || v != "" {
		t.Fatalf("readSecret with no fd returned %q, %v; want an error", v, err)
	}
}

func TestReadSecretReadsAnInheritedFdOnce(t *testing.T) {
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	w.WriteString("fd-secret-0123456789\n")
	w.Close()
	got, err := readSecret(int(r.Fd()))
	if err != nil || got != "fd-secret-0123456789" {
		t.Fatalf("got %q, %v", got, err)
	}
}

// The release binary: no fd means it refuses to run, whatever the environment says.
func TestWorkerBinaryWithoutASecretFdRefusesToRunAndIgnoresTheEnvSecret(t *testing.T) {
	bin := filepath.Join(t.TempDir(), "mother-worker")
	if out, err := exec.Command("go", "build", "-o", bin, ".").CombinedOutput(); err != nil {
		t.Fatalf("build: %v\n%s", err, out)
	}
	root := t.TempDir()
	cmd := exec.Command(bin, "--id", "w1", "--root", filepath.Join(root, "w"), "--coord-sock", filepath.Join(root, "x.sock"))
	cmd.Env = append(os.Environ(), "MOTHER_WORKER_SECRET=env-secret-must-not-be-used", "MOTHER_WORKER_SECRET_FD=")
	done := make(chan struct{})
	var out []byte
	var err error
	go func() { out, err = cmd.CombinedOutput(); close(done) }()
	select {
	case <-done:
	case <-time.After(20 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("a worker with no secret fd kept running")
	}
	if err == nil || !strings.Contains(string(out), "secret fd") {
		t.Fatalf("want a non-zero exit naming the missing secret fd, got %v: %s", err, out)
	}
	if _, serr := os.Stat(filepath.Join(root, "w", "worker.pid")); serr == nil {
		t.Fatal("the worker started (wrote worker.pid) without a secret")
	}
}

func TestSourceHasNoEnvironmentSecretPath(t *testing.T) {
	b, err := os.ReadFile("main.go")
	if err != nil {
		t.Fatal(err)
	}
	for _, line := range strings.Split(string(b), "\n") {
		if strings.Contains(line, `Getenv("MOTHER_WORKER_SECRET")`) {
			t.Fatalf("the worker reads the secret from the environment: %s", line)
		}
	}
}
