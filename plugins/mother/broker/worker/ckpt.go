package worker

// Checkpoints, salvage and graceful stop (cluster P1-6, docs/worker-protocol.md section 9):
//
//   - ckptLoop: every Config.CkptInterval each live lease gets `mother checkpoint take <job> --ship`
//     run against the worker root, so its wip commit is pushed and its transcript delta and manifest
//     enter the job's ordered outbox. The supervisor does the same at phase boundaries and before every
//     exit (bin/mother-run-job, _ckpt_final); both serialise on the checkpoint lock inside `take`.
//   - salvage: a fenced lease's work tree is pushed to refs/mother/wip-salvage/<job>/lease-<epoch> and
//     reported with a salvage control frame (the stream is refused, so the report cannot ride it).
//   - GracefulStop: SIGTERM to the daemon stops every supervisor (each takes its final checkpoint) and keeps
//     shipping until the outboxes drain.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"

	"mother-broker/workerproto"
)

// ckptWatchdog bounds one cadence checkpoint (the library's own deadline is 60 s; this is the backstop that
// kills the whole process group if the CLI itself hangs).
const ckptWatchdog = 90 * time.Second

// runMother runs `mother <args...>` in its own process group with env, killing the group after timeout.
// It returns stdout and the exit code (-1 when it could not be run or was killed).
func (d *Daemon) runMother(timeout time.Duration, env []string, args ...string) (string, int) {
	cmd := exec.Command(d.cfg.MotherCLI, args...)
	cmd.Env = env
	cmd.Dir = d.cfg.Root
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	var out bytes.Buffer
	cmd.Stdout = &out
	if err := cmd.Start(); err != nil {
		d.logf("run mother %v: %v", args, err)
		return "", -1
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err == nil {
			return out.String(), 0
		}
		if ee, ok := err.(*exec.ExitError); ok {
			return out.String(), ee.ExitCode()
		}
		return out.String(), -1
	case <-time.After(timeout):
		_ = syscall.Kill(-cmd.Process.Pid, syscall.SIGKILL)
		<-done
		return out.String(), -1
	}
}

// ckptLoop takes a checkpoint of every live lease each interval. Takes run outside d.mu, one per job at a time.
func (d *Daemon) ckptLoop(ctx context.Context) {
	if d.cfg.CkptInterval <= 0 {
		return
	}
	t := time.NewTicker(d.cfg.CkptInterval)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			d.mu.Lock()
			if d.stopping {
				d.mu.Unlock()
				continue
			}
			var todo []*lease
			for _, l := range d.leases {
				if l.loc.State != stateActive || l.exited || l.pid <= 0 || l.ckptBusy {
					continue
				}
				// No live Claude session in awaiting or a terminal state: the supervisor checkpointed on the way in.
				if d.mirrorState(l.loc.Job) != "running" {
					continue
				}
				l.ckptBusy = true
				todo = append(todo, l)
			}
			d.mu.Unlock()
			for _, l := range todo {
				go d.ckptOne(l)
			}
		}
	}
}

func (d *Daemon) ckptOne(l *lease) {
	d.mu.Lock()
	job, leaseID, epoch := l.loc.Job, l.loc.LeaseID, l.loc.Epoch
	d.mu.Unlock()
	_, rc := d.runMother(ckptWatchdog, d.scrubbedEnv("MOTHER_LEASE_ID="+leaseID, "MOTHER_LEASE_EPOCH="+itoa(epoch)),
		"checkpoint", "take", job, "--ship")
	d.mu.Lock()
	l.ckptBusy = false
	if rc == 3 { // exit 3: the lease was lost (fenced push)
		d.logf("checkpoint of %s was fenced (lease %s epoch %d)", job, leaseID, epoch)
		d.fence(l, workerproto.CodeFenced)
	} else if rc != 0 {
		d.logf("checkpoint of %s failed (exit %d); the next interval retries", job, rc)
	}
	d.mu.Unlock()
}

// salvageSnapshot copies the lease's mirror document into a private mother root so the salvage take keeps
// pointing at the OLD work tree even after a new lease for the same job rewrites the mirror.
func (d *Daemon) salvageSnapshot(l *lease) (string, bool) {
	root := d.p("salvage", fmt.Sprintf("%s-e%d", l.loc.Job, l.loc.Epoch))
	b, err := os.ReadFile(d.p("jobs", l.loc.Job+".json"))
	if err != nil {
		d.logf("salvage %s: no mirror document: %v", l.loc.Job, err)
		return "", false
	}
	if err := writeFileAtomic(filepath.Join(root, "jobs", l.loc.Job+".json"), b); err != nil {
		d.logf("salvage %s: %v", l.loc.Job, err)
		return "", false
	}
	return root, true
}

// salvage pushes the fenced lease's work tree to its salvage ref and reports it. The supervisor is already
// stopped (the caller waited for it).
func (d *Daemon) salvage(l *lease, root string) {
	job, leaseID, epoch := l.loc.Job, l.loc.LeaseID, l.loc.Epoch
	env := []string{"PATH=" + os.Getenv("PATH"), "HOME=" + os.Getenv("HOME"), "TMPDIR=" + os.TempDir(),
		"MOTHER_ROOT=" + root, "MOTHER_LEASE_ID=" + leaseID,
		"MOTHER_CHECKPOINT_FINAL_TIMEOUT_S=" + strconv.Itoa(int(d.cfg.CkptFinalWait/time.Second))}
	for _, k := range []string{"MOTHER_CLAUDE_PROJECTS_DIR", "MOTHER_TEST_ROOT", "MOTHER_LIB_DIR", "MOTHER_BIN_DIR", "GIT_SSH_COMMAND", "SSH_AUTH_SOCK"} {
		if v := os.Getenv(k); v != "" {
			env = append(env, k+"="+v)
		}
	}
	out, rc := d.runMother(d.cfg.CkptFinalWait+30*time.Second, env, "checkpoint", "take", job, "--final", "--salvage-epoch", itoa(epoch))
	var m struct {
		WipSHA string `json:"wip_sha"`
		Pushed bool   `json:"pushed"`
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	_ = json.Unmarshal([]byte(lines[len(lines)-1]), &m)
	if rc != 0 || !m.Pushed || m.WipSHA == "" {
		d.logf("salvage of %s (epoch %d) did not push (exit %d)", job, epoch, rc)
		return
	}
	rec := map[string]any{"job": job, "lease": leaseID, "epoch": epoch, "wip_sha": m.WipSHA, "ref": workerproto.SalvageRef(job, epoch)}
	if err := writeJSON(d.p("salvage", "pending", fmt.Sprintf("%s.%d.json", job, epoch)), rec); err != nil {
		d.logf("salvage %s: record: %v", job, err)
		return
	}
	d.logf("salvaged %s (lease %s epoch %d) to %s", job, leaseID, epoch, workerproto.SalvageRef(job, epoch))
	d.mu.Lock()
	if d.sess != nil {
		d.sendSalvages(d.sess)
	}
	d.mu.Unlock()
}

// sendSalvages sends every pending salvage report (kept on disk until sent, so a coordinator absence loses
// none). Caller holds d.mu.
func (d *Daemon) sendSalvages(s *session) {
	ents, _ := os.ReadDir(d.p("salvage", "pending"))
	for _, e := range ents {
		if !strings.HasSuffix(e.Name(), ".json") {
			continue
		}
		path := d.p("salvage", "pending", e.Name())
		b, err := os.ReadFile(path)
		if err != nil {
			continue
		}
		var r struct {
			Job    string `json:"job"`
			Lease  string `json:"lease"`
			Epoch  int64  `json:"epoch"`
			WipSHA string `json:"wip_sha"`
			Ref    string `json:"ref"`
		}
		if json.Unmarshal(b, &r) != nil || r.Job == "" {
			_ = os.Remove(path)
			continue
		}
		l := &lease{loc: localLease{Job: r.Job, LeaseID: r.Lease, Epoch: r.Epoch}}
		fb, err := build(workerproto.TypeSalvage, l, nil, workerproto.Salvage{Ref: r.Ref, WipSHA: r.WipSHA})
		if err != nil {
			d.logf("salvage frame for %s: %v", r.Job, err)
			_ = os.Remove(path)
			continue
		}
		if s.send(fb) != nil {
			return
		}
		_ = os.Remove(path)
	}
}

// GracefulStop (SIGTERM to the daemon): every supervisor gets SIGTERM so it can finish its own final
// checkpoint, then the daemon keeps shipping until each outbox drains, the coordinator has been unreachable
// for 5 s, or wait has passed; whatever is still running after that is killed so no child outlives the daemon.
func (d *Daemon) GracefulStop(wait time.Duration) {
	d.mu.Lock()
	d.stopping = true
	for _, l := range d.leases {
		if l.loc.State == stateActive && l.pid > 0 && !l.exited && d.signalable(l) {
			_ = syscall.Kill(l.pid, syscall.SIGTERM) // the supervisor only: it stops its own claude, checkpoints, exits
		}
	}
	d.mu.Unlock()
	deadline := time.Now().Add(wait)
	var unreachableSince time.Time
	for time.Now().Before(deadline) {
		d.mu.Lock()
		pending := false
		for _, l := range d.leases {
			if l.loc.State != stateActive {
				continue
			}
			if !l.exited || (l.ship != nil && !l.noHB) {
				pending = true // still running, or exited with its outbox, log or release not yet acknowledged
			}
		}
		connected := d.sess != nil
		d.mu.Unlock()
		if !pending {
			break
		}
		if connected {
			unreachableSince = time.Time{}
		} else {
			if unreachableSince.IsZero() {
				unreachableSince = time.Now()
			} else if time.Since(unreachableSince) >= 5*time.Second {
				d.logf("graceful stop: coordinator unreachable for 5s; leaving the outboxes on disk")
				break
			}
		}
		time.Sleep(100 * time.Millisecond)
	}
	// Reap: nothing the daemon started may outlive it.
	d.mu.Lock()
	var stragglers []*lease
	for _, l := range d.leases {
		if l.pid > 0 && !l.exited {
			stragglers = append(stragglers, l)
		}
	}
	d.mu.Unlock()
	for _, l := range stragglers {
		d.terminate(l.pid, l.pidStart, l.done)
	}
}

// signalable: pid is ours (own child) or a re-verified adopted supervisor.
func (d *Daemon) signalable(l *lease) bool {
	if l.done != nil {
		return true
	}
	return alive(l.pid) && (l.pidStart == "" || procStart(l.pid) == l.pidStart) && d.isSupervisor(l.pid)
}
