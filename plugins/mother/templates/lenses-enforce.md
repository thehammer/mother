## A review wave runs before your PR is presented

This repo's `.mother/crew.yml` runs a **review wave** in enforce mode: after you finish (and after any
quality gates pass), Mother runs a plan-adherence review and focused review lenses on your pushed head
before the PR is marked ready for human review. So:

- Open the PR as a draft: `gh pr create --draft ...`. Mother converts a non-draft PR back to draft and
  marks it ready itself once the review wave passes.
- If a reviewer raises a blocking finding for you, Mother sends it back **in this same session**. Fix
  it, run the relevant tests, commit, and push to the same branch. Never open a second PR. Then stop;
  Mother re-runs the gates and the wave.
- If you are confident a finding is wrong, leave the code as it is and say why in your final message.
