# Cluster Phase 1 burn-in: running jobs through the local coordinator and worker

Phase 1 of the cluster work puts a coordinator (`mother-coord`) and a worker (`mother-worker --id local`) between
the runner and `mother-run-job`. With `MOTHER_DISPATCH_MODE=worker` a job is leased to the laptop's own worker, its
state comes back through the outbox, and a worker that stops (crash, SIGKILL, SIGTERM, lost lease) is replaced by
resuming the job from its last pushed checkpoint. This runbook is how the owner turns that on, watches it, proves
the kill-and-resume path on a throwaway job, and turns it back off.

Rule it enforces (2026-11-08): a worker pushes its committed work at every checkpoint and before it exits for any
reason; uncommitted changes are captured too; the transcript goes to the coordinator on the same cadence. Worst-case
loss on SIGKILL is the checkpoint interval plus the 60 s watchdog (default 120 + 60 = 180 s; under the 300 s bound).

## 1. Turn it on

```bash
echo 'MOTHER_DISPATCH_MODE=worker' >> ~/.mother/config.env      # durable; real env vars still win
mother daemon stop && mother daemon start                        # the runner re-reads config.env
mother status | grep -i 'dispatch mode'                          # Dispatch mode: worker (config file)
mother workers                                                   # name, connection, heartbeat age, jobs
```

Do this with no job running (or `mother drain --wait` first). The default stays `legacy`; nothing else changes.
A single job can opt in without the switch: `mother add --via-worker ...` (or `via_worker: true` in the plan).

Optional knobs (env or `config.env`): `MOTHER_CHECKPOINT_INTERVAL_S` (30..240, default 120),
`MOTHER_CHECKPOINT_FINAL_TIMEOUT_S` (30), `MOTHER_WORKER_RESUME_MAX` (3 resumes per job before it is held),
`MOTHER_LEASE_TTL_S` (how long a silent lease lives before the coordinator declares it lost).

## 2. What to watch

| Where | What it tells you |
|---|---|
| `mother workers` | the worker is connected, heartbeat age, which jobs it holds |
| `mother status <id>` | `worker: local (lease eN, hb Ns ago)`, and after a loss a timeline line: `worker local lost at 2:14 pm CST; resumed on local from the checkpoint at 2:11 pm CST; about 3 minutes of work re-done` |
| `~/.mother/runner/leases/audit.jsonl` | one JSON line per refusal, lost lease, offer rejection and salvage push (`code: salvage`) |
| `~/.mother/checkpoints/<job>/index.jsonl` | every checkpoint the coordinator received (`n`, `at`, `pushed`, `transcript_ok`); `latest.json` is the one a resume uses |
| job events (`mother events`) | `checkpoint_final {reason}`, `worker_lost {reason: lost\|released_running}`, `resumed_from_checkpoint {lost_work_s, checkpoint_at, ...}`, `worker_salvaged {epoch, ref}` |
| `git ls-remote origin 'refs/mother/wip*'` | the work as the remote sees it (`refs/mother/wip/<job>`; `refs/mother/wip-salvage/<job>/lease-<epoch>` after a fenced worker) |

A job that cannot be resumed is **held**, never restarted from scratch: it fails `no_checkpoint_restorable` with a
stated `why` (`no pushed checkpoint`, `wip ref missing on remote`, `transcript missing or unverifiable`, ...), or
`worker_resume_exhausted`. Both route to an operator hold (`mother resume|retry|cancel <id>`).

## 3. The live kill test (real `claude`, a throwaway personal-repo job)

Use a scratch repo you do not mind pushing `refs/mother/*` refs to, and a plan that edits a few files slowly
(for example "create five small files, committing after each, and wait 20 seconds between them").

```bash
mother add --via-worker <plan>            # or rely on MOTHER_DISPATCH_MODE=worker
mother status <id>                        # wait until it is running and at least one checkpoint is in
cat ~/.mother/checkpoints/<id>/index.jsonl | tail -n 1
read pid pgid < ~/.mother-worker/local/worker.pid
kill -9 -"$pgid"                          # the worker daemon, its supervisor and claude: the exact group, nothing by pattern
```

Expected, within the lease TTL plus a runner tick: a `worker_lost` event, the job back to `ready`, a new `local`
worker started by the runner, a new lease with epoch + 1 at a different worktree path (`...-e<epoch>`), the same Claude
session continuing (`--resume`), and a finished PR. `mother status <id>` shows the timeline line with the work re-done.
Check that `lost_work_s` is at most interval + 60.

To see the SIGTERM path instead: `kill -TERM <pid>` (the daemon pid from `worker.pid`). Within 30 s the final
checkpoint is pushed, the lease is released with the job still running, and the job resumes with `lost_work_s` near 0.

## 4. Turn it off

```bash
sed -i.bak '/^MOTHER_DISPATCH_MODE=/d' ~/.mother/config.env   # or set it to legacy
mother drain --wait                                           # let worker-path jobs finish; legacy jobs are unaffected
mother daemon stop && mother daemon start
```

Jobs already on the worker path finish there (the runner keeps the coordinator and worker up while a lease is in
flight). Legacy mode takes no checkpoints and pushes no `refs/mother/*` ref.

## 5. Cleaning up `refs/mother/wip*`

Nothing deletes them yet (follow-up). After a job is archived, remove its refs from the remote:

```bash
git -C <repo> push origin --delete refs/mother/wip/<job>
git ls-remote origin "refs/mother/wip-salvage/<job>/*" | awk '{print ":" $2}' | xargs git -C <repo> push origin
```

Wip refs hold a commit on top of the job's head with the working tree at capture time (including untracked files that
are not ignored); treat them like the branch itself when deciding who may read the remote.
