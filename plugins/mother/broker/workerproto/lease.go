package workerproto

import "time"

// Lease timing (spec section 7).
const (
	LeaseTTL          = 180 * time.Second
	HeartbeatInterval = 10 * time.Second
)

type LeaseState string

const (
	LeaseOffered  LeaseState = "offered"
	LeaseActive   LeaseState = "active"
	LeaseReleased LeaseState = "released"
	LeaseLost     LeaseState = "lost"
	LeaseRevoked  LeaseState = "revoked"
)

func (s LeaseState) terminal() bool {
	return s == LeaseReleased || s == LeaseLost || s == LeaseRevoked
}

// Lease is one grant of a job to a worker.
type Lease struct {
	ID     string
	Job    string
	Epoch  int64
	Worker string
	State  LeaseState
	// LastHB is the time of the last heartbeat (the offer time until the first one).
	LastHB time.Time
}

// LeaseTable holds each job's current lease and the highest epoch ever issued. It is a pure
// value: callers pass now; there is no clock.
type LeaseTable struct {
	current map[string]*Lease
	epochs  map[string]int64
}

func NewLeaseTable() *LeaseTable {
	return &LeaseTable{current: map[string]*Lease{}, epochs: map[string]int64{}}
}

// Get returns the job's current (latest) lease, terminal or not.
func (t *LeaseTable) Get(job string) (Lease, bool) {
	l, ok := t.current[job]
	if !ok {
		return Lease{}, false
	}
	return *l, true
}

// Offer grants a new lease with epoch = previous + 1. A job with a live (offered or active)
// lease is busy.
func (t *LeaseTable) Offer(job, leaseID, worker string, now time.Time) (Lease, error) {
	if cur, ok := t.current[job]; ok && !cur.State.terminal() {
		return Lease{}, protoErr(CodeBusy, "job %s already has live lease %s", job, cur.ID)
	}
	t.epochs[job]++
	l := &Lease{ID: leaseID, Job: job, Epoch: t.epochs[job], Worker: worker, State: LeaseOffered, LastHB: now}
	t.current[job] = l
	return *l, nil
}

// matches returns the job's current lease when (job, lease, epoch) names it, else a fenced or
// unknown_job error.
func (t *LeaseTable) matches(job, leaseID string, epoch int64) (*Lease, error) {
	cur, ok := t.current[job]
	if !ok {
		return nil, protoErr(CodeUnknownJob, "no lease for job %s", job)
	}
	if cur.ID != leaseID || cur.Epoch != epoch {
		return nil, protoErr(CodeFenced, "lease %s epoch %d is not current for job %s", leaseID, epoch, job)
	}
	return cur, nil
}

// Accept moves an offered lease to active (the worker acked the offer).
func (t *LeaseTable) Accept(job, leaseID string, epoch int64, now time.Time) error {
	cur, err := t.matches(job, leaseID, epoch)
	if err != nil {
		return err
	}
	if cur.State != LeaseOffered {
		return protoErr(CodeFenced, "lease %s is %s, not offered", leaseID, cur.State)
	}
	cur.State = LeaseActive
	cur.LastHB = now
	return nil
}

// Heartbeat refreshes an active lease.
func (t *LeaseTable) Heartbeat(job, leaseID string, epoch int64, now time.Time) error {
	if err := t.CheckFence(job, leaseID, epoch); err != nil {
		return err
	}
	t.current[job].LastHB = now
	return nil
}

// CheckFence passes only for the job's current active lease at that epoch; anything else is fenced
// (unknown_job when the job has never been leased). The caller answers with refuse{fenced} and
// writes an audit line.
func (t *LeaseTable) CheckFence(job, leaseID string, epoch int64) error {
	cur, err := t.matches(job, leaseID, epoch)
	if err != nil {
		return err
	}
	if cur.State != LeaseActive {
		return protoErr(CodeFenced, "lease %s is %s", leaseID, cur.State)
	}
	return nil
}

// Expire marks live leases lost and returns them. A lease is lost only when it has had no heartbeat
// for LeaseTTL and the coordinator itself has been up for at least LeaseTTL (MC-16): coordinator
// downtime never expires a lease, and a restarted coordinator gives workers a full TTL to reconnect.
func (t *LeaseTable) Expire(now, coordUpSince time.Time) []Lease {
	if now.Sub(coordUpSince) < LeaseTTL {
		return nil
	}
	var lost []Lease
	for _, l := range t.current {
		if !l.State.terminal() && now.Sub(l.LastHB) >= LeaseTTL {
			l.State = LeaseLost
			lost = append(lost, *l)
		}
	}
	return lost
}

// Release ends the current lease at the worker's request (lease.release).
func (t *LeaseTable) Release(job, leaseID string, epoch int64) error {
	return t.end(job, leaseID, epoch, LeaseReleased)
}

// Revoke ends the current lease at the coordinator's request (lease.revoke).
func (t *LeaseTable) Revoke(job, leaseID string, epoch int64) error {
	return t.end(job, leaseID, epoch, LeaseRevoked)
}

func (t *LeaseTable) end(job, leaseID string, epoch int64, to LeaseState) error {
	cur, err := t.matches(job, leaseID, epoch)
	if err != nil {
		return err
	}
	if cur.State.terminal() {
		return protoErr(CodeFenced, "lease %s already %s", leaseID, cur.State)
	}
	cur.State = to
	return nil
}
