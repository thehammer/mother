package workerproto

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
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
	if WipRef("j") != "refs/mother/wip/j" || SalvageRef("j", 3) != "refs/mother/wip/j/lease-3" {
		t.Fatal("refs")
	}
}
