# Phase 0 spike: can an RWX task be a Mother worker?

Date: 2026-11-06. Org: `carefeed` (default CLI login). Vault: `mother-spike` only. Repo cloned: the public
`thehammer/nostromo` only. Configs, README and `collect.sh` are in `spikes/rwx-worker/`.
PRD: `.claude/prds/mother-cluster.md` (Phase 0, MC-11, MC-13, MC-22 to MC-25).

## Recommendation: GO WITH CONDITIONS (for RWX as a personal-repo worker kind, Phase 3)

Everything that decides feasibility passed: the vault token authenticates `claude -p`, a real job runs and costs
cents, a transcript restored on a different machine (even at a different checkout path) resumes correctly (so
MC-13 is possible), the task can hold an outbound WebSocket and push progress out live, and the data can be pulled
out live (logs, `rwx ssh`, outbound push) and at the end (artifacts).

Conditions, in order of how likely they are to bite:

1. **Duration is still pending** (4.5 h and 8.5 h runs, ids below). If the 270 minute run fails or its late
   `claude -p` calls get 401, cap RWX jobs at the longest surviving duration and rely on checkpoint and requeue
   (MC-13 works, see probe 6). If even the start-to-2 h call fails, token lifetime is the blocker: **no-go** until
   an API key (not a subscription token) is used.
2. **Account standing is a real, observed risk.** The `rate_limit_event` in probe 5's own output said the owner's
   subscription `five_hour` window was at 102% utilisation (`status: rejected`) and the job ran on **overage**
   (`isUsingOverage: true`, `overageStatus: allowed`). The spike's few cents of Claude use were billed as extra
   usage, not subscription quota. Mother must read that event and refuse to dispatch to paid workers (or at least
   alert) when a window is rejected.
3. **A task does not end while it has orphaned children.** Probe 3's task finished its script at 17:32 but stayed
   "running" (and billed at 4 vCPU) until the `tail -F` and `python3` helpers it had started were killed over
   `rwx ssh` nine minutes later, and its logs and artifacts were not available until then. A worker wrapper must
   reap all children (or run helpers under `rwx`'s background-process mechanism) and use `timeout`.
4. **No pause.** A waiting task costs the same as a working one (probe 7). MC-11 must end the task and requeue
   from the checkpoint rather than wait.
5. **Outbound WebSocket is fine from RWX** (probe 4): 25 minutes with zero drops to `wss://ntfy.sh`. The 10
   minute drops seen against `echo.websocket.org` were that server. The worker protocol needs reconnect-and-resume
   regardless.
6. **Secret masking is exact-match only**: the decoy was masked, its base64 was not. A worker must never print
   derived forms of a secret, and an agent with a shell can print the environment, so transcripts and artifacts
   must be treated as possibly containing the token.

What flips it to no-go: a failed duration run that is a token or platform limit under 2 h; a policy change by
Anthropic or RWX on unattended subscription tokens; or Carefeed objecting to a personal subscription token in a
Carefeed RWX org. What flips it to plain go: both duration runs pass with all three `claude -p` calls ok, and the
WebSocket drop turns out to be the echo server.

## Probe table

| # | Probe | Result | Evidence (run id) | Cost |
|---|---|---|---|---|
| 1 | Auth | **PASS** after the owner re-set the secret. `claude -p --model sonnet "Reply with the word ok"` printed `ok`, exit 0. Decoy masked (`********`); **base64 of the decoy not masked.** First two attempts failed `401 Invalid bearer token` because the stored value was 143 chars with whitespace and no `sk-ant-` prefix (shape diagnostic, run `01a1b1ccc10d752591eda38bb8810311`). A locked vault was readable by CLI-launched runs for the vault's user without any access change. | pass `01a1b1d161937db2aaffb9dd83d66b33`; fail `01a1b1cc3fb07af2b25436873a2e2f2b`, `01a1b1cb3ac27b4aa756842512d8f846` | about $0.06 |
| 2 | Duration | **PENDING.** Two 1 vCPU runs launched 17:07 UTC, no waiting. 270 min run and 510 min run both accepted by RWX and running. Each calls `claude -p` at start, at 2 h and at the end, heartbeat every 60 s. Smoke run (2 min) passed and `collect.sh` works on it. | 270 min: `01a1b1d48e49737eabae52814cea3675`; 510 min: `01a1b1d4979575059de9ec4e3bdee2cc`; smoke `01a1b1d1c6ee747c9a1ad20cb2e88756` | up to $1.13 and $2.14 (billed to timeout at worst) |
| 3 | Live and final extraction | **PASS**, see detail below. | `01a1b1d89aa17477af551d5e9315cec5` (task `01a1b1d89aa572028f82eef30c3ae3cb`) | $0.49 (9 min lost to orphan children) |
| 4 | WebSocket and egress | **PASS.** 30 min hold to `wss://echo.websocket.org`, ping every 20 s: 91 pings, 89 pongs, 2 drops at about 10 min 10 s each, 2 reconnects (3 s each), RTT median 105 ms. Follow-up to `wss://ntfy.sh`, 25 min, protocol ping every 20 s: **0 drops**, RTT median 17 ms, so the drops were the echo server. Egress table below. | hold `01a1b1d6db4f76f1bd06a76a4cba10f7`; egress `01a1b1d4e3fb7acba83cf11f1bcf24c4`; follow-up `01a1b1f40bed7253b1cda8bea17d91db` | $0.13 + $0.01 + $0.11 (+ $0.04 cancelled run) |
| 5 | A real job and its cost | **PASS.** 4 vCPU, clone nostromo (2 s), `claude -p --model sonnet`, 3 turns, wrote `/tmp/out.md` (first line `# Slowest steps in docs/rwx-sandbox.md`). Claude wall 9 s (7 s in the 20 min run), `total_cost_usd` 0.0482 (first, cold cache) and 0.0161 (second). Usage, run 1: input 6, cache_creation 9,910, cache_read 55,097, output 941. RWX: task 14 s, billed at the 1 minute minimum, 4 x 60 x $0.00007 = $0.0168. `claude` install is one task, cached after the first run (about 14 s as a cache hit). | `01a1b1d805957183bc91f4a301547783` | $0.017 RWX + $0.048 Claude (list price) |
| 6 | Resume elsewhere | **PASS, all three variants.** Fresh container, transcript restored, `claude --resume <id> -p "What file did you write and what was its first line?"` answered `/tmp/out.md` and `# Slowest steps in docs/rwx-sandbox.md` in (a) same path, (b) different checkout path with the transcript under the ORIGINAL path's encoded name, (c) different path with the new path's encoded name. **No path rewriting was needed.** Session id preserved. | `01a1b1dfd63477028589970abad64c0c` | $0.008 RWX + $0.17 Claude |
| 7 | Idle cost | **No pause.** Two parallel 1 vCPU tasks, 10 min each: plain sleep ran 601 s and `rwx-breakpoint` (waiting for a debugger) 603 s, both billed for the whole time. Docs offer no suspend; sandboxes stop after 30 min of inactivity and are billed while alive. Filesystem state survives between tasks as a cached layer (7 days), process state does not (not measured across runs). | `01a1b1e0bda9708abb692d947761884c` | $0.085 |

### Probe 3 detail: how to get data out

| Method | Live? | Latency | Limits | Notes |
|---|---|---|---|---|
| `rwx logs <task-id>` while running | **partly** | worked in two tasks: a line printed 8 s earlier was present on the first poll, and a 25 min task's lines showed within 20 s | 5 MiB of logs per task, 28 days retention | Poll-based download, not a stream. Task id from `rwx runs show <run> --json`. **Not reliable for long tasks:** for the 20 min probe 3 task after about 25 minutes, and for both duration runs after 46 to 60 minutes, `rwx logs` returned an empty archive while the task was still running (the full log appeared once the task finished, probe 3). `claude -p` output is only visible if the task prints it. |
| `rwx ssh <task-id>` | yes | about 10 s to attach; then a live shell | `--max-duration`; needs a TTY | Works non-interactively only through a pty (`script -q`). `tail -F` of the transcript or log showed each line at 1 s granularity. Marks the run `debugged`. |
| Task pushes progress out (HTTPS POST to a public pub/sub; WebSocket proven in probe 4) | yes | 55 to 80 ms end to end from a Mac subscriber (clock skew included) | none seen | Best option for Mother: it is the same outbound channel the worker protocol needs. |
| `rwx artifacts` | **no, end only** | `rwx artifacts list` said none while running; present after the task finished | 10 GB free plus 250 MB per compute hour; 14 days | Uploaded `~/.claude/projects` (one 186 KB transcript for a 3 turn job), agent log (33 KB), out.md, diff. `rwx artifacts download <task> --all --auto-extract --output <dir>` took under a second. |

### Egress (from a task, 2026-11-06)

| Target | Result |
|---|---|
| HTTPS api.anthropic.com | allowed (HTTP 404 on `/`) |
| HTTPS github.com | allowed (200) |
| HTTPS crates.io | allowed (403, needs a User-Agent; reachable) |
| HTTPS pypi.org | allowed (200) |
| HTTPS registry.npmjs.org | allowed (200) |
| HTTPS raw IP 1.1.1.1 | allowed (301) |
| HTTPS claude.ai, astral.sh, ntfy.sh, echo.websocket.org | allowed |
| TCP 22 outbound (github.com) | **blocked or filtered** (no banner in 8 s) |
| UDP 51820 outbound | **unknown** (send returned ok; no listener to confirm). WireGuard from RWX is therefore unproven. |

### WebSocket follow-up

The two 10 minute drops against `echo.websocket.org` could be RWX (a connection or NAT limit) or that server.
A second 25 minute run held a protocol-level ping connection to `wss://ntfy.sh` to separate them:
25 minutes, 75 pings, 75 pongs, **0 drops, 0 reconnects**, RTT median 17 ms, max 22 ms (run
`01a1b1f40bed7253b1cda8bea17d91db`). So RWX does not cut long WebSocket connections at 10 minutes; the drops
were specific to `echo.websocket.org`. (A third run against `echo.websocket.events` failed DNS resolution, the host
no longer exists; it was cancelled, `01a1b1f415537a8abaf5c3d10a1db966`.) A worker still needs reconnect logic,
because public servers and networks drop connections, but the platform is not the limiter.

## Verified RWX facts versus the PRD's "Notes for Archie"

| PRD assumed (from public pages) | Verified |
|---|---|
| Default task timeout 10 minutes | Confirmed in docs (`rwx docs pull /docs/timeouts`). The key is `timeout` (not `timeout-minutes`). |
| Undocumented maximum | Still undocumented. 270 m and 510 m were accepted at launch; outcome pending. |
| No documented stdin or log streaming | Confirmed: no stdin, no streaming API. `rwx logs` can be polled while running, `rwx ssh` gives a live shell, and a task can push out. |
| Undocumented egress controls | No allowlist found in docs; measured table above: open except TCP 22. |
| Sandboxes stop after 30 minutes idle | Docs say 30 minutes (configurable `--inactivity-timeout`); the `sandbox stop` page says 1 hour. Not measured. |
| (not in PRD) compute sizes | Docs table lists 2 vCPU as smallest, but `cpus: 1` works (1 vCPU, 4 GB) and the pricing page lists it. $0.00007 per vCPU-second general purpose, 1 minute minimum per runner size per run. |
| (not in PRD) secrets | Masking is exact-match: base64 of the decoy was not masked. |
| (not in PRD) cost view | `rwx billing usage` is organisation-wide only; per-run cost has to be computed from task runtime x vCPUs (`collect.sh` does this). |
| (not in PRD) how a run is launched | `rwx run` attaches to the git repo of the working directory (run metadata shows `thehammer/mother`). A production worker should be dispatched with init parameters, not from a checkout. |

## MC-13 (resume on another machine): feasible

Probe 6 shows `claude --resume` works from a restored transcript on a fresh container with no path rewriting,
even when the checkout path differs, as long as the transcript is under `~/.claude/projects/<any project dir>/`.
Checkpoint size: the transcript (186 KB for a 3 turn read-only job; grows with tool output) plus `git diff` of
the checkout (empty here; the job wrote outside the repo). Caveats: only a short text session was resumed (no
tool use after resume, so file state was not exercised) and the model answered from the transcript, not from
files. File edits made in task A are NOT in B's fresh checkout unless the diff is applied, so the checkpoint must
be transcript plus diff (plus any untracked files), and the resume prompt should say what state to expect. If a
later test shows tool-using resumes misbehave, the fallback is: start a fresh session in B from the checkpointed
diff with a summary prompt.

## Spend

- RWX compute: about $1.5 so far (all probes except the two duration runs' remaining time) and a projected total of about $4.3 once the duration runs end (worst case about $4.4 if both run to their timeouts), well under the $12 cap (computed from task runtimes x vCPUs x $0.00007 with the 1 minute minimum; the
  organisation-level `rwx billing usage` cannot isolate the spike). Hard cap was $12.
- Claude (list price, from `total_cost_usd`): about $0.31 for probes 5 and 6 plus a handful of one-word calls.
  Some or all of it ran as subscription **overage** (see condition 2).

## What is NOT verified

- Runs beyond 2 minutes on one task for the token: the 4.5 h and 8.5 h runs are pending (`collect.sh`).
- Any RWX maximum task duration; whether 510 m survives. Also whether the duration runs' logs can be read live (they could not, so `collect.sh` is for after they finish).
- That the OAuth token itself is masked in logs (only the decoy was tested; the token is never read).
- That the agent cannot leak the token (no shell tool was given to Claude in the probes).
- A tool-using `claude --resume`, resume of a long transcript, resume with a non-empty diff.
- UDP 51820 delivery; any inbound connectivity; whether the WebSocket drop is RWX-side (unless the follow-up says so).
- Multiple concurrent RWX workers, concurrency pools, queueing delay, cold-start time without cache (a cache-hit
  start was about 3 to 5 s).
- Cross-run restoration of a finished task's filesystem (documented, not exercised).
- Phase 4 / Orderlies isolation, and anything about Carefeed repos or data (none were touched).

## After the spike

The owner should revoke the `claude setup-token` token (claude.ai) and delete the vault (`rwx vaults delete
mother-spike`) if RWX is a no-go. Temp files: transcripts and logs were downloaded only into fresh `/tmp`
directories and read as data.
