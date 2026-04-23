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
