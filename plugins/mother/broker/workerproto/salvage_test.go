package workerproto

import (
	"strings"
	"testing"
	"time"
)

func salvageFrame(t *testing.T, ref, sha string) Frame {
	t.Helper()
	f, err := NewFrame(TypeSalvage, "f-1", time.Unix(1700000000, 0), Salvage{Ref: ref, WipSHA: sha})
	if err != nil {
		t.Fatal(err)
	}
	f.Job, f.Lease, f.Epoch = Str("j1"), Str("L-1"), Int(2)
	return f
}

func TestSalvageFrameIsAWorkerControlFrameOnly(t *testing.T) {
	sha := strings.Repeat("a", 40)
	f := salvageFrame(t, SalvageRef("j1", 2), sha)
	if err := ValidateFrom(FromWorker, f); err != nil {
		t.Fatalf("a well-formed salvage frame was refused: %v", err)
	}
	if IsStreamType(TypeSalvage) {
		t.Fatal("salvage must not be a seq-numbered stream frame: a fenced worker's stream is refused")
	}
	if err := ValidateFrom(FromCoordinator, f); err == nil {
		t.Fatal("the coordinator must not be able to send a salvage frame")
	}
}

func TestSalvageFrameRefMustBeTheOneDerivedFromJobAndEpoch(t *testing.T) {
	sha := strings.Repeat("a", 40)
	for _, ref := range []string{"refs/mother/wip/j1", "refs/mother/wip-salvage/j1/lease-3", "refs/heads/main", ""} {
		if err := ValidateFrom(FromWorker, salvageFrame(t, ref, sha)); err == nil {
			t.Fatalf("ref %q was accepted for job j1 epoch 2", ref)
		}
	}
	if err := ValidateFrom(FromWorker, salvageFrame(t, SalvageRef("j1", 2), "not-a-sha")); err == nil {
		t.Fatal("a bad wip_sha was accepted")
	}
}
