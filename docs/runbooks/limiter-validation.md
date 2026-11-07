# Limiter validation runbook (MC-41, MC-43)

The backpressure limiter is observe-only until you decide otherwise. It computes what it *would* admit, hold or
cut and logs it next to what dispatch did. This runbook is how you decide it is safe to let it enforce. Every
step is run by hand, and each says what to record. Keep the notes in one place (a dated file under
`.claude/notes/` is fine); the report output is the evidence.

Reading tools: `mother limiter` (now), `mother limiter signals` (raw values), `mother limiter report --since <24h|3d|ISO>`
(history). `mother status` shows the same summary under `Concurrency:`.

**Targets (MC-41), checked by `mother limiter report`:**

| Target | Report line |
|---|---|
| 429 rate under 1 per 10 job-hours | `429 rate: 0.4 per 10 job-hours (target < 1) PASS` |
| the 5h window is never exhausted while the limiter is admitting | `5h exhausted while admitting: 0 (target 0) PASS` |
| `k` (% of window per USD) is calibrated for 5h | `5h k calibrated: yes (target true) PASS` |

"Distress" is what the limiter counts: a 429/503/529 retry or result, a non-overage `rate_limit_event` rejection,
or a `failure_routed` event for `rate_limited`/`api_overloaded`. The tick writes each one to
`$MOTHER_ROOT/limiter/distress.jsonl`. Job-hours come from the decision log's `actual.running` samples (a sample holds
until the next one, and a gap over 15 minutes counts as 15 minutes: that is a limiter outage, not running time).

## 0. Before you start

1. `mother limiter` says `mode: observe` and no `limiter: not running` line. If it is not running, fix that first
   (`mother doctor`, `$MOTHER_ROOT/runner/limiter.err`, `limiter-fault.json`). A report over a stretch where the
   limiter was down measures nothing.
2. Note the current `MOTHER_CONCURRENCY` (`mother status`, first line). Record it, the date and the Bishop feed
   source (`mother limiter signals`, `feed:`).
3. Leave `MOTHER_LIMITER_MODE` unset.

## 1. Observe-only soak: at least 3 days at the current concurrency

Do nothing different. Run Mother as usual, including your normal interactive Claude sessions: the limiter needs
real interactive demand in the data.

After 3 full days (72 hours of the limiter running; the report's decision count shows it):

```bash
mother limiter report --since 3d
mother limiter report --since 3d --json > ~/soak-report.json
mother limiter signals
```

**Record:** the whole report; the divergence counts and top codes; `k` and its sample count for each window;
how many 5h windows you went through; anything that surprised you.

How to read the divergences:

- `would_hold_but_spawned`: the limiter would have held a job that dispatch started. The top code says why
  (`reserve`, `budget_pace`, `backoff`, `ramp`, `interactive_personal`, `retry_after`, `concurrency_full`). A few
  are expected. A steady stream of `budget_pace` while no 429 followed means the pace estimate is conservative
  (`k` low or the sustainable rate tight): note it, do not change anything yet.
- `would_admit_but_waited`: the limiter would have started a job that dispatch held (rate-limit pause, quota
  gate over cap, low disk, concurrency full). These are dispatch's existing rules winning, and are not a fault.

If `5h k calibrated` is `no`, the soak was too quiet (under 12 usable samples for the window): extend it. Until `k`
is calibrated, `budget_pace` never holds, so the soak says nothing about pacing.

## 2. Staged ramp: 3, then 4, then 6

Raise concurrency in steps, never skipping one. Edit `~/.mother/config.env`:

```
MOTHER_CONCURRENCY=3
```

then restart the daemon so it reads it (`mother daemon stop && mother daemon start`; `mother status` shows the new value and
`source: config file`). The limiter picks up the same value on its next tick.

Each step runs for **at least one full 5-hour window** (watch `mother limiter signals` for the 5h `resets:`
time and let it pass once while jobs are running). If the queue is empty the step proves nothing: queue enough
work to keep the new concurrency busy.

At the end of each step run:

```bash
mother limiter report --since <the step's duration, e.g. 8h>
mother limiter signals
```

**Record, for every step (3, 4, 6):**

1. the concurrency and the start and end times (Central);
2. the full `mother limiter report` output;
3. window movement: 5h `used %` at the start and the end of the step and the peak, and the 7d `used %` movement
   (from `mother limiter signals`, or `mother quota status`);
4. the 429 count (`distress:` line) and how many of them the limiter cut for (`concurrency` state `backoff` in
   `mother limiter` while it happened);
5. one line on how your interactive sessions felt (did Claude Code slow down, hit limits, wait?).

**Move to the next step only if** the step's report shows `429 rate ... PASS` and `5h exhausted while admitting: 0`.
On a FAIL, drop back to the previous concurrency (edit `config.env`, restart the daemon), record why, and repeat
that step after the cause is understood.

## 3. Exit criteria

All of these hold at concurrency 6:

- `mother limiter report` over the concurrency-6 step shows `429 rate ... PASS` (under 1 per 10 job-hours) and
  `5h exhausted while admitting: 0 ... PASS`;
- `5h k calibrated: yes ... PASS` (`mother limiter signals` shows the 5h `samples` at or above the minimum, 12 by default);
- you recorded all three steps and the interactive-feel note for each.

If any fails, stay in observe mode, fix or retune, and redo step 2 at 6.

## 4. Enforcement

Only after step 3, and only you, at a terminal: `mother limiter mode enforce`. It is refused from a worker or an
agent's subprocess (logged to `limiter/mode-refusals.jsonl`); changes are audited in `limiter/mode-audit.jsonl`.
`mother limiter mode` prints the current mode. `MOTHER_LIMITER_MODE=enforce` in the environment is **not**
honoured (only `off` is): enforcement lives in `limiter/mode.json`.

Under enforce the limiter decides which ready jobs start (budget pace, reserve, backoff after distress, ramp after
a reset, interactive demand for personal work; company work first, `--priority raise|lower`), bounded by
`min(MOTHER_CONCURRENCY, allowed)`. Running jobs are never touched in this slice. The quota-gate 90% cap stays as a
backstop; with the gate `off`/`off_until_reset` the budget terms are advisory (the `limiter_enforcing_gate_off`
item says so). If the limiter goes stale or faults, dispatch falls back to fixed concurrency and `mother status`
shows `limiter_fault`. Watch `mother limiter report`: under enforce, `divergence` entries are a bug signal.

## 5. Backing out

- Observe-only mode changes no dispatch, so there is nothing to undo for that. To stop the limiter observing at
  all: write `{"mode":"off"}` to `$MOTHER_ROOT/limiter/mode.json` (preferred: the daemon and the `mother limiter`
  CLI both read it), or set `MOTHER_LIMITER_MODE=off` in the daemon's environment (a hard kill switch that wins over
  everything; note a `mother limiter` run from your own shell may not see it, so the CLI can disagree with the daemon). `mother limiter --json`
  then prints `{"v":1,"mode":"off"}`.
- `mother limiter mode observe` returns from enforce to observe-only (dispatch is exactly as before the limiter),
  and `MOTHER_LIMITER_MODE=off` still turns it off completely.
- To undo a concurrency step: set the previous `MOTHER_CONCURRENCY` in `~/.mother/config.env` and
  `mother daemon stop && mother daemon start`.
