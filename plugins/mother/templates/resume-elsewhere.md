# Mother moved this job to a new machine

The machine that was running this job stopped. Mother restored your worktree on a new one from a
checkpoint taken at {{AT}} (branch `{{BRANCH}}`, head `{{HEAD_SHA}}`). Committed work is on the branch;
uncommitted changes were restored as **unstaged** changes (the staged versus unstaged split is not kept).

Work you did after that checkpoint may be missing. This session continues the same conversation, so you
remember what you were doing, but the files are what they are on disk now.

Before you continue:

1. Run `git status` and `git log --oneline -5`.
2. Compare them with what you expected, and redo anything that is missing.
3. Keep working on branch `{{BRANCH}}`. If a PR for it already exists, push to it; do not open a second one.
{{NOTES}}
