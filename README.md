# Mother

> *"Mother, may I?"*

**Mother** is a local background-work orchestrator for Claude Code. You converge
on a plan in conversation, ask Mother if she may, and she runs it in a worktree
while you keep working.

Named for the ship's computer in *Alien* (`MU/TH/UR 6000`) and the children's
permission game. Both are apt: Mother grants or denies permission, mediates
between you and your agents, and never runs without explicit consent.

## How it works

```
  you ─── converge on a plan ─── Claude
                                   │
                                   ▼
                        spawns Archie (planner)
                                   │
                                   ▼
                      plan draft ──── you review
                                   │
                               approved
                                   │
                                   ▼
                      ┌──── MU/TH/UR ────┐
                      │   (daemon)       │
                      │                  │
                      │  worktree        │
                      │     │            │
                      │     └─ Cody ─── implements, opens PR
                      └──────────────────┘
                                   │
                  PR opened ─── notification ─── next reply
```

## What ships in this plugin

- A **skill** (`mother`) that Claude reaches for naturally when you agree to ship a plan.
- A **CLI** (`mother`) for adding, listing, peeking, cancelling, retrying jobs.
- A **daemon** (`mother-runner`) that picks up queued jobs and spawns workers.
- A **worker spawner** (`mother-run-job`) that sets up the worktree and runs Claude.
- A **UserPromptSubmit hook** that surfaces job completions in your next message.
- Reference **Archie** (planner) and **Cody** (worker) agents, customizable.
- An **fzf-based tmux popup** (`mother-switcher`) bound to your tmux prefix for
  glanceable status and quick actions.
- An **opt-in statusline segment** showing running/queued counts.

## Requirements

- macOS or Linux (tested on macOS)
- `bash` 4+ (`/bin/bash` on macOS is old — install from brew if needed)
- `jq`, `tmux`, `fzf`, `git`
- `claude` CLI (Claude Code)
- For the daemon on macOS: launchd (built-in). Linux: systemd user units.

## Install

Planned: single-plugin marketplace you add to Claude Code.

```
/plugin marketplace add thehammer/mother
/plugin install mother
```

Then one-shot bootstrap from the CLI:

```
mother doctor          # verify deps
mother daemon install  # installs the launchd plist or systemd unit
mother daemon start
```

## Status

🚧 **Scratch / design phase.** This repo is a structural sketch being walked
through interactively. Files here may be skeletons; the real ported content
lives at `~/.claude/bin/queue*` and related paths on the author's machine.

## Design doc

See the original design: [`docs/design.md`](docs/design.md) (TODO: port from
`~/.claude/plans/queue-system.md`).

## License

TBD — MIT leaning.
