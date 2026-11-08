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

## State safety (never destroy the live tree)

Mother's state tree (`~/.mother`: jobs, events, archive) is irreplaceable; on 2026-10-17 a stray
`rm -rf "$MOTHER_ROOT"` in a test teardown deleted all of it. Rules for anyone touching this repo:

- **Never `pkill`/`killall`/`kill` by pattern.** Other workers run bats concurrently on this machine.
  Kill only a process you started, by exact pid or background task id.
- **Tests must never use the real `~/.mother`.** Every bats file uses `setup_mother_env` /
  `teardown_mother_env` (temp `MOTHER_ROOT`, `MOTHER_TEST_ROOT=1`, `MOTHER_LIVE_ROOT` unset). Never
  point a test at `$HOME/.mother` or an inherited root.
- **Every recursive directory delete goes through `safe_rm_tree`** (`lib/safe-rm.sh`). It refuses
  `""`, `/`, `$HOME` and anything that is or contains a `.mother-live` marker. Don't add a bare
  `rm -rf <dir>` in `bin/` or `lib/`; file-level `rm -f` is fine.
- **Workers get `MOTHER_LIVE_ROOT`, not `MOTHER_ROOT`.** Resolve the root as
  `${MOTHER_ROOT:-${MOTHER_LIVE_ROOT:-$HOME/.mother}}` in any new entry point.
- **CI:** `.github/workflows/test.yml` runs with `MOTHER_ROOT=/nonexistent-guard` and fails if `~/.mother` or that
  path ever exists (see "Tests").
- **Backups:** the runner writes `mother-state-<UTC>.tar.gz` (plus a separate `mother-archive-<UTC>.tar.gz` for
  `archive/`) at most every `MOTHER_BACKUP_INTERVAL` (3600s) outside the tree, skipping when nothing changed;
  `mother backup now|list|restore`. See `docs/design.md` "State safety".
  **Restore gap:** archiving moves jobs from `jobs/` into `archive/`. A job archived after the last archive tarball (up to 24h under `--auto`) is in neither the newest state backup nor its paired archive, so restoring the newest backup drops it; an older retained backup (dailies, up to 14 days) still has it. `mother backup restore` prints a `note:` when the paired archive tarball is more than 1h older than the state backup, and `mother doctor` shows the newest archive tarball's age.

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
| `adherence_reviewed_sha` / `adherence_sha_runs` | string / int | Loop guard. The PR head SHA at the last adherence-review spawn (`unknown` when `gh` couldn't say) and how many reviews have been spawned on it. A passed head is never re-reviewed; past `MOTHER_ADHERENCE_MAX_RUNS_PER_SHA` the runner stops, emits `adherence_capped` and sets `needs_attention.reason = adherence_loop_capped`. A new head resets the count; `retry`/`escalate`/`reconcile` reset it too. |
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
| `not_before` | int\|null | Epoch seconds. A `ready` job with `not_before` in the future is not dispatched (`mother list` shows `[BACKOFF 2m]`). Set by `route-failure` for `backoff`; cleared by `resume`, `retry`, `escalate` by a successful end of a run, and by a run that gets `MOTHER_BACKOFF_CLEAR_TURNS` (5) real assistant turns through. A value further than `MOTHER_BACKOFF_RETRY_AFTER_MAX_S` (3600) in the future is treated as expired. |
| `backoff_count` / `backoff_first_at` | int\|null / int\|null | Rate-limit backoffs so far and the epoch of the first (kept across backoffs; the 15-minute give-up is measured from it). Cleared with `not_before`. Never touch `current_tier`, `escalation_count`, `retry_count` or `auto_retry_count`. |
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
| `running` | (`limiter_hold` field) | L4: Cody is running but the limiter wants the job held; it stops at its next boundary (see "Boundary holds"). `activity` is unchanged; `mother list` shows `[HELD]` |
| `running` | `cody_rework` | Cody running (second attempt, after adherence fail) |
| `running` | `continuation` | Cody re-running after idle_timeout (auto-continuation) |
| `awaiting` | (none) | Cody asked a question; answer with `mother resume` |
| `awaiting` | `adherence_blocked` | Archie failed twice; human must review PR, then `resume` or `cancel` |
| `running` | `gating` | Mother is running the repo's quality gates on the head commit; the previous `activity` is restored afterwards |
| `running` | `gate_fix` | enforce mode: the worker's same session (`--resume`) is fixing red blocking gates (attempt n/N); `mother list` shows `[GATES-FIXING]` |
| `running` | `review_wave` | HC-14: adherence and the selected lenses are reviewing the gated commit (before `gh pr ready`) |
| `running` | `review_rework` | HC-14: the worker's same session (`--resume`) is addressing blocking wave findings (cycle n of `cycle_cap`) |
| `awaiting` | `review_hold` | HC-14: a human-blocking finding, a lens error, a second adherence fail or the wave cycle cap; `paused_reason: review_hold`, a `review_hold` decision (`resume_with_guidance`, `override_open`, `cancel`) and `decision_awaiting` attention |
| `awaiting` | `gate_hold` | enforce mode: blocking gates still red after `max_attempts`; `paused_reason: gate_hold`, a `gate_hold` decision and `decision_awaiting` attention. Answer with `mother resume <id> "<guidance>"` or `--option escalate\|override_open\|cancel`; `mother status` shows `[GATES-HELD]` |
| `awaiting` | `limiter_hold` | L4: the job's boundary hold outlasted `MOTHER_LIMITER_HOLD_GRACE_S` with a quiet log (or at a phase boundary) and the worker was stopped; `paused_reason: limiter_hold`. Mother resumes it by itself (with its session) once the limiter admits it; no push notification. `mother resume` works too |
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
| `base_sha` | string | Commit SHA of `base_ref` resolved at `mother add` (absent/null if it didn't resolve). `base_ref` is a moving remote-tracking ref (a fix-up job pushes to the branch it is based on), so every LOCAL diff consumer — wave changed files/patch, `--pre-ready` review, commits-ahead checks, gate `when` scopes, PR-detection candidate ranges — compares against `base_sha` via `mother_job_diff_base` (`lib/state.sh`) / `_diff_base` (`mother-run-job`), falling back to `base_ref` for older jobs. `mother-run-job` re-snapshots it to the new branch point only when it creates the job branch/worktree; resume/rework keep it. Worktree creation and PR targeting still use `base_ref`. Shown by `mother status`/`peek`. |
| `continuation_count` | int | Number of auto-continuation attempts so far. Incremented each time an `idle_timeout` triggers a re-queue. |
| `pipeline.review_cycle` | int | Number of review cycles completed so far (0-indexed). Incremented once per continue-cycle. Surfaced by W5 as `review_cycle_count`. |
| `expect_branch_mismatch` | bool | Set by `expect_branch_mismatch: true` in the plan YAML block, or `mother add --expect-branch-mismatch`. Declares that the worker is deliberately targeting a branch other than the assigned one (e.g. landing more commits on an existing open PR) — a mismatching PR head branch is accepted without the commit-containment check. Default `false`. |
| `actual_branch` | string | Set when the captured/accepted PR's head branch differs from the job's assigned `branch` (a branch-name mismatch that PR detection accepted via `expect_branch_mismatch` or commit-containment, or that `mother reconcile` adopted). Absent when the PR's head branch matches `branch`. |
| `resume_not_yet_acted_on` | bool | Sticky audit flag. Set when an idle-timeout continuation is queued for a job that was resumed with an operator answer but has no commit postdating that resume. Never cleared automatically; surfaced by `mother status` as `[RESUME-MAY-BE-UNAPPLIED]`. |
| `dep_wait` | object | Set on a `queued` job that isn't promotable yet: `{dep_id, status: "wait"\|"blocked", reason, pr_url, checked_at}` for the first unsatisfied dependency. Written only when `dep_id`/`status`/`reason` change. Cleared on promotion. `blocked` (dependency failed/cancelled/missing, PR closed unmerged, no PR url) never auto-cancels the job; it appears under needs-attention and `mother force-start <id>` releases it. |
| `awaiting_notify` | object | `{episode, first_seen_at, count, last_notified_at}` — the push-notification bookkeeping for an `awaiting` job (see "Operator attention and notifications"). Cleared when the job leaves `awaiting`. |
| `needs_attention` | object | Producer-agnostic flag `{reason, note, since}`. Anything that holds a job for the operator sets it; Mother renders it as a `job_flagged` needs-attention item. This repo adds no producer. |
| `origin` | object | Provenance captured at `mother add` time: `{project, cwd, session, enqueued_by, label, focus?, focus_name?}`. `project` = basename of the enqueuing cwd's git toplevel, or the `--origin-project` override; `session` = `--origin-session` → `$MOTHER_ORIGIN_SESSION` → `$CLAUDE_SESSION_ID` → `""`. `focus` (Nostromo focus tag, `[A-Za-z0-9._-]{1,128}`, invalid values dropped with a warning) = `--origin-focus` → `$MOTHER_ORIGIN_FOCUS` → `$NOSTROMO_FOCUS_TAG` → `$NOSTROMO_PTY_ID`; `focus_name` (cleaned, ≤120 chars) = `--origin-focus-name` → `$MOTHER_ORIGIN_FOCUS_NAME`, stored only when a focus is. Both keys are absent when unset; archived jobs lose `origin_focus`. `mother events` adds `origin_focus` to each event of a job with a focus, and the hook skips the current focus's own jobs. Surfaced as `mother list`'s ORIGIN column, filtered by `mother list --project`/`--label`, and rendered by `mother status`'s `=== origin ===` block. |
| `decision` | object | Structured hold: `{id, kind, options[{id,label,consequence,takes_text}], opened_at, resolved_at, resolution{option,source,session,agent}}` (`lib/decision.sh`; option ids `resume_with_guidance`, `escalate`, `override_open`, `cancel`). Opened by a hold producer via `mother_decision_open`; resolved only by an explicit answer — Mother never selects an option (no timeout, no default). A resolved decision blocks answers only while `paused_reason == decision.kind`. |
| `crew` | object | Resolved `.mother/crew.yml` snapshot taken at `mother add` (see "Quality gates"). Absent when the repo has no crew.yml: such a job, and any job enqueued before the snapshot existed, never runs gates. |
| `gates` | object | Gate outcome written by `mother-run-job`'s `_gates_run_attempt`: `{mode, effective_mode, posture, status, attempt, max_attempts, head_sha, started_at, finished_at, results[{name, result, blocking, duration_s, exit_code, unavailable_reason, skip_reason}], not_run[]}`, plus in enforce mode `budget_reset_by` (`resume`/`escalate`) and, after `override_open`, `status: "overridden"` and `override {at, source, red[]}`. Ids, enums, counts and durations only (no output text); `effective_mode` is `enforce` only for non-pipeline jobs in an enforce repo. |
| `attention` | array | Typed attention `[{reason, since}]` (`lib/state.sh` `mother_job_attention_add/drop`). HC-08 adds `gates_incomplete` and `decision_awaiting`; resolving a decision option drops `decision_awaiting`. |
| `resume_session_id` | string | Set by the `gate_hold` `resume_with_guidance` hook. The next run resumes that session (`--resume`) with `pending_answer` as its prompt (fresh fallback if it can't), then clears it. |
| `review_wave` | object | HC-14, written by `mother-run-job`'s `_run_review_wave`: `{mode, cycle, cycle_cap, status: running\|shipped\|held\|observed\|overridden\|stopped, decision, budget_usd, spent_usd, over_budget, head_sha, posture, pending_reviewers[], lenses[{reviewer, lens, state: pending\|running\|done\|skipped\|error, skip_reason, findings{blocking, advisory}, cost_usd, examined_files, budget_usd, refuted}], adherence{state, verdict, cost_usd}, coverage_gaps, claims{verified, refuted, unverified}, cycles[{cycle, reviewers, pending_reviewers, decision}]}`. States, counts and costs only: finding text, claim quotes and adherence notes stay in `$MOTHER_ROOT/crew/<id>/wave/c<N>/` and `crew/<id>/adherence/c<N>.json`. `spent_usd` (lens spend), `cycle` numbering and `cycles` carry over across runs; the cycle cap is per run. |
| `last_answer` | object | `{source, session, agent, option, at}` of the most recent `mother resume` / broker `answer`. `source` is `nostromo_app`, `cli` or `broker_client`; `option` is null for a plain-text answer to a decision-less job. |

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
- `MOTHER_TM_EXCLUDE_WORKTREES=0` — disable the sticky Time Machine exclusion (`tmutil addexclusion`, no `-p`, no sudo) `mother-run-job` applies to a new job worktree and its `$MOTHER_ROOT/tmp/<id>` scratch dir (default: `1`; never the main checkout; best-effort, event `tm_excluded`). It keeps churn out of backups but does not stop local snapshots pinning deleted worktrees, hence the next knob. Stopgap until the cluster moves worktrees off the laptop.
- `MOTHER_SNAPSHOT_THIN_BELOW_GB=N` — below N GB free (default: 40; `0` disables) the runner's disk check (`_disk_check` → `_maybe_snapshot_thin`) thins Time Machine local snapshots in the background (`tmutil thinlocalsnapshots / 999999999999 4`; never `deletelocalsnapshots`), at most every `MOTHER_SNAPSHOT_THIN_INTERVAL` (1800s; failures back off to it) under a `MOTHER_SNAPSHOT_THIN_TIMEOUT` (120s) watchdog, never blocking dispatch. Outcome in `$RUNNER_DIR/snapshot-thin.json`, the runner log and `mother status` ("Last snapshot thin"). Why: snapshots are whole-volume and pin deleted worktrees (2026-11-07: ~150 GB → 12 GB free in a day at 5-wide; one thin freed ~119 GB). Separate from, and higher than, `MOTHER_MIN_FREE_GB` (the dispatch pause). Stopgap until the cluster.
- `MOTHER_GC_ENABLED=0` — disable `mother gc` in the hourly ride-along and the low-disk trigger (manual `mother gc` still works). `MOTHER_GOCACHE_MAX_GB=N` (default 10) caps the Go build cache `mother gc` will tolerate; `MOTHER_GC_TIMEOUT=N` (default 300) bounds a scheduled run.
- `MOTHER_TEARDOWN_MAX_DEFERRALS=N` — deferrals before a stalled teardown is flagged for attention (default: 30; never triggers deletion).
- `MOTHER_ARCHIVE_TIMEOUT=N` — seconds the hourly archive sweep gets before `_maybe_archive` kills it and moves on (default: 300). Not a behaviour toggle like the others above — it's a watchdog bound. `_loop` is single-threaded, so a wedged sweep (gh/docker/git stuck, a TCC prompt with no UI session to answer it, a shell-level pipe deadlock — see the resolved 2026-08-12 bug report) used to block every subsequent tick — dispatch, auto-resume, escalation, adherence, pipeline advancement, everything — forever, silently. Raise this if legitimate sweeps (many jobs, many `gh pr view` calls) routinely take longer than the default.
- `MOTHER_EVENTS_MAX_AGE_HOURS=N` — age floor (default: 6) for `mother events --since-cursor`, the query the `UserPromptSubmit` hook (`hooks/mother-inject.sh`) uses to inject a queue-update banner into interactive sessions. No event older than this is ever surfaced on the `--since-cursor` path, no matter how stale a syntactically valid cursor is. `0` disables the floor. Plain `mother events` and `mother events --since <ts>` are never floored. This is defense in depth on top of a hard contract in `cmd_events`: an unreadable or non-ISO session cursor (missing file, zero-byte, non-JSON, missing/`null` `.last_seen`, or a `.last_seen` that isn't an ISO-8601 instant) is always treated as a brand-new session — bootstrap the cursor to now, emit nothing — and must never degrade into a full-history replay of `$EVENTS_DIR` (which retains orphaned `.jsonl` files for long-archived jobs; see the resolved 2026-07-14 bug report).
- `MOTHER_RETENTION_SWEEP_ENABLED=0` — disable the orphaned atomic-write temp file sweep (reserved as the shared gate for future retention steps — see "Orphaned temp file sweep" below).
- `MOTHER_TEMP_ORPHAN_MINUTES=N` — age threshold in minutes before an orphaned `*.tmp.*` / `*.bak.*` state file is removed (default: 60). This gate is what prevents deleting an in-flight write's temp file out from under its own writer.
- `MOTHER_BACKUP_ENABLED=0` — disable the runner's periodic state-tree backup (default: `1`). `MOTHER_BACKUP_INTERVAL=N` (default 3600), `MOTHER_BACKUP_TIMEOUT=N` (watchdog, default 300), `MOTHER_BACKUP_DIR=PATH` (default `~/Library/Application Support/Mother/backups` on macOS, `${XDG_STATE_HOME:-~/.local/state}/mother/backups` elsewhere; refused when inside `$MOTHER_ROOT`), `MOTHER_BACKUP_KEEP_HOURS=N` (12) / `MOTHER_BACKUP_KEEP_DAYS=N` (14) retention, `MOTHER_BACKUP_LOGS=1` to include `logs/`. The runner calls `mother backup now --auto`, which skips the state tarball when the change fingerprint (`$RUNNER_DIR/last-backup.sig`) is unchanged, unless the newest one is older than `MOTHER_BACKUP_MAX_AGE` (21600s; `0` = never skip). `archive/` is backed up separately, only when it changed and at most every `MOTHER_BACKUP_ARCHIVE_INTERVAL` (86400s). `mother doctor` / `mother backup list --summary` warn when backups exceed `MOTHER_BACKUP_WARN_GB` (5).
- `MOTHER_RWX_SANDBOX_ENABLED=0` — disable the RWX sandbox lifecycle (default: `1`). When a job's work_dir has `.rwx/sandbox.yml` and `rwx` is on PATH, `mother-run-job` runs `rwx sandbox reset` before the first spawn of each fresh attempt and `rwx sandbox stop` after every worker exit (`lib/rwx.sh`). Best-effort: failures, hangs and a missing CLI are events only (`rwx_sandbox_reset` / `rwx_sandbox_stop`) and never change the job's state or `failure_reason`. Repos without `.rwx/sandbox.yml` see no calls and no events.
- **RWX SIGKILL gap:** `_rwx_post_exit` covers normal exit, the EXIT trap, SIGTERM and SIGINT, but not a SIGKILLed `mother-run-job` (OOM, `kill -9`, host crash). `mother-runner`'s orphan reaper then calls the same best-effort stop for worktree-isolated jobs whose worktree still has `.rwx/sandbox.yml` (event `rwx_sandbox_stop`, `reason: "orphan"`). If the host itself dies, the sandbox bills until its own `--inactivity-timeout` (10m in admin-portal's `sandbox.yml`).
- `MOTHER_RWX_RESET_TIMEOUT=N` / `MOTHER_RWX_STOP_TIMEOUT=N` — watchdog seconds for the reset (default: 90) and stop (default: 60); on expiry the call is killed, the event says `outcome: "timeout"`, and the job proceeds.
- `MOTHER_WORKER_MCP_SCOPE=0` — restore the pre-cost-visibility behavior of every `claude` invocation loading the operator's full personal MCP config. Default `1`: workers, `review-phase`, and `adherence-review` all pass `--strict-mcp-config --mcp-config "$MOTHER_WORKER_MCP_CONFIG"` (default `templates/worker-mcp.json`, an empty allowlist). See "Bishop budget posture" section's sibling, the cost-visibility feature's CHANGELOG entry, for the measured before/after.
- `MOTHER_WORKER_MCP_CONFIG=PATH` — override the MCP allowlist file passed to every headless `claude` invocation. Put servers a background worker genuinely needs here; default is an empty `{"mcpServers": {}}`.
- `MOTHER_USAGE_CHECK_INTERVAL=N` — seconds between live usage/cost-cap checks in `mother-run-job`'s poll loop (default: 120).
- `MOTHER_TOKEN_ALERT_THRESHOLD=N` — cumulative token count (default: 100,000,000) that trips the sticky `token_alert_at` field and the statusline's `$!N` count.
- `MOTHER_COST_CAP_GRACE_SECONDS=N` — seconds a job with `max_cost_usd` set is given, after crossing the cap, for a cooperative `mother await` before the runner force-pauses it (default: 300).
- `MOTHER_FAILURE_ROUTING_ENABLED=0` — restore the pre-routing behavior: every `failed` job takes the legacy reconcile-then-escalate path in `_auto_escalate_failed`, regardless of `.failure_reason` (default: `1`).
- `MOTHER_BACKOFF_ENABLED=0` — restore the pre-backoff routing: `rate_limited`, `api_overloaded`, `billing` and `auth_error` all take the `escalate` class again, and the dispatcher/reviewers ignore `$MOTHER_ROOT/ratelimit-until` (default: `1`). Tuning: `MOTHER_BACKOFF_BASE_S` (30), `MOTHER_BACKOFF_CAP_S` (300), `MOTHER_BACKOFF_JITTER_PCT` (20), `MOTHER_BACKOFF_MAX_S` (900, the give-up point and the longest a reviewer waits on the pause), `MOTHER_BACKOFF_RETRY_AFTER_MAX_S` (3600, clamps a server-given retry-after), `MOTHER_REVIEW_RATELIMIT_RETRIES` (2). See "Rate-limit backoff" below.
- `MOTHER_REWORK_ADVANCE_CHECK_ENABLED=0` — disable `_verify_run_advanced_or_fail` (default: `1`), so a run that starts with an existing PR/pushed branch can report `succeeded` without pushing anything new.
- `MOTHER_ADHERENCE_MAX_RUNS_PER_SHA=N` — adherence review spawns per job per PR head SHA before the runner flags the job for attention instead of looping (default: 3). `MOTHER_ADHERENCE_LOOP_THRESHOLD=N` (default 5) — reviews per hour on one job above which the `adherence_loop` needs-attention item / `mother doctor` warning appears.
- `MOTHER_LENSES_ENABLED=0` — disable the HC-14 review wave: jobs with a `lenses` crew section behave as repos without one (gates, then `gh pr ready`, then post-PR adherence).
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
- `MOTHER_PROGRESS_ENABLED=0` — disable the progress indicator entirely (default: `1`): `mother-usage progress-tick`/`calibrate` do nothing, and `mother list`/`status` ignore progress files, so displays look as before. See "Progress indicator" below. `MOTHER_PROGRESS_INTERVAL=N` (default 30) is the tick cadence; `MOTHER_PROGRESS_CALIBRATE_INTERVAL=N` (default: `MOTHER_ARCHIVE_INTERVAL`, 3600) the calibration cadence; `MOTHER_PROGRESS_TIMEOUT=N` (default 60) the watchdog on each.

- `MOTHER_NOTIFY_SUPPRESS_WHEN_CLIENT=1` — opt in to skipping awaiting pushes while a broker client subscribed to `await` (Nostromo) is connected (default: `0`, always push). Opt-in because an `await` subscription doesn't mean the client shows notifications: Nostromo subscribes but shows none today, so suppressing by default silenced Mother whenever Nostromo was open. To be replaced by an explicit `notify` surface registration (see "Operator attention and notifications").
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

The suite is the Go broker tests plus the bats files in `plugins/mother/tests/`. **The full suite runs in
CI** (`.github/workflows/test.yml`) on every PR and every push to `main`; `ci-ok` is the required check.
Workers and reviewers do **not** run the full suite locally: run only the files covering your change, push,
and don't wait for CI before your final result (the required check is the merge gate). Reviewers read
`gh pr checks <pr>`. The operator may still run the whole thing.

```bash
# targeted local run (always rebuilds the broker first; no Go half)
./plugins/mother/scripts/run-tests.sh plugins/mother/tests/<file>.bats [more.bats ...]
./plugins/mother/scripts/run-tests.sh                  # everything: Go half + all bats; both always run
./plugins/mother/scripts/run-tests.sh --go-only        # gofmt, go vet (native + GOOS=darwin), build, go test
./plugins/mother/scripts/run-tests.sh --shard 2/5      # what a CI shard runs
```

Requires `bats` (`brew install bats-core`) and Go (version in `plugins/mother/broker/.tool-versions`), plus
`pip install -r plugins/mother/requirements-ci.txt` (PyYAML) if your Python lacks it. A Go failure no longer hides
the bats result: with no args both halves run and the script prints `go: PASS|FAIL` / `bats: PASS|FAIL`.

- **ThreatDown:** `broker.bats` and `contract.bats` run Python socket clients, which ThreatDown has flagged
  ("Reverse Shell via Python", and the alert emails other people). Prefer CI for those two files.
- **Sharding:** CI runs `SHARDS` (workflow env, currently 5 = the macOS concurrency cap on the Free plan)
  `bats` shards on `macos-15`. `scripts/test-shards.sh` assigns each top-level `tests/*.bats` file to a shard by
  greedy longest-processing-time over `tests/shard-weights.tsv` (per-file seconds); a file with no weight gets the
  median, so new test files are picked up automatically. The `shard-plan` job fails if a file is in no shard or two
  shards, or a `*.bats` file sits in a subdirectory (bats would silently skip it). Refresh weights from a CI run:
  `gh run download <run-id> -p 'bats-timings-*' -D /tmp/t && plugins/mother/scripts/test-shards.sh weights /tmp/t`.
  `MOTHER_TEST_LANES=2` runs two file lists concurrently inside a shard.
- **Quarantine:** `tests/quarantine.tsv` lists known-flaky tests (`target<TAB>name<TAB>issue URL<TAB>note`; target is
  a bats file or `go`). A quarantined test that fails is re-run once, alone; passing on retry keeps the shard
  green but emits a `::warning::` and a step-summary line. Failing twice is red. Any non-quarantined failure is red
  immediately. Quarantined tests are never skipped, and nothing retries a whole file or suite. Every row needs an
  open `flaky-test` issue; remove the row when the issue is fixed (20 consecutive `main` runs with no warning).
- **Strict skips:** CI sets `MOTHER_TEST_STRICT_SKIPS=1`: a TAP `# skip` fails the shard unless the test is listed in
  `tests/ci-allowed-skips.tsv` (`file<TAB>name<TAB>reason`), so a missing tool or failed broker build can't hide as a
  skip. Locally skips stay allowed.
- **CI never touches `~/.mother`:** the workflow sets `MOTHER_ROOT=/nonexistent-guard`, never sets
  `MOTHER_LIVE_ROOT`, and each shard fails if `~/.mother` or the guard path exists before or after the run.
- **Limiter is off in the harness by default:** `setup_mother_env` exports `MOTHER_LIMITER_MODE=off`, so the runner
  does not run a python limiter tick every 10 s (and jobs get no hold-hook settings) inside timing-sensitive tests
  (`review_wave`, `pipeline_driver`). A test of the limiter itself opts back in with `unset MOTHER_LIMITER_MODE`
  after `setup_mother_env` (`limiter_*.bats`, `contract.bats`) and then sets the mode it needs via `mode.json`.

## Bishop budget posture

Mother consumes `~/.claude/budget-posture.json`, produced by Bishop
(`~/.local/bin/bishop`, source at `~/Code/bishop/`). Bishop computes a
"budget posture" from Claude Code's rolling 5-hour and 7-day quota windows and
writes the result to that file. Mother reads posture at Cody-spawn time and at
adherence-review time to bias the model/effort tier.

**Kill switch:** set `MOTHER_POSTURE_ENABLED=0` (in the launchd plist or shell
environment) to disable posture bias entirely. The default is `1` (enabled).

**Label mapping.** Bishop prints five labels (since bishop `508fe2a`, 2026-05-16); `_normalize_posture`
(`lib/state.sh`) is the one boundary that maps them to Mother's internal four (case-insensitive, whitespace trimmed
and squashed): `Pump the brakes` -> `conservative`, `Ease up` -> `normal`, `Cruise` -> `normal`, `Push` -> `elevated`,
`Put the hammer down` -> `flush`; the four legacy labels map to themselves. `Ease up` is `normal` deliberately:
Bishop's own text for it is only "consider lighter model selection", while `conservative` also clamps to tier_0,
skips non-mandatory lenses and limits enforce gates to one attempt; to reverse, move `"ease up"` into the
conservative arm of `_normalize_posture`. Empty input -> `normal` silently; any other unrecognized value -> `normal`
plus one stderr line (`mother: unrecognized bishop posture "<label>"; treating as normal`, control characters and ANSI
escapes stripped, 40 characters max). `tests/posture.bats` checks the vendored vocabulary
(`tests/fixtures/bishop-posture-labels.txt`) in CI and has a local-only canary against the real `bishop`.

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
| `rate_limited`, `api_overloaded` | `backoff` | Never reconciles, never escalates. Back to `ready`/`queued` at the **same** tier with `.not_before` = now + delay (`retry-after`, else 30 s doubling, cap 300 s, +<=20% jitter); `backoff_count` +1; event `failure_routed {action: backed_off, reason, delay_s, backoff_count}`. `rate_limited` also extends `$MOTHER_ROOT/ratelimit-until`. Past `MOTHER_BACKOFF_MAX_S` since `backoff_first_at`: hold `backoff_exhausted`. |
| `billing`, `auth_error` | `hold` | Hold immediately (an operator must fix the account); never reconciles or escalates. |
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

### Rate-limit backoff

`lib/backoff.sh` holds the primitives; `mother route-failure`'s `_rf_backoff` applies them. `mother-usage classify-exit`
maps a result event's `api_error_status` to a reason (429 `rate_limited`; 529/503/other 5xx `api_overloaded`; 402 or a
billing body `billing`; 401/403 `auth_error`; else `api_error`) and reports `retry_after_s`. The shared pause
`$MOTHER_ROOT/ratelimit-until` (one epoch-seconds integer, written under `_with_lock`, never cleared: it expires)
stops `_dispatch_ready_jobs` starting anything new, defers the runner's adherence pass (not counted as a run), and makes
`review-lens`, `review-phase` and `adherence-review` wait before spawning. A reviewer whose run ended on a 429 is
re-spawned up to `MOTHER_REVIEW_RATELIMIT_RETRIES` times, then recorded as `error` (`error_reason: rate_limited`, never
a pass, never a failed review). **Success means work happened:** `mother-run-job` fails a run whose own result event
carries an `api_error_status` even at exit 0 (`_fail_on_api_error_result`), and `_rf_reconcile_and_record` adopts an
existing PR only when HEAD moved past the run's starting head (`current_run.head_sha_at_start`; a commit past `base_sha` when that is missing). `MOTHER_BACKOFF_MAX_COUNT` (10) caps consecutive backoffs before the `backoff_exhausted` hold. Only a result event with an `api_error_status` may set a wait (`retry_after_s`) or extend the pause; a text-only `rate_limited` backs off just its own job. Nothing the backoff writes (question, events, hold
detail) contains the worker's `tail_excerpt`. `force-start` does not bypass `not_before` or the pause.

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
`job_flagged` (a job carrying the `needs_attention` field), `adherence_loop`
(more than 5 adherence reviews on one job in the last hour), and
`plugin_cache_stale`, and (limiter, enforce only) `limiter_fault` and the informational `limiter_enforcing_gate_off`. `mother_attention_write` publishes the list atomically to
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

**Typed attention reasons and acks.** Kind `job_attention` — one item per raised
reason from a closed list: `progress_stalled`, `burn_ahead`, `gates_incomplete`,
`decision_awaiting`. A job's raised reasons are the union of its `.attention[]`
(`{reason, since}`, job-owned) and `$MOTHER_ROOT/progress/<id>.json` `.flags[]`
(progress-owned; file may be absent), computed in one place:
`mother_attention_reasons_json <id>` → `[{reason, since, acked}]`. The item is
`{reason: <enum>, detail: {acked, since}, hint: "mother status <id>"}`. The same
array is the derived `attention_reasons` key on every job object in
`mother list/status --format json` and on broker snapshot / `query.list` /
`query.get` records (computed in Go by `attentionReasons`, a pure read; no CLI
shell-out). `mother ack <id> <reason> [--source cli|nostromo_app|broker_client]`
(broker command `ack {job, reason}`, advertised in `hello`) acknowledges a raised
reason: stored in `$MOTHER_ROOT/acks/<id>.json` = `{"<reason>": {since, at,
source}}` under `_with_lock` — **never in job JSON**, whose writes are unlocked.
An ack applies only while its `since` equals the condition's current `since`, so
a condition that clears and returns lapses it. Acking a reason not raised fails
with `is in state` wording (broker: `invalid_state`); an unknown reason fails;
a worker (`MOTHER_JOB_ID` set) is refused. Event `attention_acked {reason,
source}`. Acked items stay listed as `(acked)` but do not count toward `⚑N`
(statusline, `mother list` footer, `mother status`). Mother produces none of the
reasons yet (HC-08/HC-11/HC-14).

**No duplicate pushes while Nostromo is connected.** The broker writes
`$RUNNER_DIR/broker-clients.json` = `{pid, updated_at, clients,
await_subscribers}` on subscribe/unsubscribe/connect/drop and every ping tick.
`_notify_awaiting` skips the transport when `MOTHER_NOTIFY_SUPPRESS_WHEN_CLIENT`
(default `0`, opt-in) is on and the file is fresh (`updated_at` within 3 x
`MOTHER_BROKER_PING_SEC`, default 15), its `pid` is alive and
`await_subscribers > 0`. A suppressed push is bookkept exactly like a delivered
one (so the 24h cadence continues) and recorded as `awaiting_notified` with
`transport: "suppressed_client"`, `ok: true`. Any missing/stale/unparseable file
or dead pid fails closed to "push as usual". The operator-only boundary is
unchanged: only `.awaiting_notify` and `awaiting_notified` events are written.

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


## Backpressure limiter

Observe by default (L1; L2 added the surfaces below; L3 added enforcement of **admission of new work**; L4 added boundary
holds on running jobs, see "Boundary holds (L4)"). It computes what it admits, holds or cuts each tick and logs it next to what dispatch did. **In
`observe` and `off` it changes no dispatch behaviour.** See "Enforcement (L3)" below.

- **Pure core (bet B1).** `lib/limiter_core.py` is the control law: stdlib `math`/`re` only, no file, clock or
  process I/O, `now` is a parameter. Keep it that way (a unit test scans its imports) so the coordinator can host it
  later. `bin/mother-limiter` (python3) is the I/O shell: `tick --root`, `status --json --root`,
  `estimate --root --job`, `classify --work-dir --repo`.
- **Runner.** `_maybe_limiter_tick` (`bin/mother-runner`, after `_dispatch_ready_jobs`) runs `tick` every
  `MOTHER_LIMITER_INTERVAL` (10s) under a `MOTHER_LIMITER_TIMEOUT` (20s) watchdog. A timeout or non-zero exit writes
  `$RUNNER_DIR/limiter-fault.json` `{at, why}` and the loop carries on (B6); a good tick removes it. Each dispatch
  pass writes `$RUNNER_DIR/dispatch-last.json` (`{ts, running, ceiling, ratelimit_paused, quota_over_cap, low_disk,
  spawned, skipped}`); nothing in dispatch reads it. Annotations go through `_job_update` only when a value
  changed, and only `data_class`, `limiter.estimate` and `limiter.would` are ever written. Test entry:
  `mother-runner --limiter-tick`.
- **Fault backoff.** After a fault the runner skips limiter ticks: `MOTHER_LIMITER_BACKOFF_BASE_S` (20) doubling per
  consecutive fault up to `MOTHER_LIMITER_BACKOFF_MAX_S` (600), state in `$RUNNER_DIR/limiter-backoff.json`
  `{faults, skip_until}`; a clean tick clears it. Annotation apply (`_limiter_apply_one`) runs under the job-file lock
  and writes only while the job is still `ready`/`queued`. A job new to the active set has its events file seeded at the
  end (no replay of old distress). `mother add` bounds its `mother-limiter` calls by `MOTHER_LIMITER_ADD_TIMEOUT` (5s).
  A repo with `crew.phi_sensitive: true` is `company`.
- **Modes.** `$MOTHER_ROOT/limiter/mode.json` `{mode: observe|enforce|off, changed_at, changed_by}`; missing/corrupt =
  `observe`. `MOTHER_LIMITER_MODE=off` is a hard kill switch that wins over the file and returns everything to the
  pre-limiter behaviour. Any other env value (including `enforce`) is ignored with one stderr line: enforcement is set
  only by `mother limiter mode enforce`. Reader/writer: `lib/limiter.sh` (`mother_limiter_mode`, `mother_limiter_mode_set`).
- **Files** (`$MOTHER_ROOT/limiter/`): `state.json` (atomic; components, budget per window, interactive, per-job
  would-decisions, log offsets, burn samples), `decisions.jsonl` (`{ts, mode, allowed, running, would, actual,
  divergence}` when the decision set changes and at least every 300s; rotated to `.1` past
  `MOTHER_LIMITER_DECISIONS_MAX_MB`), `burn-history.json` (hourly cache of finished-job burn).
- **Knobs** (env, then `config.env`, then default; a non-numeric value falls back with a stderr line):
  `MOTHER_LIMITER_INTERVAL` 10, `_TIMEOUT` 20, `_RESERVE_PCT` 15, `_BURN_WINDOW_S` 600,
  `_DEFAULT_BURN_USD_PER_MIN` 0.5, `_HISTORY_N` 20, `_HISTORY_MIN` 3, `_CALM_S` 900, `_COALESCE_S` 120,
  `_RAMP_START` 2, `_RAMP_STEP_S` 300, `_INTERACTIVE_PCT_H` 10, `_INTERACTIVE_SUSTAIN_S` 600, `_K_MIN_SAMPLES` 12,
  `_DECISIONS_MAX_MB` 20, `_HOLD_GRACE_S` 600, `_QUIET_S` 30 (L4); `MOTHER_COMPANY_REPOS` (space-separated repo names forced to `company`).
- **Rules.** `allowed = min(MOTHER_CONCURRENCY, backoff_level, ramp_level)`. Distress (429/503/529 `api_retry`,
  `result` with `api_error_status` 429/503/529 (503 is deliberately an overload signal and cuts, like 529), a non-overage rejected `rate_limit_event`, a `failure_routed` event
  with `rate_limited`/`api_overloaded`) halves `allowed` (events within `COALESCE_S` are one cut); calm raises the
  level one step per `CALM_S`. Overage-only rejections and `api_retry` with `error_status: null` are not distress.
  A window reset (`resets_at` forward by more than half the window, or `used_pct` down 20+) restarts a ramp at
  `RAMP_START`, +1 per `RAMP_STEP_S`. Budget codes (`budget_pace`, `reserve`, `interactive_personal`, preempt) are
  `advisory` (not holds) when the quota gate is `off`/`off_until_reset` or the feed is stale (B3). `k` (% per USD)
  is calibrated per window as the 25th percentile of samples with no reset, `used_pct < 99` and Mother spend above a
  floor; until `MOTHER_LIMITER_K_MIN_SAMPLES` samples, `budget_pace` never holds. Pace holds at >= 1.0x.
  Priority: effective class (company 0, personal 1, shifted by `priority_adjust`), then `created_at`, then id;
  `force_start` skips budget terms only. `would_preempt` lists personal running jobs only.
- **Feed.** Same freshness rules as `_quota_feed_json` / `_quota_gate_read` (`lib/state.sh`); a bats test runs both
  on the same fixtures. If you change one reader, change the other.

- **Surfaces (L2).** `mother-limiter status --json` prints the **limiter block**; `status --raw` keeps the old
  `{mode, age_s, state}` dump. The block is built from `state.json` (plus `runner/limiter-fault.json` and
  `quota-gate.json`) with no recomputation, because the broker calls it: `{v:1, mode, age_s, stale, fault,
  concurrency{ceiling, allowed, effective, state steady|backoff|ramp|uncalibrated, detail}, burn{fleet_usd_per_min,
  sustainable_usd_per_min, pace, window, calibrated}, reserve{pct, holding, enforceable}, interactive{state,
  pct_per_hour}, overage_in_use, gate, last_distress{at, ago_s, kind, status, job_id}, distress_24h, waiting[]}`;
  mode `off` prints exactly `{"v":1,"mode":"off"}`. `stale` = `state.json` missing or older than 3 x
  `MOTHER_LIMITER_INTERVAL`; `fault` = the fault file's content. Both make the text surfaces say "limiter: not
  running (...) — dispatch uses fixed concurrency". `effective` is the running-job count from the last tick.
  The shape is a **cross-repo contract**: `tests/fixtures/limiter_block.json` (Nostromo vendors it) — additive
  changes only, and a bats test diffs its key set against the CLI output.
- **CLI.** `mother limiter [status] [--json]`, `mother limiter signals [--json]` (raw per-window values; resets via
  `_quota_fmt_time`), `mother limiter report [--since 24h|ISO] [--json]` (`cmd_limiter`, next to `cmd_quota`). The
  report reads `decisions.jsonl` (+ `.1`), `distress.jsonl` (tick-written, one line per distress event; falls back
  to `failure_routed` job events when the file never existed) and `state.json`: divergences by type and code,
  distress per 10 job-hours (job-hours from `actual.running` samples, each holding until the next, a gap capped at
  900s), 5h exhaustion while admitting (a run of samples with 5h `used_pct` >= 100 and gate `on` that contains a
  spawn; uses the decision line's `window {used_pct_5h, gate}`), calibration, and verdicts (429 < 1 per 10
  job-hours, exhaustion 0, 5h `k` calibrated). `mother status` adds a 2-line summary under `Concurrency:` and
  `limiter` in `--format json`. Runbook: `docs/runbooks/limiter-validation.md`.
- **Wait reasons.** The tick gives every `ready`/`queued` job `limiter.wait` `{code, reason, source, advisory, would,
  since}`: what ACTUALLY holds it, in dispatch's own order — `dep_wait`, `backoff` (future `not_before`),
  `ratelimit_paused`, `quota_over_cap` (not for `force_start`), `low_disk`, `concurrency_full`, else `next`. `source`
  is `dispatch`; the limiter's own different decision rides in `would {code, reason}`. It is written (via the
  runner's `_limiter_apply_one`, which still only touches `data_class`/`limiter.*`) only when `code` changes; `since`
  moves only then. The same rows, oldest job first, are `waiting` in the block (`st["waiting"]` in `state.json`).
  `mother list` appends `[WAIT <code>]` (not for `backoff`, which already shows `[BACKOFF …]`); `mother status <id>`
  prints `Waiting: <reason>`. `awaiting` jobs are not "waiting" here.
- **Broker.** The subscribe snapshot gains `limiter` (omitted when `mother limiter status --json` fails), hello
  lists the `limiter` category, and a block watcher (`broker/quotawatch.go`, shared with `quota`;
  `MOTHER_BROKER_LIMITER_SEC`, default 15) publishes a `limiter` event only when the block's content changes (it
  ignores `age_s`, `last_distress.ago_s`, `concurrency.detail` and waiting `reason`). No broker command changes the
  limiter mode: that stays CLI-only and human-only.

### Enforcement (L3)

`mother limiter mode [observe|enforce|off]` (`_limiter_cmd_mode`) is the only writer of `mode.json`. Human-only: it is
owner-only, stricter than the quota gate: `_owner_only_refusal` refuses a worker (`_quota_in_worker`), an agent session (`CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT`) and a non-TTY stdin (same guard for the `limiter_fault` ack and for raising or un-raising `mother priority`; reading the mode is open); refusals are logged to `limiter/mode-refusals.jsonl`;
changes append `limiter/mode-audit.jsonl`; a same-mode call writes nothing. The lock is `_switch_with_lock`
(`lib/state.sh`, shared with the quota gate, stale takeover). No broker command sets the mode.

- **Enforcing** (`mother_limiter_enforcing`, `lib/limiter.sh`) = mode `enforce`, `state.json` written under enforce and
  fresher than 3 x `MOTHER_LIMITER_INTERVAL`, and no `runner/limiter-fault.json`. Anything else is the old path unchanged (B6).
- **Admit list.** The core emits `state.json` `admit`: ordered ids, cumulative (each admitted job's estimate joins the projected
  fleet burn before the next is judged), never more than `allowed - running`. Advisory budget holds (gate `off`/`off_until_reset`
  or a stale feed, bet B3) are admitted and take a slot; backoff, ramp and retry-after always apply.
- **Dispatch.** `_dispatch_ready_jobs` under enforcing: `_pick_next_limiter_ready` walks `admit` in order (skips `_DISPATCH_SKIP`,
  non-`ready` jobs and a future `not_before`), loop bound `min(MOTHER_CONCURRENCY, allowed)`, the `ratelimit-until` dispatch pause
  is skipped (the limiter's backoff and `admissions_paused_until` replace it). The quota-gate cap stays a backstop (over the cap only
  `force_start` jobs, and only if admitted); `_disk_dispatch_ok` and `_supervisor_alive_for_job` are unchanged. `dispatch-last.json`
  gains `enforcing`. `force_start` skips the budget terms only, never backoff, ramp or retry-after. No other bypass exists.
- **Surfaces.** Held ready jobs get `limiter.wait` `{source: "limiter", code, reason, advisory}`; decision lines carry `mode: "enforce"`
  and `divergence` is a bug signal (the running-job `would_hold_running_but_running` kind is not recorded under enforce: holding
  running jobs is L4).
- **`_rf_backoff` under enforce** (`mother_limiter_mode` = enforce): a `rate_limited`/`api_overloaded` job still returns to `ready`/`queued`
  at the same tier with `backoff_count` +1, but `.not_before` is set only from a server retry-after (clamped by
  `MOTHER_BACKOFF_RETRY_AFTER_MAX_S`), else null; the time-based give-up (`MOTHER_BACKOFF_MAX_S`) does not apply, the count-based one
  (`MOTHER_BACKOFF_MAX_COUNT`) does. `ratelimit-until` is still written (reviewers wait on it). The `failure_routed` event gains
  `limiter: "enforce"`. Observe/off: unchanged.
- **Attention.** `limiter_fault` (mode enforce and state stale/missing or a fault file; reason "limiter not running; dispatch fell back to
  fixed concurrency"; marker `limiter-fault-marker.json`; `mother ack limiter limiter_fault`, acks/_limiter.json, worker-refused) and info-level
  `limiter_enforcing_gate_off` ("budget terms advisory (quota gate off)").
- **Priority.** `priority_adjust` (+1 raise, -1 lower, 0) is read by the core (`effective_rank`): data class shifted by it, company first.
  `mother add --priority` / `mother priority <id> raise|lower|normal` (queued/ready only), event `priority_changed {from, to, by}`.
  Raise is refused from a worker, when `CLAUDECODE`/`CLAUDE_CODE_ENTRYPOINT` is set, or when stdin is not a TTY (`MOTHER_TEST_FORCE_TTY=1`
  stands in for the TTY only under `MOTHER_TEST_ROOT=1`). Lower/normal are open.

New job field: `priority_adjust` (int, -1|0|1) — owner-set ordering shift, absent = 0.

### Boundary holds (L4)

Under `enforce` (`mother_limiter_enforcing`), a running job the limiter wants to yield stops at its next **boundary**, never
mid-request. Nothing is held in observe/off.

- **Selection** (`lib/limiter_core.py`). `would_hold` = the excess `running - min(ceiling, backoff_level)` after a distress cut,
  personal before company, newest before oldest (company jobs only when the personal ones cannot cover the excess).
  `would_preempt` = personal jobs only, when interactive demand is high **and** the 5h reserve is projected to be breached; it is
  advisory (never held) while the quota gate is off or the feed is stale (bet B3). Each running row in `state.json` carries
  `hold {code: backoff|interactive_personal, reason}` when it is in either set.
- **Flag.** `mother-runner`'s `_sync_limiter_holds` (after `_maybe_limiter_tick`) writes `runner/<id>.hold` = `{code, reason,
  since}` atomically and only when code/reason changed, for each running job in `would_hold ∪ non-advisory would_preempt`. Never for a
  job with `cancel_requested`, a `final_result_at`, or not `running`; `force_start` is exempt from `interactive_personal`, not from
  distress holds. When not enforcing (mode left enforce, state stale/faulted: bet B6) every `.hold` is removed within one tick.
  Test entry: `mother-runner --holds-tick`.
- **Tool boundary.** Unless the limiter mode is `off`, every job's settings file (`runner/<id>.settings.json`) has a PreToolUse
  hook `hooks/mother-limiter-hold.sh` (`MOTHER_LIMITER_HOOK_MAX_S=grace+240`, hook `timeout` grace+300), plus the cost gate when
  `max_cost_usd` is set. With no `.hold` it exits 0 at once (no `jq`, no stdin). With one it writes `runner/<id>.held`
  (`{at, pid}`), polls every 2 s, and exits 0 when the flag is gone or at `MOTHER_LIMITER_HOOK_MAX_S` (fail open; garbage in = exit 0).
- **Supervisor** (`mother-run-job` poll loop, `_limiter_hold_tick`): `.hold` seen → `.limiter_hold = {code, reason, since,
  at_boundary: false}`; `.held` appears → event `held {code, reason, boundary: "tool"}`, `at_boundary: true`; `.hold` gone →
  `hold_released {held_s}` and `.limiter_hold` cleared; `.held` older than `MOTHER_LIMITER_HOLD_GRACE_S` **and** the log quiet for
  `MOTHER_LIMITER_QUIET_S` → `awaiting` (`paused_reason: limiter_hold`, or the `quota_*` code for a quota hold), then
  `paused_for_limiter {code, reason, held_s, boundary, paused_reason, question}` (`paused_for_quota` for quota codes), then
  `_terminate_worker`; grace passed but log busy → `hold_giveup_deferred` at most once a minute.
- **Observe installs the hook too.** Whenever the mode is not `off`, the settings file carries the PreToolUse hold hook, so a mode flip
  reaches workers already running. Cost: in observe the Pre/PostToolUse hooks run on every tool call (one stdin read, one `date`,
  one small atomic record write in `runner/<id>.calls/`); no behaviour change, and with no `.hold` the hook exits 0 right after.
  The hook fails open: any write failure, missing root or garbled input exits 0 silently, and it never outlives `MOTHER_LIMITER_HOOK_MAX_S`.
- **Never stop a worker on a stale boundary (MC-37).** Before parking, `_hold_boundary_check` requires `.held` to exist, its pid to be
  alive and under the worker, and the hook's max wait (`_hold_hook_max_s`, also what the settings file passes the hook) not to have passed;
  otherwise the latch resets and the next fresh `.held` re-latches. `_hold_park` takes the job-file lock for its state write and uses the
  `.hold` flag's current code; the runner's `_resume_limiter_hold` re-checks `awaiting`/`limiter_hold` under the same lock.
- **Quota holds when the limiter turns unhealthy.** If the limiter stops enforcing while a quota `.hold` exists, the old quota mid-run
  pause/kill path takes over (pre-existing behaviour).
- **Park protocol (never kill unless parked).** `_hold_park` (tool boundary) writes `runner/<id>.park` (`{pid, at}` of the
  supervisor), re-validates `.held`, writes the awaiting state, then re-reads the job and requires its own `awaiting` +
  `paused_reason` + `paused_at`; any failure (including `_with_lock` timing out) removes `.park`, returns 1 and the tick
  keeps waiting: no event, no kill. Only after a landed park does the caller `_terminate_worker`, then remove `.park`. While
  `.park` exists and its pid is alive the hook keeps blocking even if `.hold` is gone or `MOTHER_LIMITER_HOOK_MAX_S` passed,
  bounded by `MAX_S + MOTHER_LIMITER_HOOK_PARK_CAP_S` (120); a `.park` with a dead pid is ignored (fail open).
- **In-flight tool calls (park only when every call is blocked).** Claude Code issues parallel tool calls (and subagents run
  their own), so "the last hook is blocked" does not prove nothing is executing. The hook records every call in
  `runner/<id>.calls/<tool_use_id>.json` = `{state: running|blocked, pid, at}` at PreToolUse (even with no `.hold`; input
  without a `tool_use_id` is not recorded), marks it `blocked` while it blocks and `running` on release; `mother-limiter-hold.sh
  post`, wired as `PostToolUse` and `PostToolUseFailure` in the same settings file, removes it. `_hold_calls_safe` allows a park
  only when at least one call is blocked in a live hook under the worker and none is `running`; a record whose hook is dead
  counts as running (the tool is executing) until older than `MOTHER_LIMITER_CALL_STALE_S` (21600, a lost PostToolUse), when it
  is discarded; an unreadable record counts as running. It is checked before `.park` is written, after it, and (test delay
  only) again before the state write; the hook records a call before it looks at `.hold`/`.park`, so a call starting in the
  window is either seen or blocked by `.park`. A deferral emits `hold_giveup_deferred {reason: tool_call_in_flight}` (at most
  once a minute). Spawn removes `<id>.park` and `<id>.calls/`. After `_terminate_worker` the supervisor stops the blocked hook
  pids it recorded at park time (by exact pid, never the process group). Verified against a real session: `claude -p` with two
  parallel Bash calls fires `PreToolUse` x2 then `PostToolUse` x2 with distinct `tool_use_id`s, and `PostToolUseFailure` for a
  failing call.
- **Gated test hooks.** `MOTHER_TEST_PARK_DELAY_S` (seconds slept inside `_hold_park` between the last check and the state
  write) only takes effect under `MOTHER_TEST_ROOT=1`; it widens the window the park-sequence tests probe. **Test-only:** never set
  `MOTHER_TEST_ROOT` or `MOTHER_TEST_PARK_DELAY_S` in production (the code comment at the use site says the same).
- **Unidentified calls block parking.** In enforce mode (`limiter/mode.json`; an unreadable or garbled file counts as not enforce, so the hook fails open and drops no marker: enforce must be positively configured), a hook that gets no `tool_use_id` or cannot write its call
  record drops `runner/<id>.calls/_unidentified`; `_hold_calls_safe` returns false while it exists, so the worker is never parked on a
  boundary that may hide a live unrecorded call. The spawn-time `.calls` cleanup clears it. Observe mode never writes it.
- **Job lock takeover.** Every `<file>.lockdir` taker (`_with_lock` in `lib/state.sh` and `mother-run-job`, `_job_locked`, the runner's
  limiter apply, the quota/limiter switches) goes through `_switch_with_lock`, which records the owner pid. A recorded owner that is
  alive is never displaced, however long it holds; a dead one is taken over; an owner-less lockdir is taken over only past
  `MOTHER_QUOTA_LOCK_STALE_S` (30s). Takeovers are serialized by a short-lived `<lockdir>.takeover` mkdir mutex (own owner
  file, dead owner reaped, ~2s timeout): the taker re-judges the lockdir under the mutex and removes it only if it is still stale, so there is no
  rename-and-put-back and a live owner that took the path meanwhile is left alone. Residual heuristic: the owner-less age rule (30s) cannot
  distinguish a crashed owner-less holder from a live one that has not written its pid. `lib/usage.sh` `_usage_with_lock` and the Python
  events append in `bin/mother-usage` use the same lockdir and owner file (Python waits for, never reaps, a dead owner; neither writes unlocked).
  `mother-run-job`'s `_with_lock` fails loudly if `_switch_with_lock` is undefined (`_install_core_job_helpers` sources `lib/state.sh` first).
- **Phase boundary.** `_hold_wait_before_spawn` (top of `_spawn_and_wait`, and `_wave_cycle` before the adherence/lens spawns) waits
  while `.hold` exists (`held {boundary: "phase"}`, poll 2 s); past the grace period it parks the job without spawning (no worker to
  stop; a same-session prompt that never started is kept in `.limiter_resume_prompt` and replayed on resume). Reviewers already
  running are never held.
- **Quota under enforce.** `_maybe_pause_running` writes a `quota_*` `.hold` and keeps `auto_resume_at` on the job instead of
  setting `pause_requested`; the supervisor's give-up parks it as that `quota_*` reason and `_auto_resume_check` is unchanged. The
  runner removes a quota hold when the quota is back under cap or the gate is open (`_withdraw_quota_pause` also handles it).
- **Resume.** `_auto_resume_check` releases `paused_reason == limiter_hold` to `ready` (`pending_answer` "The limiter released this
  job — continue from where you left off.", `resume_session_id = session_id`, `resume_kind: limiter_hold`, `limiter_hold` cleared)
  once the job id is in the limiter's `admit` list (parked jobs are candidates in `mother-limiter`'s tick), or at once when the
  limiter is not enforcing; never while `_supervisor_alive_for_job`. Event `auto_resumed {from_paused_reason: "limiter_hold",
  reason: "limiter_admitted"|"limiter_not_enforcing"}`. The next worker re-enters the same session (`--resume`). `mother resume`
  by hand takes the ordinary answer path. `limiter_hold` awaiting jobs get no push notification and show as auto-resuming.
- **Knobs:** `MOTHER_LIMITER_HOLD_GRACE_S` (600), `MOTHER_LIMITER_QUIET_S` (30), `MOTHER_LIMITER_CALL_STALE_S` (21600); tests only: `MOTHER_LIMITER_HOOK_POLL_S` (2).
- **Surfaces.** `mother status <id>`: `⏸ [HELD <code>] <reason> (at boundary since 3m; gives up worker after 10m)`; `mother list`:
  `[HELD]`. Broker: `paused_for_limiter` folds to `awaiting` with `paused_reason`; `held`/`hold_released` are `activity` events.

| Field | Type | Description |
|---|---|---|
| `limiter_hold` | object\|null | `{code, reason, since, at_boundary, boundary_since?}` while a running job is held (or about to be); cleared on release or park. Written only by the supervisor. |
| `resume_kind` / `limiter_resume_prompt` | string / string | Set by the limiter auto-resume / a phase-boundary park; consumed (cleared) by the next worker start. |

New job fields:

| Field | Type | Description |
|---|---|---|
| `data_class` | string | `company` (Carefeed origin owner, `MOTHER_PHI_REPOS`, or `MOTHER_COMPANY_REPOS`) or `personal`. Set at `mother add`; the tick fills it for older ready/queued jobs. |
| `limiter.estimate` | object | `{usd_per_min, source: history\|fleet_p75\|default, basis: "<repo>+<actor>", samples, computed_at}` expected burn (MC-38). Refreshed at most hourly for non-running jobs. |
| `limiter.wait` | object | `{code, reason, source: dispatch, advisory, would {code, reason}\|null, since}` why a `ready`/`queued` job has not started (L2, see "Wait reasons"). Rewritten only when `code` changes. Display only. |
| `limiter.would` | object | `{code, reason, advisory, at}` the observe-only decision for a `ready` job (`admit`, `concurrency_full`, `backoff`, `ramp`, `budget_pace`, `reserve`, `interactive_personal`, `retry_after`). Display/audit only. |

## Quality gates

A repo opts in with `.mother/crew.yml` (`version: 1`; `gates:{mode, max_attempts 1..5,
budget_minutes, checks[]}`; `lenses:` is accepted and ignored until HC-12). A check is `{name
[a-z0-9][a-z0-9_-]{0,31} unique, run, when:{paths:[globs]} (omitted = always), blocking (default
true), where: any|sandbox (default any), timeout_s 1..3600 (default 900), hint <= 500 chars}`.
`**` globs cross directories; `*` and `?` don't cross `/`.

- **Read from the base ref, never the worktree.** `lib/crew_config.py resolve <repo> <ref> <name>`
  runs `git show <ref>:.mother/crew.yml`, so a worker can't weaken its own gates. Errors are
  `{path, message}` and print as `<repo>: .mother/crew.yml: <path>: <message>`.
  `where: sandbox` is only valid when `.rwx/sandbox.yml` exists at that ref.
- **`mother add`** resolves it from `--base` (skipped when `MOTHER_GATES_ENABLED=0` or the ref doesn't
  resolve locally): an invalid file fails the add; a valid one is stored as `.crew`
  `{version, source_ref, source_sha, phi_sensitive, gates, lenses}`, with the plan's optional
  `gates: {max_attempts: N}` applied. No file means no `crew` key. A job's `.crew` snapshot (never the repo) is what drives the in-lifecycle gates below.
- **`mother gates run`** (worker-callable; `--job`/`MOTHER_JOB_ID` use the job's work dir, base and
  `.crew`) always passes `--allow-unpushed` to `mother_gates_run` (`lib/gates.sh`). Exit 0 passed,
  1 failed, 2 incomplete. Logs/excerpts land in `$MOTHER_ROOT/gates/<job-or-adhoc>/`. `mother gates
  check [--repo] [--ref]` validates only; `mother doctor` runs `scripts/doctor.sh` then checks every
  non-archived job's repo (at its base ref) and the cwd repo, exiting non-zero on an invalid config.
- **Unavailable is never passed.** Sandbox gates are `unavailable` (reason `no_cli`, `disabled`,
  `no_config`, `head_not_pushed`, `rwx_error` for a failed reset or an exec rwx couldn't run,
  `rwx_timeout` for a watchdog expiry) and make the overall status `incomplete`. An `exec` that
  runs and exits non-zero is a normal `failed` (rwx passes the command's exit code through). An
  `any` check that times out is `failed` (exit 124). Status is `failed` if any blocking check
  failed, else `incomplete` if any is unavailable, else `passed`.
- **No output text in JSON.** Full output goes to `<name>.log`, the last 60 lines (<= 4 KB) to
  `<name>.excerpt`. Every check sees `MOTHER_GATE_BASE` (merge-base sha) and
  `MOTHER_GATE_CHANGED_FILES` (newline-separated, <= 64 KB); sandbox checks get them prepended to the
  `bash -c` string because local env doesn't reach the sandbox.
- **Enforce mode (HC-08).** `crew.gates.mode: enforce` on a non-pipeline job: the prompt gets
  `templates/gates-enforce.md` (open the PR as a draft); `_gates_ensure_draft` converts a non-draft PR
  back to draft (`pr_marked_draft` / `pr_draft_unverified`). `_run_gates_enforce` (one function) loops:
  attempt n → passed/incomplete: gates block in the PR body (`lib/prbody.sh`, `<!-- mother:gates -->`),
  `gh pr ready`, `pr_marked_ready`, incomplete adds `gates_incomplete` attention; failed and n < max:
  `$RUNNER_DIR/<id>.gatefix.<n>.md` (red gates, excerpts, hints) → `activity: gate_fix`,
  `gate_fix_started`, `_spawn_and_wait resume` (fresh fallback `mode: fresh_fallback`), usage row
  `run_kind: gate_fix`; failed and n == max: push HEAD if origin is behind (never force),
  `gates_exhausted`, hold `awaiting`/`gate_hold` with a decision. `max` = repo `max_attempts` (a plan can
  only lower it), 1 under `conservative`. A continuation keeps counting; other runs start a fresh budget.
  The loop never touches `current_tier`, `escalation_count` or `retry_count`. `no_pr` jobs make no PR
  calls. Decision handlers (`lib/decision.sh`): `resume_with_guidance` sets `.resume_session_id`;
  `escalate` = one tier up (cap `tier_3`), `escalation_count` +1, `.gates.attempt = 0`, state `ready`
  with a gate summary as `pending_answer`, fresh session; `override_open` = `.gates.status: overridden`,
  `.gates.override`, `gates_overridden`, PR-body note, `gh pr ready`, `succeeded`; `cancel` = `cmd_cancel`.
  The runner never runs adherence on a job whose `.gates.status` is `failed`; the adherence prompt gets a
  `## Gate results` section (names and results only).
- **Observe mode in the job lifecycle (HC-06).** `_run_gates_observe` (`mother-run-job`) runs right after
  `_finalize_pr_url`, before `_rwx_post_exit` and the main-dir restore/lock release (HEAD must still be
  the job branch). It runs only when the job has `.crew.gates`, `MOTHER_GATES_ENABLED` is not `0`, the run
  is heading for success (exit 0, or reaped after a final result), the job isn't cancelled or `awaiting`,
  and this supervisor still owns `worker_pid`. It sets `activity=gating`, emits `gates_started`, runs
  `mother_gates_run … --attempt 1 --allow-unpushed` (logs in `$MOTHER_ROOT/crew/<id>/gates/1/`), emits one
  `gate_result` per result and `gates_completed`, writes `.gates` and restores the previous `activity`.
  It never changes `state`, `failure_reason`, the PR or a prompt. Pipeline jobs in an enforce repo stay on
  this path (`.gates.mode = "enforce"`, `.gates.effective_mode = "observe"`). A gate run that produces no result is
  recorded `incomplete`, never `passed`. `mother status <id>` renders a `=== gates ===` section (the only
  place excerpts appear, read from the side files); `mother list` shows `[gating]`.
- **Settings:** `MOTHER_GATES_ENABLED=0` makes `gates run` a no-op (`{"status":"disabled"}`) and
  skips the add-time snapshot. `MOTHER_PHI_REPOS` (default `admin-portal referral-monitor`, also
  settable in `config.env`) forces `phi_sensitive: true` for those repo names.

### Review wave (HC-14)

`_run_post_run_checks` (`mother-run-job`) = the gate step, then `_run_review_wave` when `_wave_applicable`
(`.crew.lenses` object, `MOTHER_LENSES_ENABLED` != 0, not pipeline, run heading for success, a PR url or
`no_pr`). While a wave is configured, `_gates_present` defers `gh pr ready` (`_pr_ready_reason`) to
`_wave_ship`; `_pr_draft_managed` (gates enforce **or** lenses enforce) owns draft discipline. Per cycle
(`_wave_cycle`): select (`crew_config.py select`, posture, changed files), budget split, launch
`mother adherence-review --pre-ready` and one `mother review-lens` per lens with `&` (reviewers get
`MOTHER_LIVE_ROOT`, not `MOTHER_ROOT`), poll so each finished reviewer updates `.review_wave` under
`_with_lock "$job_file"` (adherence-review --pre-ready writes the same file under the same lock), then
`mother merge-findings --wave`, then `findings_exit_decision` on blocking findings + adherence. `continue` →
`_wave_rework` (`_spawn_and_wait resume`, `$RUNNER_DIR/<id>.reviewfix.<n>.md`), `_finalize_pr_url`,
`_run_gates`, next cycle; `block_human`/cap → `_wave_hold`; `ship` → `_wave_ship`. Observe mode always ships.
Decision handlers for `review_hold` live next to `gate_hold` in `lib/decision.sh`; the PR-body block is
`mother_prbody_write_review` (`lib/prbody.sh`, `<!-- mother:review -->`). A lens with no side file after it
exits gets an `error` side file (merge then reports it as a human-blocking `lens_error`).

### Reviewer lenses (HC-12)

`.mother/crew.yml` `lenses:` declares the focused reviewer set: `mode` observe|enforce,
`default` and `mandatory` (subsets of `correctness`, `phi-security`, `tests`, `ops-infra`),
`scopes` (lens -> glob list), `budget_usd` (>0, <=20, default 3), `cycle_cap` (1..3,
default 2). Mandatory lenses are folded into `default`. In a PHI repo `phi-security` is
injected into both and any scope on it is dropped.

- **`crew_config.select(crew, plan_lenses, changed_files, posture)`** returns
  `[{reviewer: "perri:<lens>", lens, run, skip_reason}]`. Skip reasons: `removed_by_plan`,
  `path_scope`, `posture` (non-mandatory under `conservative`). Mandatory lenses, and
  `phi-security` whenever `crew.phi_sensitive`, always run: no plan removal, scope or
  posture skips them (R11).
- **`mother add`** reads the plan's `lenses: {add, remove}` (next to `suggested_config`).
  Unknown lens names fail; removing a mandatory lens fails with
  `add: lens '<lens>' is mandatory in <repo> and cannot be removed by a plan`, even when
  the repo has no `crew.yml` (PHI repos). Stored as `.crew.lenses.plan` (only when the repo
  has a `crew.yml`).
- **`mother review-lens <id> --lens <name> [--budget-usd N]`** (`cmd_review_lens`, separate
  from `cmd_review_phase`) spawns `claude --agent perri-lens --max-budget-usd N`, default
  sonnet/medium (`suggested_config.perri` overrides; `conservative` clamps the model to
  sonnet). Findings and the `examined` list go to
  `$MOTHER_ROOT/crew/<id>/wave/c<cycle>/<lens>.json` only. Usage stage `review-perri:<lens>`.
  Exit 0 ok, 2 invalid findings, 1 usage error.
- Findings gain optional `claims[{path,line,quote<=200}]` and `asserts_existing_code`;
  lens reviewers also emit an `examined` block (`findings_extract_examined`).

## Progress indicator

An observer-only estimate (`≈NN% · gates n/N · ETA ~band`) for running jobs. **It never writes job JSON** — job
writes are unlocked read-modify-write, so a second writer would race the supervisor. State lives in:

- `$MOTHER_ROOT/progress/<id>.json` — the `.progress` object (`docs/design.md`, "Headless crew contract"),
  written atomically only by `mother-usage progress-tick` (run by the runner's `_maybe_progress_tick`).
  `progress/meta/<id>.json` is rate-limit bookkeeping (last emitted tuple/time, `progress_half` done). Files
  for jobs no longer in `jobs/` are removed by the tick.
- `$RUNNER_DIR/progress-calibration.json` — `{fitted_at, min_repo_n, fleet, repos}` from `mother-usage calibrate`
  (stage shares/medians/p90 and remaining/elapsed ratios; per-repo entries only at n ≥ 20).

Stages in pct order: `build`, `rework`, `gates`, `review`, `present`. The active clock counts worker, gate and
review process time only (no queue waits, no `awaiting`). `progress_fraction` (pct) and `eta_band` (ETA) in
`bin/mother-usage` are the single tunable functions (HC-11). pct is a multiple of 5, ≤ 95 until terminal.
`progress_updated` events (broker category `progress`) are emitted only when the visible tuple changes and at
most once per job per 60s (the terminal 100% write bypasses the gap); `progress_half` once at the first ≥ 50%.
`mother list`/`status` and the broker merge the file/latest event in as `.progress` — job files stay identical.

**Flags (HC-11).** `progress-tick` writes observe-only `flags[]` entries (`{reason, since, detail}`): `progress_stalled`
(`{stage, stuck_s}`; no pct increase for > the stage's p90 active duration, floor 10 min, paused time excluded; the last
increase is tracked in `signals.pct_moved_at_active_s`) and `burn_ahead` (`{cost_frac, progress_frac}`; cost fraction >= 0.5
and >= 2x pct/100). Raise/clear append `attention_raised` / `attention_cleared {reason}`; a flag change counts as a visible
change for `progress_updated`. Flags never change state or act on anything. They always show in `mother status`, `mother list`
(`⚠stalled`/`⚠burn`, `(acked)`) and JSON `attention_reasons`, but enter the `job_attention` needs-attention list only when
`MOTHER_PROGRESS_FLAGS_ATTENTION=1` (default `0`; job-owned reasons are always included).
The statusline writes a sibling `${MOTHER_STATUSLINE_CACHE}.progress` (`<id>\t<label>` of the running job with the soonest
ETA hi; empty if none) next to the **unchanged 6-field cache**; `MOTHER_PROGRESS_ENABLED=0` skips it. `mother retro` reports
`stage_calibration`, `progress_accuracy` (I13: coverage and median band width / median remaining at the `progress_half` event;
PASS/FAIL vs 70% and `MOTHER_I13_WIDTH_TARGET`, default `5`, i.e. median band ≤ 5× median remaining per the 2026-10-17 decision) and `progress_flags` (real = operator acted while raised, or job
failed/cancelled; target >= 50%).

## Worker mode: the state seam (cluster P1-2)

With `MOTHER_WORKER_MODE=1` (default: off, behaviour unchanged), `mother-run-job` and everything it calls run against a
**worker root** (`MOTHER_ROOT` = a mirror holding the job; marker `.mother-worker-live`, which `safe_rm_tree` refuses like
`.mother-live`). Every write still lands in the mirror, and `lib/outbox.sh` also appends it as a protocol op
(`docs/worker-protocol.md` section 4: `job.set`, `event.append`, `record.append`, `artifact.put`) to
`$MOTHER_WORKER_OUTBOX_DIR/<job>.ndjson`. Lease/epoch are added later by the worker daemon.

**One predicate, validated once.** `mother_worker_mode_active` (`lib/outbox.sh`) is the only worker-mode test (the outbox,
the cost recompute, the live-spend baseline, the marker all use it). `mother_worker_mode_validate` runs at startup, before any
path is created (top of `lib/state.sh` and `bin/mother-run-job`): worker mode REQUIRES an explicit root (`MOTHER_ROOT`, or
`MOTHER_LIVE_ROOT` as the in-agent view of the same mirror; if both are set they must agree) that is not `$HOME/.mother` and
has no `.mother-live` marker, plus a writable `MOTHER_WORKER_OUTBOX_DIR`. Anything else prints why and exits non-zero having
written nothing (no marker, no canonical write). The outbox dir alone, without the mode variable, changes nothing.

**Emit is safe and loud.** The next seq is derived from the last complete, parseable line of the ndjson (the `<job>.seq` file
is informational), a torn tail is terminated before appending, and `MOTHER_OUTBOX_MAX_OP_BYTES` (1 MiB) /
`MOTHER_OUTBOX_MAX_BYTES` (512 MiB) cap what is written. Any emit failure (jq, lock, unwritable or full dir, empty previous
document) logs to stderr, returns non-zero from `mother_job_write_doc` / `_job_write_doc` / `_usage_job_write` /
`mother_job_update` / the event and record helpers, and persists `runner/<job>.outbox-degraded`. The supervisor then holds the
job (`awaiting`, `paused_reason: outbox_degraded`) instead of reporting a state the coordinator cannot see; later emits fail
fast until the flag is cleared.

**The replay is the boundary.** `lib/coord_apply.sh <canonical-root> <job> < ops.ndjson` judges every op as strictly as the P1-1
Go allowlist (`broker/workerproto` `WorkerKeys`, `CoordinatorDerivedKeys`, `SyncDownKeys`, `StateValues`, `keyKinds`): the bash
tables are copies, and `tests/state_seam.bats` fails when they drift from `ownership.go`. A worker can never set `succeeded` or a
coordinator-derived key (`pr_url`, `actual_branch`, `finished_at`, `exit_code`, `failure_reason`: the coordinator derives them,
P1-5, or holds the job), never leave a terminal state or resume `running` after a cancel, and never touch `cancel_requested`,
`pause_requested`, `force_start`, `max_cost_usd` (only `pending_answer: null` is allowed) or the P1-2 inventory keys
(`work_dir`, `base_sha`, `not_before`, `current_tier`, ...), all of which are coordinator-side writes. Values are checked
against the Go kinds and sizes. Keys apply one by one (refused keys are audited in `runner/leases/audit.jsonl`); a refused
`state` refuses the whole op. The one bash-side extension is `pipeline`: only its `reviewer_findings` object is merged (typed,
<= 64 KiB), because `_review_slot_write` writes it in worker mode; add it to the Go table in P1-3. seq must be contiguous
(`seq <= applied` is a duplicate, a gap stops the replay); a structurally bad line or op is quarantined to
`runner/leases/<job>.quarantine.ndjson` and skipped, a transient failure retries `MOTHER_APPLY_MAX_RETRIES` (3) times then is
quarantined. Each call holds a per-job apply lock and stops after `MOTHER_APPLY_MAX_SECONDS` (120) / `MOTHER_APPLY_MAX_OPS`
(exit 4: call again). Caps: `MOTHER_APPLY_MAX_LINE_BYTES`, `_EVENT_BYTES` (64 KiB), `_ROW_BYTES` (16 KiB), `_FILE_BYTES`,
`_ARTIFACT_BYTES` (per job, 1 GiB); a `final` artifact chunk needs a sha256. Exit: 0 applied, 1 stopped, 3 done with quarantined
ops, 4 budget. `mother_recompute_job_cost` is a no-op in worker mode (the canonical side recomputes on a terminal `failed` /
`cancelled` state and on every usage row).

**What worker mode does NOT mirror** (a deliberate exclusion, not an oversight): `runner/<job>.usage-state.json`, progress and
every other `runner/` file (including the `.hold`/`.held`/`.park`/`.calls` limiter files), the worker log, and `limiter`/`quota`
state. Those are runner-local; the coordinator observes the worker through the heartbeat and the log stream instead. The
`decision.sh` writes `last_answer`, `resumed_at`, `escalation_count` (and the tier bump) happen when an operator answers on the
canonical tree, never inside a worker, so a worker op carrying them is refused (consciously excluded). `.decision` itself is a
worker key and is mirrored.

Rules for new code: write a job document only through `mother_job_update`, `mother_job_write_doc` (lib/state.sh),
`_job_update` / `_job_write_doc` (mother-run-job) or usage.sh's `_usage_job_write`; append events through
`mother_event_append`/`_append_event`/`_usage_append_event`; call `mother_outbox_artifact` after finalising a file under
`crew/<id>/`. `tests/state_seam_lint.bats` enforces this by function name. Not verified yet: a real worker process against a
real coordinator (P1-4).

## Internals reference (lazy-loaded)

Resource teardown (worktrees/containers), PR detection (`lib/prdetect.sh`,
`mother reconcile`), pipeline visibility (W5) and resume-answer continuity are
documented in the `mother-internals` skill (`.claude/skills/mother-internals/`).
Load it before changing `lib/teardown.sh`, `lib/prdetect.sh`, or pipeline cycle output.
