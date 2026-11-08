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

- Phase 1: a Unix socket at `$MOTHER_ROOT/runner/worker.sock`, mode 0600.
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
  `limiter_resume_prompt`, `attention`, `decision`. Each has a kind and bound: timestamps and tokens are short strings, `session_id` and
  `resume_session_id` are ids, `worker_pid`/`continuation_count`/`live_tokens` non-negative integers, `live_cost_usd` a non-negative number,
  `resume_not_yet_acted_on` a boolean, `gates`/`review_wave`/`limiter_hold`/`current_run`/`rwx_sandbox`/`decision` objects and `attention` an
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
- Follow-up (not built): delete `refs/mother/wip/<job>` and `refs/mother/wip-salvage/<job>/*` when the job is archived.
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
