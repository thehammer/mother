package workerproto

import (
	"path"
	"regexp"
	"strconv"
	"strings"
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

// Manifest is the checkpoint manifest. Field order is the wire key order. The worker-local
// work_dir_at_capture of earlier drafts is not on the wire: a worker's filesystem layout is none of
// the coordinator's business and is never trusted as a path. Keep it in the worker's own state.
//
// PushError is the worker's description of a failed push, capped at 512 bytes; the worker must redact
// it (credentials, tokens, remote URLs with userinfo) before sending, because the coordinator stores
// and displays it verbatim.
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
}

var (
	gitSHARe = regexp.MustCompile(`^([0-9a-f]{40}|[0-9a-f]{64})$`)
	branchRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,199}$`)
)

// BranchOK reports whether b is a conservative git branch name: 1..200 of [A-Za-z0-9._/-], not
// starting with "-" or ".", no "..", "//", "@{", trailing "/" or ".", or ".lock" suffix. It can never
// be read as an option (--upload-pack=x) or climb a ref path.
func BranchOK(b string) bool {
	return branchRe.MatchString(b) && !strings.Contains(b, "..") && !strings.Contains(b, "//") &&
		!strings.HasSuffix(b, "/") && !strings.HasSuffix(b, ".") && !strings.HasSuffix(b, ".lock") &&
		!strings.Contains(b, "/.") && !strings.HasPrefix(b, ".")
}

// ValidateManifest checks every manifest field a coordinator would act on: ids, 40/64-hex SHAs, a
// conservative branch, the job id before WipRef is built from it, the transcript path (confined to
// the job like artifact.put), the skipped-file list and the bounded push_error.
func ValidateManifest(m Manifest) error {
	switch {
	case m.V != 1:
		return protoErr(CodeInvalid, "manifest: v must be 1")
	case !IDOK(m.Job) || !IDOK(m.Lease) || m.Epoch < 1 || m.N < 1 || !TimestampOK(m.At):
		return protoErr(CodeInvalid, "manifest: job, lease, epoch, n and at must be well-formed")
	case !gitSHARe.MatchString(m.HeadSHA) || !gitSHARe.MatchString(m.BaseSHA) || !gitSHARe.MatchString(m.WipSHA):
		return protoErr(CodeInvalid, "manifest: head_sha, base_sha and wip_sha must be 40 or 64 lowercase hex")
	case !BranchOK(m.Branch):
		return protoErr(CodeInvalid, "manifest: branch is not a conservative ref name")
	case m.WipRef != WipRef(m.Job):
		return protoErr(CodeInvalid, "manifest: wip_ref must be %s", WipRef(m.Job))
	case !IDOK(m.SessionID):
		return protoErr(CodeInvalid, "manifest: session_id must be well-formed")
	case !ArtifactPathOK(m.Job, m.Transcript.PathRel) || !sha256Re.MatchString(m.Transcript.SHA256) || m.Transcript.Bytes < 0:
		return protoErr(CodeInvalid, "manifest: transcript{path_rel, sha256} must be a job-confined path and a sha256")
	case len(m.PushError) > MaxMsgLen:
		return protoErr(CodeTooLarge, "manifest: push_error is %d bytes, limit %d", len(m.PushError), MaxMsgLen)
	case !textOK(m.PushError, MaxMsgLen):
		return protoErr(CodeInvalid, "manifest: push_error has control characters or invalid UTF-8")
	case len(m.UntrackedSkipped) > MaxUntrackedSkipped:
		return protoErr(CodeInvalid, "manifest: untracked_skipped has %d entries, limit %d", len(m.UntrackedSkipped), MaxUntrackedSkipped)
	}
	for _, u := range m.UntrackedSkipped {
		if u.Bytes < 0 || u.Path == "" || len(u.Path) > MaxPathLen || !textOK(u.Path, MaxPathLen) ||
			strings.HasPrefix(u.Path, "/") || strings.Contains(u.Path, "\\") || path.Clean(u.Path) != u.Path ||
			u.Path == ".." || strings.HasPrefix(u.Path, "../") {
			return protoErr(CodeInvalid, "manifest: bad untracked_skipped entry")
		}
	}
	return nil
}
