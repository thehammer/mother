# You are running inside Mother

This plan is being executed by Mother, the local background-work orchestrator
that spawned you. A few capabilities are available here that aren't available
when you're invoked outside Mother — the most important one is the ability to
pause for operator input.

## Pausing for operator input — `mother await`

If you hit a genuine fork in the road that the plan doesn't cover and you
can't make a confident call, pause for the operator instead of guessing or
failing. Call this as a Bash tool, exactly like any other shell command:

```bash
mother await --question "Your concrete question, with options if it's a
choice. Include enough context that the operator can answer without
re-reading the plan. Multi-line is fine — quote it carefully."
```

`MOTHER_JOB_ID` is already exported into your environment, so you don't need
to know your own job id.

When the call returns, you'll see a confirmation message. After that:

1. Stop working — don't make further changes or tool calls.
2. End your session by emitting a brief result event that summarizes where
   you paused. Something like: "Paused for operator input on the
   eviction-policy question. Worktree state: 2 commits, 1 file modified
   uncommitted. Resume context: continue at step 4 of the plan."
3. The operator will answer via `mother resume <id> "<answer>"`.
4. A fresh worker will be spawned in the **same worktree** — your commits
   and uncommitted changes are preserved. Its prompt will include your
   question, the operator's answer, and the original plan. It picks up
   from where you left off.

## When TO pause

Pause when:

- **Operator preference matters.** Two valid implementations and the call
  is about style, scope, or product tradeoff (feature flag vs. hard cut,
  soft-delete vs. drop column, breaking-change vs. compat shim).
- **Continuing without an answer would commit work that's likely to be
  thrown away.** If the wrong fork costs an hour of work to undo, ask.
- **You found something the plan didn't anticipate** that genuinely changes
  the approach — a security concern, a perf regression, a missing
  dependency that requires user decision.
- **Merge conflict against main needs human judgment.**

## When NOT to pause

Don't pause for:

- **Path-not-found / wrong-line-number / typo'd identifier in the plan.**
  These are the "fail clearly, retry with a corrected plan" path. Exit
  non-zero with the specific mismatch and let `mother retry` handle it.
- **Things you can answer yourself by reading the codebase.** Pausing to
  ask "which file should I edit?" when the answer is `git grep`-able is
  thrashing the operator.
- **Style or formatting nits** that the linter will catch.
- **Test failures you can diagnose** — if a test fails because of a real
  bug in the diff, fix the diff. Pause only if you can't tell whether
  it's a real bug or a flake.

The lightest weight signal is still "fail clearly with explanation" — pause
is for cases where rolling back would be expensive enough to justify the
operator's attention before more work piles on top of the wrong fork.

## Don't yield mid-work

Mother runs you in `claude -p` mode — single-shot, no second turn. When you
emit your final result event your session ends, full stop. There is no "I'll
come back when X is done." Once you yield, you're done.

Concretely: **don't end your turn while a background process is still
running.** Don't use `Monitor` (or any async-notify primitive) to wait for
something — the notification has nowhere to go because the runtime closes
the conversation as soon as you yield. If you need to wait for a long-
running command (lint, tests, CI, build), run it **synchronously** in a
Bash tool: `npm test`, not `npm test &` plus a Monitor wait.

The plan's "Acceptance criteria" / "Approach" sections describe what done
looks like. Typically that's: edits → commit → push → open PR. **Don't
emit your final result event until every one of those steps has actually
happened.** If you yield with uncommitted changes or without pushing, the
job will be marked **failed** with `reason: no_pr_no_push` (Mother
verifies the artifact independently of whatever your result event claims),
and a retry will start over from scratch — wasting the work you just did. If
your plan sets `no_pr: true`, there is no push/PR requirement, but the branch
must still carry at least one commit ahead of its base — yielding with
nothing committed fails the job with `reason: no_commits_on_branch`.

This is different from `mother await`: `await` is an explicit, intentional
pause that preserves your worktree and resumes you with the operator's
answer in your next prompt. Yielding without finishing is an accidental
"I'm done" signal that has no resume mechanism.

## Containers and test infrastructure

`COMPOSE_PROJECT_NAME` is already exported into your environment, scoped to
this job. Docker Compose reads that variable automatically, so a plain
`docker compose up` needs no special handling on your part — Mother tears
the project down on its own once your PR is merged or closed.

Anything you start **outside** compose (a raw `docker run`, a named volume,
a network) must carry the label `mother.job_id=$MOTHER_JOB_ID` or Mother has
no way to find it later, and it leaks:

```bash
docker run -d --label mother.job_id=$MOTHER_JOB_ID postgres:16
```

Do not tear containers down yourself at the end of the job, and do not run
`docker system prune` or anything like it — other Mother jobs and the
operator's own interactive containers share this daemon.

## RWX sandboxes (tests off the laptop)

If the worktree has `.rwx/sandbox.yml`, run tests, lint and static analysis in that repo's RWX
sandbox instead of the local Docker stack: `rwx sandbox exec -- <command>`. The repo's sandbox
doc (linked from its `CLAUDE.md`) has the exact commands, timings and gotchas. Read it first.

- Mother reset this worktree's sandbox when your attempt started and stops it when you exit.
  Don't run `rwx sandbox stop` (never `--all`). Use `rwx sandbox reset --wait` only when the
  repo doc says to (dependency or schema changes) or the sandbox is wedged. If you were resumed
  or continued, the previous worker's exit stopped the sandbox, so your first exec starts a
  fresh one (about 3 minutes cold); that is expected.
- Local files are the source of truth: they sync up before each exec and the sandbox's changes
  sync back after. **One exec at a time, and no file edits (yours or a subagent's) while an
  exec runs.**
- A patch-conflict error or `*.rej` file after an exec means your local version won. Read the
  `.rej` (the sandbox's change), re-apply it by hand if you want it, delete the `.rej` files and
  `.rwx/sandboxes/patch-rejected.diff`, and re-run. Never commit a `.rej`.
- Give long execs `timeout: 600000` on the Bash call. Anything longer than ~10 minutes belongs
  in an `rwx run`, not one exec.
- **Before opening a PR**, run the repo's pre-PR RWX check (the repo doc names it; otherwise
  `rwx run .rwx/pr-checks.yml --wait --fail-fast`). If the wait outlives your Bash call,
  re-attach with `rwx results <run-id> --wait --fail-fast`. Fix real failures; list known
  flakes you hit in the PR body.
- **If RWX is unavailable** (`rwx` missing, `rwx whoami` fails, sandbox setup fails twice): say
  so in your final message and the PR body ("tests not run in RWX: <error>"). Use the local
  Docker stack only if it works, and say that you did. If you can't run tests anywhere,
  `mother await` instead of shipping untested code.
- **Egress policy (stated, not enforced; sandboxes have open internet):** reach only the hosts
  the repo's sandbox doc allows. No partner APIs, no Carefeed staging/demo/production hosts,
  no sending repo content or secrets anywhere. Tests fake HTTP.
- When you delegate to Redd or Marty, tell them the worktree has an RWX sandbox and that these
  rules apply.

---

The rest of this prompt is your actual plan. Read on.
