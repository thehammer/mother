# Headless-crew contract fixtures

Hand-written broker transcripts that show Nostromo (and any other client) what the
headless-crew producers will put on the wire. The contract itself is documented in
`docs/design.md`, "Headless crew contract (Phase 1)".

**Provisional.** These are written by hand, not recorded. HC-16 re-records them from real
runs at the same paths and with the same names. Treat shapes and names as the contract; treat
ids, SHAs, timings and costs as illustrative.

## Format

One broker message per line (NDJSON), in the exact envelope from `broker/envelope.go`:

```
{"v":1,"dir":"event|cmd|ack","t":"<kind|command>","id":"<id>","ts":"<ISO-8601 ms Z>","data":{...}}
```

- Events (`dir: event`) use a per-connection monotonic `id`; `data` is the event detail plus
  `job` and `category`.
- Commands (`dir: cmd`) and their acks (`dir: ack`) share the command's `id`.
- Snapshot jobs carry the existing job keys Nostromo's fake broker emits
  (`id, state, repo, isolation, title, created_at, started_at, finished_at, ...`) with unchanged
  types; new data appears only under new keys.

## Files

| File | Shows |
|---|---|
| `gates_fix_pass.ndjson` | gates fail, a fix run, gates pass, PR marked ready; `progress_updated` interleaved |
| `lens_wave.ndjson` | reviewer wave with a skipped lens, lens-qualified reviewers, claim verification |
| `gate_hold_answered.ndjson` | gates exhausted, decision opened, answered with `option` and `source`, job re-queued |

## Checking

```bash
plugins/mother/scripts/contract-check.sh plugins/mother/tests/fixtures/contract/*.ndjson
some-recorder | plugins/mother/scripts/contract-check.sh      # stdin
```

Exit 0 when conforming; otherwise `file:line: reason` per violation and exit 1.
