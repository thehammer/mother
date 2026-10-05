# Changelog

All notable changes to Mother are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[SemVer](https://semver.org/spec/v2.0.0.html).

## [0.3.1] - 2026-10-05

### Changed

- `lib/preview.sh` no longer re-implements the kill-tree helper or the event/job-file
  writers: `mother_kill_tree` now lives in `lib/proc.sh` (shared with `lib/rwx.sh`), and
  `_preview_event` / `_preview_job_update` delegate to the state.sh primitives
  (`mother_event_append` / `mother_job_update`, the latter now accepting extra jq args). No behaviour change.
- Trimmed the `mother-run-job` header comment (prompts are on stdin).

### Added

- Test that the plugin, marketplace and changelog versions agree.

## [0.3.0] - 2026-10-04

### Added

- **`mother preview`: per-job preview stacks with guaranteed teardown.** A worker can
  launch an RWX preview stack (`Carefeed/preview-stack`: admin-portal, family-portal,
  payments, referral-monitor) of its own *pushed* branch to check a behavioural
  acceptance criterion: `mother preview up|wait|info|verify|call|fake|down`. One stack per
  job (`job-<id slug>`), components picked per job, owner secrets kept in a `0600` file and
  only ever passed to `curl` on stdin. Exit codes 0 ok / 1 failure / 2 usage / 3 refused /
  4 still starting.
- **Teardown on every path** (`lib/preview.sh`): `mother-run-job` stops the stack after every
  worker exit (`_preview_post_exit`, also from the EXIT trap, with the newer-worker guard) and
  before a fresh attempt (`_preview_pre_spawn`); `mother-runner`'s orphan reaper stops a
  SIGKILLed supervisor's stack for every isolation (`_orphan_preview_stop`). Best-effort,
  event-only (`preview_up`, `preview_ready`, `preview_stop`).
- Config: `MOTHER_PREVIEW_ENABLED`, `MOTHER_PREVIEW_BACKEND`, `MOTHER_PREVIEW_STACK_BIN`,
  `MOTHER_PREVIEW_STACK_REF`, `MOTHER_PREVIEW_WAIT_TIMEOUT`, `MOTHER_PREVIEW_STOP_TIMEOUT`,
  `MOTHER_PREVIEW_CURL`, `MOTHER_PREVIEW_POLL_INTERVAL`.
- Preamble "Preview stacks" section and a Cody bullet.
- **Backend seam; operations deferred.** Only the `preview-stack` CLI backend exists. The
  operations control-plane backend plugs into `_preview_backend_up` / `_preview_backend_stop`
  later without touching the commands or hooks.

## [0.2.1] - 2026-10-04

Version bump so `claude plugin update` refreshes caches that already hold 0.2.0. It picks up
prompts-on-stdin (#43, listed under 0.2.0 Security below) and everything else merged since.

## [0.2.0] - unreleased

Operator-facing signals made trustworthy.

### Security

- **Prompts go to `claude` on stdin, never argv.** Workers (`mother-run-job`),
  `review-phase` and `adherence-review` previously passed the whole plan/diff
  as `-p "<text>"`, exposing it to `ps`, EDR command-line scanners (a diff
  containing a curl probe tripped a ThreatDown alert) and `E2BIG`. They now
  run `claude -p --output-format stream-json --verbose` with the prompt on
  stdin. The plugin cache must be refreshed for the fix to take effect.

### Added

- **Needs-attention list** (`lib/attention.sh`): `mother status` with no id now
  prints a queue overview, awaiting jobs and a needs-attention section
  (`--format json` supported); `mother list` prints a `⚑ N item(s) need
  attention` footer; the statusline cache gains a 6th `ATTENTION` field
  rendered `⚑N`. The daemon refreshes `attention.json` every
  `MOTHER_ATTENTION_INTERVAL` seconds. Sources: stalled teardowns, PRs open
  more than `MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS`, blocked dependencies,
  unrestored `mother:auto-stash:*` stashes, jobs carrying a `needs_attention`
  field, and a stale plugin cache. Never calls `gh`.
- **Awaiting push notifications** (`lib/notify.sh`, `_notify_awaiting`): one push
  when a job enters `awaiting`, a reminder at 24h then daily, coalesced when
  many are due; transports `terminal-notifier` / `osascript` (argv-safe) /
  `command` / `none`. Never auto-acts on an awaiting job.
- `--depends-on` waits for the dependency's **PR to merge** (or a `no_pr`
  dependency); `dep_wait` job field, `dependency_waiting` / `dependency_blocked`
  / `dependency_satisfied` events. Blocked dependents are never auto-cancelled.
- **Durable daemon config** (`lib/config.sh`): `mother-runner` reads
  `$MOTHER_ROOT/config.env` (`MOTHER_*=value` lines, parsed not sourced, env
  vars win) before applying defaults, so `MOTHER_CONCURRENCY` survives
  `mother daemon install` re-rendering the launchd plist. The installer moves an
  existing plist's `MOTHER_CONCURRENCY` into `config.env` first (never lowering
  it). `mother status` (and `scripts/doctor.sh`) print the effective
  concurrency and its source (`env` / `config file` / `default`), published by
  the runner to `runner/effective-config.json`.
- **RWX sandbox lifecycle** (`lib/rwx.sh`): for repos that commit
  `.rwx/sandbox.yml`, `mother-run-job` resets the job's RWX sandbox before the
  first spawn of each fresh attempt (attempt key `escalation_count:retry_count`;
  resume/continuation/rework/later pipeline phases keep it) and stops it after
  every worker exit, before the main-dir stash restore and lock release.
  Best-effort and time-bounded (`MOTHER_RWX_RESET_TIMEOUT` / `MOTHER_RWX_STOP_TIMEOUT`,
  kill switch `MOTHER_RWX_SANDBOX_ENABLED=0`); recorded as `rwx_sandbox_reset` /
  `rwx_sandbox_stop` events and the audit-only `rwx_sandbox` job field, never
  affecting job outcome. The job preamble gains an "RWX sandboxes" section.
- `mother-runner` publishes its CLI path to `runner/cli-path`; the hook prefers it.
- `scripts/doctor.sh` warns when the plugin cache differs from the checkout.

### Fixed

- **Scraped PR URLs are verified before they are recorded.** The live poll-loop
  capture and the finalization fallback used to take any same-repo
  `github.com/<owner>/<repo>/pull/N` URL out of the worker transcript — so a doc
  the worker merely *read* (e.g. a Read `tool_result` linking an already-merged
  PR from another branch) became the job's `pr_url` and emitted `pr_opened`
  seconds after `started`. Both paths now go through `_accept_scraped_pr_url`,
  which accepts a URL only when the PR's head branch is the job's branch
  (`expect_branch_mismatch` jobs accept any head) or the PR contains one of the
  job's own commits, and always rejects a MERGED/CLOSED PR while the job has no
  commits beyond `base_ref`. A rejection records nothing and emits
  `pr_url_rejected {url, reason}` once per URL per spawn. Definitive reasons
  (`head_branch_mismatch`, `merged_before_job_commits`,
  `closed_before_job_commits`) are remembered — the live loop doesn't re-query
  `gh`. Transient reasons (`pr_unresolved`, `evidence_indeterminate`,
  `gh_unavailable`) carry `transient: true`, are not remembered, and are retried
  on the next poll tick, up to 10 failures per URL per spawn
  (`MOTHER_PR_TRANSIENT_RETRY_CAP`), after which finalization decides. With `gh` missing the
  live path records nothing; finalization keeps its offline behavior and emits
  `pr_url_unverified`. All candidate URLs are now tried newest-first, so a
  valid PR isn't shadowed by an unrelated URL read later.
- Teardown: healthy `pr_open`/`pr_open_live` waits no longer increment
  `deferrals` or write a `teardown_deferred` event every sweep.
- Teardown: a job that never created a worktree (empty `work_dir`, no worktree
  registered for its branch) clears on the next sweep instead of parking as
  `worktree_probe_failed` forever; a real probe failure is flagged after 2
  stalled passes (`MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS`).
- The `UserPromptSubmit` hook no longer replays months-old archived job events
  as live failures: it reads from the daemon's CLI rather than a possibly stale
  plugin cache, and applies its own `MOTHER_EVENTS_MAX_AGE_HOURS` age floor.

### Changed

- Plugin version `0.1.0` → `0.2.0` (so `claude plugin update` refreshes the cache).

## [0.1.0] - unreleased

Initial scaffolding for the Mother plugin.

### Added

- `mother` CLI: add / list / status / logs / peek / cancel / retry / events / drafts / archive / run.
- `mother daemon` subcommand: start / stop / status / install / uninstall (macOS launchd; Linux systemd TBD).
- `mother` skill for natural dispatch from inside an interactive Claude Code session.
- Reference `archie` (planner) and `cody` (worker) agent definitions.
- `UserPromptSubmit` hook that surfaces queue events in the next Claude reply.
- `mother-switcher` fzf-based tmux popup for job browsing, log-tail, cancel, retry.
- Opt-in statusline segment (`statusline/segment.sh`) with ANSI colour counts.
- `scripts/install.sh` and `scripts/doctor.sh` bootstrap + dependency checks.
- Design doc at `docs/design.md`.

## [Unreleased] - truthful terminal states

### Fixed

- Failures are routed by reason instead of always escalating the model tier.
  `no_pr_no_push` (reconcile, else hold), `rework_no_new_commit`,
  `branch_create_failed` and `checkout_failed` (hold) never escalate;
  `worktree_create_failed`, `runner_died_early` and `unspecified` get one
  as-is retry then a hold; everything else keeps reconcile-then-escalate.
  A hold is `awaiting` / `activity: operator_hold` with a question naming the
  next commands (`resume`, `retry`, `reconcile`, `cancel` all accept it).
  Every `failed` transition now persists `.failure_reason` on the job.
  Kill switch: `MOTHER_FAILURE_ROUTING_ENABLED=0`.
- A rework/resume run that started with an open PR or pushed branch can no
  longer report `succeeded` without pushing anything new; it fails
  `rework_no_new_commit`. Kill switch: `MOTHER_REWORK_ADVANCE_CHECK_ENABLED=0`.
- A main-dir job that fails during workspace setup (`branch_create_failed`,
  `checkout_failed`), or whose supervisor dies, now restores the operator's
  auto-stashed tracked and untracked changes — before releasing the workspace
  lock — instead of leaving them only in `git stash list`.

## [Unreleased] - cost visibility, `--max-cost` enforcement, `--effort` passthrough, `mother retro`

### Added

- `bin/mother-usage`: a new Python 3 (stdlib-only) transcript parser and cost
  engine. Subcommands: `parse` (per-run token/cost/actor accounting from a
  worker's stream-json log), `classify-exit` (structured failure reasons from
  exit code + log tail), `publish-rates` (publishes `lib/rates.json` to
  `~/.claude/model-rates.json` for Bishop to read, never downgrading),
  `retro` (the 11-table cost/outcome/failure report).
- `lib/rates.json`: static per-model pricing table, using published per-MTok
  list prices with the cache_write_1h multiplier calibrated against real
  archived job logs (see "Known limitation" below for the separate,
  unresolved output-token undercount this pricing sits on top of).
- `lib/usage.sh`: bash glue — `mother_claude_extra_args` (builds `--effort`
  and MCP-scoping flags for every `claude` invocation), `mother_record_run_usage`
  / `mother_recompute_job_cost` (one schema-2 `runs.jsonl` row per worker run;
  `actual_cost_usd` is now the true cumulative sum across every run for a
  job — never reset by retry/escalate/continuation/adherence rework),
  `mother_usage_check_live` (live cost/token polling), `mother_classify_exit`.
- `--effort` now actually reaches the `claude` CLI at all three direct call
  sites (worker spawn, `mother review-phase`, `mother adherence-review` via
  `MOTHER_ADHERENCE_EFFORT`) — previously resolved internally but never
  passed through.
- `mother add --max-cost USD` is now enforced. A job that exceeds its cap
  pauses to `awaiting` (`paused_reason: cost_cap`) via a `PreToolUse` hook
  (`hooks/mother-cost-gate.sh`) that blocks all tool calls except
  `mother await`, with a post-grace forced-pause fallback. Resuming a
  cost-capped job requires `mother resume <id> --max-cost <usd>|none`.
- `mother list` gains a COST column (actual / `~live` / spend-over-cap).
- `mother retro --since <window> [--format table|json] [--backfill]`: an
  11-table retrospective (outcomes, failure reasons, escalation, adherence,
  awaiting, tokens & cost, turns & context, wall-clock, repos served,
  teardown backlog, Perri decision mix) built from job records, events, and
  `runs.jsonl`/`usage-backfill.jsonl` — never mutates `runs.jsonl` itself.
- Structured failure reasons: every `failed` event now carries a `.reason`;
  the non-zero-exit path classifies via `mother-usage classify-exit`, and a
  guard in `_transition`/`_job_transition` injects `reason: unspecified` (plus
  a `failure_reason_missing` event) for any caller that omits one.
- Statusline: a fifth cache field renders a magenta `$!N` token-alert count
  (jobs whose cumulative tokens crossed `MOTHER_TOKEN_ALERT_THRESHOLD` in the
  last 24h). Backward compatible with older 3/4-field caches.
- Headless workers, `review-phase`, and `adherence-review` invocations now
  scope MCP servers to `templates/worker-mcp.json` (empty by default) via
  `--strict-mcp-config --mcp-config`, dropping the operator's personal MCP
  connectors from every background job. No `ENABLE_CLAUDEAI_MCP_SERVERS` env
  var was needed — the flags alone zero out `claude.ai` connectors. Measured
  with two real `claude -p "Reply with exactly: OK" --model sonnet --effort
  low` calls in a scratch repo (`--agent mother:cody`, same agent every
  worker uses):

  | | tools | MCP servers | turn-1 fixed prefix (input+cache_read+cache_create) |
  |---|---|---|---|
  | before | 262 | 32 | 48,809 tokens |
  | after (`--strict-mcp-config --mcp-config templates/worker-mcp.json`) | 27 | 0 | 39,394 tokens |

  That's a ~19% cut in the fixed prefix — real, but well short of "cutting
  the prefix substantially" (this entry's own earlier wording, corrected
  here): most of the baseline prefix turns out to be Claude Code's own
  built-in tool/system-prompt overhead, not the ~30 personal MCP connectors'
  schemas. Core tools (Bash, Read, Edit, Write, Task/Agent, …) are unaffected
  and `--agent mother:cody` still resolves normally. Kill switch:
  `MOTHER_WORKER_MCP_SCOPE=0`.

### Changed

- `runs.jsonl` schema bumped to `schema: 2`. **`tokens_in`/`tokens_out` on
  each row now cover only that run's log slice**, not the whole job's
  cumulative log — the previous behavior double-counted resumed/escalated/
  continued jobs across every prior run. Bishop's per-agent token totals
  will read lower for multi-run jobs after this change; this is the fix, not
  a regression. `actual_cost_usd` is the sum of a job's `runs.jsonl` rows and
  is always a number (0, never null) once a job reaches a terminal state.

### Known limitation — output-token accounting undercounts true spend

Per-turn stream-json `usage.output_tokens` reliably matches the CLI's own
final `input`/`cache_read`/`cache_creation` totals (see one archived example:
per-turn summed `input=482` vs the result event's `inputTokens=482`,
`cache_read_input_tokens=41,973,002` vs `41,973,002`+cache_creation match to
within noise) — but it undercounts true OUTPUT tokens by roughly an order of
magnitude on the same run (`output_tokens` summed per-turn: 4,798; the same
run's `result.modelUsage.outputTokens`: 94,168), almost certainly because
extended-thinking tokens are billed as output but are not reflected in each
per-turn delta the way visible-text output is. Spot-checked against 13
real archived logs (sonnet-only, opus-only, and mixed):

| log | models | `cost_usd` (per-turn, what Mother now records) | `cli_cost_usd` (CLI's own `result.modelUsage` total) | gap |
|---|---|---|---|---|
| `20260801T211708Z-47db9949` | opus | $28.07 | $34.61 | 18.9% |
| `20260801T140932Z-71946e79` | opus+sonnet | $30.34 | $40.94 | 25.9% |
| `20260803T181938Z-cb4913dc` | opus | $16.07 | $19.84 | 19.0% |
| `20260801T005248Z-ecc46354` | opus+sonnet | $7.11 | $11.39 | 37.6% |
| `20260803T150909Z-967d5faa` | opus+sonnet | $19.09 | $27.32 | 30.1% |
| `20260802T142924Z-d90b0f42` | sonnet | $9.13 | $15.73 | 42.0% |
| `20260805T150404Z-128fb190` | sonnet | $1.30 | $2.49 | 47.8% |
| `20260803T000922Z-0d0e65ec` | sonnet | $6.29 | $11.83 | 46.9% |
| `20260803T123059Z-d262a72d` | sonnet | $1.96 | $3.95 | 50.4% |
| `20260803T171153Z-c8b925b1` | sonnet | $2.42 | $4.93 | 50.9% |
| `20260802T200134Z-7ce50e93` | sonnet | $1.03 | $2.02 | 48.8% |
| `20260802T200259Z-3e9eb153` | sonnet | $2.00 | $4.39 | 54.5% |

This means `actual_cost_usd`/`live_cost_usd`/`mother retro`'s cost tables are
a real, structural **undercount** of true spend (roughly 20–55% low,
apparently worse on sonnet-heavy runs than opus-heavy ones — small sample,
not yet enough logs to say why). **No rate-table adjustment can fix this**
— the gap is in the *token counts* recorded per-turn, not in the per-token
price. The plan's Phase B1 calibration requirement (rate-table cost within 2%
of `costUSD`) is consequently NOT met, and can't be met without either (a)
recovering the missing output tokens some other way (the previous, reverted
correction was one attempt, but it broke the calibration check's validity and
had an unreviewed actor-cost redistribution formula), or (b) accepting the
undercount and treating `cli_cost_usd` purely as an advisory drift signal.
This was raised to the operator via `mother await` rather than deciding
unilaterally a second time. `cli_cost_usd` is exposed on every schema-2 row
specifically so this gap stays visible and auditable in the meantime.
