# Mother — project notes for Claude Code

This repo is the Mother plugin: a local background-work orchestrator that
dispatches Claude Code sessions against self-contained plans. See `README.md`
for product-level detail.

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
| `adherence_status` | string | `passed`, `failed_first`, `blocked_for_human`. Audit trail only — do not use for operational logic. `mother list` renders an `[ADHERENCE-BLOCKED]` marker in the STATE column from `blocked_for_human` — display only. |
| `adherence_notes` | string | Archie's notes from the last review (populated on fail). |
| `activity` | string | Optional sub-state: `cody_rework` (re-running after adherence fail) or `adherence_blocked` (awaiting human) or `pipeline_phase` / `pipeline_review` / `pipeline_blocked` (pipeline jobs). Cleared on resume. |
| `cost_model` | string | Account billing mode at enqueue time: `subscription`, `metered`, or `unknown`. Clients suppress dollar displays when `subscription`. |
| `force_start` | bool | Per-job override flag. When `true`: job dispatches even over quota cap, is exempt from mid-flight quota pause, and posture bias is bypassed (runs at `suggested_config`-resolved tier; metrics record `posture_bias_applied="forced"`). Cleared on every terminal transition, escalation re-queue, and adherence-rework re-queue. Set via `mother force-start <id> [--yes]`. |
| `actual_cost_usd` | number | Cumulative spend (USD) across every `runs.jsonl` row for this job — sum of `cost_usd` from every worker run, adherence review, and pipeline reviewer invocation. Always a number (0, never null) once populated; never reset by retry/escalate/continuation/adherence rework (unlike before this feature, which reset it to `null` on each of those). Recomputed by `mother_recompute_job_cost` (`lib/usage.sh`) on every terminal transition. |
| `actual_tokens` | int | Cumulative `tokens_in + tokens_out` across every `runs.jsonl` row for this job. Companion to `actual_cost_usd`. |
| `actual_cost_complete` | bool | False if any contributing run touched an unpriced model (see `lib/rates.json`) — signals `actual_cost_usd` is a partial/undercount, not a hard error. |
| `live_cost_usd` / `live_tokens` | number/int | Best-effort spend/tokens for a **currently running** job, refreshed every `MOTHER_USAGE_CHECK_INTERVAL` seconds (default 120) by the poll loop in `mother-run-job`. `mother list` renders this as `~$N.NN` while `state == running`. |
| `current_run` | object | `{log_offset, spawned_at, session_id}` captured at spawn time, before the worker process starts. `log_offset` is this run's starting byte offset into the job's log — used by orphan recovery to record a usage row for a run that never reached its own terminal transition. |
| `token_alert_at` | string | ISO timestamp, set once (sticky) the first time a job's cumulative `actual_tokens`/live tokens crosses `MOTHER_TOKEN_ALERT_THRESHOLD` (default 100,000,000). Drives the statusline's `$!N` count (last 24h). |
| `max_cost_usd` | number\|null | Operator-set spend cap (`mother add --max-cost` / `mother resume --max-cost`). No cap means no cost-cap behavior at all — spawn args, poll-loop checks, and events are all skipped. |
| `cost_cap_breached_at` | string | ISO timestamp set when live spend first crosses `max_cost_usd`. Triggers the `$RUNNER_DIR/<id>.cost-cap` hook flag file and, after `MOTHER_COST_CAP_GRACE_SECONDS` (default 300) with no cooperative `mother await`, a forced pause to `awaiting`/`paused_reason: cost_cap`. |
| `failure_reason` | string | The `.reason` of the job's most recent `failed` transition (`unspecified` if the caller gave none), persisted by both `_transition` (`mother-run-job`) and `_job_transition` (`lib/state.sh`). Cleared on `succeeded`. Lets the runner route on it without replaying events. |
| `failure_routed` | bool\|null | Set `true` by `mother route-failure` when it deliberately leaves a job `failed` (`left_failed`) so the runner stops re-examining it. Cleared by the next `failed` transition. |
| `auto_retry_count` | int | Number of as-is (no tier bump) automatic retries the failure router has granted (max 1). Reset to `0` by `mother resume` — an operator resuming the job is a fresh chance, not a continuation of the failed retry budget. |
| `operator_hold` | object\|null | `{failure_reason, sub_reason, detail, held_at}` — present while a job is held (`activity: operator_hold`). Cleared (set to `null`) by `mother retry`, `mother reconcile`, and `mother resume`. |
| `rwx_sandbox` | object | `{reset_key, reset_at, last_reset_outcome}` — audit only. `reset_key` is the attempt key `"<escalation_count>:<retry_count>"`: a spawn whose key equals the stored one (resume, continuation, adherence rework, later pipeline phase) skips the reset; `mother retry` and escalation change the key and trigger one. Stored even when the reset failed. |
| `current_run.*` (baseline) | object | In addition to `log_offset`/`spawned_at`/`session_id`: `head_sha_at_start`, `remote_ref`, `remote_sha_at_start`, `pr_url_at_start`, `had_artifact_at_start` — what already existed on origin/as a PR when this run began (audit fields for the rework-advance check). |

### State machine

`state` is the operational status. `activity` clarifies what's happening within
a state — think of it as a sub-state that's always optional to read but useful
for display and routing.

| state | activity | meaning |
|---|---|---|
| `queued` | — | waiting on dependencies — each dependency must be `succeeded` **and** its PR merged (or be a `no_pr` job). A `queued` job with `dep_wait.status == "blocked"` is never auto-cancelled; it shows under `mother status` needs-attention (see "Operator attention and notifications") |
| `ready` | — | runnable, waiting for daemon slot |
| `ready` | `cody_rework` | re-queued for a second Cody attempt after an adherence fail (the daemon sets this; the worker has not started yet) |
| `running` | (none) | Cody running (first attempt) |
| `running` | `cody_rework` | Cody running (second attempt, after adherence fail) |
| `running` | `continuation` | Cody re-running after idle_timeout (auto-continuation) |
| `awaiting` | (none) | Cody asked a question; answer with `mother resume` |
| `awaiting` | `adherence_blocked` | Archie failed twice; human must review PR, then `resume` or `cancel` |
| `awaiting` | `operator_hold` | Mother held a failed job instead of escalating it (see "Failure routing"); `.question` names the next commands. Act with `resume`, `retry`, `reconcile`, or `cancel` |
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
| `no_pr` | bool | Set by `no_pr: true` in the plan YAML block. Swaps the `no_pr_no_push` push/PR check for an enforced commits-on-branch check: at least one commit must exist ahead of `base_ref` (`HEAD` for `worktree` isolation, `refs/heads/<branch>` for `main-dir`, since main-dir jobs restore the operator's original branch to `HEAD` before verification runs). Zero commits fails with `reason: no_commits_on_branch`; an unresolvable base_ref or branch ref fails closed with `reason: commit_check_indeterminate`. A captured `pr_url` still short-circuits the check either way. |
| `continuation_count` | int | Number of auto-continuation attempts so far. Incremented each time an `idle_timeout` triggers a re-queue. |
| `pipeline.review_cycle` | int | Number of review cycles completed so far (0-indexed). Incremented once per continue-cycle. Surfaced by W5 as `review_cycle_count`. |
| `expect_branch_mismatch` | bool | Set by `expect_branch_mismatch: true` in the plan YAML block, or `mother add --expect-branch-mismatch`. Declares that the worker is deliberately targeting a branch other than the assigned one (e.g. landing more commits on an existing open PR) — a mismatching PR head branch is accepted without the commit-containment check. Default `false`. |
| `actual_branch` | string | Set when the captured/accepted PR's head branch differs from the job's assigned `branch` (a branch-name mismatch that PR detection accepted via `expect_branch_mismatch` or commit-containment, or that `mother reconcile` adopted). Absent when the PR's head branch matches `branch`. |
| `resume_not_yet_acted_on` | bool | Sticky audit flag. Set when an idle-timeout continuation is queued for a job that was resumed with an operator answer but has no commit postdating that resume. Never cleared automatically; surfaced by `mother status` as `[RESUME-MAY-BE-UNAPPLIED]`. |
| `dep_wait` | object | Set on a `queued` job that isn't promotable yet: `{dep_id, status: "wait"\|"blocked", reason, pr_url, checked_at}` for the first unsatisfied dependency. Written only when `dep_id`/`status`/`reason` change. Cleared on promotion. `blocked` (dependency failed/cancelled/missing, PR closed unmerged, no PR url) never auto-cancels the job; it appears under needs-attention and `mother force-start <id>` releases it. |
| `awaiting_notify` | object | `{episode, first_seen_at, count, last_notified_at}` — the push-notification bookkeeping for an `awaiting` job (see "Operator attention and notifications"). Cleared when the job leaves `awaiting`. |
| `needs_attention` | object | Producer-agnostic flag `{reason, note, since}`. Anything that holds a job for the operator sets it; Mother renders it as a `job_flagged` needs-attention item. This repo adds no producer. |
| `origin` | object | Provenance captured at `mother add` time: `{project, cwd, session, enqueued_by, label}`. `project` = basename of the enqueuing cwd's git toplevel, or the `--origin-project` override; `session` = `--origin-session` → `$MOTHER_ORIGIN_SESSION` → `$CLAUDE_SESSION_ID` → `""`. Surfaced as `mother list`'s ORIGIN column, filtered by `mother list --project`/`--label`, and rendered by `mother status`'s `=== origin ===` block. |

### Kill switches

All background behaviours can be disabled without redeploying:

- `MOTHER_ESCALATION_ENABLED=0` — disable auto-escalation of failed jobs.
- `MOTHER_RECONCILE_ENABLED=0` — disable `mother-runner`'s pre-escalation `mother reconcile --auto` attempt (default: `1`). Independent of `MOTHER_ESCALATION_ENABLED`: with reconcile disabled, a failed job goes straight to escalation as before this feature.
- `MOTHER_ADHERENCE_ENABLED=0` — disable adherence review of succeeded jobs.
- `MOTHER_CONTINUATIONS_ENABLED=0` — disable auto-continuation on idle_timeout.
- `MOTHER_MAX_CONTINUATIONS=N` — cap continuation attempts (default: 3).
- `MOTHER_PIPELINE_ENABLED=0` — disable the pipeline driver entirely; `kind: "pipeline"` jobs are left untouched by the driver.
- `MOTHER_PIPELINE_CYCLE_CAP=N` — override the default cycle cap (default: 3) for pipeline jobs that do not set `pipeline.cycle_cap` themselves.
- `MOTHER_TEARDOWN_ENABLED=0` — disable worktree/container teardown entirely.
- `MOTHER_TEARDOWN_DOCKER_ENABLED=0` — skip the docker sweep, still tear down worktrees.
- `MOTHER_MIN_FREE_GB=N` — dispatch pauses (running jobs untouched) while the volume holding the next job's repo has less than N GB free (default: 20; `0` disables; also settable in `config.env`; published to `effective-config.json` as `min_free_gb`). Surfaces as a `low_disk` attention item (`$RUNNER_DIR/low-disk.json`) and triggers a rate-limited (`MOTHER_LOWDISK_GC_INTERVAL`, default 600s) `mother gc`.
- `MOTHER_GC_ENABLED=0` — disable `mother gc` in the hourly ride-along and the low-disk trigger (manual `mother gc` still works). `MOTHER_GOCACHE_MAX_GB=N` (default 10) caps the Go build cache `mother gc` will tolerate; `MOTHER_GC_TIMEOUT=N` (default 300) bounds a scheduled run.
- `MOTHER_TEARDOWN_MAX_DEFERRALS=N` — deferrals before a stalled teardown is flagged for attention (default: 30; never triggers deletion).
- `MOTHER_ARCHIVE_TIMEOUT=N` — seconds the hourly archive sweep gets before `_maybe_archive` kills it and moves on (default: 300). Not a behaviour toggle like the others above — it's a watchdog bound. `_loop` is single-threaded, so a wedged sweep (gh/docker/git stuck, a TCC prompt with no UI session to answer it, a shell-level pipe deadlock — see the resolved 2026-08-12 bug report) used to block every subsequent tick — dispatch, auto-resume, escalation, adherence, pipeline advancement, everything — forever, silently. Raise this if legitimate sweeps (many jobs, many `gh pr view` calls) routinely take longer than the default.
- `MOTHER_EVENTS_MAX_AGE_HOURS=N` — age floor (default: 6) for `mother events --since-cursor`, the query the `UserPromptSubmit` hook (`hooks/mother-inject.sh`) uses to inject a queue-update banner into interactive sessions. No event older than this is ever surfaced on the `--since-cursor` path, no matter how stale a syntactically valid cursor is. `0` disables the floor. Plain `mother events` and `mother events --since <ts>` are never floored. This is defense in depth on top of a hard contract in `cmd_events`: an unreadable or non-ISO session cursor (missing file, zero-byte, non-JSON, missing/`null` `.last_seen`, or a `.last_seen` that isn't an ISO-8601 instant) is always treated as a brand-new session — bootstrap the cursor to now, emit nothing — and must never degrade into a full-history replay of `$EVENTS_DIR` (which retains orphaned `.jsonl` files for long-archived jobs; see the resolved 2026-07-14 bug report).
- `MOTHER_RETENTION_SWEEP_ENABLED=0` — disable the orphaned atomic-write temp file sweep (reserved as the shared gate for future retention steps — see "Orphaned temp file sweep" below).
- `MOTHER_TEMP_ORPHAN_MINUTES=N` — age threshold in minutes before an orphaned `*.tmp.*` / `*.bak.*` state file is removed (default: 60). This gate is what prevents deleting an in-flight write's temp file out from under its own writer.
- `MOTHER_RWX_SANDBOX_ENABLED=0` — disable the RWX sandbox lifecycle (default: `1`). When a job's work_dir has `.rwx/sandbox.yml` and `rwx` is on PATH, `mother-run-job` runs `rwx sandbox reset` before the first spawn of each fresh attempt and `rwx sandbox stop` after every worker exit (`lib/rwx.sh`). Best-effort: failures, hangs and a missing CLI are events only (`rwx_sandbox_reset` / `rwx_sandbox_stop`) and never change the job's state or `failure_reason`. Repos without `.rwx/sandbox.yml` see no calls and no events.
- **RWX SIGKILL gap:** `_rwx_post_exit` covers normal exit, the EXIT trap, SIGTERM and SIGINT, but not a SIGKILLed `mother-run-job` (OOM, `kill -9`, host crash). `mother-runner`'s orphan reaper then calls the same best-effort stop for worktree-isolated jobs whose worktree still has `.rwx/sandbox.yml` (event `rwx_sandbox_stop`, `reason: "orphan"`). If the host itself dies, the sandbox bills until its own `--inactivity-timeout` (10m in admin-portal's `sandbox.yml`).
- `MOTHER_RWX_RESET_TIMEOUT=N` / `MOTHER_RWX_STOP_TIMEOUT=N` — watchdog seconds for the reset (default: 90) and stop (default: 60); on expiry the call is killed, the event says `outcome: "timeout"`, and the job proceeds.
- `MOTHER_WORKER_MCP_SCOPE=0` — restore the pre-cost-visibility behavior of every `claude` invocation loading the operator's full personal MCP config. Default `1`: workers, `review-phase`, and `adherence-review` all pass `--strict-mcp-config --mcp-config "$MOTHER_WORKER_MCP_CONFIG"` (default `templates/worker-mcp.json`, an empty allowlist). See "Bishop budget posture" section's sibling, the cost-visibility feature's CHANGELOG entry, for the measured before/after.
- `MOTHER_WORKER_MCP_CONFIG=PATH` — override the MCP allowlist file passed to every headless `claude` invocation. Put servers a background worker genuinely needs here; default is an empty `{"mcpServers": {}}`.
- `MOTHER_USAGE_CHECK_INTERVAL=N` — seconds between live usage/cost-cap checks in `mother-run-job`'s poll loop (default: 120).
- `MOTHER_TOKEN_ALERT_THRESHOLD=N` — cumulative token count (default: 100,000,000) that trips the sticky `token_alert_at` field and the statusline's `$!N` count.
- `MOTHER_COST_CAP_GRACE_SECONDS=N` — seconds a job with `max_cost_usd` set is given, after crossing the cap, for a cooperative `mother await` before the runner force-pauses it (default: 300).
- `MOTHER_FAILURE_ROUTING_ENABLED=0` — restore the pre-routing behavior: every `failed` job takes the legacy reconcile-then-escalate path in `_auto_escalate_failed`, regardless of `.failure_reason` (default: `1`).
- `MOTHER_REWORK_ADVANCE_CHECK_ENABLED=0` — disable `_verify_run_advanced_or_fail` (default: `1`), so a run that starts with an existing PR/pushed branch can report `succeeded` without pushing anything new.
- `MOTHER_ADHERENCE_EFFORT=<low|medium|high|xhigh|max>` — pass `--effort` to the adherence-review `claude` invocation. Unset (default) means no `--effort` flag, i.e. today's behavior.
- `MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS=N` — stalled passes before a `worktree_probe_failed` teardown is flagged (default: 2, about two hourly sweeps). Other stall reasons use `MOTHER_TEARDOWN_MAX_DEFERRALS`.
- `MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS=N` — days a teardown may wait on an open PR before it is listed under needs-attention (default: 7).
- `MOTHER_ATTENTION_INTERVAL=N` — seconds between daemon refreshes of `$MOTHER_ROOT/attention.json`, the file the statusline and `mother list` footer read (default: 60).
- `MOTHER_DEP_PR_POLL_INTERVAL=N` — seconds between re-checks of a `--depends-on` dependency's PR merge state (default: 120). `merged`/`closed` results are cached permanently; `open`/`unknown` are re-queried after this interval.
- `MOTHER_NOTIFY_ENABLED=0` — disable the `awaiting` push notifications (default: `1`).
- `MOTHER_NOTIFY_TRANSPORT=auto|terminal-notifier|osascript|command|none` — how pushes are delivered (default: `auto`).
- `MOTHER_NOTIFY_COMMAND=PATH` — program run as `PATH TITLE BODY JOB_ID` when the transport is `command` (the swap point for off-box delivery).
- `MOTHER_NOTIFY_SCAN_INTERVAL=N` — seconds between the daemon's awaiting scans (default: 60).
- `MOTHER_AWAITING_REMIND_HOURS=N` — reminder cadence for a job left `awaiting` (default: 24; open-ended).
- `MOTHER_SHARED_RATES_PATH=PATH` — destination `mother-usage publish-rates` writes the rate table to (default: `~/.claude/model-rates.json`), for Bishop or other tools to read the same per-model pricing Mother uses.

### Durable daemon config (`config.env`)

The launchd plist is re-rendered from `launchd/com.thehammer.mother.plist` on
every `mother daemon install`, so env vars hand-added to the installed plist are
lost. Durable settings (notably `MOTHER_CONCURRENCY`) live in
`$MOTHER_ROOT/config.env` instead — `KEY=VALUE` lines for `MOTHER_*` names,
parsed (never sourced) by `lib/config.sh`'s `mother_config_load`, which
`bin/mother-runner` calls before applying its defaults. Real env vars always win
over the file. `_daemon_install` first runs `mother_config_migrate_plist` to copy
the installed plist's `MOTHER_CONCURRENCY` into `config.env` (an existing file
value is only replaced by a higher plist value — a reinstall never lowers it).
The runner publishes the effective value and its source (`env` / `config file` /
`default`) to `runner/effective-config.json`; `mother status` and
`scripts/doctor.sh` display it.

### Orphaned temp file sweep

`_atomic_write` (`lib/state.sh`) and `mother_capture_rate_limits`
(`statusline/segment.sh`) both write state as `<target>.tmp.$$` then `mv` it
into place. If the writing process dies between the write and the `mv`
(killed mid-render, SIGKILL, crash), the temp file is orphaned — nothing else
ever removes it, and `~/.mother/` accumulates them indefinitely. `mother
prune-temps [--dry-run]` sweeps `$MOTHER_ROOT`, `$JOBS_DIR`, `$EVENTS_DIR`,
`$DRAFTS_DIR`, `$CURSORS_DIR`, `$RUNNER_DIR`, and `$TEARDOWN_DIR` (each
`-maxdepth 1`) for regular files matching `*.tmp.*` or `*.bak.*` older than
`MOTHER_TEMP_ORPHAN_MINUTES`. It never touches directories — `<target>.lockdir`
mutex directories (`_with_lock` in `lib/state.sh`) are a live concurrency
primitive owned by `_recover_stale_locks`, not this sweep. Both the bulk
`mother archive` sweep (every hourly run, just before its summary line) and
`mother-runner`'s daemon startup call `mother prune-temps`, so a
long-running daemon and a frequently-restarted one are both covered.

### Daemon process groups and launchd

Every process Mother spawns — the broker sidecar, each `mother-run-job`
supervisor, and the `claude` workers beneath them — shares the daemon's
process group ID. `nohup … & disown` in `mother-runner`'s `_spawn_job` /
`_start_broker` does **not** detach one: `disown` only drops the job from
the shell's job table, and neither it nor `nohup` calls `setpgid`/`setsid`.
What keeps live workers alive across a `mother daemon stop`, a daemon
crash, or a launchd `KeepAlive` respawn is the `AbandonProcessGroup`
`<true/>` key in `launchd/com.thehammer.mother.plist`; without it launchd
reaps the whole group when the tracked job exits (`launchd.plist(5)`
defaults it to false). The installed copy at
`~/Library/LaunchAgents/com.thehammer.mother.plist` is a separate
deployment — editing the template alone changes nothing until
`mother daemon install` re-renders it. `scripts/doctor.sh` warns when the
installed copy is missing the key.

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

**Metrics fields** on each `runs.jsonl` line:
- `posture_at_spawn` — posture level observed at Cody-spawn time.
- `posture_bias_applied` — action taken: `clamp`, `up1`, or `none`.
- `tokens_in` — total input tokens consumed by the worker transcript (sum of
  `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` across
  all assistant turns, de-duplicated by message id). JSON `null` when the
  transcript is unavailable or contains no assistant events.
- `tokens_out` — total output (generated) tokens across all assistant turns,
  de-duplicated by message id. JSON `null` when the transcript is unavailable.

## Failure routing and truthful terminal states

Three fixes make a job's terminal state mean what it says.

**Failure routing.** Escalating the model tier is wrong for most failures.
`mother-runner`'s `_auto_escalate_failed` now calls `mother route-failure <id>`
(internal subcommand, `lib/failure-route.sh`) for every `failed` job that has a
persisted `.failure_reason` and `.failure_routed != true`. Jobs that pre-date
`.failure_reason` keep the legacy reconcile-then-escalate path unchanged.

| reason | class | action |
|---|---|---|
| `no_pr_no_push` | `reconcile_then_hold` | `reconcile --auto`; if nothing adopted, hold (`unmerged_dependency` if a `depends_on` PR isn't merged, else `nothing_to_reconcile`). Never escalates. |
| `rework_no_new_commit` | `hold` | Hold immediately. Deliberately does **not** reconcile — that would adopt the stale PR and undo the rework-advance check. |
| `branch_create_failed`, `checkout_failed` | `hold` | Hold immediately; these fail identically every time (e.g. wrong `--base`). |
| `worktree_create_failed`, `runner_died_early`, `unspecified`, empty | `retry_once` | One as-is retry (no tier bump, adherence state untouched, a consumed operator answer is replayed), then hold `retry_exhausted`. |
| anything else | `escalate` | Reconcile, then escalate if `escalation_count < 2`; otherwise stay `failed` with `failure_routed: true`. |

**Hold** = `state: awaiting`, `activity: operator_hold`, `paused_reason:
operator_hold`, `.question` naming the concrete commands, and an
`operator_hold` object. It is non-terminal, so teardown never touches the
worktree holding the unpushed work. `mother resume`, `mother retry`,
`mother reconcile`, and `mother cancel` all accept a held job (other
`awaiting` sub-states are still refused by `retry`/`reconcile`);
`mother status` shows `[OPERATOR-HOLD]`.

**Rework-advance check.** `_capture_run_baseline` snapshots, before the worker
spawns, whether an OPEN PR or a pushed origin branch already exists.
`_verify_run_advanced_or_fail` (first step of `_verify_artifact_or_fail`, after
the `no_pr` branch) then requires the run to have moved it: a different final
`pr_url`, or a changed `git ls-remote` tip of the PR's head branch. Otherwise
the job fails `rework_no_new_commit` (`.pr_url` is not cleared; an unreachable
origin fails closed with `origin_check: "indeterminate"`). No-op for pipeline
jobs, `no_pr` jobs, and runs that started without a pre-existing artifact.

**Auto-stash restore.** `lib/autostash.sh`'s `mother_autostash_restore` is the
single implementation of putting a main-dir job's `mother:auto-stash:<id>` back.
`_restore_auto_stash` (`mother-run-job`) runs it on the post-run path, on the
`checkout_failed`/`branch_create_failed` early exits, and from the EXIT trap
via `_exit_cleanup_workspace` — always **before** releasing the workspace lock.
`mother-runner`'s orphan reaper restores for a SIGKILLed supervisor unless
another main-dir job is running in the same repo (then it emits
`auto_stash_restore_deferred`).

| Event | Detail fields | When emitted |
|---|---|---|
| `failure_routed` | `{action: reconciled\|retried_as_is\|escalated\|held\|left_failed, ...}` | Once per routing decision |
| `held_for_operator` | `{failure_reason, sub_reason, detail}` | A job is put in `operator_hold` (alongside `awaiting_input`) |
| `rework_advance_verified` | `{remote_ref, remote_sha_at_start, remote_sha_at_end}` | A run that began with an artifact advanced it |
| `auto_stash_not_found` | `{stash_message}` | Marker existed but no matching stash |
| `auto_stash_restore_deferred` | `{stash_message, conflicting_job_id}` | Orphan reaper couldn't safely restore |

## Operator attention and notifications

What the operator is told, and when, has to be trustworthy: a signal that
cries wolf trains them to ignore it, and one that never fires leaves real
problems sitting for days.

**One needs-attention list, three renderers.** `lib/attention.sh`'s
`mother_attention_items` builds a JSON array of `{kind, job_id, repo, branch,
reason, since, detail, hint}` from local state only (`$JOBS_DIR`,
`$TEARDOWN_DIR`, local `git`) — it **never calls `gh`**, because it runs on the
status/statusline hot path. Anything needing GitHub data is computed by the
hourly teardown sweep or the dependency poller and stored where it can read it.
Kinds: `teardown_stalled`, `pr_open_stale`, `dependency_blocked`,
`teardown_residue` (a worktree directory teardown could not fully remove; record in `$RESIDUE_DIR`), `low_disk` (dispatch paused, see `MOTHER_MIN_FREE_GB`), `auto_stash_unrestored` (a `mother:auto-stash:<id>` git stash whose job is no
longer running/ready/awaiting — display only, nothing is ever popped),
`job_flagged` (a job carrying the `needs_attention` field), and
`plugin_cache_stale`. `mother_attention_write` publishes the list atomically to
`$MOTHER_ROOT/attention.json` (always valid JSON). Renderers: `mother status`
with no id (queue overview, awaiting jobs, needs-attention section;
`--format json` emits `{counts, awaiting, needs_attention}`), a one-line
`⚑ N item(s) need attention` footer on `mother list`, and the statusline's 6th
cache field `ATTENTION` (rendered `⚑N`). The daemon refreshes the file every
`MOTHER_ATTENTION_INTERVAL` seconds. External consumers of the statusline cache
must read 6 colon-separated fields.

**Merge-gated `--depends-on`.** `_promote_ready` (`lib/state.sh`) releases a
`queued` job only when `_dep_gate` says every dependency is `satisfied`:
`succeeded` **and** its PR merged (or a `no_pr` job). Gate results are
`satisfied`, `wait:<reason>` (dependency still in flight, PR open, `gh`
inconclusive) or `blocked:<reason>` (failed / cancelled / missing dependency,
PR closed unmerged, no PR url). PR state is cached in
`$RUNNER_DIR/dep-pr-cache/` (`merged`/`closed` forever; `open`/`unknown` for
`MOTHER_DEP_PR_POLL_INTERVAL`). Blocked dependents stay `queued` — Mother never
auto-cancels them — and `mother force-start <id>` bypasses the gate. Events:
`dependency_waiting`, `dependency_blocked` (both only on change) and
`dependency_satisfied`. `mother retry`'s own ready/queued decision is unchanged.

**Awaiting pushes.** `_notify_awaiting` (`bin/mother-runner`) pushes one
notification when a job first enters `awaiting` for a non-`quota_*` reason
(quota pauses auto-resume), a reminder at 24h, then one a day for as long as it
sits there. If more than 3 pushes are due in one scan they are coalesced into a
single summary push. State lives in the job's `awaiting_notify` field; each
push emits `awaiting_notified {kind, count, transport, ok}`; `last_notified_at`
advances even when the transport fails so a broken notifier can't storm.
`lib/notify.sh`'s `mother_notify` picks the transport (`MOTHER_NOTIFY_TRANSPORT`);
every transport is time-bounded and worker-authored text reaches `osascript`
only as argv. **Permanent boundary:** `_notify_awaiting` may only write
`.awaiting_notify` and append `awaiting_notified` events — Mother must never
auto-cancel, auto-resume, auto-answer or auto-rework an unanswered `awaiting`
job. Push is reserved for `awaiting`; everything else is attention-list and
statusline only.

**The hook reads from the daemon's CLI.** `hooks/mother-inject.sh` resolves
the CLI as `$MOTHER_CLI`, then the path `mother-runner` publishes to
`$RUNNER_DIR/cli-path` at startup, then `$CLAUDE_PLUGIN_ROOT/bin/mother`, then
`$PATH`. The daemon's copy wins because the events on disk are written by its
code; a plugin cache installed months ago (before the cursor fixes) once
replayed every archived job's events as live failures. As defence in depth the
hook also drops any event older than `MOTHER_EVENTS_MAX_AGE_HOURS` (default 6,
`0` disables) before its kind filter. `scripts/doctor.sh` and the
`plugin_cache_stale` attention item flag a plugin cache that differs from the
checkout; plugin versions are bumped so `claude plugin update` refreshes it.


## Internals reference (lazy-loaded)

Resource teardown (worktrees/containers), PR detection (`lib/prdetect.sh`,
`mother reconcile`), pipeline visibility (W5) and resume-answer continuity are
documented in the `mother-internals` skill (`.claude/skills/mother-internals/`).
Load it before changing `lib/teardown.sh`, `lib/prdetect.sh`, or pipeline cycle output.
