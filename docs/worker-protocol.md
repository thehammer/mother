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

## 2. Transport and framing

- Phase 1: a Unix socket at `$MOTHER_ROOT/runner/worker.sock`, mode 0600.
- NDJSON: one UTF-8 JSON object per line, at most **1 MiB including the newline** (1 048 576 bytes). Encoders emit no
  embedded newlines (`encoding/json` never does); a decoder rejects a line containing one. An oversized frame is `too_large`.
- Larger payloads are chunked: `artifact.put` and `log.append` carry at most **256 KiB of raw bytes** per frame, base64.
- A frame maps 1:1 to a WebSocket text message for the Phase 3 wss carrier, through a relay that both sides dial out to.
  Kobe is behind NAT and often asleep, and the laptop is never exposed to inbound internet traffic.

## 3. Envelope v1

```json
{"v":1,"t":"<type>","id":"<uuid>","ts":"<ISO-8601 ms Z>","job":"<id>|null","lease":"<lease id>|null","epoch":<int>|null,"seq":<int>|null,"ack":<int>|null,"data":{}}
```

- Key order is fixed (as above) so that decode then encode is byte-identical; `data` is kept as raw JSON.
- `ts` is UTC with exactly **3 fractional digits**, the same format as `_iso_now` in `lib/state.sh` (Nostromo rejects 6).
- `job`, `lease`, `epoch` are required on stream frames and on every command except `sync.file`. `seq` is required on stream frames only.
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

The worker replies to each command with `cmd.ack{cmd_id, outcome: applied|duplicate|rejected, why?}`.

## 5. Versioning and capabilities

`hello{proto_min, proto_max, caps[], worker_id, instance_id, kind, auth{method}}`.

- The coordinator picks the **highest common version**, or refuses with `version`.
- `welcome.caps` is the intersection of both sides' caps. A feature is used only when both sides list it.
- Capability flags in v1: `log.stream`, `artifact.chunked`, `checkpoint.v1`, `hold.boundary`, `os.darwin`, `os.linux`.
- An unknown frame type draws `refuse{code: unsupported}` for that frame, never a silent ignore.
- Additive envelope and data fields are allowed within v1. Removing or retyping a field is v2.

## 6. Streams, ordering, exactly-once (MC-18, MC-19)

- One stream per (job, lease). `seq` starts at 1 per lease and increases by 1.
- The worker keeps every sent frame in an unacked window until an `ack` covers it, and resends the window from the first
  unacked frame after a reconnect.
- The coordinator applies in order. A frame ahead of `applied_seq+1` is a **gap**: it is buffered and the next `ack` carries
  `resend_from = applied_seq+1`. A frame at or below `applied_seq` is a **duplicate** and is dropped (still acked).
  The coordinator persists `applied_seq` after each applied batch.
- Apply is idempotent per op type (B4):
  - `job.set` is a value set.
  - `event.append` and `record.append` are skipped if the identical line is already the tail of that job's stream.
  - `log.append` and `artifact.put` are offset-addressed: an overlapping or older offset is trimmed or dropped; a gap is refused.
- Commands are deduped by `cmd_id` on the worker (bounded set, persisted). A command for an offline worker is redelivered on
  reconnect, or dropped and applied by the coordinator directly when the job's lease moves.

## 7. Leases (MC-12, MC-15, MC-16)

- States: `offered -> active -> released | lost | revoked`. `released` is the worker's `lease.release`, `revoked` the coordinator's `lease.revoke`.
- **TTL 180 s**; heartbeats every **10 s**.
- A lease is **lost** when there has been no heartbeat for TTL **and** the coordinator itself has been up for at least TTL since its
  last start (`coordUpSince`). Coordinator downtime therefore never expires a lease (MC-16), and after a restart every worker
  gets a full TTL to reconnect and heartbeat. An offer nobody accepts lapses the same way.
- A requeued job gets a new lease with `epoch = previous + 1` (MC-15). Any frame whose (lease, epoch) is not the job's current
  **active** lease gets `refuse{code: fenced}` and an audit line.
- A fenced worker must stop the job at once and salvage-push to `refs/mother/wip/<job>/lease-<epoch>` (B8).
- A job with a live lease cannot be offered again (`busy`).

## 8. Ownership table (B10)

The coordinator is the sole writer of job JSON; a worker's `job.set` is a request that is checked field by field.

- **Worker-settable** (and deletable) within its lease: `activity`, `session_id`, `worker_pid`, `pr_url`, `actual_branch`, `paused_reason`,
  `paused_at`, `question`, `final_result_at`, `finished_at`, `started_at`, `continuation_count`, `resume_not_yet_acted_on`, `gates`,
  `review_wave`, `limiter_hold`, `live_cost_usd`, `live_tokens`, `current_run`, `cost_cap_breached_at`, `token_alert_at`, `failure_reason`,
  `exit_code`, `rwx_sandbox`, `resume_session_id`, `resume_kind`, `limiter_resume_prompt`, `attention`, `decision`.
- **`state`**: settable only within the lease, to `running`, `awaiting`, `succeeded`, `failed` or `cancelled`; never deleted.
  `succeeded` is accepted only after the coordinator's remote-commit check, which lands in P1-5.
- **`pending_answer`**: a worker may only set it to `null` (consume it). Setting any other value is a violation.
- **Flows down with `sync.job`** (coordinator-owned): `cancel_requested`, `pause_requested`, `pending_answer`, `max_cost_usd`, `force_start`.
- **Everything else is coordinator-owned**, including `repo_path`, `branch`, `base_ref`, `base_sha`, tiers and counters, adherence fields,
  cost totals and `crew`. Unknown keys are refused too, so a new job field is a deliberate edit to this table.

A violation is reported as `refuse{code: ownership}` for the frame; the frame is not applied.

## 9. Checkpoints (B8, B9)

Manifest (`checkpoint.taken.data.manifest`; golden example `checkpoint_manifest.json`):

```
{v:1, job, lease, epoch, n, at, head_sha, branch, base_sha, wip_sha, wip_ref, pushed, push_error?, session_id,
 transcript:{path_rel, bytes, sha256}, untracked_skipped:[{path, bytes}], work_dir_at_capture}
```

- The wip ref is `refs/mother/wip/<job>`; the salvage ref is `refs/mother/wip/<job>/lease-<epoch>`.
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
