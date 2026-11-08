package workerproto

import (
	"encoding/json"
	"strconv"
	"time"
)

// Admitter is the coordinator's single entry for frames from an authenticated worker connection. Admit
// does decode, shape validation, direction, fence, worker identity, ownership and stream accounting in
// one call, so a caller cannot skip a step; the unchecked lease and stream primitives are unexported.
//
// The worker identity passed in is the one authenticated for the connection (peercred in Phase 1); it is
// never read from a frame. Like the LeaseTable it wraps, an Admitter is a plain value with no locking:
// the coordinator serialises calls.
type Admitter struct {
	leases   *LeaseTable
	jobState func(job string) JobState
	streams  map[string]*InStream
	issued   map[string]string // cmd_id -> command type, for the commands the coordinator sent
	issuedQ  []string
}

// NewAdmitter wraps a lease table. jobState reports a job's current state for job.set transition rules
// (it must not be nil; return the zero JobState when unknown).
func NewAdmitter(leases *LeaseTable, jobState func(job string) JobState) *Admitter {
	return &Admitter{leases: leases, jobState: jobState, streams: map[string]*InStream{}, issued: map[string]string{}}
}

// HbRefusal is one heartbeat entry that was not accepted (fenced, not_leased or unknown_job).
type HbRefusal struct {
	Job  string
	Code string
}

// Admission is the result of admitting a frame. Verdict is meaningful for stream frames: Apply (apply,
// persist, Commit, ack), Duplicate (drop, ack) or Gap (buffer, ack with resend_from). TooFar and invalid
// frames come back as errors instead. HbRefused lists rejected heartbeat entries.
type Admission struct {
	Frame     Frame
	Verdict   Verdict
	HbRefused []HbRefusal
}

func streamKey(job, lease string, epoch int64) string {
	return job + "\x00" + lease + "\x00" + strconv.FormatInt(epoch, 10)
}

func (a *Admitter) stream(f Frame) *InStream {
	k := streamKey(*f.Job, *f.Lease, *f.Epoch)
	s, ok := a.streams[k]
	if !ok {
		s = NewInStream(0)
		a.streams[k] = s
	}
	return s
}

// Issued records a command the coordinator is about to send, so a later cmd.ack is judged against what
// was really issued and not against the worker's own `for` field. The record is bounded by DedupeHorizon.
func (a *Admitter) Issued(f Frame) {
	var c struct {
		CmdID string `json:"cmd_id"`
	}
	if !commandTypes[f.T] || json.Unmarshal(f.Data, &c) != nil || c.CmdID == "" {
		return
	}
	a.issued[c.CmdID] = f.T
	a.issuedQ = append(a.issuedQ, c.CmdID)
	for len(a.issuedQ) > DedupeHorizon {
		delete(a.issued, a.issuedQ[0])
		a.issuedQ = a.issuedQ[1:]
	}
}

// SetApplied restores a stream's persisted applied_seq after a coordinator restart.
func (a *Admitter) SetApplied(job, lease string, epoch, applied int64) {
	a.streams[streamKey(job, lease, epoch)] = NewInStream(applied)
}

// Forget drops a stream's in-memory state (call when its lease ends).
func (a *Admitter) Forget(job, lease string, epoch int64) {
	delete(a.streams, streamKey(job, lease, epoch))
}

// Admit processes one line from the worker named by worker. Errors are *ProtoError whose code is the
// refuse to send (too_large for a frame beyond the window, ownership for a bad job.set, fenced,
// not_leased, unknown_job, invalid, version, auth_failed for a hello naming another worker).
func (a *Admitter) Admit(worker string, line []byte, now time.Time) (Admission, error) {
	f, err := Decode(line)
	if err != nil {
		return Admission{Frame: f}, err
	}
	if err := ValidateFrom(FromWorker, f); err != nil {
		return Admission{Frame: f}, err
	}
	adm := Admission{Frame: f}
	switch f.T {
	case TypeHello:
		h, _ := parseData[Hello](f)
		if h.WorkerID != worker {
			return adm, protoErr(CodeAuthFailed, "hello worker_id is not the authenticated worker")
		}
	case TypeBye:
	case TypeHb:
		h, _ := parseData[Hb](f)
		for _, j := range h.Jobs {
			if err := a.leases.HeartbeatFor(worker, j.Job, j.Lease, j.Epoch, now); err != nil {
				adm.HbRefused = append(adm.HbRefused, HbRefusal{Job: j.Job, Code: ErrorCode(err)})
			}
		}
	case TypeCmdAck:
		ack, _ := parseData[CmdAck](f)
		// The sync.file exemption (not job-scoped, so no lease to fence) rests on what the coordinator
		// recorded for this cmd_id, never on the worker's `for`: a worker cannot skip the fence by
		// labelling an ack sync.file.
		if issuedType := a.issued[ack.CmdID]; issuedType == TypeSyncFile {
			break
		}
		if ack.For == TypeSyncFile || f.Job == nil {
			return adm, protoErr(CodeInvalid, "cmd.ack: cmd_id is not an outstanding sync.file")
		}
		cur, err := a.leases.ownedBy(worker, *f.Job, *f.Lease, *f.Epoch)
		if err != nil {
			return adm, err
		}
		switch cur.State {
		case LeaseActive:
		case LeaseOffered:
			// The only command that can be outstanding on an offered lease is lease.offer, so its first
			// applied ack activates the lease. A rejected ack leaves it to lapse (or be revoked).
			if ack.Outcome == OutcomeApplied {
				if err := a.leases.AcceptFor(worker, *f.Job, *f.Lease, *f.Epoch, now); err != nil {
					return adm, err
				}
			}
		default:
			return adm, protoErr(CodeFenced, "lease %s is %s", *f.Lease, cur.State)
		}
	default: // stream frames
		if err := a.leases.CheckFenceFor(worker, *f.Job, *f.Lease, *f.Epoch); err != nil {
			return adm, err
		}
		if f.T == TypeJobSet {
			s, _ := parseData[JobSet](f)
			if vs := CheckJobSet(a.jobState(*f.Job), s.Set, s.Del); len(vs) > 0 {
				return adm, protoErr(CodeOwnership, "job.set: %s: %s", vs[0].Key, vs[0].Reason)
			}
		}
		adm.Verdict = a.stream(f).Accept(*f.Seq, len(f.Data))
		switch adm.Verdict {
		case TooFar:
			return adm, protoErr(CodeTooLarge, "seq %d is beyond the inbound window", *f.Seq)
		case Invalid:
			return adm, protoErr(CodeInvalid, "bad seq")
		}
	}
	return adm, nil
}

// Commit confirms that the caller applied f (an Apply verdict, or a buffered frame from Ready) and
// persisted applied_seq: apply, persist, Commit, ack. Applying a lease.release ends the lease and
// drops the stream. When applying a buffered job.set, call CheckJobSet again with the job's state at
// apply time.
func (a *Admitter) Commit(worker string, f Frame) error {
	if !streamTypes[f.T] || f.Job == nil || f.Lease == nil || f.Epoch == nil || f.Seq == nil {
		return protoErr(CodeInvalid, "commit: not a stream frame")
	}
	if err := a.leases.CheckFenceFor(worker, *f.Job, *f.Lease, *f.Epoch); err != nil {
		return err
	}
	if err := a.stream(f).Commit(*f.Seq); err != nil {
		return err
	}
	if f.T == TypeLeaseRelease {
		if err := a.leases.ReleaseFor(worker, *f.Job, *f.Lease, *f.Epoch); err != nil {
			return err
		}
		a.Forget(*f.Job, *f.Lease, *f.Epoch)
	}
	return nil
}

// Ready lists the buffered seqs of f's stream that are now contiguous (apply each from the caller's
// buffer, persist, Commit).
func (a *Admitter) Ready(f Frame) []int64 {
	if f.Job == nil || f.Lease == nil || f.Epoch == nil {
		return nil
	}
	s, ok := a.streams[streamKey(*f.Job, *f.Lease, *f.Epoch)]
	if !ok {
		return nil
	}
	return s.Ready()
}

// AckFor builds the ack payload for f's stream: seq is applied_seq, resend_from is set when a gap is
// buffered.
func (a *Admitter) AckFor(f Frame) (AckData, error) {
	if f.Job == nil || f.Lease == nil || f.Epoch == nil {
		return AckData{}, protoErr(CodeInvalid, "ack: frame has no stream")
	}
	s := a.stream(f)
	d := AckData{Job: *f.Job, Lease: *f.Lease, Epoch: *f.Epoch, Seq: s.Applied()}
	if s.HasGap() {
		d.ResendFrom = Int(s.ResendFrom())
	}
	return d, nil
}
