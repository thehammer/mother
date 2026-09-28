# Usage fixtures — expected computed values

Synthetic `claude --output-format stream-json --verbose`-shaped transcripts used
by `tests/usage.bats` and `tests/metrics.bats`. Rates below are from
`plugins/mother/lib/rates.json` (usd per Mtok):

| model | input | output | cache_read | cache_write_5m | cache_write_1h |
|---|---|---|---|---|---|
| claude-sonnet-5 | 2.00 | 10.00 | 0.20 | 2.50 | 4.00 |
| claude-opus-5-5 | 4.00 | 20.00 | 0.40 | 5.00 | 8.00 |

`claude-made-up-9` intentionally has no entry in `rates.json` — used to exercise
`cost_complete: false` / `unpriced_models`.

## main_only.jsonl
Single main-session actor (`parent_tool_use_id: null`), `msg_1` repeated 3x
(identical usage each time — simulates content-block deltas) and one distinct
`msg_2`. Dedup by `message.id` must collapse the 3 `msg_1` lines to one.

- Per-message tokens (post-dedup): `msg_1` in=1000+500(cache_read)=1500,
  out=300. `msg_2` in=2000, out=400.
- **tokens_in = 3500, tokens_out = 700**
- cost: msg_1 = 1000*2/1e6 + 500*0.20/1e6 + 300*10/1e6 = 0.002+0.0001+0.003 = 0.0051
  msg_2 = 2000*2/1e6 + 400*10/1e6 = 0.004+0.004 = 0.008
  **cost_usd = 0.0131**
- by_actor: `cody-main` only, `messages: 2` (post-dedup), `spawns: 0`

## subagents.jsonl
Main session (`cody-main`) spawns a `redd` subagent (tool_use id `tu_redd1`,
`name: "Agent"`, `input.subagent_type: "redd"`) and a `marty` subagent
(tool_use id `tu_marty1`, `name: "Task"`, `input.subagent_type: "marty"`).
Subsequent turns carry `parent_tool_use_id` matching those tool_use ids.

- `cody-main`: msg_m1 (in=500,out=50) + msg_m2 (in=600,out=60) →
  **tokens_in=1100, tokens_out=110, messages=2, spawns=2**
- `redd`: msg_r1 (in=300,out=100) → **tokens_in=300, tokens_out=100, messages=1**
- `marty`: msg_ma1 (in=400,out=150) → **tokens_in=400, tokens_out=150, messages=1**
- Overall: **tokens_in=1800, tokens_out=360**

## cache_split.jsonl
Two sonnet events, no plain input/output tokens — pure cache-write cost, split
between the 5m and 1h ttl tiers, so a parser that ignored the split (e.g.
always priced everything at the 5m rate, or summed the two token counts
before pricing) would diverge from one that multiplies each tier's own
tokens by that tier's own configured rate.

- `msg_x1`: 1000 tokens in `ephemeral_5m_input_tokens` only.
- `msg_x2`: 1000 tokens in `ephemeral_1h_input_tokens` only.
- tokens.cache_create_5m = 1000, tokens.cache_create_1h = 1000 (always, by
  construction of this fixture).
- **cost_usd** is *not* hardcoded here: `lib/rates.json` currently calibrates
  `cache_write_1h == cache_write_5m` for `claude-sonnet-5` (a deliberate,
  log-calibrated pricing decision documented in that file's `source` field —
  not a bug), so `tests/usage.bats` derives the expected cost from
  `rates.json`'s own `cache_write_5m`/`cache_write_1h` values
  (`1000*cache_write_5m/1e6 + 1000*cache_write_1h/1e6`) rather than assuming
  the two tiers differ. If rates.json's calibration changes again, the test
  still holds — it validates that each tier is priced at *its own* configured
  rate, not that the two rates happen to differ.

## opus_model.jsonl
Single `claude-opus-5-5` event, in=1000, out=200.
cost = 1000*4.00/1e6 + 200*20/1e6 = 0.004+0.004 = **0.008**

## unpriced_model.jsonl
Single event on `claude-made-up-9` (absent from rates.json), in=1000, out=100.
Tokens must still be counted (**tokens_in=1000, tokens_out=100**) but
**cost_complete: false** and `unpriced_models` must include `"claude-made-up-9"`.

## full_run.jsonl
Plaintext banner lines (not valid JSON — must be skipped, not fatal) followed
by one assistant event (in=1000, out=200, cost 0.004) and a terminating
`result` event with `total_cost_usd: 0.004` and
`modelUsage["claude-sonnet-5"].costUSD: 0.004`. Used to test `cli_cost_usd`
extraction (must read 0.004 from the result event, independent of whatever the
assistant-event-based `cost_usd` computes).

## two_runs.jsonl
Two banner lines (`=== mother job job-two starting at RUN1/RUN2 ===`), each
followed by one assistant event:
- Run 1: `msg_t1`, in=100, out=10.
- Run 2: `msg_t2`, in=9999, out=999.

Whole-file parse: tokens_in=10099, tokens_out=1009.
Parsing from the byte offset of the `RUN2` banner line onward (i.e.
`--offset <offset-of-RUN2-line>`) must yield **only** run 2's tokens:
**tokens_in=9999, tokens_out=999** — run 1's tokens must not leak in.

## corrupt_line.jsonl
One malformed line (`{invalid json here, not even close to parseable`)
sandwiched between two valid assistant events (`msg_c1` in=100/out=20,
`msg_c2` in=200/out=30). Must tolerate/skip the corrupt line, not abort.
**tokens_in=300, tokens_out=50**.

## adherence_pass_stream.jsonl
A minimal `claude --output-format stream-json --verbose`-shaped adherence-review
transcript: one assistant event (in=1000, out=150) followed by a `result` event
whose `.result` text is `"ADHERENCE: pass\nNOTES:\nAll good."` — used by
`tests/adherence.bats` to drive `mother adherence-review` through the real
stream-json result-event parsing path (as opposed to the plaintext
`MOCK_CLAUDE_STDOUT` shortcut most other adherence tests use) and assert on the
resulting `stage:"adherence"` runs.jsonl row's `verdict`/`cost_usd` fields.

## error_tail_*.jsonl (classify-exit inputs)
No `result` event in any of these — classification must fall through to the
last-60-lines plaintext-tail rules. One assistant event precedes the tail line
in each so the fixture also validates that per-file token parsing doesn't
choke on the trailing plaintext.

- `error_tail_context_overflow.jsonl` → tail line matches
  `prompt is too long` → expected reason `context_overflow`.
- `error_tail_rate_limit.jsonl` → tail line matches `429` / `rate limit` →
  expected reason `rate_limited`.
- `error_tail_overloaded.jsonl` → tail line matches `Overloaded (529)` →
  expected reason `api_overloaded`.
- `error_tail_billing.jsonl` → tail line matches `credit balance` →
  expected reason `billing`.

## result_*.jsonl (classify-exit inputs)
Per the classify-exit rule order ("first match wins"), the generic
`is_error`/`api_error_status` → `api_error` rule is checked *before* the
subtype-specific `max_turns`/`execution_error` rules — so `result.is_error`
must be `false` on the max_turns/execution_error fixtures, or the api_error
rule would shadow them. `result_api_error.jsonl` is the one fixture that
deliberately sets `is_error: true`.

- `result_max_turns.jsonl` → `result.subtype == "error_max_turns"`,
  `is_error: false` → expected reason `max_turns`.
- `result_execution_error.jsonl` → `result.subtype == "error_during_execution"`,
  `is_error: false` → expected reason `execution_error`.
- `result_api_error.jsonl` → `result.is_error == true` with
  `api_error_status: 529` → expected reason `api_error`.
