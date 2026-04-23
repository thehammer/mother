# Mother — Design Doc

Background-execution system for Claude Code sessions. Plans are co-authored in the
interactive session, dispatched to a local runner, and tracked via events that surface
naturally in subsequent conversations.

## Goals

- Plans become background implementation work without leaving the interactive session.
- No slash commands on the user's side. Dispatch happens via Bash tool calls from Claude.
- Background sessions run locally — tmux + worktrees + `claude --agent cody`.
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
    tmux window at the target path, run `claude --agent cody -p "$PLAN"` with
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
> **Flow:** Invoke the `archie` agent to produce a plan. Present it inline for
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
