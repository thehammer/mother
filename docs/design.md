# Mother — Design Doc

Background-execution system for Claude Code sessions. Plans are co-authored in the
interactive session, dispatched to a local runner, and tracked via events that surface
naturally in subsequent conversations.

## Goals

- Plans become background implementation work without leaving the interactive session.
- No slash commands on the user's side. Dispatch happens via Bash tool calls from Claude.
- Background sessions run locally — tmux + worktrees + `claude --agent mother:cody`.
- In-session awareness of queue state (completions, failures, PR URLs) surfaces via
  prompt-injection, not polling.
- Architecture is executor-agnostic so a cloud executor can slot in later without
  refactoring the CLI, skill, hook, or statusline.

## Non-goals

- No persistent web UI, dashboard, or TUI. Everything is CLI + statusline + OS notifications.
- No SQLite or other embedded DB. Plain JSON / JSONL files under `${MOTHER_ROOT}` (default
  `$HOME/.mother/`).
- No distributed coordination. Single-user, single-machine. Cloud is additive, not a
  replacement.
- No automatic plan generation without review — Archie produces the plan; the active
  session *must* walk through it with the user and iterate before dispatch.

## Primary user flow

1. The user and the interactive Claude session converge in conversation on a problem and
   a direction.
2. Claude proactively proposes queueing the implementation.
3. On user agreement, Claude invokes the **archie** agent with a brief. Archie returns
   a self-contained plan markdown.
4. Claude presents the plan to the user **inline in the conversation** for review.
5. User iterates. Feedback can be stylistic ("split this into two jobs"), technical
   ("use the existing helper instead"), or scoping ("pare this down"). Claude either
   edits the plan directly or re-invokes Archie with the feedback.
6. When the user approves, Claude calls `mother add` with the plan.
7. The runner picks up the job — worktree, tmux window, cody session — and begins.
8. Claude continues the conversation normally. The user can start another plan, ask
   status ("what's running?"), or change topics.
9. When the job reaches a terminal state, the next `UserPromptSubmit` hook injection
   surfaces it. Claude mentions it at the top of its next reply: "TICKET-NNNN finished,
   PR #N opened."
10. Out-of-session completions (laptop idle, no active session) go to Slack DM.

## Components

### 1. `mother` CLI — `$MOTHER_BIN_DIR/mother`

Single-file bash script, the only public interface. All state mutations and reads flow
through it. Output is JSON by default (`--format=table` for humans).

**Subcommands:**

| Subcommand | Purpose |
|---|---|
| `mother add --repo X --branch B --isolation worktree\|main-dir --plan-file P [--max-cost N] [--depends-on ID]` | Create a new job in `queued` state. Returns the job id. |
| `mother list [--state ...] [--repo X]` | List jobs. Default shows active (non-terminal). |
| `mother status <id>` | Full job record + recent events. |
| `mother logs <id> [--follow]` | Stream the captured stdout/stderr. |
| `mother peek <id>` | Live transcript snapshot of a running job. |
| `mother cancel <id>` | Request cancellation. Runner kills the tmux window on next tick. |
| `mother retry <id>` | Clone a failed job into a new queued job. |
| `mother events --since-cursor <session-id>` | Returns events newer than that session's last-seen cursor, then advances the cursor. Used by the hook. |
| `mother drafts list\|show\|rm` | Manage pre-approval plan drafts. |

**Implementation notes:**

- State lives at `${MOTHER_ROOT:-$HOME/.mother}/` (see File Layout).
- Atomic mutations: write to `<id>.json.tmp` and rename.
- Only the runner mutates existing job files. The CLI *creates* new job files (no
  contention) and appends events via `flock`.
- Every subcommand writes a structured event to `events/<id>.jsonl`.

### 2. `mother-runner` daemon — `$MOTHER_BIN_DIR/mother-runner`

Single process, launchd-managed on macOS (`mother daemon install` drops the plist
into `~/Library/LaunchAgents/`).

**Responsibilities:**

- Watch `${MOTHER_ROOT}/jobs/` for new `queued` jobs.
- Promote `queued` → `ready` when dependencies are satisfied.
- Schedule `ready` jobs when a slot is available:
  - Global concurrency cap (default 2, configurable via `MOTHER_CONCURRENCY`).
  - Worktree jobs run in parallel up to the cap.
  - Main-dir jobs for a given repo serialize via `locks.sh` (`<repo>:workspace`).
- Spawn executor:
  - **local-tmux** (v1): call `worktree_create` if isolation is worktree, open a new
    tmux window at the target path, run `claude --agent mother:cody -p < "$PLAN_FILE"` with
    `--max-cost` and `--output-format stream-json`, tee output to `logs/<id>.log`.
  - Parse the stream for known signals (PR URL created, cost updates, errors) and emit
    corresponding events.
- Emit events on every transition: `queued`, `ready`, `started`, `pr_opened`,
  `cost_update`, `cancelled`, `succeeded`, `failed`.
- Enforce `max_cost_usd`: if exceeded, cancel the job and mark it failed with a
  `cost_exceeded` reason.
- Crash recovery: on startup, scan `running` jobs; if their tmux window is gone, mark
  them `failed` with reason `runner_died`.

**Dispatch pseudocode:**

```
loop:
    promote queued → ready where depends_on satisfied
    for each ready job, oldest first:
        if slots_available and can_acquire_lock(job):
            spawn_executor(job)
            mark job as running
    poll running jobs for completion signals
    sleep 2s
```

### 3. `archie` agent

Planning specialist. Takes a brief from the main session and produces a self-contained
implementation plan markdown. Output format is standardized so the runner's cody
session knows exactly what to expect.

**Output shape** (enforced by the agent's system prompt):

```markdown
# <Job title — imperative>

## Context
<Why this work matters, what problem it solves, linked ticket if any>

## Target
- Repo: <name>
- Branch: <fix/TICKET-NNNN-slug>
- Base: <main | master | specific ref>

## Files to change
- `path/to/file.ext:NNN` — <what to change and why>
- `path/to/test` — <new test to add>

## Approach
<Step-by-step sequence. No vague steps.>

## Acceptance criteria
- <Specific, checkable>
- <Cody verifies these before opening the PR>

## Out of scope
<What cody should NOT do, even if tempted>
```

**Why an agent, not inline generation:** plan quality is the single biggest determinant
of background-session success. Isolating plan generation keeps the main session's
context lean and lets Archie specialize. Archie is also where we enforce "self-
contained" discipline — no implicit references to the user's local env.

### 4. `mother` skill

Skill definition so every session sees it in the system reminder. The user is not
expected to type `/mother`; the purpose is discoverability — Claude reaches for the
Skill / Bash tool naturally when a conversation hits a relevant trigger.

**Description** (what appears to Claude in every session's skills list):

> Dispatch and monitor background implementation work via Mother. Use when the user
> agrees on a plan to ship, asks "what's running?", wants to cancel or retry a job,
> or asks about PRs Mother has opened. Plans must be self-contained; call the
> `archie` agent first to produce one from a conversation before enqueueing.

### 5. `UserPromptSubmit` hook

The mechanism by which background work becomes visible in the interactive session.

Before each of the user's messages reaches Claude, this hook runs. It:

1. Resolves a stable session-id (tmux pane name or Claude's session id — TBD).
2. Calls `mother events --since-cursor <session-id>` to fetch unseen events.
3. If non-empty, emits a `<system-reminder>` with the events as a structured block.
4. The CLI advances the cursor as part of returning the events.

Result: Claude sees the delta in its system reminders, and naturally opens its reply
with an acknowledgement ("Heads up — that job finished, PR #N opened. Anyway…").

**Event injection format:**

```
<system-reminder>
Mother updates since your last message:
- [succeeded] job 01J5... (TICKET-NNNN fix) — PR opened: https://github.com/<org>/<repo>/pull/N
- [started]  job 01J6... (TICKET-NNNM refactor)
</system-reminder>
```

### 6. Statusline segment

Opt-in segment shipped at `statusline/segment.sh`. Source it from your statusline
script and call `mother_segment` where you want the counts to render. Same
file-cache + background refresh pattern — no direct CLI calls in the statusline hot path.

**Format:**

```
Q ▶2 ⏸5
```

- `▶2` — 2 running (yellow)
- `⏸5` — 5 queued / ready (blue)
- Trailing `!3` in red if there are unseen failures (cleared when Claude mentions them
  via the hook).
- Segment hidden entirely when counts are all zero.

**Cache:** `/tmp/.mother-statusline` written by `mother_statusline_refresh` in the
background. Refresh TTL: 10s.

### 7. User's PREFERENCES (optional)

Recommended block under Workflow Preferences in the user's personal prompt:

> **Queueing background work with Mother.** When the user and I converge on a plan
> that is self-contained and CI-verifiable (small bug fixes, guard additions,
> workflow tweaks, targeted refactors), proactively offer to queue it rather than
> implementing inline.
>
> **Flow:** Invoke the `mother:archie` agent to produce a plan. Present it inline for
> review. Iterate with the user until approved. Then call `mother add`. Do NOT
> enqueue without explicit user approval of the plan.
>
> **Keep interactive for:** planning, review, code that needs local fixtures/
> Docker/browser verification, and anything where the plan is still fluid.

## File layout

```
${MOTHER_ROOT}/  (default: $HOME/.mother/)
├── jobs/<id>.json              # current state of each job
├── events/<id>.jsonl           # append-only event log per job
├── logs/<id>.log               # captured stdout/stderr
├── drafts/<draft-id>.md        # plans under review, pre-approval
├── cursors/<session-id>.json   # hook's last-seen-event markers
├── runner/
│   ├── runner.pid
│   └── slots.json
└── archive/<yyyy-mm>/          # jobs older than 30 days in terminal states
```

All kept out of any project repo — `${MOTHER_ROOT}` is user state, not source.

## Data model

```jsonc
// jobs/<id>.json
{
  "id": "01J5XYZ...",
  "repo": "<repo-name>",
  "repo_path": "/Users/<you>/Code/<repo-name>",
  "branch": "fix/TICKET-NNNN-slug",
  "base_ref": "origin/main",
  "isolation": "worktree",          // worktree | main-dir
  "executor": "local-tmux",         // future: cloud-routine
  "depends_on": [],
  "max_cost_usd": 5.00,
  "plan_path": "events/01J5XYZ...-plan.md",  // snapshot copy, immutable
  "state": "queued",                // queued | ready | running | succeeded | failed | cancelled
  "created_at": "2026-04-22T17:32:14Z",
  "started_at": null,
  "finished_at": null,
  "pr_url": null,
  "tmux_window": null,
  "log_path": "logs/01J5XYZ....log",
  "actual_cost_usd": null
}
```

Events append one JSON object per line:

```jsonc
// events/<id>.jsonl
{"ts":"2026-04-22T17:32:14Z","kind":"queued","detail":{}}
{"ts":"2026-04-22T17:32:16Z","kind":"ready","detail":{}}
{"ts":"2026-04-22T17:32:17Z","kind":"started","detail":{"tmux_window":"hammer:3"}}
{"ts":"2026-04-22T17:34:22Z","kind":"pr_opened","detail":{"url":"https://github.com/<org>/<repo>/pull/N"}}
{"ts":"2026-04-22T17:34:30Z","kind":"succeeded","detail":{"cost_usd":0.42}}
```

## Phased build

Each phase is independently useful.

**Phase 1 — CLI + one-shot runner (no daemon)**
- Build `mother` CLI with `add`, `list`, `status`, `logs`, `cancel`.
- Build `mother run --once` — processes one ready job in the foreground (blocking).
- Build `archie` agent and `mother` skill.
- Add a Mother block to the user's PREFERENCES.
- **Outcome:** you and I can converge on a plan, invoke Archie, review, enqueue,
  and run. Main session is blocked while the job runs. Not truly background yet,
  but the full review-and-dispatch loop works end to end.

**Phase 2 — Daemon + hook**
- Build `mother-runner` daemon and launchd plist.
- Build `UserPromptSubmit` hook.
- Wire settings.json manually (human step).
- **Outcome:** jobs run in the background while you keep working interactively;
  completions surface via hook injection in the next message.

**Phase 3 — Statusline + Slack + polish**
- Ship `statusline/segment.sh` and document how to source it.
- Add Slack notifications for out-of-session completions/failures.
- Retention / archive logic.
- **Outcome:** passive and out-of-session awareness.

**Phase 4 — Cloud executor** (deferred)
- Add `executor: cloud-routine` handler that dispatches via the `schedule` skill.
- Same event stream, same CLI, same hook. Executor swap only.

## Acceptance criteria per phase

**Phase 1**
- [ ] `mother add --plan-file <path> --repo <repo> --branch fix/xxx --isolation worktree` creates a job and returns its id.
- [ ] `mother run --once` picks the oldest ready job, spawns cody in a new tmux window inside a worktree, captures logs, and updates job state on completion.
- [ ] `archie` agent produces plan docs in the standard format.
- [ ] The `mother` skill appears in every session's skills list.
- [ ] Claude, in a clean session, proactively offers to queue a self-contained plan when the user agrees to ship it.
- [ ] End-to-end smoke: you describe a bug, we plan, Archie drafts, you and I iterate, you approve, I enqueue, it runs, a PR is opened.

**Phase 2**
- [ ] `launchctl load` starts the daemon; it survives a laptop restart.
- [ ] Jobs run in parallel up to the concurrency cap; main-dir jobs serialize via `locks.sh`.
- [ ] `UserPromptSubmit` hook injects queue deltas into each new user message.
- [ ] Claude mentions completions and failures at the top of its reply when the hook surfaces them.
- [ ] Killing the daemon mid-job leaves the job as `failed` with `runner_died` on restart.

**Phase 3**
- [ ] Statusline shows `Q ▶N ⏸M` with correct counts and colors.
- [ ] Statusline hides the segment when counts are zero.
- [ ] Slack DM fires for completions/failures when no Claude session has consumed the event within N minutes.
- [ ] Archived jobs older than 30 days move to `archive/yyyy-mm/` and logs are gzipped.

## Open questions

1. **Session id for cursors.** The hook needs a stable per-session key. Options: tmux
   pane number (breaks if the pane moves), Claude's session uuid (need to confirm
   hook env exposes it). Pick during Phase 2.
2. **launchd vs. user-invoked daemon.** launchd gives robustness but adds an install
   step. User-invoked (`mother daemon start` from a login shell) is simpler but more
   fragile. Phase 2 decision.
3. **Settings.json hook wiring.** Must be done by the user, not Mother itself.
   Worth a one-time manual doc step when phase 2 lands.
4. **Plan drafts during iteration.** Persist as `drafts/<draft-id>.md` (cross-turn
   durable) or keep inline in the conversation (simpler, loses state on distraction)?
   Leaning persistent drafts.
5. **Cost enforcement mechanism.** Does Claude Code honor `--max-cost` cleanly, or do
   we need to parse stream events and SIGTERM ourselves? Verify during Phase 1.
6. **What counts as a "failure" worth escalating?** Job-level (cody errored), vs.
   CI-level (PR opened but tests red). Phase 2 refinement.

## What we keep

- `lib/locks.sh` — main-dir serialization, unchanged.
- `lib/worktree.sh` — worktree creation, unchanged.
- Slack notification pipes (from the user's existing setup), unchanged.
- Existing statusline scripts — extended via `statusline/segment.sh`.
- `cody` agent — the background executor. Minor description tweak to note it's
  commonly invoked by Mother on self-contained plans.

## What we retire

- Any ad-hoc dashboard / session registry the user was running before — Mother's
  `list` / `status` / `logs` / statusline segment replace the "see what's running"
  use case.
- Previous session-history logic — folded into `events/` archive if useful;
  otherwise dropped.
- Any prior session-spawning scope in general-purpose launcher agents — narrower
  now (mother-runner owns spawning for queued jobs). Launchers remain for
  deploying services and non-queue tmux orchestration.

### Preview stacks

`lib/preview.sh` backs `mother preview`: a per-job RWX preview stack
(`Carefeed/preview-stack`) that a worker launches for behavioural checks and that
Mother always stops. The record lives on the job as `.preview`
(`{stack_id, backend, combo, components, refs, urls, run_id, run_url, launched_at, status,
expected_sha, launches, stopped_at}`), with `preview_up` / `preview_ready` / `preview_stop`
events. Teardown layers: `mother preview down`, `_preview_post_exit` after every worker exit
(with the same newer-worker guard as the RWX sandbox stop), `_preview_pre_spawn` before a fresh
attempt, and the runner's `_orphan_preview_stop` (every isolation).

**Backend seam.** Only `_preview_backend_up` and `_preview_backend_stop` know how a stack is
launched or stopped; the commands, hooks and runner go through them and the record stores
`backend`. Only `cli` (the `preview-stack` CLI with `--via dispatch`) exists. The **operations
control-plane backend is deferred** (`P4a-ops.md` plus a later Mother follow-up): it would add an
`operations)` arm to each `case` and nothing else. Until then operations still sees these stacks
through its discoverer (source `cli`, purpose `job`, `job-` id prefix) and its reconciler
auto-stops `job` stacks after an hour asleep, a backstop behind Mother's own layers.

---

## State safety

On 2026-10-17 the whole state tree (`~/.mother`: ~1,500 job records, events, archive) was deleted when a
test run killed mid-flight executed `rm -rf "$MOTHER_ROOT"` with the real path inherited from its worker.
No backup existed. Three independent layers now make a single mistake survivable.

### 1. Live marker and the delete guard

- `$MOTHER_ROOT/.mother-live` (explanation + creation time) is ensured by `lib/state.sh` whenever it is sourced
  (every `mother` command and the runner) and again at runner startup. Test setup exports `MOTHER_TEST_ROOT=1`,
  which suppresses it, so temp trees never carry one.
- `lib/safe-rm.sh` `safe_rm_tree <path>` is the only way `bin/` and `lib/` delete a directory tree. It returns
  non-zero with a `safe_rm_tree: refusing ...` message (deleting nothing) for: an empty path, `/`, `$HOME` or any
  ancestor of it, and any directory that is or contains (within 4 levels, or as an ancestor of
  `$MOTHER_ROOT` / `$MOTHER_LIVE_ROOT` / `~/.mother`) a `.mother-live` marker. Call sites: `lib/gc.sh`,
  `lib/teardown.sh` (residue and job tmp), `bin/mother-runner` (stale lockdirs), `lib/backup.sh` (restore rollback)
  and `teardown_mother_env`. `git worktree remove` is not a state-tree delete and is left alone; file-level
  `rm -f` is out of scope.

### 2. `MOTHER_LIVE_ROOT`

The worker wrapper exports the live root as `MOTHER_LIVE_ROOT`, never `MOTHER_ROOT`. Every entry point resolves
`${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}`, so in-worker `mother await` / `mother status` still reach
the real tree, an explicit `MOTHER_ROOT` (tests) wins, and anything a worker spawns that "cleans up
`$MOTHER_ROOT`" sees nothing. `setup_mother_env` unsets both variables, so test code cannot resolve the live tree.

### 3. Backups and restore

- The runner calls `mother backup now` at most every `MOTHER_BACKUP_INTERVAL` seconds (default 900), gated by
  `$RUNNER_DIR/last-backup.ts` (written before the run, like `_maybe_archive`) and bounded by a
  `MOTHER_BACKUP_TIMEOUT` watchdog (default 300s) so a slow `tar` cannot block dispatch.
- Location: `MOTHER_BACKUP_DIR`, default `~/Library/Application Support/Mother/backups` (macOS) or
  `${XDG_STATE_HOME:-~/.local/state}/mother/backups`. A dir inside `$MOTHER_ROOT` is refused.
- Contents: `jobs events archive drafts cursors metrics attention.json rate-limits.json config.env`; `logs/` only
  with `MOTHER_BACKUP_LOGS=1`. (`metrics/runs.jsonl` is the retro / ETA-calibration history and `config.env`
  the durable operator settings; both are small and unrecoverable, so they ride along.)
- Format: `mother-state-<YYYYmmddTHHMMSSZ>.tar.gz`, written to a hidden temp name and `mv`'d into place, so a
  crash never leaves a half-written file that looks valid.
- Retention (after each successful backup): keep everything newer than `MOTHER_BACKUP_KEEP_HOURS` (24); of the
  older ones keep the newest per UTC day for `MOTHER_BACKUP_KEEP_DAYS` (30); prune the rest. Age comes from the
  timestamp in the file name, never mtime; files that don't match the name pattern are never touched.
  `MOTHER_BACKUP_ENABLED=0` disables the timer.
- CLI: `mother backup now`, `mother backup list` (newest first, size, `jobs=N`), and
  `mother backup restore <file> [--yes]`. Restore refuses while `$RUNNER_DIR/runner.pid` names a live process
  (`mother daemon stop` first), validates the archive (relative paths, known top-level entries only) before
  touching anything, moves the current restorable entries to `$MOTHER_ROOT/.pre-restore-<ts>/` (never deleted),
  extracts, and prints what it restored. Without `--yes` it asks on a tty and refuses otherwise.

**Recovering from a lost tree:** `mother daemon stop`; `mother backup list`; `mother backup restore <newest> --yes`;
`mother daemon start`. Jobs that were `running` are picked up by the runner's orphan recovery.

## Broker / IPC protocol (W1 + W2)

The **broker** is a long-lived Go sidecar that gives clients a single bidirectional
connection over which they get current state, receive every subsequent change as a
server-push, and send correlatable commands — replacing shell-out + filesystem
polling. It is **remote-ready**: the event model and command surface hold unchanged
when TCP replaces the local Unix socket (W4).

This section is the spec a client author codes against. The architecture bets are
recorded inline as B1–B9.

### Process model (B1)

- The broker is a **separate process**, supervised by `mother-runner` (started on
  daemon start, SIGTERM'd on drain, restarted with bounded backoff if it dies).
  Gated by `MOTHER_BROKER_ENABLED` (default 1); with it `0`, Mother runs exactly as
  before.
- **Bash stays the sole writer of job state.** The broker is a reader + a CLI caller:
  - It learns of changes by tailing the append-only event logs
    (`$MOTHER_ROOT/events/<id>.jsonl`) with fsnotify — the same logs bash already
    writes via `_append_event`. No second writer to job JSON.
  - It executes `answer`/`cancel`/`retry` by shelling out to the existing `mother`
    CLI (`mother resume`/`cancel`/`retry`), so every mutation routes through the one
    atomic state path.
- The broker holds **no durable state**: on start it rebuilds its world from the
  job records and event logs, so a restart is safe and cheap.

### Transport boundary (B2)

The transport is Go's `net.Listener`/`net.Conn`. W1 binds a Unix socket at
`$MOTHER_ROOT/broker.sock`. Moving to TCP is a one-line change in the listener;
everything above operates on an `io.ReadWriteCloser` and is transport-blind.

No event or command payload contains a local filesystem path the client must open,
and initial state is delivered **in-band** over the connection. Session/transcript/
log *content* is exposed as data where needed; clients never receive a path to open.

### Framing & envelope (B3)

**Newline-delimited JSON** (NDJSON): one JSON object per line, `\n`-terminated, UTF-8,
no embedded raw newlines (escaped per JSON). Debuggable with `nc -U broker.sock | jq .`.

Every message — both directions — carries:

| Field | Type | Meaning |
|---|---|---|
| `v` | int | Envelope version (currently `1`). |
| `dir` | string | `event` (server→client, unsolicited), `cmd` (client→server), or `ack` (server→client, correlated reply). |
| `t` | string | Type tag. `event`: an event type; `cmd`: a command name; `ack`: mirrors the command it answers. |
| `id` | string | On `cmd`: client-chosen, echoed on the matching `ack` (the correlation key). On `event`: broker-assigned monotonic per-connection id (gap detection). On `ack`: equals the `cmd`'s id. |
| `ts` | string | Millisecond ISO-8601 UTC (e.g. `2026-05-30T09:30:56.510Z`), matching `state.sh`'s `_iso_now` so protocol events sort with the on-disk logs. |

Type-specific fields live under `data`. Errors are an `ack` with `data.ok=false` and a
structured `data.error` (B8).

### Connect-time handshake (B8)

Immediately on connect the broker sends a `hello` event:
`data = {protocol_version: 1, capabilities: [<category>..., <command>...]}`. A client
compares `protocol_version` and inspects `capabilities` to discover support (e.g.
`output` is absent until W2). An older client keeps working against a newer broker for
shared capabilities; the broker never rejects a connection for an unknown-but-additive
client field.

### Subscriptions & commands (B4)

A connection may hold **multiple independent named subscriptions**. Each has a
client-chosen `sub` name and a selector — server-side filtering from day one (never a
firehose):

- `subscribe {sub, jobs, categories}` → `ack`, then a `snapshot` event for the
  selected jobs, then matching live events. Snapshot + live-tail attach happen
  atomically inside the broker (under the fan-out lock), so the client gets current
  state then every subsequent change with **neither gap nor dup** (B5). `jobs` is a
  list of ids or `["all"]`; `categories` is a subset of the categories below.
- `unsubscribe {sub}` → tears down one subscription.
- `query.list {jobs?, state?, repo?}` → one-shot `ack` with job records (the
  `mother list --format json` equivalent, served from broker memory).
- `query.get {job}` → one-shot `ack` with one job record + its event history.
- `answer {job, text}` → routes to `mother resume <job> -` (text on stdin). Since HC-02 it also takes
  optional `option` and `source` (see "Headless crew contract" → Broker additions); it is the one command
  refused (`unauthorized`) when the peer's process ancestry contains `mother-run-job`.
- `cancel {job}` → routes to `mother cancel <job>`.
- `retry {job}` → routes to `mother retry <job>`.

The `snapshot` event carries `data = {sub, jobs: [<job record>...]}` — initial state
delivered in-band. Each job record's dynamic fields (`state`, `question`,
`paused_reason`, `current_activity`) are overlaid from the broker's event-derived
fold so the snapshot is consistent with the live stream.

### Event categories & ordering (B5)

| Category | Source | Reconnect semantics |
|---|---|---|
| `state` | the seven state transitions | Resync — snapshot re-establishes authoritative state; intermediate transitions not replayed. |
| `activity` | activity sub-state + pipeline kinds | Resync, folded into snapshot. |
| `await` | `awaiting_input` (carries question) | Resync — snapshot job record carries `question`/`paused_reason`. |
| `current_activity` | broker-derived from the worker transcript | None (ephemeral); snapshot carries the latest value, no history. |
| `quota` | `pause_requested`/`auto_resumed`/`paused_for_quota` | Resync for current pause state; live changes pushed. |
| `output` | worker session stream (W2) | **Best-effort log-backed replay** — bounded tail on subscribe; live tail thereafter. See §output category below. |

**Per-job ordering is guaranteed** (each job's events come from one append-only log,
read in file order). **Cross-job global ordering is not promised**; each event carries
its source `ts` for within-job sorting.

The canonical **event→state fold** (B7 — shared vocabulary with the SDLC-pipeline
feature): the seven state kinds map to themselves; `awaiting_input` and
`paused_for_quota` ⇒ `awaiting`; `resumed`/`auto_resumed` ⇒ `ready`;
`retried`/`escalated` carry the resulting state in `detail.to_state`. The pipeline
feature emits its phase/cycle events through `_append_event` using shared type names
so the broker surfaces them under `activity` with zero broker changes.

### current_activity (B6)

The broker tails each running job's Claude transcript (resolved via `session_id` +
`work_dir`, the same logic `mother peek` uses) and, on each new `tool_use`, pushes a
`current_activity` event with the rendered string (e.g. `"Edit: src/lib.rs"`) — the
polled field becomes a pushed value, with no client-side file I/O. The full
turn-by-turn `output` stream is covered in §output category below.

### Output category (W2)

The `output` category delivers structured worker session output over the existing
connection — no new on-disk format, no new writer, no shared-filesystem delivery. Each
worker's entire output is already captured as **newline-delimited stream-json** in
`$MOTHER_ROOT/logs/<id>.log` (written by `mother-run-job`'s `tee` wrapper). The broker
tails that file, classifies each stream-json line into a typed `output` event, and fans
it out in-band to subscribed clients.

#### Event schema

Every `output` event has `t = "output"`, `dir = "event"`, and `data` carrying at minimum:

| `data` field | Type | Meaning |
|---|---|---|
| `category` | `"output"` | Always. Injected by the hub. |
| `job` | string | Job ID. Injected by the hub. |
| `subtype` | string | One of the sub-types below. |

Sub-type-specific fields:

| `data.subtype` | Source stream-json line | Additional `data` fields |
|---|---|---|
| `"system"` | `{"type":"system","subtype":"init",…}` | `session` (session ID), `model` |
| `"text"` | assistant message, content part `type:"text"` | `text` (the assistant's prose) |
| `"tool_use"` | assistant message, content part `type:"tool_use"` | `tool` (name), `brief` (one-line input summary, ≤110 runes) |
| `"tool_result"` | user message, content part `type:"tool_result"` | `is_error` (bool), `size` (raw content bytes), `preview` (≤512 runes; `truncated:true` + `size` when elided) |
| `"result"` | `{"type":"result",…}` | `subtype_val` (e.g. `"success"`), `cost_usd`, `duration_ms` |
| `"gap"` | synthetic (slow-client marker) | `dropped` (int — number of output events that were dropped) |

**Path safety (B2):** tool inputs that contain filesystem paths are rendered into the
`brief` string as display content only. No `output` event carries a path-typed field at
the top level that a client is expected to open.

**Volume bounding (B9):** `tool_result.preview` is truncated at 512 runes; oversized
results carry `truncated:true` and the original `size` in bytes. Banner lines
(`=== mother job … ===`) and blank/malformed/partial lines produce no events.

#### Reconnect semantics — best-effort log-backed replay

On `subscribe … categories:["output"]`, the broker performs a best-effort replay of the
job's recent output **before** registering the live tail, all under the hub's fan-out
lock so the replay/live boundary has no gap and no duplicate:

1. The broker reads the last `MOTHER_BROKER_OUTPUT_REPLAY_BYTES` (default 65536) of
   `<id>.log` up to the committed byte offset of the output tail.
2. Parsed lines are enqueued as `output` events ahead of the live tail.
3. The live tail then starts exactly at the committed offset — no dup, no gap.

The replay is **explicitly not a guaranteed full history**: a multi-megabyte log does
not replay in full. Clients that need complete history should read the log file directly
(best-effort, out-of-band).

`output` events are **not folded into the `snapshot`**. The snapshot delivers
authoritative job state; `output` is a stream, not state.

For a job that has already finished (`state != "running"`), an `output` subscribe is
valid but yields only the bounded replay (if a log exists) with no subsequent live events.

#### Backpressure — gap marker, not disconnect

W1's policy for `state`/`await`/etc. is **drop the client** on outbound-buffer overflow
(losing a state transition corrupts the client's view). `output` is high-volume and
replayable, so it uses a softer policy:

1. The per-client bounded send channel (`MOTHER_BROKER_CLIENT_BUF`, default 1024) and
   non-blocking dispatch are unchanged — the fan-out loop never blocks on a slow client.
2. When an `output` event fails to enqueue (buffer full), the broker **does not drop
   the client**. Instead it increments the subscription's drop counter and sets a
   `pendingGap` flag.
3. On the next **successful** output enqueue for that subscription, the broker first
   emits a synthetic `output` event `subtype:"gap", data.dropped:<n>`, resetting the
   counter. The client learns "you missed N output events here."
4. Non-output events (`state`, `await`, etc.) keep the W1 hard-drop semantics
   unchanged.
5. **Hard ceiling:** if a subscription's drop counter exceeds
   `MOTHER_BROKER_OUTPUT_MAX_GAP` (default 10000) — indicating a durably wedged client,
   not a transient burst — the broker falls back to W1's drop-the-client path.

#### Configuration knobs

| Env var | Default | Meaning |
|---|---|---|
| `MOTHER_BROKER_OUTPUT_ENABLED` | `1` | Master switch. When `0`, `output` is absent from `hello.capabilities` and `subscribe categories:["output"]` returns `malformed`. |
| `MOTHER_BROKER_OUTPUT_SEC` | `1` | Poll interval for `<id>.log` tailing (seconds). |
| `MOTHER_BROKER_OUTPUT_REPLAY_BYTES` | `65536` | Byte window for best-effort replay on subscribe. |
| `MOTHER_BROKER_OUTPUT_MAX_GAP` | `10000` | Per-subscription dropped-output ceiling before hard client drop. |

### Errors (B8)

Every `ack` carries `data.ok` (bool). On failure, `data.error = {code, message}` where
`code` is from a **closed enumeration** — clients switch on `code`, never the message:

| `code` | Condition |
|---|---|
| `no_such_job` | command names a job that does not exist |
| `invalid_state` | command invalid for the job's current state |
| `malformed` | envelope/command failed to parse or validate |
| `unavailable` | broker restarting / transiently unable to serve — back off and retry |
| `version_mismatch` | client/broker protocol version incompatible |
| `unauthorized` | reserved for the network-auth path (W4); never returned by W1's local transport |
| `internal` | broker-side failure (e.g. CLI shell-out errored) |

### Disconnect, backpressure, lifecycle (B9)

- **Disconnect:** a read error/EOF reclaims the client's goroutine and subscriptions
  immediately. A periodic `ping` event (every `MOTHER_BROKER_PING_SEC`, default 15s)
  doubles as a liveness probe — a dead/half-open peer makes the writer's send fail,
  dropping the client. Inbound silence is NOT a drop condition: a pure subscriber that
  only listens stays connected.
- **Backpressure:** each client has a bounded outbound buffer
  (`MOTHER_BROKER_CLIENT_BUF`, default 1024 messages). For non-output categories, on
  overflow the broker drops the slowest client rather than blocking the fan-out — a slow
  client harms only itself. For the `output` category the broker uses a softer
  gap-marker policy (see §output category above), falling back to a hard drop only when
  the gap counter exceeds `MOTHER_BROKER_OUTPUT_MAX_GAP`.
- **Lifecycle:** supervised by `mother-runner` (bounded restart with backoff). During a
  restart, connecting clients get connection-refused; mid-stream clients see EOF and
  should reconnect with backoff (the `unavailable` notice distinguishes this from a
  fatal error).

### Build & ship

The broker is a single static binary built by `scripts/build-broker.sh` into
`plugins/mother/broker/bin/mother-broker` (gitignored). `scripts/run-tests.sh` builds
it and runs `go test ./broker/...` alongside the bats suite. `mother broker status|path`
are read-only diagnostics.

## Headless crew contract (Phase 1)

The headless-crew work adds quality gates, a parallel reviewer "lens wave", decisions, attention
flags and a progress indicator. This section is the **client contract** for all of it, published
before any producer lands so that Nostromo can build against fixtures
(`plugins/mother/tests/fixtures/contract/*.ndjson`, provisional until re-recorded from real runs)
while Mother builds the producers. Every later PR emits exactly these names.
`plugins/mother/scripts/contract-check.sh` validates NDJSON streams against this section; its
table at the top of the script must match the tables below exactly.

### Compatibility rules

- **Additive only (C4).** New keys, new `activity` values, new event kinds, new capabilities, new
  command names and new broker categories only. Nothing here renames or re-types an existing field,
  state, activity, event, command or error code, and no existing key changes its format.
- **Why the rule is strict.** Clients get raw job JSON (`broker/commands.go` `query.list`/`query.get`
  and the snapshot) with an overlay of `state`/`question`/`paused_reason`/`current_activity`
  (`broker/server.go`). Nostromo's Rust daemon decodes the snapshot as a single `Vec<MotherJob>`, so
  one type change on an existing key breaks every job. **New keys only; never change an existing
  key's type or format.** Timestamps stay ISO-8601 millisecond `Z`.
- **Unknown event kinds** are classified `activity` by the broker (`broker/eventsource.go`), so
  clients that do not know a kind still see it as generic activity.
- **Wire payloads carry no free text (C11).** Wire payloads (events, snapshots, `query.*` results)
  carry ids, enums, counts, durations, costs and the Mother-templated `question` only. Gate output,
  finding text, claim quotes and checklist text never go on the wire, for any repo. They live in side
  files under `$MOTHER_ROOT/crew/<id>/` that only local `mother status` reads. PHI-sensitive repos
  never get an excerpt in `question`. The checker rejects the keys `excerpt`, `output`,
  `detail_text`, `summary`, `quote`, `text` (allowed only on the client `answer` cmd) and
  `criterion_text` anywhere in new-kind event details and new job keys.
- Existing event details are not changed by this PR. `resumed` today carries `answer` (the operator's
  text); this contract only adds `option` and `source` to it, and HC-02 owns what happens to
  `answer`.

### New `activity` values

Each maps onto an existing `state` (C4); `paused_reason` is an existing key.

| `activity` | `state` | `paused_reason` | Meaning |
|---|---|---|---|
| `gating` | `running` | — | Mother is running gates on the head commit |
| `gate_fix` | `running` | — | worker (resumed session) fixing red gates |
| `review_wave` | `running` | — | adherence and lenses running on the gated commit |
| `review_rework` | `running` | — | worker (resumed session) addressing blocking wave findings |
| `gate_hold` | `awaiting` | `gate_hold` | gate attempts exhausted, a decision is open |
| `review_hold` | `awaiting` | `review_hold` | human-blocking finding or wave cycle cap, a decision is open |

### New job keys

All optional; absent until the producing feature runs. Existing keys keep their types.

| Key | Fields |
|---|---|
| `crew` | resolved crew snapshot (opaque to clients; presence means the repo opted in) |
| `gates` | `{mode, posture, status, attempt, max_attempts, head_sha, started_at, finished_at, results[{name, result: passed\|failed\|skipped\|unavailable, blocking, duration_s, exit_code, unavailable_reason}], not_run[], override}` |
| `review_wave` | `{mode, cycle, cycle_cap, status, budget_usd, spent_usd, lenses[{reviewer, lens, state: pending\|running\|done\|skipped\|error, skip_reason, findings{blocking, advisory}, cost_usd, examined_files}], adherence{state, verdict}, coverage_gaps, claims{verified, refuted, unverified}}` |
| `decision` | `{id, kind, options[{id, label, consequence, takes_text}], opened_at, resolved_at, resolution}` |
| `attention` | `[{reason, since}]` |
| `last_answer` | `{source, session, agent, option, at}` |
| `criteria_source` | `checklist` or `ledger` (the checklist/ledger seam) |

**`.progress` overlay.** Not stored in job JSON (job files are identical with the indicator on or
off). `mother list/status --format json` merge `$MOTHER_ROOT/progress/<id>.json` in as `.progress`,
and the broker overlays the latest `progress_updated` detail as `.progress`:
`{v, pct, label, stage, signals{stage, checklist, gates, elapsed_active_s, cost}, eta{lo_s, hi_s, label, basis: repo|fleet|none}, paused, moved_back{reason, at}, flags[], updated_at}`.

As produced by HC-09 (additive detail on the shape above): `stage` is one of `build|rework|gates|review|present|done`;
`signals` also carries `stage_share` and `stage_frac`, `gates` is `null` or `{passed, failed, total, attempt, max_attempts}`,
`checklist` is `{status: "unavailable"}` until HC-10, and `cost` is `{usd, of_usd, basis: cap|estimate|none, fraction}`;
`eta` also carries `n` (jobs behind the calibration) and its `label` is `~25m`, `~1–2h`, `?` (no usable calibration) or
`paused · <reason>`; `moved_back` also carries `from_pct` (`reason`: `gate_failed|adherence_rework|review_rework`).
`pct` is a multiple of 5, at most 95 until the job is terminal. `progress_updated` is emitted only on a visible change
and at most once per job per 60s; the broker keeps the latest one per job (snapshot, `query.list`, `query.get`).
The provisional fixtures under `tests/fixtures/contract/` use older illustrative stage names and scalar `cost`; they
are replaced when re-recorded from real runs.

### Attention reasons

Closed and documented; new reasons are additive. Acknowledgements live in
`$MOTHER_ROOT/acks/<id>.json`, never in job JSON.

| `reason` | Meaning |
|---|---|
| `progress_stalled` | no visible progress movement for too long |
| `burn_ahead` | spend is running ahead of progress |
| `gates_incomplete` | gates could not all run (`unavailable`/`not_run`) at presentation |
| `decision_awaiting` | a decision is open and unanswered |

### Events

Category `activity` unless noted. Every detail value is an id, enum, count, duration or cost.
On the wire an event is `{v, dir:"event", t:<kind>, id, ts, data}` with `data` = the detail plus
`job` and `category`.

| Kind | Detail keys |
|---|---|
| `gates_started` | `attempt, max_attempts, head_sha, mode, posture, gates[]` |
| `gate_result` | `attempt, name, result, blocking, duration_s, exit_code` |
| `gates_completed` | `attempt, status, passed, failed, unavailable, not_run[]` |
| `gate_fix_started` | `attempt, session_id, red[]` |
| `gates_exhausted` | `attempts, red[]` |
| `gates_overridden` | `red[], source` |
| `pr_marked_draft` | `reason` |
| `pr_marked_ready` | `reason` |
| `pr_draft_unverified` | *(none)* |
| `criterion_checked` | `id, status, has_evidence` |
| `review_cycle_started` *(existing)* | `cycle, reviewers[]`, plus `pending_reviewers[], wave: true` for a wave (see note) |
| `lens_skipped` | `reviewer, lens, reason: path_scope\|posture\|budget\|removed_by_plan` |
| `reviewed` *(existing)* | `reviewer, finding_count, decision` |
| `claims_verified` | `verified, refuted, unverified` |
| `review_cycle_completed` *(existing)* | `cycle, decision, findings_count`, plus `coverage_gaps` for a wave |
| `review_wave_completed` | `cycles, status` |
| `decision_opened` | `decision_id, kind, options[]` (option ids) |
| `decision_resolved` | `decision_id, option, source` |
| `resumed` *(existing)* | gains `option` and `source` |
| `attention_raised` | `reason` |
| `attention_cleared` | `reason` |
| `attention_acked` | `reason, source` |
| `progress_updated` *(category `progress`)* | the `.progress` object above |
| `progress_half` *(category `progress`)* | `eta_lo_s, eta_hi_s, elapsed_active_s` |

Notes:
- `review_cycle_started` currently carries `reviewers` (not `pending_reviewers`), and `findings_routed`
  is never emitted (`bin/mother-runner`). This table records the real names; `pending_reviewers` is
  added additively by HC-14.
- `gate_result.result` is `passed|failed|skipped|unavailable`. `unavailable` is never reported as `passed`.
- Reviewer names are `archie:adherence` and `perri:<lens>` (`perri:correctness`, `perri:phi-security`,
  `perri:tests`, `perri:ops-infra`).
- New `runs.jsonl` run kinds are `gate_fix` and `review_rework`; lens stages are `review-perri:<lens>`.
- The job key `criteria_source` is `checklist` or `ledger`; `criterion_checked` events come from HC-10.
  A job's `criteria_source` is set once at `mother add` (`checklist`) and never changed. All criteria reads go
  through `mother_criteria_view <id>` (`{source, items:[{id,status,evidence}]|null}`, no text). `checklist` reads
  `$MOTHER_ROOT/checklists/<id>.json`; `ledger` is the Phase 3 source behind the same view (until then
  `items: null`, i.e. unavailable), so the indicator switches over with no display change and no migration.

### Broker additions

Hello capabilities are additive strings.

| Addition | Detail |
|---|---|
| category `progress` | carries `progress_updated` and `progress_half`; clients that do not subscribe see nothing new |
| command `ack {job, reason}` | maps to `mother ack <id> <reason>`; `reason` is an attention reason |
| `answer` fields `option`, `source` | `answer {job, text?, option?, source?}`; plain text with no option means `resume_with_guidance` |
| capability `answer.option` | advertised in `hello.capabilities` when the `answer` command accepts `option` and `source` |
| error `unauthorized` | existing code, now also returned when the peer is a Mother worker (it was reserved for the network-auth path) |

**Answer authorization.** Only the operator, or an agent session acting for them, may answer a hold.
`mother resume` exits 1 (`refused`) when `MOTHER_JOB_ID` is set (a worker inside a Mother job). The
broker applies the same rule to `answer` by reading the peer pid of the Unix socket (darwin
`LOCAL_PEERPID`) and walking its parent chain (32 levels) for a `mother-run-job` process; if the pid
cannot be read it allows the answer (logged) because the CLI guard still applies. `cancel`, `retry` and
`force-start` are not guarded. Option validation errors use `invalid_state:` so the broker maps them to
`invalid_state`. A resolved decision only blocks answers while the job is still in that decision's hold.

**Decision option ids:** `resume_with_guidance` (`takes_text: true`), `escalate`, `override_open`, `cancel`.

**Answer sources:** `nostromo_app`, `cli`, `broker_client`.
