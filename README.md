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
- `mother` **CLI** — `add`, `list`, `status`, `peek`, `logs`, `plan`, `attach`,
  `cancel`, `retry`, `await`, `resume`, `events`, `drafts`, `archive`, `run`,
  `daemon install|start|stop|status|uninstall`.
- `mother-runner` **daemon** — long-lived process that picks up queued jobs
  and spawns workers. Managed via launchd on macOS.
- `mother-run-job` **worker spawner** — sets up the worktree, composes the
  worker's prompt (capabilities preamble + resume context if applicable +
  user's plan), spawns `claude --agent "$MOTHER_WORKER_AGENT" -p <prompt>`
  (default: your local `cody` if you have one, else the plugin-shipped
  `mother:cody`) as a headless background process, tees the log, polls for
  completion. Verifies the artifact (PR URL or pushed branch) before
  marking succeeded — see _Reliability behaviors_ below.
- `UserPromptSubmit` **hook** — surfaces state changes (succeeded, pr_opened,
  failed, awaiting) in your next user message as a `<system-reminder>`.
- **Pause / resume** — workers can pause themselves mid-job for operator
  input via `mother await --question "..."`; the operator answers with
  `mother resume <id> "<answer>"` and a fresh worker continues from the
  same worktree (commits + uncommitted edits preserved). The daemon also
  auto-pauses jobs when the user's Claude Code quota cap is reached and
  auto-resumes them when the window resets. See _Reliability behaviors_.
- **Capabilities preamble** — `plugins/mother/templates/preamble.md` is
  prepended to every worker's prompt at spawn time, teaching agents how
  to call `mother await` and warning them not to yield mid-work in
  `claude -p` mode. The on-disk plan file stays the user's authored
  content — Mother decorates at spawn, not at queue time. Override with
  `MOTHER_PREAMBLE_PATH=/path/to/custom.md` or disable by pointing at
  `/dev/null`.
- Reference `mother:archie` (planner) and `mother:cody` (worker)
  **agents** — plugin-shipped defaults, namespaced under the plugin. Claude
  Code exposes plugin-shipped agents as `<plugin>:<agent>`, so a fresh
  install gives you `mother:archie` and `mother:cody`. If you already have
  an unprefixed `cody` in `~/.claude/agents/` (or project-level in
  `<repo>/.claude/agents/`), Mother prefers your personal version
  automatically — the shipped one is a fallback for fresh installs.
  Force the shipped version with `MOTHER_WORKER_AGENT=mother:cody` or
  pick an entirely different worker with `MOTHER_WORKER_AGENT=<name>`.
- `mother-switcher` **fzf popup** — bind to your tmux prefix (`prefix Space`);
  live log tail in the top pane, queue across the bottom; cancel/retry/
  archive/plan bindings. Press enter on a row to swap the preview to a
  follow-mode tail of that job's log; esc closes.
- Opt-in **statusline segment** — `source plugins/mother/statusline/segment.sh`
  and call `mother_segment` for a compact render like `Q ▶2 ⏸5 ?1 !1 🚦`
  (running, queued, awaiting, failed, quota-gate-active). Optionally call
  `mother_capture_rate_limits "$input"` from the same script to enable
  the daemon's quota-aware dispatch (see _Quota awareness_).

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

# statusline segment + quota-aware dispatch
source "$PLUGIN_DIR/plugins/mother/statusline/segment.sh"
mother_capture_rate_limits "$input"   # writes ~/.mother/rate-limits.json
# then include "$(mother_segment)" in your statusline renderer.
# `$input` is the JSON Claude Code pipes in via stdin — you'll have already
# captured it (e.g. `input=$(cat)`) before this point.
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

# 6. if a worker pauses to ask a question (state goes to `awaiting` —
#    surfaced as `?N` in the statusline segment), see the question with
#    `mother peek <id>`, then answer:
mother resume <id> "Use option B (LRU). The traffic pattern is recency-skewed."
# (or pipe a longer answer: `mother resume <id> --from-file answer.md`)
```

Or, from inside tmux: hit your bound key (default `prefix Space`) and use the
switcher.

## Works well with

- **Redd** and **Marty** — optional companion agents for test-first and
  refactor phases of red-green-refactor. Cody uses them when available.

## Reliability behaviors

Mother runs unattended for long stretches and the agents it spawns aren't
always well-behaved. A handful of guardrails make the queue's terminal-
state row reflect reality rather than what the agent claimed:

- **Post-result-grace reaper.** stream-json sometimes leaves `claude` in
  `S`-state interruptible sleep after emitting its final `result` event.
  Mother watches the log for the result event, waits
  `MOTHER_RESULT_GRACE_SECONDS` (default 300s) for the wrapper to exit
  on its own, then SIGTERM-then-SIGKILLs it. The wrapper's signal-trap
  forwards to claude so the kill actually lands instead of orphaning it.
- **Idle-timeout reaper.** If the log mtime hasn't advanced in
  `MOTHER_IDLE_REAP_SECONDS` (default 1800s) and we haven't seen a result
  event, the worker is wedged. Reaps to `failed: idle_timeout` so the
  outcome is honest rather than indefinite.
- **Verify-artifact-or-fail.** Before marking `succeeded`, isolation=worktree
  jobs without a captured `pr_url` are checked against
  `git ls-remote origin <branch>`. Branch missing → `failed: no_pr_no_push`
  with `local_commits_ahead_of_base` and `uncommitted_files` counts in
  the event detail. Catches agents that yield mid-work without committing
  or pushing — a failure mode that used to look green in `mother list`.
- **Pause / resume.** Workers can call `mother await --question "..."` to
  hand a question back to the operator without losing their worktree.
  `mother resume <id> "<answer>"` spawns a fresh worker with the answer
  prepended to the original plan; commits and uncommitted edits carry
  forward unchanged. The capabilities preamble teaches agents when to
  pause vs. when to fail-and-retry.

## Quota awareness

Mother can read the user's true rolling 5h / 7d quota state from the
same payload Claude Code already pipes to the statusline. Three behaviors
hang off it once enabled:

- **Pre-dispatch gate** — won't spawn new ready jobs while either window
  is at or over its cap. Held jobs stay `ready`.
- **Mid-flight pause** — running jobs (with no final result yet, not
  already awaiting, no cancel pending) get paused via the same await/
  resume mechanism with `paused_reason: quota_5h|quota_7d` and an
  `auto_resume_at` timestamp.
- **Auto-resume** — paused jobs come back automatically once their
  blocking window has reset and the cache shows quota is genuinely under
  cap.

Enable by adding one line to your statusline that ingests the rate-limit
data from Claude Code's per-render JSON payload:

```bash
# in your statusline.sh, after `input=$(cat)` (or wherever you read stdin):
source "$HOME/Code/mother/plugins/mother/statusline/segment.sh"
mother_capture_rate_limits "$input"
```

Without this line, `mother_capture_rate_limits` doesn't run, the cache
stays unwritten, the daemon's quota check returns "no signal → no gate,"
and Mother behaves the same as it did before quota awareness shipped.

The cache is only fresh while a Claude Code session is rendering its
statusline. Smart-staleness handling: if a window's `resets_at` has
passed since the cache was written, the window has rolled over and
Mother treats its percentage as 0 — so a stale cache from a closed
session doesn't permanently block dispatch.

To preserve headroom for interactive use, lower the caps:
`MOTHER_QUOTA_CAP_5H_PCT=70` reserves the top 30% of your 5h window.

## Environment variables

Defaults preserve current behavior — every variable is optional.

| Variable | Default | Purpose |
|---|---|---|
| `MOTHER_ROOT` | `$HOME/.mother` | State dir (jobs, events, logs, locks) |
| `MOTHER_WORKER_AGENT` | (auto) | Force a specific worker agent name |
| `MOTHER_PREAMBLE_PATH` | `<plugin>/templates/preamble.md` | Capabilities preamble prepended to every worker's prompt; point at `/dev/null` to disable |
| `MOTHER_CONCURRENCY` | `2` | Max parallel jobs |
| `MOTHER_POLL_INTERVAL` | `2` | Daemon tick interval (seconds) |
| `MOTHER_SHUTDOWN_GRACE` | `30` | Seconds the daemon waits for children before exiting |
| `MOTHER_ORPHAN_GRACE` | `60` | Seconds before treating a `running` job with no `worker_pid` as crashed |
| `MOTHER_RESULT_GRACE_SECONDS` | `300` | Wait this long after the agent's `result` event before reaping the wrapper |
| `MOTHER_IDLE_REAP_SECONDS` | `1800` | Reap workers whose log hasn't moved in this long |
| `MOTHER_ARCHIVE_INTERVAL` | `3600` | Seconds between automatic archive sweeps |
| `MOTHER_ARCHIVE_OLDER_THAN` | `30` | Days before terminal-state jobs are archived |
| `MOTHER_RATE_LIMIT_CACHE` | `$MOTHER_ROOT/rate-limits.json` | Where the statusline writes 5h/7d quota state |
| `MOTHER_QUOTA_CAP_5H_PCT` | `90` | Refuse new dispatches when the 5h window is at or over this percentage |
| `MOTHER_QUOTA_CAP_7D_PCT` | `90` | Same for the 7d window |

## Design

See [`docs/design.md`](docs/design.md) for the full architecture: data model,
event lifecycle, file layout, phased build.

## License

MIT — see [`LICENSE`](LICENSE).
