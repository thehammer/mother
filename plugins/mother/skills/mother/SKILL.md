---
name: queue
description: Dispatch and monitor background implementation work via the local queue runner. Use when the user agrees on a plan to ship, asks "what's running?" or "what's queued?", wants to cancel or retry a job, or asks about PRs the queue has opened. Plans must be self-contained — invoke the `archie` agent first to produce one from the conversation before enqueueing.
---

# Queue — Background Work Dispatch

Local queue for background Claude Code jobs. Plans run in worktrees (parallel) or
in the main repo dir (serialized via existing workspace locks). Background sessions
spawn via tmux, run `claude --agent cody -p "<plan>"`, and open PRs on completion.

State lives at `${MOTHER_ROOT:-$HOME/.mother}/` (plain JSON, gitignored). See
`~/.claude/plans/queue-system.md` for the full design.

## When to use this skill

**Trigger — offer to queue work** when the user:
- Agrees to ship a plan you've just converged on together
- Says "let's implement this", "make it happen", "go build it", "ship it"
- Has a Jira ticket with a clear, self-contained fix

**Trigger — report queue state** when the user asks:
- "What's running?" / "What's in flight?" / "What's queued?"
- "What happened with that job?" / "Did CORE-XXXX's PR open?"
- "Cancel that" / "Retry it"

## The flow (proactive — PREFERENCES tells you to offer this)

1. **Converge on intent** in conversation with the user.
2. **Offer to queue.** ("Want me to queue this as a background job?")
3. **Invoke the `archie` agent** with a brief. Archie returns a full self-contained
   plan doc in the standard format.
4. **Present the plan inline for review.** Show it in the conversation. Let the
   user iterate — edits, scope changes, splits, or scrap-and-restart. Re-invoke
   Archie with feedback if needed.
5. **On explicit approval, enqueue.** Save the plan to a temp file and call
   `mother add`. Never enqueue without the user saying go.

## CLI surface

The `queue` command is always in PATH (`~/.claude/bin/queue`).

```bash
# Enqueue (returns job id on stdout)
queue add --plan-file /tmp/plan.md \
          --repo my-service \
          --branch fix/TICKET-1234-slug \
          --isolation worktree \
          --max-cost 5

# List active jobs (omit --state to see non-terminal only)
queue list
queue list --state running
queue list --format json   # for programmatic reads

# Full job + event history
queue status <id>
queue logs <id>
queue logs <id> --follow

# Mutations
queue cancel <id>
queue retry <id>

# Deltas for in-session awareness (the UserPromptSubmit hook uses this; you may
# occasionally call it manually if the user asks "what's new?")
queue events --since-cursor <session-id>
```

## Typical invocation pattern

After user agreement:

```bash
# 1. Save approved plan to a temp file
cat > /tmp/plan-TICKET-1234.md <<'PLAN'
<Archie's output pasted verbatim>
PLAN

# 2. Enqueue
id=$(queue add --plan-file /tmp/plan-TICKET-1234.md \
               --repo my-service \
               --branch fix/TICKET-1234-slug \
               --isolation worktree \
               --max-cost 3)
echo "Queued: $id"

# 3. Run it (phase 1 blocks the current session — this is expected for now)
queue run --once
```

In phase 2 once the daemon is live, step 3 goes away — `mother add` is enough,
the daemon picks up the job asynchronously.

## Useful details

- **Isolation default is `worktree`.** Use `--isolation main-dir` only when the
  work genuinely has to happen in the main checkout (e.g. you can't run more
  than one copy of the dev stack). Main-dir jobs auto-serialize via the repo's
  workspace lock.
- **Always set `--max-cost`** unless the user explicitly says otherwise. A few
  dollars is plenty for most small fixes.
- **Branch names** follow the project's convention: check the repo's
  `CLAUDE.md`, `.claude/preferences/`, or recent `git log` for the established
  pattern. Common shapes: `fix/TICKET-NNNN-slug`, `feature/TICKET-NNNN-slug`,
  `<username>/<slug>`.
- **Base ref.** Defaults to `origin/main`. Some repos use `master` or a
  release branch. Archie is responsible for checking the repo's default and
  specifying correctly in the plan.

## Do not use this skill when

- The work needs the user's **local Docker stack** for verification (seeded DB,
  herd services, fixture data) — keep it interactive.
- The work is **frontend / UI** that needs browser verification — cody in a
  worktree has no browser.
- The plan is **still taking shape** — wait until it's solid. Enqueueing a
  half-formed plan wastes a cody session and the user's budget.
- The work is **one line** you could do inline in under 30 seconds.
