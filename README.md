# Mother

> *"Mother, may I?"*

**Mother** is a local background-work orchestrator for [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview).
You converge on a plan in conversation, Mother runs it in a git worktree while
you keep working, and completion surfaces in your next message.

Named for the ship's computer in *Alien* (`MU/TH/UR 6000`) and the children's
permission game. Both are apt: Mother grants or denies permission, mediates
between you and your agents, and never runs without explicit consent.

## How it works

```
  you ─── converge on a plan ─── Claude
                                   │
                                   ▼
                        spawns archie (planner)
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
                      │     └─ cody ─── implements, opens PR
                      └──────────────────┘
                                   │
                  PR opened ─── notification ─── next reply
```

## What ships in this plugin

- `mother` **skill** — Claude's natural handle into the system. Triggers when
  you agree to ship a plan, ask "what's running?", or want to cancel/retry.
- `mother` **CLI** — `add`, `list`, `status`, `peek`, `logs`, `cancel`,
  `retry`, `archive`, `plan`, `attach`, `daemon install|start|stop|status|uninstall`.
- `mother-runner` **daemon** — long-lived process that picks up queued jobs
  and spawns workers. Managed via launchd on macOS.
- `mother-run-job` **worker spawner** — sets up the worktree, spawns
  `claude --agent "$MOTHER_WORKER_AGENT" -p <plan>` (default: `mother:cody`)
  as a headless background process, tees the log, polls for completion.
- `UserPromptSubmit` **hook** — surfaces state changes (succeeded, pr_opened,
  failed) in your next user message as a `<system-reminder>`.
- Reference `mother:archie` (planner) and `mother:cody` (worker)
  **agents** — plugin-shipped defaults, namespaced under the plugin. Claude
  Code exposes plugin-shipped agents as `<plugin>:<agent>`, so a fresh
  install gives you `mother:archie` and `mother:cody`. If you already have
  unprefixed `archie` / `cody` agents in `~/.claude/agents/`, Claude will
  use those by name; set `MOTHER_WORKER_AGENT=cody` to have Mother dispatch
  your personal `cody` instead of the plugin's.
- `mother-switcher` **fzf popup** — bind to your tmux prefix (`prefix Space`);
  live preview, quick cancel/retry/archive/plan bindings.
- Opt-in **statusline segment** — `source plugins/mother/statusline/segment.sh`
  and call `mother_segment` for a compact `Q ▶2 ⏸5` render.

## Requirements

- macOS (launchd daemon) or Linux (systemd TODO — start manually for now)
- `bash` 4+ (macOS `/bin/bash` is 3.2; `brew install bash` if needed)
- `jq`, `tmux`, `fzf`, `git`, `python3` (for `mother peek`)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code/overview) (`claude`) on PATH

## Install

```
/plugin marketplace add thehammer/mother
/plugin install mother
```

Then bootstrap the daemon and symlinks:

```
plugins/mother/scripts/install.sh   # symlinks bin/* into ~/.local/bin + runs doctor
mother doctor                        # verify deps
mother daemon install                # launchd plist on macOS
mother daemon start
```

Optional:

```
# tmux popup
echo 'bind Space display-popup -w 80% -h 80% -E "$HOME/.local/bin/mother-switcher"' >> ~/.tmux.conf
tmux source-file ~/.tmux.conf

# statusline segment
source "$PLUGIN_DIR/plugins/mother/statusline/segment.sh"
# then include "$(mother_segment)" in your statusline renderer
```

## Usage sketch

```
# 1. propose a plan (archie agent produces one, or write your own)
# 2. review + approve
# 3. queue it
mother add \
  --plan-file /tmp/my-plan.md \
  --repo my-service \
  --branch fix/TICKET-1234-slug \
  --isolation worktree \
  --max-cost 3

# 4. keep working in your Claude session.
#    mother runs the job headless; completion surfaces via the hook.

# 5. peek / logs / manage
mother list
mother peek <id>
mother logs <id> --follow
mother cancel <id>
```

Or, from inside tmux: hit your bound key (default `prefix Space`) and use the
switcher.

## Works well with

- **Redd** and **Marty** — optional companion agents for test-first and
  refactor phases of red-green-refactor. Cody uses them when available.

## Design

See [`docs/design.md`](docs/design.md) for the full architecture: data model,
event lifecycle, file layout, phased build.

## License

MIT — see [`LICENSE`](LICENSE).
