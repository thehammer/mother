---
name: mother
description: Dispatch and monitor background implementation work via Mother, a local background-work orchestrator. Use when the user agrees on a plan to ship, asks "what's running?" or "what's queued?", wants to cancel or retry a job, or asks about PRs Mother has opened. Plans must be self-contained — invoke the `archie` agent first to produce one from the conversation before enqueueing.
---

# Mother — Background Work Dispatch

Local orchestrator for background Claude Code jobs. Plans run in worktrees
(parallel) or in the main repo dir (serialized via workspace locks). Background
sessions spawn as headless workers running `claude --agent cody -p "<plan>"` and
open PRs on completion.

State lives at `${MOTHER_ROOT:-$HOME/.mother}/` (plain JSON, gitignored). See
the Mother plugin's `docs/design.md` for the full design.

## When to use this skill

**Trigger — offer to queue work** when the user:
- Agrees to ship a plan you've just converged on together
- Says "let's implement this", "make it happen", "go build it", "ship it"
- Has a ticket (Jira, GitHub Issue, Linear, etc.) with a clear, self-contained fix

**Trigger — report Mother's state** when the user asks:
- "What's running?" / "What's in flight?" / "What's queued?"
- "What happened with that job?" / "Did TICKET-XXXX's PR open?"
- "Cancel that" / "Retry it"

## The flow (proactive — PREFERENCES tells you to offer this)

1. **Converge on intent** in conversation with the user.
2. **Offer to queue.** ("Want me to have Mother run this as a background job?")
3. **Invoke the `archie` agent** with a brief. Archie returns a full self-contained
   plan doc in the standard format.
4. **Present the plan inline for review.** Show it in the conversation. Let the
   user iterate — edits, scope changes, splits, or scrap-and-restart. Re-invoke
   Archie with feedback if needed.
5. **On explicit approval, enqueue.** Save the plan to a temp file and call
   `mother add`. Never enqueue without the user saying go.

## CLI surface

The `mother` command is on PATH when the plugin is installed (via the plugin's
`scripts/install.sh`, which symlinks into `~/.local/bin`).

```bash
# Enqueue (returns job id on stdout)
mother add --plan-file /tmp/plan.md \
           --repo my-service \
           --branch fix/TICKET-1234-slug \
           --isolation worktree \
           --max-cost 5

# List jobs (omit --state to see non-terminal only)
mother list
mother list --state running
mother list --format json   # for programmatic reads

# Full job + event history
mother status <id>
mother peek <id>            # live snapshot of worker's transcript (running or done)
mother logs <id>
mother logs <id> --follow

# Mutations
mother cancel <id>
mother retry <id>

# Attach to a running worker's log in a new tmux window (opt-in)
mother attach <id>

# Deltas for in-session awareness (the UserPromptSubmit hook uses this; you may
# occasionally call it manually if the user asks "what's new?")
mother events --since-cursor <session-id>
```

## Typical invocation pattern

After user agreement:

```bash
# 1. Save approved plan to a temp file
cat > /tmp/plan-TICKET-1234.md <<'PLAN'
<Archie's output pasted verbatim>
PLAN

# 2. Enqueue — the daemon picks it up asynchronously
id=$(mother add --plan-file /tmp/plan-TICKET-1234.md \
                --repo my-service \
                --branch fix/TICKET-1234-slug \
                --isolation worktree \
                --max-cost 3)
echo "Queued: $id"
```

Claude can keep working in the interactive session; state changes (succeeded,
pr_opened, failed) surface via the UserPromptSubmit hook in the next turn.

## Useful details

- **Isolation default is `worktree`.** Use `--isolation main-dir` only when the
  work genuinely has to happen in the main checkout (e.g. you can't run more
  than one copy of the dev stack). Main-dir jobs auto-serialize via the repo's
  workspace lock.
- **Always set `--max-cost`** unless the user explicitly says otherwise. A few
  dollars is plenty for most small fixes.
- **Branch names** follow the project's convention: check the repo's
  `CLAUDE.md` or recent `git log` for the established pattern. Common shapes:
  `fix/TICKET-NNNN-slug`, `feature/TICKET-NNNN-slug`, `<username>/<slug>`.
- **Base ref.** Defaults to `origin/main`. Some repos use `master` or a
  release branch. Archie is responsible for checking the repo's default and
  specifying correctly in the plan.

## Do not use this skill when

- The work needs the user's **local Docker stack** for verification (seeded DB,
  fixtures, per-developer services) — keep it interactive.
- The work is **frontend / UI** that needs browser verification — Cody in a
  worktree has no browser.
- The plan is **still taking shape** — wait until it's solid. Dispatching a
  half-formed plan wastes a Cody session and the user's budget.
- The work is **one line** you could do inline in under 30 seconds.
