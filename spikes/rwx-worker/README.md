# RWX worker spike (Phase 0)

Evidence for "can an RWX task be a Mother worker?". Findings and the go/no-go are in
[`docs/spikes/rwx-worker-phase-0.md`](../../docs/spikes/rwx-worker-phase-0.md). Nothing here changes
Mother's runner, broker or CLI.

All commands use the **default `rwx` login** (organization `carefeed`; check with `rwx whoami`) and are run
from this directory (`spikes/rwx-worker/`), so `rwx` finds `.rwx/` here. Do not pass `--access-token`.

Rules the configs follow: the only vault referenced is `mother-spike` (secrets `CLAUDE_CODE_OAUTH_TOKEN`
and `SPIKE_DECOY`); the only repository cloned is the public `https://github.com/thehammer/nostromo.git`
(anonymously, no GitHub token in any task); `claude -p` always runs with `--model sonnet` and a turn cap.

## One-time: store the token

```bash
bash spikes/rwx-worker/set-vault-token.sh
```

`set-vault-token.sh` prompts (hidden) for a `claude setup-token` token, refuses anything that is not an
`sk-ant-oat...` token, strips whitespace, writes it to a private temp file only long enough for
`rwx vaults secrets set --vault mother-spike --file ...`, and deletes the file. The token never touches
the command line, shell history or process list. (A first attempt stored a 143-character value with
whitespace and no `sk-ant-` prefix, which gave `401 Invalid bearer token`; `.rwx/p1-diag.yml` prints only
the *shape* of the secret, never its value, and found that.)

## Probes

| Probe | File | Command |
|---|---|---|
| 1 auth (+ decoy masking) | `.rwx/p1-auth.yml` | `rwx run .rwx/p1-auth.yml --wait` |
| 1 diagnostic (secret shape only) | `.rwx/p1-diag.yml` | `rwx run .rwx/p1-diag.yml --wait` |
| 2 duration (4.5 h and 8.5 h) | `.rwx/p2-duration.yml` | `rwx run .rwx/p2-duration.yml --init minutes=255 --init timeout=270m` and `--init minutes=500 --init timeout=510m` (do not `--wait`) |
| 3 + 5 live/final extraction and a real job | `.rwx/p5-job.yml` | clean job: `rwx run .rwx/p5-job.yml --init delay-seconds=0 --init idle-minutes=0 --init topic=none --wait`; 20 min live variant: `--init delay-seconds=240 --init idle-minutes=16 --init topic=<random ntfy topic>` |
| 4 egress table | `.rwx/p4-egress.yml` | `rwx run .rwx/p4-egress.yml --wait` |
| 4 WebSocket hold (30 min) | `.rwx/p4-websocket.yml` | `rwx run .rwx/p4-websocket.yml --init minutes=30` |
| 6 resume elsewhere | `.rwx/p6-resume.yml` | needs `.rwx/p6data/` (gitignored): copy probe 5's `<session>.jsonl`, `session_id`, `original_path` from `rwx artifacts download <job-task-id> --all --auto-extract --output <fresh dir>`; then `rwx run .rwx/p6-resume.yml --wait` |
| 7 idle cost | `.rwx/p7-idle.yml` | `rwx run .rwx/p7-idle.yml` |

Live-extraction checks used by probe 3 (all read-only, run from outside):

```bash
rwx runs show <run-id> --json           # find the running task id
rwx logs <task-id> --output <fresh dir> # logs while the task is still running
# rwx ssh needs a TTY; to script it, wrap it in `script`:
( sleep 12; printf 'tail -n 5 /tmp/agent.log; exit\n'; sleep 3 ) | script -q /tmp/ssh.out rwx ssh <task-id> --max-duration 3m
```

## Collecting the long runs

```bash
spikes/rwx-worker/collect.sh <run-id>            # task key defaults to "duration"
spikes/rwx-worker/collect.sh <run-id> job        # any other task key
```

Read-only. Downloads the task log into a fresh temp dir and prints status, heartbeat count, first and last
heartbeat time, every `claude -p` result (start / 2 h / end) and the compute cost estimated from RWX's task
runtime x vCPUs x $0.00007. Tested on the probe 2 smoke run.

## Cleanup when the spike ends

Revoke the token at claude.ai (Settings, Claude Code tokens) and delete the vault if RWX is a no-go:
`rwx vaults delete mother-spike` (check `rwx vaults --help`).
