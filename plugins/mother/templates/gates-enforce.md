## Quality gates are enforced in this repo

This repo's `.mother/crew.yml` runs its quality gates in **enforce** mode. Mother decides when your
PR is ready for human review, so:

- Open the PR as a draft: `gh pr create --draft ...`. Mother converts a non-draft PR back to draft
  and marks it ready itself once the gates pass.
- Run `mother gates run` before you finish, and fix what it reports as failed.
- After you finish, Mother runs the gates again on your pushed head. If a blocking gate fails, Mother
  sends the failure (gate name, output excerpt, hint) back to you **in this same session**.
- When that happens: fix the cause, commit, and push to the same branch. Never open a second PR.
  Then stop; Mother re-runs the gates.
- Never suppress a check, add a baseline or ignore entry, or skip a test to turn a gate green,
  unless the plan explicitly tells you to.
