package workerproto

import (
	"strconv"
	"time"
)

// Checkpoint timing (spec section 9). Worst-case work loss is CheckpointInterval +
// CheckpointWatchdog = 180 s, under the MC-14 bound of 300 s.
const (
	CheckpointInterval    = 120 * time.Second
	CheckpointMaxInterval = 240 * time.Second
	CheckpointFinalWait   = 30 * time.Second
	CheckpointWatchdog    = 60 * time.Second
	CheckpointLossBound   = 300 * time.Second // MC-14
)

// WorstCaseLoss is the most work a crash can lose for the given interval.
func WorstCaseLoss(interval time.Duration) time.Duration { return interval + CheckpointWatchdog }

// IntervalOK reports whether a configured checkpoint interval is acceptable (0 < d <= 240 s).
func IntervalOK(d time.Duration) bool { return d > 0 && d <= CheckpointMaxInterval }

// WipRef is the job's rolling wip ref.
func WipRef(job string) string { return "refs/mother/wip/" + job }

// SalvageRef is the ref a fenced worker pushes to when its lease is lost.
func SalvageRef(job string, epoch int64) string {
	return "refs/mother/wip/" + job + "/lease-" + strconv.FormatInt(epoch, 10)
}

type Transcript struct {
	PathRel string `json:"path_rel"`
	Bytes   int64  `json:"bytes"`
	SHA256  string `json:"sha256"`
}

type SkippedFile struct {
	Path  string `json:"path"`
	Bytes int64  `json:"bytes"`
}

// Manifest is the checkpoint manifest. Field order is the wire key order.
type Manifest struct {
	V                int           `json:"v"`
	Job              string        `json:"job"`
	Lease            string        `json:"lease"`
	Epoch            int64         `json:"epoch"`
	N                int           `json:"n"`
	At               string        `json:"at"`
	HeadSHA          string        `json:"head_sha"`
	Branch           string        `json:"branch"`
	BaseSHA          string        `json:"base_sha"`
	WipSHA           string        `json:"wip_sha"`
	WipRef           string        `json:"wip_ref"`
	Pushed           bool          `json:"pushed"`
	PushError        string        `json:"push_error,omitempty"`
	SessionID        string        `json:"session_id"`
	Transcript       Transcript    `json:"transcript"`
	UntrackedSkipped []SkippedFile `json:"untracked_skipped"`
	WorkDirAtCapture string        `json:"work_dir_at_capture"`
}

// ValidateManifest checks the required manifest fields.
func ValidateManifest(m Manifest) error {
	switch {
	case m.V != 1:
		return protoErr(CodeInvalid, "manifest: v must be 1")
	case m.Job == "" || m.Lease == "" || m.Epoch < 1 || m.N < 1 || m.At == "":
		return protoErr(CodeInvalid, "manifest: job, lease, epoch, n and at are required")
	case m.HeadSHA == "" || m.Branch == "" || m.BaseSHA == "" || m.WipSHA == "":
		return protoErr(CodeInvalid, "manifest: head_sha, branch, base_sha and wip_sha are required")
	case m.WipRef != WipRef(m.Job):
		return protoErr(CodeInvalid, "manifest: wip_ref must be %s", WipRef(m.Job))
	case m.SessionID == "" || m.Transcript.PathRel == "" || !sha256Re.MatchString(m.Transcript.SHA256):
		return protoErr(CodeInvalid, "manifest: session_id and transcript{path_rel, sha256} are required")
	case m.WorkDirAtCapture == "":
		return protoErr(CodeInvalid, "manifest: work_dir_at_capture required")
	}
	return nil
}
