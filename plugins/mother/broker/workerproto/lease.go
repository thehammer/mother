package workerproto

import (
	"sort"
	"time"
)

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
// unknown_job error. A job that has an epoch history but no current lease (a restored table keeps only
// live leases) is fenced, not unknown: the caller is a stale holder.
func (t *LeaseTable) matches(job, leaseID string, epoch int64) (*Lease, error) {
	cur, ok := t.current[job]
	if !ok {
		if t.epochs[job] > 0 {
			return nil, protoErr(CodeFenced, "lease %s epoch %d is not current for job %s", leaseID, epoch, job)
		}
		return nil, protoErr(CodeUnknownJob, "no lease for job %s", job)
	}
	if cur.ID != leaseID || cur.Epoch != epoch {
		return nil, protoErr(CodeFenced, "lease %s epoch %d is not current for job %s", leaseID, epoch, job)
	}
	return cur, nil
}

// ownedBy returns the current lease for (job, lease, epoch) after checking the authenticated worker
// owns it (MC-27). Pass the identity authenticated for the connection (peercred in Phase 1), never a
// value read from a frame. A different worker gets not_leased.
func (t *LeaseTable) ownedBy(worker, job, leaseID string, epoch int64) (*Lease, error) {
	cur, err := t.matches(job, leaseID, epoch)
	if err != nil {
		return nil, err
	}
	if cur.Worker != worker {
		return nil, protoErr(CodeNotLeased, "job %s is not leased to worker %s", job, worker)
	}
	return cur, nil
}

// AcceptFor moves an offered lease to active (the worker acked the offer), for the worker it was
// offered to.
func (t *LeaseTable) AcceptFor(worker, job, leaseID string, epoch int64, now time.Time) error {
	cur, err := t.ownedBy(worker, job, leaseID, epoch)
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

// HeartbeatFor refreshes an active lease for its worker. LastHB never moves backwards (a late or
// reordered heartbeat cannot shorten the TTL); callers must pass wall-clock times from one consistent
// clock, since Expire compares them with its own now.
func (t *LeaseTable) HeartbeatFor(worker, job, leaseID string, epoch int64, now time.Time) error {
	if err := t.CheckFenceFor(worker, job, leaseID, epoch); err != nil {
		return err
	}
	cur := t.current[job]
	cur.LastHB = laterOf(cur.LastHB, now)
	return nil
}

func laterOf(a, b time.Time) time.Time {
	if b.After(a) {
		return b
	}
	return a
}

// checkFence passes only for the job's current active lease at that epoch; anything else is fenced
// (unknown_job when the job has never been leased). The caller answers with refuse{fenced} and
// writes an audit line.
func (t *LeaseTable) checkFence(job, leaseID string, epoch int64) error {
	cur, err := t.matches(job, leaseID, epoch)
	if err != nil {
		return err
	}
	if cur.State != LeaseActive {
		return protoErr(CodeFenced, "lease %s is %s", leaseID, cur.State)
	}
	return nil
}

// CheckFenceFor is the exported fence: checkFence plus the worker-identity check (see ownedBy). The
// unchecked checkFence is unexported so a caller cannot skip the identity step.
func (t *LeaseTable) CheckFenceFor(worker, job, leaseID string, epoch int64) error {
	if err := t.checkFence(job, leaseID, epoch); err != nil {
		return err
	}
	_, err := t.ownedBy(worker, job, leaseID, epoch)
	return err
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

// ReleaseFor ends the current lease at its worker's request (lease.release), once the coordinator
// has applied that frame.
func (t *LeaseTable) ReleaseFor(worker, job, leaseID string, epoch int64) error {
	if _, err := t.ownedBy(worker, job, leaseID, epoch); err != nil {
		return err
	}
	return t.end(job, leaseID, epoch, LeaseReleased)
}

// Revoke ends the current lease at the coordinator's request (lease.revoke). It is coordinator-
// initiated, so there is no worker to check.
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

// LeaseRecord is one persisted lease.
type LeaseRecord struct {
	ID     string     `json:"id"`
	Job    string     `json:"job"`
	Epoch  int64      `json:"epoch"`
	Worker string     `json:"worker"`
	State  LeaseState `json:"state"`
	LastHB time.Time  `json:"last_hb"`
}

// LeaseSnapshot is the durable form of a LeaseTable: the highest epoch ever issued per job (fence
// tokens must be monotonic across coordinator restarts, MC-15/16) and every live lease. Terminal
// leases are not kept: their epoch is covered by Epochs, and a stale holder of one is fenced.
//
// Persistence order (spec section 7): write the snapshot, durably, before the lease.offer that carries
// a new epoch leaves the coordinator; otherwise a crash could reissue that epoch.
type LeaseSnapshot struct {
	Epochs map[string]int64 `json:"epochs"`
	Leases []LeaseRecord    `json:"leases"`
}

// Snapshot returns a deep copy of the table's durable state (leases ordered by job id).
func (t *LeaseTable) Snapshot() LeaseSnapshot {
	snap := LeaseSnapshot{Epochs: make(map[string]int64, len(t.epochs)), Leases: []LeaseRecord{}}
	for j, e := range t.epochs {
		snap.Epochs[j] = e
	}
	for _, l := range t.current {
		if !l.State.terminal() {
			snap.Leases = append(snap.Leases, LeaseRecord{ID: l.ID, Job: l.Job, Epoch: l.Epoch, Worker: l.Worker, State: l.State, LastHB: l.LastHB})
		}
	}
	sort.Slice(snap.Leases, func(i, j int) bool { return snap.Leases[i].Job < snap.Leases[j].Job })
	return snap
}

// RestoreLeaseTable rebuilds a table from a snapshot. It refuses a corrupt snapshot (a lease whose
// epoch exceeds its job's recorded epoch, a terminal or duplicate lease, bad ids) rather than risk
// reissuing a fence token. Live leases keep their LastHB; Expire's coordUpSince grace (MC-16) gives
// their workers a full TTL to reconnect.
func RestoreLeaseTable(s LeaseSnapshot) (*LeaseTable, error) {
	t := NewLeaseTable()
	for j, e := range s.Epochs {
		if !IDOK(j) || e < 0 {
			return nil, protoErr(CodeInvalid, "lease snapshot: bad epoch entry for %q", j)
		}
		t.epochs[j] = e
	}
	for _, r := range s.Leases {
		if !IDOK(r.Job) || !IDOK(r.ID) || r.Worker == "" || r.Epoch < 1 || r.Epoch > t.epochs[r.Job] || r.State.terminal() ||
			(r.State != LeaseOffered && r.State != LeaseActive) {
			return nil, protoErr(CodeInvalid, "lease snapshot: bad lease for job %q", r.Job)
		}
		if _, dup := t.current[r.Job]; dup {
			return nil, protoErr(CodeInvalid, "lease snapshot: two live leases for job %q", r.Job)
		}
		l := r
		t.current[r.Job] = &Lease{ID: l.ID, Job: l.Job, Epoch: l.Epoch, Worker: l.Worker, State: l.State, LastHB: l.LastHB}
	}
	return t, nil
}
