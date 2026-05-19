# Changelog

All notable changes to Mother are documented here. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning is
[SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`waiting` state for dependency gating.** Jobs created with
  `--depends-on <id>` now enter `waiting` instead of `queued` when the
  parent's PR has not yet been merged (or, for `no_pr: true` jobs, when
  the parent has not yet succeeded). The daemon's `_promote_ready` tick
  advances waiting jobs to `queued` once the dependency is satisfied.
  This prevents a child from branching off a base that does not yet
  contain the parent's work.
- **PR-merge detection.** `_dep_merge_state` wraps `gh pr view` with a
  per-tick result cache (`~/.mother/cache/pr-state/`) keyed by SHA-1 of
  the PR URL. Cache TTL is controlled by `MOTHER_DEP_PR_POLL_INTERVAL`
  (default: 60 s). Transient `gh` failures are treated as `pending` so
  they never silently unblock a child.
- **Cancellation cascade.** When a parent job is cancelled or fails, the
  daemon's next tick calls `_cascade_parent_terminal`, which cancels all
  waiting children of that parent (with `{reason: "parent_cancelled"|
  "parent_failed", parent_id: "…"}`).
- **`--keep-on-parent-cancel` flag** on `mother add`. Children with this
  flag set remain in `waiting` when a parent is cancelled or fails,
  rather than being cascaded to `cancelled`.
- **`mother cancel`** now accepts jobs in `waiting` state (direct
  transition to `cancelled`).
- **`mother retry --skip-dep-check`**: by default, retrying a child
  re-evaluates its dependency via `_dep_merge_state` and sets the retry
  target to `waiting` if the dep is not yet satisfied. Pass
  `--skip-dep-check` to bypass this check and restart immediately.
- **`WAIT-ON` column** in `mother list` (text format): when at least one
  displayed row is in `waiting`, a `WAIT-ON` column appears showing
  `<dep_id>:<dep_merge_state>` for waiting rows and `-` for others. The
  JSON output shape is unchanged.
- **v1 single-dependency constraint**: `--depends-on` accepts exactly
  one job id. A comma-separated list with more than one id is rejected at
  add time with a clear error message.

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
