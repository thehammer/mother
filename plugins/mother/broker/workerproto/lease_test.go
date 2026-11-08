package workerproto

import (
	"encoding/json"
	"testing"
	"time"
)

var t0 = time.Date(2026, 11, 8, 12, 0, 0, 0, time.UTC)

func activeLease(t *testing.T, tb *LeaseTable, job, id string, now time.Time) Lease {
	t.Helper()
	l, err := tb.Offer(job, id, "w", now)
	if err != nil {
		t.Fatal(err)
	}
	if err := tb.Accept(job, id, l.Epoch, now); err != nil {
		t.Fatal(err)
	}
	return l
}

func TestLeaseLifecycle(t *testing.T) {
	tb := NewLeaseTable()
	l, _ := tb.Offer("j", "L1", "w", t0)
	if l.Epoch != 1 || l.State != LeaseOffered {
		t.Fatalf("%+v", l)
	}
	if ErrorCode(tb.CheckFence("j", "L1", 1)) != CodeFenced {
		t.Fatal("an offered lease is not yet active")
	}
	if _, err := tb.Offer("j", "L1b", "w", t0); ErrorCode(err) != CodeBusy {
		t.Fatalf("live lease: %v", err)
	}
	if err := tb.Accept("j", "L1", 1, t0); err != nil {
		t.Fatal(err)
	}
	if err := tb.CheckFence("j", "L1", 1); err != nil {
		t.Fatal(err)
	}
	if ErrorCode(tb.CheckFence("nope", "L1", 1)) != CodeUnknownJob {
		t.Fatal("unknown job")
	}
	if err := tb.Release("j", "L1", 1); err != nil {
		t.Fatal(err)
	}
	if ErrorCode(tb.Release("j", "L1", 1)) != CodeFenced || ErrorCode(tb.Revoke("j", "L1", 1)) != CodeFenced {
		t.Fatal("release is terminal")
	}
	if ErrorCode(tb.Heartbeat("j", "L1", 1, t0)) != CodeFenced {
		t.Fatal("no heartbeat after release")
	}
}

func TestRevokeIsTerminal(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0)
	if err := tb.Revoke("j", "L1", 1); err != nil {
		t.Fatal(err)
	}
	if ErrorCode(tb.CheckFence("j", "L1", 1)) != CodeFenced || ErrorCode(tb.Release("j", "L1", 1)) != CodeFenced {
		t.Fatal("revoke is terminal")
	}
	if l, _ := tb.Get("j"); l.State != LeaseRevoked {
		t.Fatal(l.State)
	}
}

// MC-15: a requeued job's new lease bumps the epoch and the old epoch is fenced.
func TestEpochBumpAndFence(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0)
	tb.Expire(t0.Add(time.Hour), t0)
	l2, err := tb.Offer("j", "L2", "w2", t0.Add(time.Hour))
	if err != nil || l2.Epoch != 2 {
		t.Fatalf("%+v %v", l2, err)
	}
	tb.Accept("j", "L2", 2, t0.Add(time.Hour))
	if ErrorCode(tb.CheckFence("j", "L1", 1)) != CodeFenced {
		t.Fatal("old lease must be fenced")
	}
	if ErrorCode(tb.CheckFence("j", "L2", 1)) != CodeFenced || ErrorCode(tb.CheckFence("j", "L1", 2)) != CodeFenced {
		t.Fatal("lease id and epoch must both match")
	}
	if err := tb.CheckFence("j", "L2", 2); err != nil {
		t.Fatal(err)
	}
	if ErrorCode(tb.Heartbeat("j", "L1", 1, t0)) != CodeFenced {
		t.Fatal("old heartbeat fenced")
	}
}

func TestExpireTTL(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0)
	up := t0.Add(-time.Hour) // coordinator has been up a long time
	if got := tb.Expire(t0.Add(LeaseTTL-time.Second), up); len(got) != 0 {
		t.Fatal("not yet expired")
	}
	tb.Heartbeat("j", "L1", 1, t0.Add(100*time.Second))
	if got := tb.Expire(t0.Add(100*time.Second+LeaseTTL-time.Second), up); len(got) != 0 {
		t.Fatal("heartbeat resets the TTL")
	}
	got := tb.Expire(t0.Add(100*time.Second+LeaseTTL), up)
	if len(got) != 1 || got[0].State != LeaseLost || got[0].Job != "j" {
		t.Fatalf("expired: %+v", got)
	}
	if len(tb.Expire(t0.Add(time.Hour), up)) != 0 {
		t.Fatal("a lost lease is not expired twice")
	}
}

// MC-16: coordinator downtime never expires a lease.
func TestCoordinatorDowntimeNeverExpiresLease(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0)
	// Coordinator was down for 2 hours and restarted just now: the last heartbeat is 2 h old.
	restart := t0.Add(2 * time.Hour)
	if got := tb.Expire(restart, restart); len(got) != 0 {
		t.Fatal("must not expire at restart")
	}
	if got := tb.Expire(restart.Add(LeaseTTL-time.Second), restart); len(got) != 0 {
		t.Fatal("must not expire before the coordinator has been up one TTL")
	}
	// A heartbeat inside that grace window saves it.
	tb.Heartbeat("j", "L1", 1, restart.Add(60*time.Second))
	if got := tb.Expire(restart.Add(LeaseTTL), restart); len(got) != 0 {
		t.Fatal("worker reconnected and heartbeated: not lost")
	}
	// A worker that stays silent past one full TTL of coordinator uptime is lost.
	tb2 := NewLeaseTable()
	activeLease(t, tb2, "j", "L1", t0)
	if got := tb2.Expire(restart.Add(LeaseTTL), restart); len(got) != 1 {
		t.Fatal("silent worker is lost once the grace has passed")
	}
}

func TestOfferedLeaseExpiresToo(t *testing.T) {
	tb := NewLeaseTable()
	tb.Offer("j", "L1", "w", t0)
	if got := tb.Expire(t0.Add(LeaseTTL), t0.Add(-time.Hour)); len(got) != 1 {
		t.Fatal("an offer nobody accepted must lapse")
	}
}

func TestFencedAfterRequeueFixture(t *testing.T) {
	fs := decodeFixture(t, "fenced_after_requeue.ndjson")
	tb := NewLeaseTable()
	var fenced int
	for _, f := range fs {
		switch f.T {
		case TypeLeaseOffer:
			if _, err := tb.Offer(*f.Job, *f.Lease, "w", t0); err != nil {
				// the second offer arrives after the first was revoked
				t.Fatal(err)
			}
			if err := tb.Accept(*f.Job, *f.Lease, *f.Epoch, t0); err != nil {
				t.Fatal(err)
			}
		case TypeHb:
			var hb Hb
			json.Unmarshal(f.Data, &hb)
			if err := tb.Heartbeat(hb.Jobs[0].Job, hb.Jobs[0].Lease, hb.Jobs[0].Epoch, t0); err != nil {
				t.Fatal(err)
			}
		case TypeLeaseRevoke:
			if err := tb.Revoke(*f.Job, *f.Lease, *f.Epoch); err != nil {
				t.Fatal(err)
			}
		case TypeEventAppend:
			err := tb.CheckFence(*f.Job, *f.Lease, *f.Epoch)
			if ErrorCode(err) != CodeFenced {
				t.Fatalf("late frame from the old lease must be fenced: %v", err)
			}
			fenced++
		case TypeRefuse:
			var r Refuse
			json.Unmarshal(f.Data, &r)
			if fenced != 1 || r.Code != CodeFenced {
				t.Fatalf("expected the refuse{fenced} reply after the fenced frame: %+v", r)
			}
		}
	}
	if l, _ := tb.Get("j" + "ob-abc123"); l.Epoch != 2 || l.State != LeaseActive {
		t.Fatalf("%+v", l)
	}
}

func TestLeaseTimingConstants(t *testing.T) {
	if LeaseTTL != 180*time.Second || HeartbeatInterval != 10*time.Second {
		t.Fatal("spec: TTL 180 s, heartbeat 10 s")
	}
	if LeaseTTLSeconds != int(LeaseTTL/time.Second) || HeartbeatIntervalS != int(HeartbeatInterval/time.Second) {
		t.Fatal("welcome constants must match")
	}
}

func TestCheckFenceForWorkerIdentity(t *testing.T) {
	tb := NewLeaseTable()
	activeLease(t, tb, "j", "L1", t0) // granted to worker "w"
	if err := tb.CheckFenceFor("w", "j", "L1", 1); err != nil {
		t.Fatal(err)
	}
	if ErrorCode(tb.CheckFenceFor("other", "j", "L1", 1)) != CodeNotLeased {
		t.Fatal("a different worker must get not_leased")
	}
	if ErrorCode(tb.CheckFenceFor("w", "j", "L1", 2)) != CodeFenced {
		t.Fatal("fencing still applies")
	}
}
