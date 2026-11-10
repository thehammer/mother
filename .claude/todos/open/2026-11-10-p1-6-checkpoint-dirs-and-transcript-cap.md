# P1-6 follow-ups: checkpoint dir keys and restore transcript cost

Not built; notes from PR #124 round 4.

- Coordinator `checkpoints/<job>/<n>/` dirs are keyed by `n` only: epoch 2's n=2 overwrites epoch 1's n=2 (the manifest in
  `index.jsonl` keeps both, the per-n files do not). Key by `<epoch>-<n>` or keep the files for the newest epoch only.
- Every cross-host restore ships the WHOLE transcript once (the first take after a restore, by design: numbering seeds only), and
  that counts toward the 1 GB per-job artifact cap (`MOTHER_APPLY_ARTIFACT_BYTES`). A job with many failovers and a big
  transcript can hit the cap; decide whether the cap should be per-epoch or the reset should send a rebase marker instead.

Acceptance: a test with two epochs that both number n=2 keeps both checkpoints' files; the cap behaviour is decided and documented.
