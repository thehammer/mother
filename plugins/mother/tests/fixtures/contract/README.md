# Headless-crew contract fixtures

Broker transcripts that show Nostromo (and any other client) what the headless-crew producers put
on the wire. The contract itself is documented in `docs/design.md`, "Headless crew contract (Phase 1)".

**Recorded** by `plugins/mother/scripts/record-contract-fixtures.sh` at `8fd283d`; re-run it after any
contract change (`tests/contract.bats` fails when the committed files no longer match a fresh recording).

The script runs each scenario through the real `mother add`, `mother-run-job`, `mother-usage progress-tick`
and (for the answer) the real broker `answer` command, which shells out to `mother resume --option`. `claude`,
`gh` and `rwx` are scripted stand-ins; everything else is the real binaries. A python client subscribed to every
category (`state, activity, await, current_activity, quota, progress`) records each message it sends and receives.
Volatile values are then normalised to stable placeholders, so a re-recording is byte-identical:

| Value | Normalised to |
|---|---|
| job id, decision id, session ids, shas | `j-gates1` / `j-wave1` / `j-hold1`, `d-0001…`, `0000…0001…` counters |
| paths | `/tmp/mother-root/…`, `/tmp/work/admin-portal`, `/tmp/origin.git` |
| data timestamps (`created_at`, `updated_at`, `since`, …) | before the stream; each timestamp key is its own rank space, one second apart **in real order** (so `progress.updated_at` strictly increases), the key spaces in lifecycle order |
| envelope `ts` | `2026-10-18T12:00:00.000Z` + 10 ms per line: monotonic, an ack is never earlier than its cmd |
| `duration_s`, `elapsed_active_s`, pids, `log_offset`, `stage_frac` (nearest 0.25) | fixed or quantised |

Three things are dropped or reordered because they are timing races, not contract: `final_result_observed`
(a poll-loop event) is omitted, the parallel reviewer spawn events (`adherence_review_spawned`, `review_spawned`) are put in reviewer-name order, and the ack of
the `answer` command is placed after the events its `mother resume` produced (it is sent when that command exits).
Reviewers are released one at a time, so every `reviewed` event arrives in a fixed order.

## Format

One broker message per line (NDJSON), in the exact envelope from `broker/envelope.go`:

```
{"v":1,"dir":"event|cmd|ack","t":"<kind|command>","id":"<id>","ts":"<ISO-8601 ms Z>","data":{...}}
```

- Events (`dir: event`) use a per-connection monotonic `id`; `data` is the event detail plus
  `job` and `category`.
- Commands (`dir: cmd`) and their acks (`dir: ack`) share the command's `id`.
- Snapshot jobs are the real job records the broker serves (existing keys with unchanged types, plus
  the new keys `crew`, `gates`, `review_wave`, `decision`, `attention`, `attention_reasons`, `progress`).
- `crew.gates.mode` / `crew.lenses.mode` are configuration. Read `gates.mode` and `review_wave.mode`.
- `progress.label` is the Mother-rendered display line (`≈80% · gates ✗ attempt 1/3 · ETA ?`); render it verbatim.

## Files

| File | Shows |
|---|---|
| `gates_fix_pass.ndjson` | gate fails (`unit`), a fix run in the same session, gates pass, a clean one-lens wave, PR ready; `progress_updated` throughout; a reconnect (re-subscribe) mid-fix |
| `lens_wave.ndjson` | reviewer wave with a skipped lens (`ops-infra`, `path_scope`), a blocking human finding, an advisory finding, a refuted claim, then a `review_hold` decision; reconnects mid-wave and at the hold |
| `gate_hold_answered.ndjson` | gates exhausted, `gate_hold` decision opened, `answer {option: "resume_with_guidance", text, source}` over the broker, its ack, `decision_resolved`, `resumed`, and a reconnect snapshot after the job has left `awaiting` |

The repo in every scenario is named `admin-portal`, so it is PHI-sensitive (`MOTHER_PHI_REPOS`): the recorder
seeds `SENTINEL-PHI-42` into gate output, finding text, claim quotes, adherence notes and acceptance-criteria
text, and none of it may appear in a recording (`contract.bats`).

## Checking

```bash
plugins/mother/scripts/contract-check.sh plugins/mother/tests/fixtures/contract/*.ndjson
some-recorder | plugins/mother/scripts/contract-check.sh      # stdin
plugins/mother/scripts/record-contract-fixtures.sh            # re-record in place (about 4 minutes)
```

Exit 0 when conforming; otherwise `file:line: reason` per violation and exit 1.
