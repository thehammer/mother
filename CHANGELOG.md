# Changelog

All notable changes to Mother are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[SemVer](https://semver.org/spec/v2.0.0.html).

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

## [Unreleased] - cost visibility, `--max-cost` enforcement, `--effort` passthrough, `mother retro`

### Added

- `bin/mother-usage`: a new Python 3 (stdlib-only) transcript parser and cost
  engine. Subcommands: `parse` (per-run token/cost/actor accounting from a
  worker's stream-json log), `classify-exit` (structured failure reasons from
  exit code + log tail), `publish-rates` (publishes `lib/rates.json` to
  `~/.claude/model-rates.json` for Bishop to read, never downgrading),
  `retro` (the 11-table cost/outcome/failure report).
- `lib/rates.json`: static per-model pricing table, calibrated against real
  archived job logs (see the feature's PR for the calibration table).
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
  `--strict-mcp-config --mcp-config`, cutting the fixed per-turn prefix
  substantially by dropping the operator's ~30 personal MCP connectors from
  every background job. Kill switch: `MOTHER_WORKER_MCP_SCOPE=0`.

### Changed

- `runs.jsonl` schema bumped to `schema: 2`. **`tokens_in`/`tokens_out` on
  each row now cover only that run's log slice**, not the whole job's
  cumulative log — the previous behavior double-counted resumed/escalated/
  continued jobs across every prior run. Bishop's per-agent token totals
  will read lower for multi-run jobs after this change; this is the fix, not
  a regression. `actual_cost_usd` is the sum of a job's `runs.jsonl` rows and
  is always a number (0, never null) once a job reaches a terminal state.

### Fixed

- Per-turn stream-json `usage.output_tokens` reliably matches the CLI's
  input/cache-read/cache-creation totals but can undercount true OUTPUT
  tokens by an order of magnitude (extended thinking tokens are billed as
  output but not reflected the same way in each per-turn delta). `mother-usage
  parse` now corrects output-token totals from the run's own `result` event
  when one is available, verified within <0.01% of the CLI's own reported
  `costUSD` on 5 real archived logs spanning sonnet-4-6, haiku, and opus-4-7.
