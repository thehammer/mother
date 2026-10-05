---
name: mother-internals
description: Reference for Mother internals — worktree/container teardown gating and pending queue, evidence-based PR detection (prdetect.sh, reconcile), W5 pipeline visibility (cycles, lifecycle events), and resume-answer continuity. Load when changing or debugging lib/teardown.sh, lib/prdetect.sh, pipeline cycles output, or operator-answer handling.
---

# Mother internals reference

Moved out of the always-loaded CLAUDE.md to keep session context small.

## Resource teardown (worktrees + containers)

Mother creates two kinds of Mother-owned resources per job — a git worktree
(`mother-run-job:272-290`) and, potentially, docker containers a job's worker
starts for testing — and until this feature never cleaned up either. Both are
torn down automatically once the underlying work is *settled*, via
`plugins/mother/lib/teardown.sh`.

**Why gate on PR settlement, not "job reached a terminal state":** worktrees
are legitimately *reused* by follow-up jobs against the same branch (e.g. "fix
CI on PR #3845" runs after the original job for that branch already
succeeded). Tearing down as soon as a job goes `succeeded`/`failed` would
delete a worktree a follow-up job is about to reuse, or is actively running
in. The safe signal is "the PR is merged or closed", or "the job is terminal
and never produced a PR at all." Teardown rides along with the existing
`mother archive` path (the daemon's periodic sweep, and the manual `mother
archive <id>` used by the fzf switcher's ctrl-d) rather than introducing a new
sweep mechanism.

**The gate** (`_teardown_gate` in `lib/teardown.sh`), evaluated per job:

| Condition | Result |
|---|---|
| Job's branch has its own **live** open PR (checked first, regardless of the stored `pr_url`) | defer — `pr_open_live` |
| No `pr_url`, state `failed`/`cancelled` | proceed — nothing was ever shippable |
| No `pr_url`, state `succeeded`, `no_pr: true` | proceed — a `no_pr` job never opens a PR |
| No `pr_url`, state `succeeded`, not `no_pr` | defer — a PR may exist but was never captured; never guess |
| `pr_url` set, PR merged | proceed |
| `pr_url` set, PR closed | proceed |
| `pr_url` set, PR still open | defer — `pr_open` |
| `pr_url` set, `gh` unreachable/inconclusive | defer |

The live-branch check (`pr_open_live`, via `lib/prdetect.sh`'s
`prd_pr_for_branch`) exists because a job's stored `pr_url` is a set-once
field: if a job resumed and opened a *second*, different PR, or a branch was
reused for a fresh PR after the one Mother recorded was merged/closed, the
stored URL alone would say "safe to remove" while the branch itself still has
live, un-shipped-to-upstream work sitting on it. See
`.claude/bugs/resolved/2026-08-14-review-phase-silently-reviews-wrong-repo-when-worktree-is-torn-down.md`.
`pr_open_live` is treated exactly like `pr_open` for stall accounting (see
Deferral counters below) — it's a healthy wait, not a stall.

A race guard additionally defers when another non-terminal job shares the
same `repo_path` + `branch` (escalation re-queue, adherence rework, or a
distinct job queued against the same branch mid-flight).

**The unrecovered-work guard** (`_teardown_worktree_unsafe`, wired into
`_teardown_execute` after the gate/race checks): for a worktree-isolated job
about to be torn down, probes whether the worktree holds uncommitted/untracked
changes or commits that exist on no remote at all. Either makes the worktree
**unsafe** — force-removing it would destroy genuinely unrecoverable work —
and teardown defers instead, with reason `unsafe_worktree` (detail:
`{uncommitted_files, unpushed_commits}`). An **empty/unset** `work_dir` is
disambiguated with git's own registry: if `repo_path` has **no** worktree
registered for `refs/heads/<branch>`, Mother never created anything for the job
(typically it was cancelled before it started) and it is treated as safe — the
worktree step then takes its `already_absent` skip and the pending record
clears on the next sweep. If one *is* registered, we can't prove this job owns
it (two jobs can share a branch), so it stays `worktree_probe_failed`
(indeterminate). A `work_dir` that exists but isn't a git repo, a missing
`repo_path`/branch, or an unexpected git error also defer as
`worktree_probe_failed` (never guess "safe"). A `work_dir` that is *set* but simply absent from disk is **not**
indeterminate — there is categorically nothing left in it to lose, so that
case is treated as safe and falls through to the ordinary `already_absent`
skip below. Both `unsafe_worktree` and `worktree_probe_failed` count as
**stall** deferrals. The
probe is skipped (worktree removed exactly as before this guard) when the
gate reason is `pr_merged` (content demonstrably reached upstream already) or
when `MOTHER_TEARDOWN_ALLOW_UNSAFE=1` is set. See
`.claude/bugs/resolved/2026-06-13-merged-job-worktrees-never-gc-d-target-dirs-exhaust-disk.md`.

**Container convention:** `mother-run-job` exports `COMPOSE_PROJECT_NAME`
(job-scoped, derived by `mother_compose_project` in `lib/state.sh`) into
every worker, so a plain `docker compose up` needs zero convention-following
to be teardown-safe. Anything started outside compose must carry the label
`mother.job_id=$MOTHER_JOB_ID` (see `templates/preamble.md`) or Mother can't
find it. Every docker mutation in the teardown path carries either the
`-p <project>` compose flag or one of these label filters — never an
unfiltered `docker system/volume/container prune`.

Teardown eligibility is decoupled from the record-archiving age cutoff
(`MOTHER_ARCHIVE_OLDER_THAN`, default 30 days). `cmd_archive`'s bulk sweep
gives every terminal job younger than the cutoff a **teardown-only** attempt
(`_teardown_only`) — same `_teardown_execute` call as the archive path, but
the job's JSON record stays in `$JOBS_DIR`; only the worktree/docker state is
touched. Once a job's `finished_at` crosses the cutoff it takes the normal
`_archive_one` path and its record moves. A job can legitimately get a
teardown attempt while young (e.g. torn down the hour its PR merges) and a
second, no-op attempt when it's later archived — `_teardown_record_fields`
guards against that second pass downgrading a recorded `torn_down` back to
`skipped`/`already_absent` in the job JSON (the events trail still records
both attempts truthfully). `mother archive <id>` (single-id form) and
`mother archive --older-than 0` are unaffected — both still archive-and-move
unconditionally, same as before this decoupling.

**The pending queue:** archiving moves a job's JSON out of `$JOBS_DIR`, so
"skip teardown this round, retry next sweep" can't be keyed off the job
record — after the move there's no live record to revisit. Deferred
teardowns instead get a self-contained facts snapshot at
`$MOTHER_ROOT/teardown-pending/<id>.json` (repo path, branch, work dir,
isolation, PR url, state — everything teardown needs, independent of whether
the job record still exists). Every bulk `mother archive` sweep drains this
queue first, re-evaluating the same gate; `mother archive <id>` re-attempts a
job's own record inline. `mother teardowns` lists pending records; `mother
teardowns --drain` re-attempts them on demand. `_teardown_drain` publishes the
ids it attempted this pass via the `TEARDOWN_DRAIN_IDS` side-channel global,
and `cmd_archive`'s bulk loop computes membership in that list **once per
job** and consults it from **both** of its branches: the teardown-only branch
skips the job entirely, and the archive-eligible branch still moves the
record but passes `skip_teardown=1` to `_archive_one` so teardown itself is
not re-run. Without both checks, a job with a pending record that has also
aged past the archive cutoff would get two `_teardown_execute` calls (and two
`gh pr view` calls) in the same sweep. `_teardown_attempt` (in
`lib/teardown.sh`) is the single choke point every caller (drain,
teardown-only, archive) routes through — it pairs each `_teardown_execute`
call with exactly one `_teardown_record_fields` write, so one attempt always
produces exactly one recorded outcome no matter which path drove it. A
consequence: `_teardown_drain` now keeps a still-live job's `teardown_status`
/ `teardown_reason` / `teardown_at` current too (previously only the archive
and teardown-only paths wrote those fields), so `mother teardowns --drain`
against a live job is no longer lossy.

**Deferral counters:** each pending record tracks two counts. `deferrals` is
the total number of *stalled* attempts and `stall_deferrals` is what the
attention cap gates on. **Healthy waits (`pr_open`, `pr_open_live`) move
neither**: while a PR really is open, each sweep re-checks it as a quiet
no-op — it refreshes `last_reason` / `last_checked_at` and an
`open_pr: {url, created_at, first_seen_open_at}` object (`created_at` comes
from one `gh pr view` per PR per lifetime, not per sweep), and emits a
`teardown_deferred` event only on the **first** pass of the wait (or when the
open PR changes). The operator hears about a PR wait only once it has been open
longer than `MOTHER_TEARDOWN_PR_OPEN_ATTENTION_DAYS` (default 7), as a
`pr_open_stale` attention item. `mother teardowns` shows a healthy wait as
`waiting: PR open Nd (<url>)` and everything else as `stalls=N/cap`.
Crossing the reason's cap in `stall_deferrals` — `MOTHER_TEARDOWN_PROBE_FAILED_MAX_DEFERRALS`
(default **2**, about two hourly sweeps) for `worktree_probe_failed`,
`MOTHER_TEARDOWN_MAX_DEFERRALS` (default 30) for everything else — emits
`teardown_needs_attention` exactly once (on the crossing, not every
subsequent pass) *and* keeps the record listed as a `teardown_stalled` attention
item for as long as it stays over the cap; it only makes a genuine stall
(gh/docker unreachable, a racing job, a missing PR url, a worktree error, the
kill switch left off) loud, it never triggers destruction. Records written
before these counters existed default `stall_deferrals` to 0 via `// 0` — no
backfill needed, and historical `deferrals` values are left as they were.

**Events** (see `_teardown_event` in `lib/teardown.sh`):

| Event | Detail | When |
|---|---|---|
| `teardown_started` | `{gate_reason, pr_url}` | Gate passed, about to remove |
| `teardown_completed` | `{worktree_path, worktree_removed, compose_project, containers, volumes, networks}` | Teardown finished |
| `teardown_deferred` | `{reason, pr_url, conflicting_job_id, deferrals}` — `reason` includes `pr_open_live`, `unsafe_worktree` (detail merged in), `worktree_probe_failed` | Retryable skip; record queued. For the healthy waits `pr_open`/`pr_open_live` only the **first** pass of a wait (or a change of open PR) emits it — later passes are silent |
| `teardown_skipped` | `{reason}` | `disabled` / `main_dir` / `already_absent` |
| `teardown_failed` | `{stage, note}` | Docker or worktree step errored |
| `teardown_needs_attention` | `{deferrals, stall_deferrals, reason}` | Stall cap crossed (once) |

**Job fields:**

| Field | Type | Description |
|---|---|---|
| `teardown_status` | string | `torn_down` / `deferred` / `skipped` / `failed` |
| `teardown_reason` | string | Gate or skip reason from the last attempt |
| `teardown_at` | string | ISO timestamp of the last teardown attempt |

**Kill switches:** `MOTHER_TEARDOWN_ENABLED=0` disables teardown entirely
(worktree/containers are left alone, but a pending record is still queued so
nothing is lost if the switch is flipped back on). `MOTHER_TEARDOWN_DOCKER_ENABLED=0`
skips only the docker sweep. `MOTHER_TEARDOWN_MAX_DEFERRALS` (default 30) tunes
the stall-attention threshold above (counted in `stall_deferrals`, not raw
`deferrals`). `MOTHER_TEARDOWN_ALLOW_UNSAFE=1` (default `0`) restores
unconditional force-removal, bypassing the unrecovered-work guard above —
an explicit opt-out for an operator who has already confirmed a worktree's
"unsafe" state is fine to discard. All switches behave identically on the
teardown-only path and the full-archive path.

**Summary line:** `cmd_archive`'s bulk sweep reports three mutually exclusive
counters: `archived: N, teardown-only: M, skipped: K (cutoff: ...)`.
`teardown-only` counts jobs actually given a teardown attempt without their
record moving; `archived` counts jobs whose record moved into
`archive/YYYY-MM/`. A job short-circuited by `_teardown_only` (already
`torn_down`, worktree absent, no pending record — nothing left to do) counts
as `skipped`, not `teardown-only`, since no attempt was made. Likewise a job
the drain already handled this sweep counts as `skipped` on the teardown-only
branch (see the pending-queue section above) rather than double-counted.

**Out of scope (deliberately):** git branch deletion, retroactive cleanup of
worktrees/containers left behind by jobs archived before this feature shipped,
and the operator's personal `/prune-worktrees` slash command (a separate,
Mother-unaware, manual tool for worktrees Mother did not create).

## PR detection (evidence-based, not branch-name-based)

`plugins/mother/lib/prdetect.sh` is the shared library behind "did this job
produce a PR?" — sourced by `bin/mother`, `bin/mother-run-job`, and
`lib/teardown.sh`. It replaced a weaker pair of proxies (the assigned branch
name, and a set-once `pr_url` field trusted as-is) with live evidence: which
commits exist, which PR actually contains them, what GitHub says right now.
See `.claude/bugs/resolved/2026-06-15-worker-ignores-assigned-branch-name.md`
and `.claude/bugs/resolved/2026-08-14-review-phase-silently-reviews-wrong-repo-when-worktree-is-torn-down.md`
for the incidents that drove this.

Key functions (all read-only, all degrade to empty/non-zero — never crash —
when `gh` is missing, offline, or unauthenticated):

| Function | Purpose |
|---|---|
| `prd_owner_repo_from_url` / `prd_owner_repo_from_dir` | Resolve a `owner/repo` slug from a remote URL or a working directory's `origin` remote. |
| `prd_candidate_shas` | Up to 12 candidate commit SHAs identifying "what this job produced" (HEAD, the assigned branch's own tip, and recent commits ahead of base), most specific first. |
| `prd_pr_for_branch` | The open PR (if any) whose head is a given branch — the cheap, common-case path. |
| `prd_pr_for_commit` | A PR (preferring OPEN, else most recently updated) containing a given commit. |
| `prd_pr_contains_sha` | 0/1/2 (contains / clean miss / indeterminate) — whether a PR's commit list contains a given SHA. |
| `prd_detect_pr` | The entry point: branch match first, then commit match over `prd_candidate_shas`, else empty. |
| `prd_sha_on_origin` | Whether HEAD has reached origin under *any* branch name — and, when a base ref is supplied, is genuinely ahead of it. |

**mother-run-job's post-run capture** (`_finalize_pr_url`) re-derives rather
than trusts: a stored `pr_url` that's no longer `OPEN` is replaced by whatever
`prd_detect_pr` finds now (event `pr_url_updated`); a PR whose head branch
doesn't match the job's assigned branch is no longer automatically cleared —
it's accepted when the job's `expect_branch_mismatch` field is set, or when
`prd_pr_contains_sha` confirms the PR actually contains one of the job's
commits (event `pr_branch_mismatch_accepted`, `.actual_branch` recorded); a
confirmed miss still clears it (`pr_url_branch_mismatch`, unchanged); a `gh`
failure during the check leaves the URL untouched rather than destroying a
pointer over a network wobble (`pr_branch_mismatch_unverified`).
`_verify_artifact_or_fail`'s `no_pr_no_push` failure gets one more escape
hatch: if `prd_sha_on_origin` finds HEAD on origin under a *different* branch
name, the job succeeds anyway (event `pushed_to_other_branch`) instead of
failing over a branch-naming miss when the work genuinely shipped. That hatch
requires HEAD to be strictly ahead of `base_ref` (passed as `prd_sha_on_origin`'s
second argument) — a HEAD identical to base is already on origin by
construction, so without this precondition a worker that committed nothing
would pass the check vacuously and report `succeeded` for no work at all.

**Scraped URLs are gated, never trusted.** Both transcript-scrape paths — the
live poll-loop capture (`_live_capture_pr_url`) and `_finalize_pr_url`'s
last-resort fallback (`_finalize_scrape_pr_url`) — pass each candidate URL
through `_accept_scraped_pr_url` (`bin/mother-run-job`). A URL in the log is not
evidence the worker opened that PR: any doc, plan, `gh pr list` or `git log`
output the worker reads can mention one (the 2026-10-03 incident: a Read
`tool_result` linking an already-merged PR was recorded 23s after start). The
gate accepts only when GitHub-side evidence ties the PR to this job — its
`headRefName` equals the job's branch, `expect_branch_mismatch` is set, or
`prd_pr_contains_sha` finds one of the job's commits **ahead of `base_ref`** —
and always rejects a MERGED/CLOSED PR while the job has no commits beyond
`base_ref`. Candidates are tried newest-first, so an unrelated URL read later
can't shadow the real one. Rejections emit `pr_url_rejected` and record nothing;
the live path remembers *definitively* rejected URLs per spawn
(`_pr_rejected_urls`), so they are neither re-queried nor re-reported. Transient
failures (`pr_unresolved`, `evidence_indeterminate`, `gh_unavailable` — `gh`/network
trouble, not evidence) are not remembered: the next poll tick retries, the event
(`transient: true`) is emitted once per URL, and after
`MOTHER_PR_TRANSIENT_RETRY_CAP` (default 10) failures the live path stops
retrying that URL for the spawn and leaves it to finalization. With `gh` missing the live
path records nothing; finalization keeps its pre-gate offline behavior and
emits `pr_url_unverified`.

| Event | Detail fields | When emitted |
|---|---|---|
| `pr_url_rejected` | `{url, reason[, transient: true]}` — definitive reasons: `head_branch_mismatch`, `merged_before_job_commits`, `closed_before_job_commits`; transient (`transient: true`, retried): `pr_unresolved`, `evidence_indeterminate`, `gh_unavailable` | A scraped PR URL failed the evidence gate; once per URL per spawn |
| `pr_url_unverified` | `{url, reason: "gh_unavailable", note}` | Finalization recorded a scraped URL without verification because `gh` is missing |

**`no_pr: true` jobs get their own, separate verification**
(`_verify_no_pr_commits_or_fail`, called from `_verify_artifact_or_fail`
instead of the push/PR logic above): a captured `pr_url` still short-circuits
to success, but otherwise the job must have at least one commit ahead of
`base_ref` on a ref that depends on isolation — `HEAD` for `worktree` jobs
(a dedicated workspace, safe to trust), or `refs/heads/<branch>` for
`main-dir` jobs, because a main-dir workspace's `HEAD` may have already been
restored to the operator's original branch by `_restore_auto_stash`
(`lib/autostash.sh` does the work) that runs before verification. Zero commits fails with `reason:
no_commits_on_branch`; an unresolvable `base_ref` or missing branch ref fails
closed with `reason: commit_check_indeterminate` (same fail-closed precedent
as `prd_sha_on_origin` above — a false `succeeded` is worse than a false
`failed`). A successful check appends a `no_pr_commits_verified` event
(`{branch, base_ref, tip_ref, commits_ahead}`). The count is cumulative
commits on the branch, not commits attributed to this specific worker run —
in a pipeline job, earlier phases' commits already on the branch satisfy a
later phase (e.g. marty finding nothing to refactor) that makes none of its
own.

**`mother add`** gained `--expect-branch-mismatch` (also settable via the
plan's `suggested_config` YAML block) for the deliberate cross-branch case,
and warns (stderr, does not fail) when the plan's own `## Target` `**Branch:**`
line disagrees with `--branch`.

**`mother reconcile <id> [--pr-url URL] [--auto] [--yes] [--dry-run]`** gives a
job that failed detection (but may have real, shippable work on GitHub
already) a route straight to `succeeded` with the real `pr_url` attached,
without spawning a worker. Applies to `failed`/`cancelled`/`succeeded` jobs.
Resolves the PR from `--pr-url` or auto-detection via `prd_detect_pr`;
requires verification (branch or commit match) unless `--yes` is passed.
Never touches `current_tier`/`escalation_count` — the cost audit trail stays
truthful. Emits `reconciled` (`{pr_url, previous_state, match_kind,
matched_sha, source}`) then `succeeded`. Exit codes: `0` adopted, `1`
refused/error, `3` (only with `--auto`) nothing detected/verified — the
non-interactive contract `mother-runner`'s `_auto_escalate_failed` uses to
try reconciliation before escalating a failed job (gated by
`MOTHER_RECONCILE_ENABLED`, see Kill switches above).

**`mother retry` / `mother escalate` / `mother force-start`** all run
`_guard_existing_pr` before dispatching: when the job's branch already has a
verified open PR, they refuse (naming the PR and pointing at `mother
reconcile`) unless `--yes` is passed (new flag on `retry`/`escalate`;
`force-start`'s existing `--yes` now also bypasses this guard, not just its
interactive confirmation prompt).

**`mother review-phase`** hard-fails (event `review_workdir_missing`, no
reviewer spawned, no findings written) when the job's resolved `work_dir`
doesn't exist, instead of falling back to rendering artifacts and spawning
the reviewer against the operator's ambient cwd — the exact failure mode in
the 2026-08-14 bug doc above, including a fabricated finding about a
completely unrelated repo.

## Pipeline visibility (W5)

W5 makes the SDLC pipeline observable. Key surfaces:

### `cycles` derived field on JSON output

`mother list --format json` and `mother status --format json` attach a `cycles`
array to `kind: "pipeline"` jobs. Standard jobs carry no `cycles` key (back-compat
guaranteed by a regression test). The `cycles` array is derived at read time from
`pipeline.*` fields and the events log — W4 does not store it.

Schema per cycle:
```json
{"cycle": 1, "phases": [
  {"agent": "redd",  "request_type": "test",    "state": "completed",
   "started_at": "...", "finished_at": "..."},
  {"agent": "cody",  "request_type": "build",   "state": "running", "started_at": "..."},
  {"agent": "marty", "request_type": "refactor", "state": "pending"},
  {"agent": "perri", "request_type": "review",  "state": "pending", "findings": 0}
]}
```

- Cycle numbers are **1-indexed** in output (`pipeline.review_cycle` is 0-indexed internally).
- Timestamps (`started_at`, `finished_at`) come from the lifecycle events below;
  absent for jobs that predate those events.
- Build agents not in `pending_agents` on re-run cycles carry `"state": "skipped"`.

### Lifecycle events

These four events are emitted by `mother-runner` alongside the existing `pipeline_*`
events. All classify as `activity` in the IPC broker (not `state`).

| Event | Detail fields | When emitted |
|---|---|---|
| `phase_started` | `{cycle, agent, request_type}` | When driver advances a build phase to `ready` |
| `phase_completed` | `{cycle, agent, request_type}` | When driver advances past a completed build phase |
| `review_cycle_started` | `{cycle, reviewers}` | Alongside `pipeline_review_started` |
| `review_cycle_completed` | `{cycle, decision, findings_count}` | After B4 decision, before state transitions |

The `_pipeline_cycles_json` helper uses these events for timestamps. If they're absent
(e.g. the job predates these events), timestamps are simply omitted.

### Advisory findings — display and IPC

- `mother status <id>` renders a distinct `Advisory findings:` block in the pipeline
  section, listing each advisory with `[advisory] <summary> (<reviewer>)`.
- `mother list <id>` appends ` · N advisor(y/ies)` to the `shipped` label when
  `pipeline.advisories` is non-empty.
- The IPC broker's `mother_jobs` snapshot includes `pipeline.advisories` verbatim in
  the raw job JSON passthrough — no Go change needed; the field reaches clients
  automatically once W4 writes it.

## Preview stacks (lifecycle hooks)

`lib/preview.sh` holds all preview logic (`mother preview …`, the stop function, the backend seam).
Teardown hooks, all best-effort, watchdog-bounded and event-only (`preview_stop`, never `_transition`):

| Hook | Where | Reason |
|---|---|---|
| `_preview_pre_spawn` | `mother-run-job`, right after `_rwx_pre_spawn` | `attempt_start`: only when a previous worker left a non-stopped `.preview` |
| `_preview_post_exit` | `mother-run-job`, right after `_rwx_post_exit`, and in `_runner_died_trap` | `worker_exit`: after EVERY worker exit; skipped with `reason: newer_worker` when `.worker_pid` isn't ours |
| `_orphan_preview_stop` | `mother-runner` orphan reaper, next to `_orphan_rwx_stop` | `orphan`: every isolation (a stack stop isn't keyed to a worktree) |

`mother_preview_stop <job_id> <reason>` reads only the job record, never the worktree. It's a no-op
without `.preview` or when already `stopped`, treats CLI `down` exit 2 as ok, writes `status`
`stopped`/`stop_failed`, removes `$RUNNER_DIR/<job>.preview-secrets.json`, and appends `preview_stop
{outcome: ok|error|timeout|skipped, backend, reason, exit_code, duration_s, output_tail}`. A failed
`up` leaves a provisional record so the hooks still stop a launch that was dispatched before the CLI
failed or timed out. `_preview_backend_up` / `_preview_backend_stop` are the only functions that know
how to launch/stop; the operations backend is deferred behind them (see `docs/design.md`).

## Resume-answer continuity

An operator's `mother resume <id> "<answer>"` reply to a `mother await` question
is, functionally, a live amendment to the plan document — the plan itself is
never rewritten to reflect it. Two downstream consumers used to never see that
amendment at all: the idle-timeout auto-continuation preamble, and the
adherence-review prompt. Both now do.

`_resume_qa_history` (in `plugins/mother/lib/state.sh`) is the single renderer
that feeds both. It walks a job's event log pairing each `awaiting_input` event
with the `resumed` event that answers it, and renders every pair — in
chronological order, most-recent labelled — as a `## Operator Answers` markdown
block. `_attempt_continuation` (in `mother-run-job`) splices that block into the
continuation prompt via `_continuation_preamble`; `cmd_adherence_review` (in
`mother`) splices it into Archie's review prompt, immediately after the
`## Original Plan` section.

The `resumed_from_input` event is deliberately **not** the source. It fires on
every spawn that consumes a `pending_answer` — including adherence rework and
continuations themselves — so its `answer` field is often a machine-generated
preamble rather than operator-authored text. Only `awaiting_input`/`resumed`
pairs are operator-authored.

`_resume_not_yet_acted_on` detects the sharper failure mode the original bug
report described: a job resumed with an operator answer, then idle-timed-out
with no commit postdating that resume — meaning the previous worker almost
certainly never got to implement the answer. When `_attempt_continuation`
detects this it sets the sticky `resume_not_yet_acted_on` job field (see the
job-fields table above), surfaces a `⚠️ The operator's answer may not have been
implemented yet` warning directly in the continuation prompt, and emits a
`resume_not_yet_acted_on` event (once, on the crossing — mirroring the
`teardown_needs_attention` precedent in `lib/teardown.sh`) alongside the
existing `continuation_queued` event, which is otherwise unchanged. The event
classifies as `activity` in the IPC broker, like `resumed` and `escalated`.

| Event | Detail fields | When emitted |
|---|---|---|
| `resume_not_yet_acted_on` | `{resumed_at, last_commit_epoch, last_commit_sha, continuation_count, note}` | Once, when an idle-timeout continuation is queued for a job resumed with an operator answer that has no commit postdating it |

`mother status <id>` renders a `⚠️  [RESUME-MAY-BE-UNAPPLIED]` banner whenever
`resume_not_yet_acted_on` is `true`, in any job state — it's an audit signal,
not an operational one, and is never cleared automatically.
