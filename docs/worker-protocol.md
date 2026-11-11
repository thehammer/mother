# Mother worker protocol v1

Reference spec for the wire between Mother's **coordinator** and its **workers** (PRD: `.claude/prds/mother-cluster.md`).
Executable form: the Go package `plugins/mother/broker/workerproto` and the golden frames in
`plugins/mother/tests/fixtures/worker-proto/`. MC numbers are the PRD's requirement ids; B-numbers are the
bets in the cluster Phase 1 plan index.

This protocol is separate from the broker's client protocol and from Nostromo's wire (`broker/envelope.go` is untouched).

## 1. Roles and trust

- The **coordinator** is the only writer of canonical job state (B1). It holds job files, events and records, and schedules.
- A **worker** runs jobs. It sees only jobs leased to it (MC-27) and reports everything over its per-job stream.
- Phase 1 auth is `peercred`: same uid, checked on the Unix socket the way `broker/peerguard.go` does today.
- The `hello.auth` object is the extension point for Phase 2 per-worker credentials and mutual auth (MC-25, MC-26).
  Until then, any `auth.method` other than `peercred` is refused with `auth_unsupported`. Auth is checked before version.
- **Identity is never read from a frame.** The coordinator passes the identity authenticated for the connection to every
  check (`Admitter.Admit(worker, line, now)`); `hello.worker_id` must equal it (`auth_failed` otherwise), and a lease is
  bound to the worker it was offered to (`not_leased` for anyone else).
- **One entry point.** `Admitter.Admit` does decode, shape validation, direction, fence, worker identity, ownership and
  stream accounting in a single call. The unchecked primitives (`checkFence`, `InStream` internals) are unexported, so a
  caller cannot skip a step. Section 12 lists the order.

## 2. Transport and framing

- Phase 1: a Unix socket at `$MOTHER_ROOT/runner/coord/worker.sock`, mode 0600, in a private 0700 directory (verified with `Lstat` on every start: ours, not a symlink) that also holds `coord.pid` and `coord.lock` (an `flock` held for the coordinator's lifetime). Same-uid peercred alone does not identify a worker (a job's agent runs as the same uid), so a worker id is bound to a per-worker secret (memory-only; `hello.auth.credential` = HMAC-SHA256 over `HelloTranscript` with the worker's `nonce`) and to the worker daemon's pid (`SO_PEERCRED` / `LOCAL_PEERPID`). A second live connection for an id is refused unless instance id and credential match.

  Secret and identity rules of the local carrier: the secret reaches `mother-worker` **only over an inherited fd** (`--secret-fd N` or `MOTHER_WORKER_SECRET_FD=N`; read once, fd closed, memory only). There is no environment fallback and a worker without an fd refuses to run, because the initial environment block stays readable by a same-uid process (`/proc/<pid>/environ`, `ps eww`). The coordinator registers each worker with its **real pid** (`LaunchWorker` registers the pid it started; `mother-coord --secrets-fd` reads `worker-id=pid=secret` lines for as long as the launcher keeps the fd open, so a restarted worker is re-registered with its new pid); a pid-0 registration is refused, so no id is ever bound to "the first authenticated connection". Connections from the registered pid are exempt from pre-hello eviction. Known limits, accepted for the local carrier: same-uid ptrace/debugger access to the worker or coordinator is out of scope; a pid reused by an unrelated process after the worker died makes that worker refuse (`pid_mismatch`) until it is re-registered or the coordinator restarts; the hello proof has no coordinator challenge (a replayed proof is blocked by the pid binding, not by freshness); and `runner/revoke/` and `runner/dispatch/` request files are plain same-uid files, the same trust domain as canonical state.
- NDJSON: one UTF-8 JSON object per line, at most **1 MiB including the newline** (1 048 576 bytes). Encoders emit no
  embedded newlines (`encoding/json` never does); a decoder rejects a line containing one. An oversized frame is `too_large`.
- Readers use `ReadFrame(*bufio.Reader)`, which enforces the limit **while reading**: a line still unterminated at 1 MiB
  yields `too_large` after at most 1 MiB plus one buffer of input, never the whole line. The connection is then closed.
- Invalid UTF-8 and lone `\uD800`-style surrogate escapes are refused (`encoding/json` would silently rewrite them).
- Larger payloads are chunked: `artifact.put` and `log.append` carry at most **256 KiB of raw bytes** per frame, base64.
- A frame maps 1:1 to a WebSocket text message for the Phase 3 wss carrier, through a relay that both sides dial out to.
  Kobe is behind NAT and often asleep, and the laptop is never exposed to inbound internet traffic.

## 3. Envelope v1

```json
{"v":1,"t":"<type>","id":"<uuid>","ts":"<ISO-8601 ms Z>","job":"<id>|null","lease":"<lease id>|null","epoch":<int>|null,"seq":<int>|null,"ack":<int>|null,"data":{}}
```

- Key order is fixed (as above) so that decode then encode is byte-identical; `data` is kept as raw JSON.
- **Strict decoding.** Go's `encoding/json` is case-insensitive and last-wins, so the decoder scans the keys itself: a
  duplicate key, or a key that is a case-variant of a known one (`T`, `Data`), is `invalid`, at the envelope and at the top
  level of `data`. Unknown envelope keys are `invalid` too: **additive fields are tolerated only inside `data`**; a new
  envelope key is a v2 change. A `v` other than 1 is `version` (so a v2 hello is answered with `refuse{version}`, via
  `RefuseFor`); a missing `v` is `invalid`.
- `ts` is UTC with exactly **3 fractional digits**, the same format as `_iso_now` in `lib/state.sh` (Nostromo rejects 6).
  `ts` must parse; `id` (and every job, lease, session, command and worker id) is 1..128 of `[A-Za-z0-9._:-]` with no `..`.
- **Limits** (`data.go`): ids 128; `hello.caps` 64 entries of at most 64; `hb.jobs` 256; `job.set` set/del 128 keys;
  `untracked_skipped` 1024; kinds/reasons 64; `refuse.msg`/`push_error` 512 bytes; `question`/`limiter_resume_prompt`
  8 KiB; object/array-valued job keys 64 KiB. All are refused as `invalid` (or `too_large`).
- `job`, `lease`, `epoch` are required on stream frames and on every command except `sync.file`. `seq` is required on stream frames only.
  `cmd.ack` carries the job/lease/epoch of the command it answers (see section 4).
- **Direction.** Each type has one sender. Worker: `hello`, `hb`, `cmd.ack`, `bye` and the stream frames. Coordinator: `welcome`,
  `refuse`, `ack`, `bye` and every command (`lease.offer`, `lease.revoke`, `cancel`, `hold`, `release`, `sync.job`, `sync.file`).
  A frame the sender may not send is `invalid` (`AllowedFromWorker`, `AllowedFromCoordinator`, `ValidateFrom`).
- Every command carries `cmd_id` in `data`.

## 4. Frame types

**Control**

| type | data |
|---|---|
| `hello` | see section 5 |
| `welcome` | `{proto, caps[], hb_interval_s, lease_ttl_s}` |
| `refuse` | `{code, retry_after_s?, msg?}`; `code` from section 10 |
| `hb` | `{jobs:[{job, lease, epoch, last_seq}]}`, worker to coordinator, every **10 s** |
| `ack` | `{job, lease, epoch, seq, resend_from?}`; `seq` is the coordinator's `applied_seq` |
| `bye` | `{reason}` |

**Worker to coordinator (per-job stream, seq-numbered)**

| type | data |
|---|---|
| `job.set` | `{set:{k:v}, del:[k]}`; subject to the ownership table (section 8) |
| `event.append` | `{line}`: one line of the job's events stream |
| `record.append` | `{stream, line}`; `stream` is one of: `metrics/runs.jsonl` (P1-2's inventory adds any others here, explicitly) |
| `log.append` | `{offset, b64}`: job log bytes at `offset` |
| `artifact.put` | `{path, offset, b64, final, sha256?}`; `path` is relative and confined to `crew/<job>/` or `checkpoints/<job>/` |
| `checkpoint.taken` | `{manifest}` (section 9) |
| `lease.release` | `{reason, final_sha?}` |

**Coordinator to worker (each carries `cmd_id`)**

| type | data |
|---|---|
| `lease.offer` | `{cmd_id, job_doc, plan, crew_bundle?, checkpoint?, repo, attempt}` |
| `lease.revoke` | `{cmd_id, reason}` |
| `cancel` | `{cmd_id}` |
| `hold` | `{cmd_id, code, reason}` |
| `release` | `{cmd_id}` (lift a hold) |
| `sync.job` | `{cmd_id, set:{k:v}}`; keys limited to the "flows down" list in section 8 |
| `sync.file` | `{cmd_id, path, content\|null}`; `null` deletes. Path allowlist: `limiter/mode.json`, `quota-gate.json`, `ratelimit-until` |

The worker replies to each command with `cmd.ack{cmd_id, outcome: applied|duplicate|rejected, why?, for?}`.

- `cmd.ack` has the envelope `job`/`lease`/`epoch` of the command and is fence-checked and worker-checked exactly like a stream
  frame: a stale worker cannot ack commands for a job it no longer holds (`fenced`, `not_leased`).
- **One exemption: `sync.file`.** It is not job-scoped, so its ack has null job/lease/epoch and is bound only to the authenticated
  connection. The exemption rests on what the coordinator recorded, not on the worker's `for` field: the coordinator calls
  `Admitter.Issued(frame)` for every command it sends, and `Admit` exempts an ack only when that `cmd_id` was issued as `sync.file`.
  A worker labelling an ack `for: "sync.file"` for any other `cmd_id` gets `invalid`.
- While a lease is `offered`, the only command that can be outstanding on it is `lease.offer` (the coordinator sends nothing else
  until the lease is active), so the first `cmd.ack{applied}` activates the lease. A `rejected` ack leaves it to lapse or be revoked.

## 5. Versioning and capabilities

`hello{proto_min, proto_max, caps[], worker_id, instance_id, kind, auth{method}}`.

- The coordinator picks the **highest common version**, or refuses with `version`. The coordinator's own range is the package
  constants `ProtoMin`/`ProtoMax` (1..1 in v1): never read from the peer or the environment. `Negotiate` takes them as parameters
  only so tests can model a newer coordinator.
- `welcome.caps` is the intersection of both sides' caps. A feature is used only when both sides list it.
- Capability flags in v1: `log.stream`, `artifact.chunked`, `checkpoint.v1`, `hold.boundary`, `os.darwin`, `os.linux`.
- An unknown frame type draws `refuse{code: unsupported}` for that frame, never a silent ignore.
- Additive **data** fields are allowed within v1; the envelope is closed (section 3). Removing or retyping a field is v2.

**Handshake extension contract (wss, Phase 2-3).** `hello.auth` is `{method, credential?, nonce?}`. A non-peercred method must:

1. carry a **per-worker credential** (never a shared secret) in `auth.credential` and a worker-chosen `auth.nonce`;
2. bind `hello.worker_id` to the **authenticated identity** the credential proves: the coordinator refuses `auth_failed` if they differ;
3. have the credential's proof (signature or MAC) cover `HelloTranscript(hello)`: protocol range, `worker_id`, `instance_id`, `kind`,
   `auth.method`, `auth.nonce` and the **sorted caps**. Caps are inside the transcript, so a carrier with no integrity of its own (plain
   ws, a TLS-terminating relay) cannot strip or add a capability without invalidating the proof (no downgrade). The coordinator signs
   `welcome` the same way over the negotiated caps, and the worker aborts if they are not the intersection it expects;
4. be checked before the version (as `peercred` is today); `auth_failed` is the refusal for a bad credential.

## 6. Streams, ordering, exactly-once (MC-18, MC-19)

- One stream per (job, lease). `seq` starts at 1 per lease and increases by 1.
- The worker keeps every sent frame in an unacked window until an `ack` covers it, and resends the window from the first
  unacked frame after a reconnect.
- The coordinator applies in order. A frame ahead of `applied_seq+1` is a **gap**: it is buffered and the next `ack` carries
  `resend_from = applied_seq+1`. A frame at or below `applied_seq` is a **duplicate** and is dropped (still acked). `seq <= 0` is `invalid`.
- **Bounds.** At most `MaxWindow = 1024` frames may be in flight: a frame beyond `applied_seq+1024`, or one that would push the
  buffered payload past `MaxBufferedBytes = 8 MiB` per stream, is refused `too_large` and nothing is recorded (verdict `TooFar`); the
  worker resends from `applied_seq+1`. A worker keeps its own unacked window under `MaxWindow` (`OutStream.Full`).
- **Order: apply, persist, ack.** For each frame judged `Apply` the coordinator (1) applies it, (2) persists `applied_seq`, (3) calls
  `Commit(seq)` and (4) sends the ack. `InStream.Accept` never advances `applied_seq` itself, so a frame is not reported applied before
  the caller confirms it; buffered frames that became contiguous are listed by `Ready()` and applied and committed the same way.
  A crash after apply but before persist leaves the persisted `applied_seq` one behind: `NewInStream(persisted)` judges the same frame
  `Apply` again, and the per-op idempotence below absorbs the replay. Buffered gap frames are lost on restart and returned by the worker's
  resend from `resend_from`. One frame at a time per stream: do not `Accept` again before the previous `Apply` is committed.
- Apply is idempotent per op type (B4):
  - `job.set` is a value set.
  - `event.append` and `record.append` are skipped if the identical line is already the tail of that job's stream. (The P1-2 file
    replay, `lib/coord_apply.sh`, does not use tail dedupe except in crash recovery: it is seq-idempotent, requires contiguous seq,
    applies a legitimately repeated identical line, and guards the apply-then-persist window with an inflight marker (the tail compare
    only runs when the marker names the very seq being retried) plus a stable usage-row id `<job>:<seq>`. A transient failure is never
    quarantined: it stops and retries, and is flagged `apply_stalled` after repeated stops. It also enforces section 8 and the `keyKinds` bounds itself, quarantines a structurally bad op instead of
    stalling on it, and never mirrors `runner/` files, progress, the worker log, or the canonical-side `decision.sh` keys
    `last_answer`, `resumed_at`, `escalation_count`: those are consciously not worker ops.)
  - `log.append` and `artifact.put` are offset-addressed: an overlapping or older offset is trimmed or dropped; a gap is refused.
- Commands are deduped by `cmd_id` on the worker (bounded set, persisted). A command for an offline worker is redelivered on
  reconnect, or dropped and applied by the coordinator directly when the job's lease moves.
- **Dedupe horizon.** `DedupeSet` forgets ids older than its horizon, the most recent **4096** (`DedupeHorizon`); an id forgotten and then
  redelivered would be applied twice. So the coordinator never redelivers a command once 4096 newer commands have been issued to that worker
  (`CmdOutbox.Redeliverable` / `Expire`: it drops the command and applies the effect itself when the lease moves), and a worker must treat a
  command it can no longer dedupe as undeliverable, never as new.

## 7. Leases (MC-12, MC-15, MC-16)

- States: `offered -> active -> released | lost | revoked`. `released` is the worker's `lease.release`, `revoked` the coordinator's `lease.revoke`.
- **TTL 180 s**; heartbeats every **10 s**.
- A lease is **lost** when there has been no heartbeat for TTL **and** the coordinator itself has been up for at least TTL since its
  last start (`coordUpSince`). Coordinator downtime therefore never expires a lease (MC-16), and after a restart every worker
  gets a full TTL to reconnect and heartbeat. An offer nobody accepts lapses the same way.
- **The lease table is persisted** (`LeaseTable.Snapshot` / `RestoreLeaseTable`): the highest epoch ever issued per job plus every live
  lease. Write the snapshot durably **before** the `lease.offer` carrying a new epoch leaves the coordinator, so a restart can never reissue
  an epoch. After a restore the next epoch for a job is previous + 1, a stale `(lease, epoch)` from before the restart is `fenced` (also for
  a job whose lease had already ended), and live leases keep their last heartbeat so `coordUpSince` gives their workers a full TTL to
  reconnect. A corrupt snapshot is refused rather than loaded.
- Heartbeats and releases are identity-checked: `AcceptFor`, `HeartbeatFor` and `ReleaseFor` take the authenticated worker. `LastHB` never
  moves backwards (a late heartbeat cannot shorten the TTL); callers pass times from one wall clock, since `Expire` compares them with its own `now`.
  Applying `lease.release` (after commit) ends the lease; admitting it does not.
- A requeued job gets a new lease with `epoch = previous + 1` (MC-15). Any frame whose (lease, epoch) is not the job's current
  **active** lease gets `refuse{code: fenced}` and an audit line.
- A fenced worker must stop the job at once and salvage-push to `refs/mother/wip-salvage/<job>/lease-<epoch>` (B8).
- A job with a live lease cannot be offered again (`busy`).

## 8. Ownership table (B10)

The coordinator is the sole writer of job JSON; a worker's `job.set` is a request that is checked field by field.

- **Worker-settable** (and deletable) within its lease: `activity`, `session_id`, `worker_pid`, `paused_reason`, `paused_at`, `question`,
  `final_result_at`, `started_at`, `continuation_count`, `resume_not_yet_acted_on`, `gates`, `review_wave`, `limiter_hold`, `live_cost_usd`,
  `live_tokens`, `current_run`, `cost_cap_breached_at`, `token_alert_at`, `rwx_sandbox`, `resume_session_id`, `resume_kind`,
  `limiter_resume_prompt`, `attention`, `decision`, `adherence_status`/`adherence_attempts`/`adherence_pending`/`adherence_notes`/`adherence_sha_runs`/`adherence_reviewed_sha` (the verdict of the pre-ready adherence review the wave runs under the supervisor: a token, counts, a bool, text of at most 8 KiB and a commit id), `attempt_run` (the supervisor-written `{key, started_at}` of the escalation/retry attempt; the clock the coordinator uses to judge a PR as created by this attempt). Each has a kind and bound: timestamps and tokens are short strings, `session_id` and
  `resume_session_id` are ids, `worker_pid`/`continuation_count`/`live_tokens` non-negative integers, `live_cost_usd` a non-negative number,
  `resume_not_yet_acted_on` a boolean, `gates`/`review_wave`/`limiter_hold`/`current_run`/`rwx_sandbox`/`decision`/`attempt_run` objects and `attention` an
  array (each at most 64 KiB), `question` and `limiter_resume_prompt` text of at most 8 KiB with no control characters other than newline and
  tab, and no C1 or bidirectional formatting controls (U+200E/F, U+202A-E, U+2066-9). `event.append`/`record.append` lines (arbitrary worker output)
get only the laxer C0-control check. `null` clears a key. A wrong kind or size is `invalid`.
- **Completion evidence is coordinator-derived, not worker-settable:** `pr_url`, `actual_branch`, `finished_at`, `exit_code`, `failure_reason`.
  A worker could claim any value, so `job.set` carrying one is refused `ownership`. The coordinator writes them itself, after its remote-commit
  check (P1-5), from the head the worker reports in `lease.release{final_sha}` and its own PR detection. (The alternative, accepting them only
  with a verified push proof, is not taken: it would need the same coordinator-side check, and then there is nothing for the worker to add.)
- **`state`**: judged against the job's current state (`CheckJobSet(JobState{State, CancelRequested}, ...)`). A worker may set `running`,
  `awaiting`, `failed` or `cancelled`; never delete it. **`succeeded` is refused outright** (the coordinator derives it after its remote-commit
  check, P1-5, and may then write it itself). Until P1-5 lands, a worker-mode job therefore stays `running` on the canonical side. No move out of `succeeded`, `failed` or `cancelled` (re-sending the same terminal state is an
  idempotent no-op), and no `running` once a cancel is requested or the job is `cancelled`.
- **`pending_answer`**: a worker may only set it to `null` (consume it). Setting any other value is a violation.
- **Flows down with `sync.job`** (coordinator-owned): `cancel_requested`, `pause_requested`, `pending_answer`, `max_cost_usd`, `force_start`.
- **Everything else is coordinator-owned**, including `repo_path`, `branch`, `base_ref`, `base_sha`, tiers and counters, adherence fields,
  cost totals and `crew`. Unknown keys are refused too, so a new job field is a deliberate edit to this table.

A violation is reported as `refuse{code: ownership}` for the frame (`invalid` for a wrong kind or size); the frame is not applied.
`Validate` applies the table itself (so a `job.set` that could never be accepted is refused at the door), and `Admit` additionally applies the
state transitions using the job's current state.

## 9. Checkpoints (B8, B9)

Manifest (`checkpoint.taken.data.manifest`; golden example `checkpoint_manifest.json`):

```
{v:1, job, lease, epoch, n, at, head_sha, branch, base_sha, wip_sha, wip_ref, pushed, push_error?, session_id,
 transcript:{path_rel, bytes, sha256, reset?, truncated?, subagents_skipped?}, untracked_skipped:[{path, bytes, reason}],
 untracked_skipped_truncated?}
```

Validation (`ValidateManifest`) runs on receipt and refuses, before any `WipRef(job)` or git command is built from a field:

- `job`/`lease`/`session_id`: ids (1..128 of `[A-Za-z0-9._:-]`, no `..`); `at`: a protocol timestamp;
- `head_sha`, `base_sha`, `wip_sha`: **40 or 64 lowercase hex**;
- `branch`: a conservative ref (1..200 of `[A-Za-z0-9._/-]`, starts alphanumeric, no `..`, `//`, `/.`, `@{`, trailing `/` or `.`, no `.lock` suffix),
  so it can never read as an option (`--upload-pack=x`) or climb a ref path (`refs/mother/wip/x/../..`);
- `transcript.path_rel`: confined to the job exactly like `artifact.put` (`ArtifactPathOK`: relative, clean, no `..`, no NUL);
- `untracked_skipped`: at most 1024 entries, each a relative clean path (no `..`, absolute, NUL or control character) with `bytes >= 0`;
- `untracked_skipped[].reason`: `too_large`, `embedded_repo` or `special_file` (empty in older manifests). `untracked_skipped_truncated: true` means
  more paths were skipped than are listed (the list is cut at 1024, and a path with a control character or backslash is never listed);
- `push_error`: at most **512 bytes**, no control characters. **The worker redacts it** (tokens, credentials, userinfo in remote URLs) before
  sending: the coordinator stores and shows it verbatim.
- `work_dir_at_capture` is **not on the wire** (it was in earlier drafts). It is the worker's own filesystem layout; keep it in worker-local state.

- **What a checkpoint captures (library behaviour, `lib/checkpoint.sh`).** The wip commit is one commit on top of `head_sha` whose tree is the
  working tree: tracked edits, staged changes, untracked files that are not ignored. Restore verifies that chain (`wip^ == head_sha`, one
  parent; otherwise `why: chain_mismatch`) and lays the tree over `head_sha` as **unstaged** changes. Not captured, by design:
  - a merge or rebase in progress is captured as plain working-tree content (conflict markers included); `MERGE_HEAD` and the rebase
    state directories are not captured, so a restored worktree is not "mid-merge";
  - the staged versus unstaged split is lost on restore (everything comes back unstaged);
  - files marked assume-unchanged / skip-worktree are not captured (git is told they did not change);
  - an unborn HEAD (no commit yet) cannot be checkpointed: `take` exits 1 with `{"why":"unborn_head"}`;
  - nested repositories and checked-out submodules: their dirty files and unpushed commits are **not** in the checkpoint and the entry is never
    recorded as a bare gitlink. They are listed in `untracked_skipped` with `reason: embedded_repo`, and `restore` reports `incomplete: true`;
  - symlinks are captured as links (never followed, sized as the link); untracked files over `MOTHER_CHECKPOINT_MAX_FILE_MB` (default 50) are
    listed as `too_large` and never hashed into the object store; `untracked_skipped` is cut at the 1024-entry wire cap and flagged with
    `untracked_skipped_truncated`;
  - the transcript is copied once per take and its bytes, sha256 and delta come from that copy; it is capped at
    `MOTHER_CHECKPOINT_MAX_TRANSCRIPT_MB` (256, `transcript.truncated`) and the subagent directory at `MOTHER_CHECKPOINT_MAX_SUBAGENT_MB`
    (64, `transcript.subagents_skipped`).
- **Fencing inputs.** `take` needs `MOTHER_LEASE_ID` and (unless `--salvage-epoch`) `MOTHER_LEASE_EPOCH`, checked before anything is pushed. The
  lease's expected remote value is `--expect-sha` / `MOTHER_CHECKPOINT_EXPECT_SHA`, else the last value this job dir pushed, else the work dir's
  `mother-wip-expect` marker (written by restore and by a successful take), else the remote's current value: a restored worker at a new path can
  checkpoint, a stale expected value still fences (exit 3). A take whose previous manifest says `pushed:false` re-pushes instead of skipping.
- **Hostile repositories.** Every git call runs with hooks, fsmonitor, signing, credential helpers and `filter.*`/`diff.*` drivers disabled, the
  global and system config ignored, `LC_ALL=C`, a deadline (`MOTHER_CHECKPOINT_TIMEOUT_S`, one for the whole take; local git included) and, on
  expiry, a kill of the whole process group.
- The wip ref is `refs/mother/wip/<job>`; the salvage ref is `refs/mother/wip-salvage/<job>/lease-<epoch>`.
  The salvage ref is in a different directory on purpose: git cannot hold `refs/mother/wip/<job>` and `refs/mother/wip/<job>/lease-<n>`
  together (a ref cannot be both a file and a directory; the second push is rejected with a refname conflict).
  `WipRef`/`SalvageRef` return `""` for a job id that is not a valid git ref component (`JobRefOK`: an id, no leading `.`, no trailing `.`
  or `.lock`), and `ValidateManifest` refuses such a job.
- **Per-checkpoint refs (round 2).** Each take pushes `refs/mother/wip-ckpt/<job>/<epoch>-<n>` (the same wip commit; force-pushed, since the name
  is unique to the lease and take number) in the SAME push as the rolling ref; git, not the refspec order, decides which is written first, so
  no ordering is relied on. A manifest says `pushed: true` only when both refs landed at `wip_sha`; if the remote refuses only the
  per-checkpoint ref the rolling ref still moved (committed work is safe, the lease's expectation advances) and the manifest says
  `pushed:false, push_error:"checkpoint ref refused"` (never "fenced": that needs the ROLLING ref refused and moved). The manifest travels
  the async outbox, so the rolling ref is routinely ahead of the newest manifest the coordinator holds, and a worker that dies in between must not fail the job. The runner
  restores from the immutable ref its own `latest.json` names (epoch and n are vetted: the frame's epoch is the coordinator's lease epoch
  and `coord_apply.sh` checks it against `runner/leases/<job>.history.jsonl`), accepts the rolling ref only when it equals `wip_sha`, and
  refuses any other sha. `wip-ckpt` is a separate directory for the same D/F reason as `wip-salvage`. The newest
  `MOTHER_CHECKPOINT_KEEP_REFS` (20) of the CURRENT epoch are kept (older ones deleted in the same push, best effort). Earlier epochs: once
  per epoch, after one successful bounded `ls-remote` (a failed one is retried on the next take), a take deletes every earlier-epoch
  `wip-ckpt` ref except the restore point the lease was restored from (`<checkpoints>/.restore-point`, "<epoch>-<n>"). So at most ONE
  earlier-epoch ref remains in total (the newest restore point), and with no well-formed restore point on record nothing earlier is
  deleted (unbounded in that case). The `n-20` delete of the current epoch happens once, in that take's push, so a take that fails
  before its push leaves its `n-20` ref behind (the bound is 20 plus a few, not strict). The delete never removes the newest pushed
  checkpoint of the epoch (`<checkpoints>/.last-ckpt-ref`) nor the ref named by `.restore-point`, so a remote that keeps refusing
  `wip-ckpt/*` for more than 20 takes cannot delete the coordinator's only restore point. A push that timed out (exit 137) may still
  have been applied: the take records `<checkpoints>/.push-pending` (the wip sha) and the NEXT take reads the rolling ref with a
  bounded `ls-remote` before judging fencing; a ref equal to the pending sha is recorded as the lease's expectation (not fenced), any
  other value leaves the expectation alone (still fenced if another writer moved the ref). Salvage refs are never pruned. A coordinator that is more than 20
  checkpoints behind its worker falls back to the rolling ref (which then must equal `wip_sha`) or fails `no_checkpoint_restorable`.
- Follow-up (not built): delete `refs/mother/wip/<job>`, `refs/mother/wip-ckpt/<job>/*` and `refs/mother/wip-salvage/<job>/*` when the job is archived.
- **Interval 120 s** (refused above **240 s**), **final-on-exit timeout 30 s**, **per-checkpoint watchdog 60 s**.
- **MC-14 mapping:** worst-case loss = interval + watchdog = 120 + 60 = **180 s**, under the 300 s bound (at the 240 s maximum it
  is 300 s, which is why the maximum is not raised).
- Every exit path checkpoints first (final-on-exit, bounded by the 30 s timeout):
  1. finished (succeeded);
  2. failed;
  3. cancelled;
  4. awaiting: a user question, or the cost cap;
  5. paused: quota, or a limiter hold;
  6. lease lost: push the salvage ref;
  7. SIGTERM.

## 10. Error codes

| code | meaning |
|---|---|
| `version` | no common protocol version |
| `auth_unsupported` | `auth.method` not supported (anything but `peercred` in Phase 1) |
| `auth_failed` | credentials rejected |
| `fenced` | (lease, epoch) is not the job's current active lease |
| `unknown_job` | no lease has ever existed for the job |
| `not_leased` | the job is not leased to this worker |
| `gap` | an offset-addressed write left a hole |
| `too_large` | frame over 1 MiB, or a chunk over 256 KiB raw |
| `invalid` | malformed envelope or data |
| `unsupported` | unknown frame type |
| `ownership` | `job.set` or `sync.job` touched a key the sender does not own |
| `busy` | the job already has a live lease |

## 11. Phase 2-3 notes (non-normative)

- **wss carrier:** the same frames as WebSocket text messages (section 2). Reconnect-and-resume is the stream's unacked window plus
  `resend_from`; nothing else is needed.
- **Relay rendezvous:** coordinator and workers both dial out to a relay and are matched there; no inbound port on the laptop.
- **Credentials:** carried in `hello.auth` (method, token or signature) with mutual auth (MC-25, MC-26); `auth_failed` is the refusal.
- **Artifacts over HTTPS:** when `artifact.put` frames are too slow for a large transcript or bundle, the worker uploads over HTTPS and
  sends a final `artifact.put` with `sha256` as the receipt.
- **Repo clone map:** the `lease.offer.repo` field names the repo; each worker maps it to a clone location it controls.

## 12. Admission order (what `Admit` does)

For each line from an authenticated worker connection, `Admitter.Admit(worker, line, now)`:

1. `Decode`: size, UTF-8, strict keys, `v` (`version`), known `t`.
2. `ValidateFrom(FromWorker, f)`: direction, id/ts shapes, per-type data, limits, the `job.set` ownership table (section 8).
3. `hello`: `worker_id` must equal the authenticated worker (`auth_failed`). `hb`: each entry is `HeartbeatFor`; rejected entries are reported
   (`fenced`, `not_leased`, `unknown_job`) without refusing the others.
4. `cmd.ack`: worker and lease check (the `sync.file` exemption, section 4); the first applied ack on an offered lease activates it.
5. Stream frames: fence plus worker identity (`CheckFenceFor`), the `job.set` state transition against the job's current state, then
   `InStream.Accept` (`Apply`, `Duplicate`, `Gap`; `TooFar` is `too_large`).

After an `Apply` the caller applies the frame, persists `applied_seq`, calls `Admitter.Commit(worker, frame)` (which ends the lease for an applied
`lease.release`) and sends `AckFor`. Frames are ordered by the one caller per connection; the package has no locks, clocks or goroutines (a test
walks the AST to enforce it: no `os`, `net`, `os/exec`, `os/signal`, `io/fs`, `log`, randomness or `sync` imports, no `go` statements, no `time.Now`,
`Since`, `Until`, `Sleep`, `After`, `Tick`, `NewTimer`, `AfterFunc`, aliased imports included).

## 13. Changes from the first draft

The review of PR #116 tightened v1 before any caller exists. Golden fixtures were re-recorded for two of them: `checkpoint_manifest.json` loses
`work_dir_at_capture` and its transcript path moves under `checkpoints/<job>/`, and the two `cmd.ack` lines in `command_dedupe.ndjson` gain the
`job`/`lease`/`epoch` envelope. All other frames round-trip byte for byte unchanged.

## 14. Phase 1 local carrier: additions made by `mother-coord` / `mother-worker` (P1-4)

Everything here is additive inside `data` (section 5: additive data fields are allowed within v1) or lives outside the frames.

- `hello.data.slots` (int, default 1): jobs the worker runs at once. The coordinator never offers a lease past `slots`.
- `welcome.data.jobs[{job, lease, epoch, applied_seq, wire_seq, log_offset}]`: for each live lease of the connecting worker, the coordinator's
  committed position. `applied_seq` is the last **outbox op** applied (`coord_apply.sh`'s own persisted seq), `wire_seq` the last stream seq
  committed, `log_offset` the size of the canonical job log. On every connection the worker **rebases** each stream to this position: it re-reads
  its outbox from `applied_seq + 1` and its log from `log_offset` and numbers new frames from `wire_seq + 1`, and the coordinator discards anything it
  buffered from the previous connection. Nothing depends on the worker remembering its unacked window across a restart, and a crash between apply and
  persist is absorbed by `coord_apply`'s seq idempotence.
- Op frames (`job.set`, `event.append`, `record.append`, `artifact.put`) carry `oseq` (the op's seq in the worker's outbox file) in `data`; the coordinator
  hands it to `coord_apply.sh` as the op's `seq`. Log chunks and `lease.release` have no outbox seq, which is why the wire seq and the outbox seq are not the same number.
  `oskip: [from, to]` on an op names outbox ops consumed without being sent (a `job.set` whose every key the ownership table refuses: the supervisor writes
  `finished_at`, `exit_code`, `state: succeeded` into its own mirror, but the wire refuses them, so the worker strips them); the coordinator fills the range
  with empty `job.set` ops, which `coord_apply` accepts as no-ops, to keep its seq contiguous. At most 4096 per frame.
- `lease.offer.data.repo_path`: the repo's path on the coordinator's machine; `repo` is `owner/name` from its origin URL.
- A heartbeat naming a lease still `offered` to that worker is ignored, not refused: the offer ack that activates it may still be in flight (or the offer is being redelivered after a coordinator restart).
- `sync.job` carries only the keys in both the plan's list and `SyncDownKeys`: `cancel_requested`, `pause_requested`, `max_cost_usd`, `force_start`.
  (`paused_reason` and `auto_resume_at` are not in the shared table, and `paused_reason` is worker-owned, so they stay on the worker side.)
- Files: `runner/dispatch/<job>.json` (request, gains `wait_reason`), `runner/leases/<job>.json`, `<job>.cmds.jsonl` (unacked commands), `<job>.lost`,
  `table.json` (the durable lease table snapshot, written before each offer leaves), `audit.jsonl`, `runner/coord/coord.pid`, `runner/coord-status.json`.
  Worker root: `leases/<job>.json`, `children/<pid>.json`, `applied-cmds.json`, `worker.pid` (`<pid> <pgid>`).
- Release rule: a worker sends `lease.release` only after its supervisor exited, the outbox and log are fully acked, and the mirror's state is terminal or
  `awaiting` (reason = that state, or `supervisor_exited` for a supervisor found dead at start). A supervisor that died with the job still `running` is not
  released and no longer heartbeated, so the coordinator's TTL decides. The wire (and hence P1-5) still refuses `succeeded` from a worker.
- Known gap for P1-6: a job re-leased to a worker that has no outbox for it restarts its outbox seq at 1 while the coordinator's `applied_seq` is higher; a resume
  onto a different worker needs the outbox seeded from the coordinator's `applied_seq`.

## 15. Failover and resume (P1-6)

- **Cadence.** The worker daemon runs `mother checkpoint take <job> --ship` for each live lease every
  `mother checkpoint interval` seconds (not while the mirror says `awaiting` or terminal). `--ship` puts the take into the job's
  ordered outbox: `artifact.put` for `checkpoints/<job>/<n>/transcript.delta` and `manifest.json`, then `checkpoint.taken{manifest}`.
  The coordinator applies it (`lib/coord_apply.sh`): the delta is appended to `checkpoints/<job>/transcript/<session>.jsonl`
  (replaced when `reset` or when the delta is the whole file), verified against the manifest's sha256, every manifest is appended to
  `checkpoints/<job>/index.jsonl` (de-duplicated by epoch, n and wip_sha), and `latest.json` advances only for a checkpoint that is
  `pushed:true` with a verified transcript and is newer in `(epoch, n)` order: a failover starts a new epoch whose worker continues
  numbering from the manifest it was offered, but even a worker that restarts at 1 outranks every earlier epoch. The epoch must be
  one in the coordinator's lease history for the job (`runner/leases/<job>.history.jsonl`, written at offer time; bounded: past 256
  lines it is cut to the newest 128; a repeated epoch resolves to its latest grant).
  The supervisor takes the same checkpoint at phase boundaries and before every exit or awaiting/terminal state write
  (`_ckpt_final`); takes serialise on the checkpoint lock and number themselves under it.
- **`salvage` control frame** (worker to coordinator, not seq-numbered, envelope job/lease/epoch of the fenced lease):
  `{ref, wip_sha}` with `ref` = `refs/mother/wip-salvage/<job>/lease-<epoch>` exactly. A fenced worker's stream is refused, so the
  report cannot ride it. The coordinator accepts it only for a lease that is superseded or no longer live, records it in
  `runner/leases/audit.jsonl` (`code: salvage`) and as `runner/leases/<job>.salvage.<epoch>.json`; the runner turns that into the
  job event `worker_salvaged`. Salvage never touches `refs/mother/wip/<job>` or the job's canonical state.
- **Graceful stop.** SIGTERM to the worker daemon sends SIGTERM to each supervisor (the pid, not the group). A supervisor stops its
  claude, takes its final checkpoint (bounded by `MOTHER_CHECKPOINT_FINAL_TIMEOUT_S`), and exits with the job still `running`; the
  daemon keeps shipping until the outboxes drain (or the coordinator has been unreachable for 5 s), releases the lease
  (`lease.release{reason: worker_stopping}`) and exits with no child left.
- **Resume.** A `running` job whose lease is `lost`, or `released` without success while the job is still `running`, gets
  `worker_lost {worker, lease_epoch, last_heartbeat_at, reason}`. If `checkpoints/<job>/latest.json` exists and its wip ref is on the
  remote the runner sets the job `ready` (`reason: worker_lost_resume`) and the next dispatch request carries
  `resume_from {manifest, transcript, from_worker, lost_work_s, ...}`; the lease offer's `checkpoint` field passes it to the worker,
  which stages it under `<root>/resume/<job>/e<epoch>/`. Otherwise `failed no_checkpoint_restorable` (a held class, never a fresh
  start). After `MOTHER_WORKER_RESUME_MAX` resumes: `worker_resume_exhausted`.
- **A restarted worker** that still holds an active lease whose supervisor is gone fences it (salvage under that lease's own epoch)
  when the coordinator offers the job again.
- **Trust limit of resuming at all.** A hostile worker authors the transcript the next session resumes (`--resume`), so a failover
  inherits any prompt injection already present in that transcript. This is inherent to continuing a session and is not filtered. The
  mitigation is that nothing the resumed session can do exceeds what the first one could: same job, same branch, same worktree class,
  same permissions, and no new credentials; the coordinator still derives success itself.
- Limitations: the checkpoint paths in `resume_from` are coordinator-side paths (local carrier only); the subagent transcript
  directory is not shipped; a main-dir job cannot be resumed (it fails `no_checkpoint_restorable`, `why: main_dir_job`).
