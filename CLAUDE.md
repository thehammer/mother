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
| `activity` | string | Optional sub-state: `cody_rework` (re-running after adherence fail) or `adherence_blocked` (awaiting human). Cleared on resume. |

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
| `awaiting` | (none) | Cody asked a question; answer with `mother resume` |
| `awaiting` | `adherence_blocked` | Archie failed twice; human must review PR, then `resume` or `cancel` |
| `succeeded` | — | terminal: all work done |
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

### Kill switches

Both features can be disabled without redeploying by setting env vars in the
launchd plist or shell environment:

- `MOTHER_ESCALATION_ENABLED=0` — disable auto-escalation of failed jobs.
- `MOTHER_ADHERENCE_ENABLED=0` — disable adherence review of succeeded jobs.

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
