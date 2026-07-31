# Mother — project notes for Claude Code

This repo is the Mother plugin: a local background-work orchestrator that
dispatches Claude Code sessions against self-contained plans. See `README.md`
for product-level detail.

## Layout cheatsheet

- `plugins/mother/bin/` — user-facing CLIs. `mother` is the main entry point;
  `mother-runner` is the long-running daemon; `mother-run-job` is the
  per-job worker spawned by the daemon (or by `mother run --once`);
  `mother-switcher` is the fzf popup.
- `plugins/mother/lib/` — sourced shell libs (`state.sh`, `worktree.sh`,
  `locks.sh`). The libs do not call `set -u` themselves; they inherit it
  from whichever bin sources them.
- `plugins/mother/launchd/` — macOS launchd plist template installed by
  `mother daemon install`.
- `.claude/bug-reports/` — inbox for filed bug reports (see below).

Runtime state lives in `~/.mother/` (jobs, events, logs, locks, runner state).
It is never tracked in the repo and `.gitignore` already excludes `.mother/`.

## Shell conventions

- All bin scripts run under `set -u`. Any external env var reference
  (`$TMUX`, `$EDITOR`, etc.) MUST use the `${VAR:-default}` form — a bare
  `$VAR` will crash the script when the var is unset, and since workers are
  spawned by the daemon with stderr discarded, the failure is silent. Use
  `${CLAUDE_SESSION_ID:-unknown}` / `${TMUX:-}` as the reference pattern.
- macOS ships `/bin/bash` as 3.2.57. Do not rely on post-3.2 features
  (e.g. `declare -A`, `mapfile`, reliable `export -f` across
  `bash -c` boundaries) in scripts that may be invoked by fzf, tmux
  popups, or `sh -c` wrappers. When a child shell needs access to a
  function defined in a parent script, prefer self-invocation
  (`"$0" --emit-foo`) over `export -f` + `bash -c`.
- Use `_job_update` (in `mother-run-job`) or `_job_update <id> <filter>`
  (in `lib/state.sh`) to mutate job JSON — both go through an atomic
  write. Don't hand-edit the json files.

## Bug report workflow

Bug reports are filed as markdown under `.claude/bug-reports/` (this
directory is in the user's global gitignore, so these are local notes,
not committed artifacts). Convention:

1. **New reports** land in `.claude/bug-reports/` as
   `YYYY-MM-DD-slug.md`. They describe symptom, root cause, suggested
   fix, and ideally a reproducer.
2. **When you fix one**:
   - Make the fix in a normal commit with a descriptive subject
     (`fix: …`). Don't reference the bug-report file in the commit
     message — the reports are local and the commit has to stand on
     its own for anyone reading `git log`.
   - Append a footer to the bug report before archiving:
     ```
     ---

     **Resolved:** <short-sha> — <commit subject>
     ```
   - Move the file into `.claude/bug-reports/resolved/`.
3. `.claude/bug-reports/` is the live inbox — anything there is still
   open. `.claude/bug-reports/resolved/` is the audit trail.

Don't delete resolved reports. The standalone narrative
("here's what was broken and why") is more useful for future debugging
than the commit message alone, and the resolved footer ties it back to
the fix.

## Routing & adherence

Mother now supports task-aware routing, failure-tier escalation, and
plan-adherence review. Here's what was added and how to work with it.

### New job fields

| Field | Type | Description |
|---|---|---|
| `suggested_config` | object | Model/effort hints from Archie's plan (cody/redd/marty/perri). |
| `current_tier` | string | Current escalation tier (`tier_0`–`tier_3`). |
| `escalation_count` | int | Number of times this job has been escalated. |
| `adherence_attempts` | int | Number of adherence reviews run so far. |
| `adherence_pending` | bool | True when a succeeded job awaits adherence review. |
| `adherence_status` | string | `passed`, `failed_first`, `blocked_for_human`. Audit trail only — do not use for operational logic. |
| `adherence_notes` | string | Archie's notes from the last review (populated on fail). |
| `activity` | string | Optional sub-state: `cody_rework` (re-running after adherence fail) or `adherence_blocked` (awaiting human) or `pipeline_phase` / `pipeline_review` / `pipeline_blocked` (pipeline jobs). Cleared on resume. |
| `cost_model` | string | Account billing mode at enqueue time: `subscription`, `metered`, or `unknown`. Clients suppress dollar displays when `subscription`. |
| `force_start` | bool | Per-job override flag. When `true`: job dispatches even over quota cap, is exempt from mid-flight quota pause, and posture bias is bypassed (runs at `suggested_config`-resolved tier; metrics record `posture_bias_applied="forced"`). Cleared on every terminal transition, escalation re-queue, and adherence-rework re-queue. Set via `mother force-start <id> [--yes]`. |

### State machine

`state` is the operational status. `activity` clarifies what's happening within
a state — think of it as a sub-state that's always optional to read but useful
for display and routing.

| state | activity | meaning |
|---|---|---|
| `queued` | — | waiting on dependencies |
| `ready` | — | runnable, waiting for daemon slot |
| `running` | (none) | Cody running (first attempt) |
| `running` | `cody_rework` | Cody running (second attempt, after adherence fail) |
| `running` | `continuation` | Cody re-running after idle_timeout (auto-continuation) |
| `awaiting` | (none) | Cody asked a question; answer with `mother resume` |
| `awaiting` | `adherence_blocked` | Archie failed twice; human must review PR, then `resume` or `cancel` |
| `running` | `pipeline_phase` | pipeline job: a build agent (redd/cody/marty) is actively running |
| `ready` | `pipeline_phase` | pipeline job: next build agent queued (driver just advanced the phase) |
| `succeeded` | `pipeline_review` | pipeline job: all build phases done, concurrent review in progress |
| `awaiting` | `pipeline_blocked` | pipeline job: blocked for human (human-blocking finding, cap hit, or empty reviewers) |
| `succeeded` | — | terminal: all work done (for pipeline jobs, set by the driver on ship) |
| `failed` | — | terminal: gave up after escalation cap |
| `cancelled` | — | terminal: explicitly cancelled |

Terminal states are exactly `succeeded`, `failed`, `cancelled`. Only terminal
jobs can be archived.

### Tier ladder

Escalation bumps the job up this ladder (cap: 2 escalations):

| Tier | Model | Effort |
|---|---|---|
| `tier_0` | sonnet | medium |
| `tier_1` | sonnet | high |
| `tier_2` | sonnet | xhigh |
| `tier_3` | opus | high |

### Job fields (additional)

| Field | Type | Description |
|---|---|---|
| `no_pr` | bool | Set by `no_pr: true` in the plan YAML block. Skips the `no_pr_no_push` failure check. Success condition becomes "worker exited cleanly with commits on the branch." |
| `continuation_count` | int | Number of auto-continuation attempts so far. Incremented each time an `idle_timeout` triggers a re-queue. |
| `pipeline.review_cycle` | int | Number of review cycles completed so far (0-indexed). Incremented once per continue-cycle. Surfaced by W5 as `review_cycle_count`. |

### Kill switches

All background behaviours can be disabled without redeploying:

- `MOTHER_ESCALATION_ENABLED=0` — disable auto-escalation of failed jobs.
- `MOTHER_ADHERENCE_ENABLED=0` — disable adherence review of succeeded jobs.
- `MOTHER_CONTINUATIONS_ENABLED=0` — disable auto-continuation on idle_timeout.
- `MOTHER_MAX_CONTINUATIONS=N` — cap continuation attempts (default: 3).
- `MOTHER_PIPELINE_ENABLED=0` — disable the pipeline driver entirely; `kind: "pipeline"` jobs are left untouched by the driver.
- `MOTHER_PIPELINE_CYCLE_CAP=N` — override the default cycle cap (default: 3) for pipeline jobs that do not set `pipeline.cycle_cap` themselves.
- `MOTHER_TEARDOWN_ENABLED=0` — disable worktree/container teardown entirely.
- `MOTHER_TEARDOWN_DOCKER_ENABLED=0` — skip the docker sweep, still tear down worktrees.
- `MOTHER_TEARDOWN_MAX_DEFERRALS=N` — deferrals before a stalled teardown is flagged for attention (default: 30; never triggers deletion).

### Metrics file

Every terminal transition (succeeded or failed) appends a JSON line to
`~/.mother/metrics/runs.jsonl`. Schema:

```json
{
  "ts": "2026-05-04T12:00:00.000000Z",
  "job_id": "...",
  "stage": "cody",
  "model": "sonnet",
  "effort": "high",
  "tier": "tier_1",
  "outcome": "succeeded",
  "retry_count": 0,
  "escalation_count": 1,
  "wall_time_seconds": 1234,
  "log_size_bytes": 56789,
  "tokens_in": 850762,
  "tokens_out": 5434,
  "pr_url": "https://github.com/..."
}
```

Query with `jq` — e.g. summarise success rate by tier:

```bash
jq -s 'group_by(.tier) | map({tier: .[0].tier, total: length, passed: map(select(.outcome == "succeeded")) | length})' ~/.mother/metrics/runs.jsonl
```

### suggested_config (required in every plan)

Plans must include a `suggested_config:` YAML block (see `archie.md`). Without it,
`mother add` fails. Archie writes this block automatically.

### Tests

The bats test suite lives at `plugins/mother/tests/`. Run with:

```bash
./plugins/mother/scripts/run-tests.sh
```

Requires `bats` (`brew install bats-core`).

## Bishop budget posture

Mother consumes `~/.claude/budget-posture.json`, produced by Bishop
(`~/.local/bin/bishop`, source at `~/Code/bishop/`). Bishop computes a
"budget posture" from Claude Code's rolling 5-hour and 7-day quota windows and
writes the result to that file. Mother reads posture at Cody-spawn time and at
adherence-review time to bias the model/effort tier.

**Kill switch:** set `MOTHER_POSTURE_ENABLED=0` (in the launchd plist or shell
environment) to disable posture bias entirely. The default is `1` (enabled).

**Posture levels and bias semantics:**

| Posture | Effect on initial tier |
|---|---|
| `conservative` | Clamp to `tier_0` (sonnet / medium) |
| `normal` | No change |
| `elevated` | +1 tier from resolved, capped at `tier_2` (sonnet / xhigh) |
| `flush` | +1 tier from resolved, capped at `tier_3` (opus / high) |

**Bias-first-then-escalation contract:** posture bias is applied to the
*initial* resolved tier (`current_tier == tier_0`). Failure escalation
(`escalation_count`) bumps `current_tier` externally before `mother-run-job`
runs, so escalated jobs already have `current_tier > tier_0` when the posture
block executes — the `tier_0` guard ensures escalation always dominates and
escalated jobs are never pulled back down by `conservative` posture.

**Degradation:** if Bishop is not installed or `bishop get posture` fails,
`_resolve_posture` echoes `normal` and Mother proceeds with no bias.

**New metrics fields** on each `runs.jsonl` line (since this feature):
- `posture_at_spawn` — posture level observed at Cody-spawn time.
- `posture_bias_applied` — action taken: `clamp`, `up1`, or `none`.
- `tokens_in` — total input tokens consumed by the worker transcript (sum of
  `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` across
  all assistant turns, de-duplicated by message id). JSON `null` when the
  transcript is unavailable or contains no assistant events.
- `tokens_out` — total output (generated) tokens across all assistant turns,
  de-duplicated by message id. JSON `null` when the transcript is unavailable.

## Resource teardown (worktrees + containers)

Mother creates two kinds of Mother-owned resources per job — a git worktree
(`mother-run-job:272-290`) and, potentially, docker containers a job's worker
starts for testing — and until this feature never cleaned up either. Both are
torn down automatically once the underlying work is *settled*, via
`plugins/mother/lib/teardown.sh`.

**Why gate on PR settlement, not "job reached a terminal state":** worktrees
are legitimately *reused* by follow-up jobs against the same branch (e.g. "fix
CI on PR #3845" runs after the original job for that branch already
succeeded). Tearing down as soon as a job goes `succeeded`/`failed` would
delete a worktree a follow-up job is about to reuse, or is actively running
in. The safe signal is "the PR is merged or closed", or "the job is terminal
and never produced a PR at all." Teardown rides along with the existing
`mother archive` path (the daemon's periodic sweep, and the manual `mother
archive <id>` used by the fzf switcher's ctrl-d) rather than introducing a new
sweep mechanism.

**The gate** (`_teardown_gate` in `lib/teardown.sh`), evaluated per job:

| Condition | Result |
|---|---|
| No `pr_url`, state `failed`/`cancelled` | proceed — nothing was ever shippable |
| No `pr_url`, state `succeeded`, `no_pr: true` | proceed — a `no_pr` job never opens a PR |
| No `pr_url`, state `succeeded`, not `no_pr` | defer — a PR may exist but was never captured; never guess |
| `pr_url` set, PR merged | proceed |
| `pr_url` set, PR closed | proceed |
| `pr_url` set, PR still open | defer |
| `pr_url` set, `gh` unreachable/inconclusive | defer |

A race guard additionally defers when another non-terminal job shares the
same `repo_path` + `branch` (escalation re-queue, adherence rework, or a
distinct job queued against the same branch mid-flight).

**Container convention:** `mother-run-job` exports `COMPOSE_PROJECT_NAME`
(job-scoped, derived by `mother_compose_project` in `lib/state.sh`) into
every worker, so a plain `docker compose up` needs zero convention-following
to be teardown-safe. Anything started outside compose must carry the label
`mother.job_id=$MOTHER_JOB_ID` (see `templates/preamble.md`) or Mother can't
find it. Every docker mutation in the teardown path carries either the
`-p <project>` compose flag or one of these label filters — never an
unfiltered `docker system/volume/container prune`.

**The pending queue:** archiving moves a job's JSON out of `$JOBS_DIR`, so
"skip teardown this round, retry next sweep" can't be keyed off the job
record — after the move there's no live record to revisit. Deferred
teardowns instead get a self-contained facts snapshot at
`$MOTHER_ROOT/teardown-pending/<id>.json` (repo path, branch, work dir,
isolation, PR url, state — everything teardown needs, independent of whether
the job record still exists). Every bulk `mother archive` sweep drains this
queue first, re-evaluating the same gate; `mother archive <id>` re-attempts a
job's own record inline. `mother teardowns` lists pending records; `mother
teardowns --drain` re-attempts them on demand. Crossing
`MOTHER_TEARDOWN_MAX_DEFERRALS` deferrals emits `teardown_needs_attention`
once (not every subsequent pass) — it only makes a stall loud, it never
triggers destruction.

**Events** (see `_teardown_event` in `lib/teardown.sh`):

| Event | Detail | When |
|---|---|---|
| `teardown_started` | `{gate_reason, pr_url}` | Gate passed, about to remove |
| `teardown_completed` | `{worktree_path, worktree_removed, compose_project, containers, volumes, networks}` | Teardown finished |
| `teardown_deferred` | `{reason, pr_url, conflicting_job_id, deferrals}` | Retryable skip; record queued |
| `teardown_skipped` | `{reason}` | `disabled` / `main_dir` / `already_absent` |
| `teardown_failed` | `{stage, note}` | Docker or worktree step errored |
| `teardown_needs_attention` | `{deferrals, reason}` | Deferral cap crossed (once) |

**Job fields:**

| Field | Type | Description |
|---|---|---|
| `teardown_status` | string | `torn_down` / `deferred` / `skipped` / `failed` |
| `teardown_reason` | string | Gate or skip reason from the last attempt |
| `teardown_at` | string | ISO timestamp of the last teardown attempt |

**Kill switches:** `MOTHER_TEARDOWN_ENABLED=0` disables teardown entirely
(worktree/containers are left alone, but a pending record is still queued so
nothing is lost if the switch is flipped back on). `MOTHER_TEARDOWN_DOCKER_ENABLED=0`
skips only the docker sweep. `MOTHER_TEARDOWN_MAX_DEFERRALS` (default 30) tunes
the stall-attention threshold above.

**Out of scope (deliberately):** git branch deletion, retroactive cleanup of
worktrees/containers left behind by jobs archived before this feature shipped,
and the operator's personal `/prune-worktrees` slash command (a separate,
Mother-unaware, manual tool for worktrees Mother did not create).

## Pipeline visibility (W5)

W5 makes the SDLC pipeline observable. Key surfaces:

### `cycles` derived field on JSON output

`mother list --format json` and `mother status --format json` attach a `cycles`
array to `kind: "pipeline"` jobs. Standard jobs carry no `cycles` key (back-compat
guaranteed by a regression test). The `cycles` array is derived at read time from
`pipeline.*` fields and the events log — W4 does not store it.

Schema per cycle:
```json
{"cycle": 1, "phases": [
  {"agent": "redd",  "request_type": "test",    "state": "completed",
   "started_at": "...", "finished_at": "..."},
  {"agent": "cody",  "request_type": "build",   "state": "running", "started_at": "..."},
  {"agent": "marty", "request_type": "refactor", "state": "pending"},
  {"agent": "perri", "request_type": "review",  "state": "pending", "findings": 0}
]}
```

- Cycle numbers are **1-indexed** in output (`pipeline.review_cycle` is 0-indexed internally).
- Timestamps (`started_at`, `finished_at`) come from W5 events; absent if the phase
  ran before W5 events were added.
- Build agents not in `pending_agents` on re-run cycles carry `"state": "skipped"`.

### New lifecycle events (W5 additive — W4 events preserved)

These four events are emitted by `mother-runner` alongside the existing `pipeline_*`
events. All classify as `activity` in the IPC broker (not `state`).

| Event | Detail fields | When emitted |
|---|---|---|
| `phase_started` | `{cycle, agent, request_type}` | When driver advances a build phase to `ready` |
| `phase_completed` | `{cycle, agent, request_type}` | When driver advances past a completed build phase |
| `review_cycle_started` | `{cycle, reviewers}` | Alongside `pipeline_review_started` |
| `review_cycle_completed` | `{cycle, decision, findings_count}` | After B4 decision, before state transitions |

The `_pipeline_cycles_json` helper uses these events for timestamps. If they're absent
(e.g. job ran pre-W5), timestamps are simply omitted.

### Advisory findings — display and IPC

- `mother status <id>` renders a distinct `Advisory findings:` block in the pipeline
  section, listing each advisory with `[advisory] <summary> (<reviewer>)`.
- `mother list <id>` appends ` · N advisor(y/ies)` to the `shipped` label when
  `pipeline.advisories` is non-empty.
- The IPC broker's `mother_jobs` snapshot includes `pipeline.advisories` verbatim in
  the raw job JSON passthrough — no Go change needed; the field reaches clients
  automatically once W4 writes it.
