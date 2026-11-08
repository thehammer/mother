package workerproto

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestCheckpointManifestFixture(t *testing.T) {
	b, err := os.ReadFile(filepath.Join(fixtureDir, "checkpoint_manifest.json"))
	if err != nil {
		t.Fatal(err)
	}
	var m Manifest
	if err := json.Unmarshal(b, &m); err != nil {
		t.Fatal(err)
	}
	if err := ValidateManifest(m); err != nil {
		t.Fatal(err)
	}
	out, _ := json.Marshal(m)
	if !bytes.Equal(append(out, '\n'), b) {
		t.Fatalf("manifest re-encode differs:\n%s\n%s", b, out)
	}
	m.WipRef = "refs/heads/x"
	if ErrorCode(ValidateManifest(m)) != CodeInvalid {
		t.Fatal("wip_ref must be refs/mother/wip/<job>")
	}
}

func TestCheckpointTimingMC14(t *testing.T) {
	if CheckpointInterval != 120*time.Second || CheckpointMaxInterval != 240*time.Second ||
		CheckpointFinalWait != 30*time.Second || CheckpointWatchdog != 60*time.Second {
		t.Fatal("spec timing constants")
	}
	if got := WorstCaseLoss(CheckpointInterval); got != 180*time.Second || got >= CheckpointLossBound {
		t.Fatalf("worst case %v must be 180 s, under 300 s", got)
	}
	if !IntervalOK(240*time.Second) || IntervalOK(241*time.Second) || IntervalOK(0) {
		t.Fatal("interval is refused above 240 s")
	}
	if WipRef("j") != "refs/mother/wip/j" || SalvageRef("j", 3) != "refs/mother/wip-salvage/j/lease-3" {
		t.Fatal("refs")
	}
}

func TestRefBuildersRefuseBadJobIDs(t *testing.T) {
	for _, j := range []string{"", ".hidden", "trail.", "x.lock", "a..b", "a/b", "a b", "bad~", strings.Repeat("a", 129)} {
		if WipRef(j) != "" || SalvageRef(j, 1) != "" {
			t.Errorf("job %q must be refused", j)
		}
	}
	if SalvageRef("j", 0) != "" || SalvageRef("j", -1) != "" {
		t.Error("epoch < 1 must be refused")
	}
	for _, j := range []string{"job-1", "a:b", "a.b", "x.locked", "0.1"} {
		if WipRef(j) == "" || SalvageRef(j, 2) == "" {
			t.Errorf("job %q is valid", j)
		}
	}
	m := goodManifest("j")
	m.Job = "x.lock"
	m.WipRef = ""
	if err := ValidateManifest(m); err == nil {
		t.Error("manifest with a .lock job must be refused")
	}
}

// The reason SalvageRef is not nested under WipRef: git refuses it.
func TestGitRefsCoexistAndNestedNameFails(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git not available")
	}
	dir := t.TempDir()
	run := func(args ...string) (string, error) {
		c := exec.Command("git", args...)
		c.Dir = dir
		c.Env = append(os.Environ(), "GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@t", "GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@t")
		out, err := c.CombinedOutput()
		return string(out), err
	}
	must := func(args ...string) {
		if out, err := run(args...); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	must("init", "--bare", "remote.git")
	must("init", "work")
	c := exec.Command("git", "-C", dir+"/work", "-c", "user.name=t", "-c", "user.email=t@t", "commit", "--allow-empty", "-m", "x")
	if out, err := c.CombinedOutput(); err != nil {
		t.Fatalf("commit: %v\n%s", err, out)
	}
	w := func(args ...string) (string, error) { return run(append([]string{"-C", "work"}, args...)...) }
	if out, err := w("push", dir+"/remote.git", "HEAD:"+WipRef("job1")); err != nil {
		t.Fatalf("normal ref: %v\n%s", err, out)
	}
	if out, err := w("push", dir+"/remote.git", "HEAD:"+SalvageRef("job1", 2)); err != nil {
		t.Fatalf("salvage ref beside normal ref: %v\n%s", err, out)
	}
	if out, err := w("push", dir+"/remote.git", "HEAD:"+WipRef("job1")+"/lease-2"); err == nil {
		t.Fatalf("old nested name must fail (file/directory conflict):\n%s", out)
	}
}
