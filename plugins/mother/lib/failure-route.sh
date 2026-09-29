#!/usr/bin/env bash
# failure-route.sh — route a failed job by its recorded failure_reason.
#
# Escalating the model tier is the right response to "the worker tried and
# couldn't" — and the wrong one to most other failures (a PR that already
# exists, an unmerged dependency, a wrong --base, an infra hiccup). This lib
# holds the pure reason -> class mapping and the operator-facing hold text;
# `mother route-failure` (bin/mother) applies them.
#
# Classes:
#   reconcile_then_hold  reconcile --auto; if nothing adopted, hold. Never escalate.
#   hold                 hold for the operator immediately (no reconcile, no retry).
#   retry_once           one as-is retry (no tier bump), then hold.
#   escalate             legacy: reconcile, then escalate if escalation_count < 2.

mother_failure_class() {
    case "${1:-}" in
        no_pr_no_push)
            echo "reconcile_then_hold" ;;
        rework_no_new_commit|branch_create_failed|checkout_failed)
            echo "hold" ;;
        worktree_create_failed|runner_died_early|unspecified|"")
            echo "retry_once" ;;
        *)
            echo "escalate" ;;
    esac
}

# mother_failure_hold_question <id> <reason> <sub_reason> <detail-json>
# Renders the operator-facing question text for a held job. Concrete and
# actionable: names the job id and the exact commands.
mother_failure_hold_question() {
    local id="$1" reason="$2" sub="$3" detail="${4:-}"
    [ -n "$detail" ] || detail='{}'
    local branch base work_dir commits unc pr rref rsha la
    branch=$(printf '%s' "$detail" | jq -r '.branch // "?"' 2>/dev/null)
    base=$(printf '%s' "$detail" | jq -r '.base // .base_ref // "?"' 2>/dev/null)
    commits=$(printf '%s' "$detail" | jq -r '.local_commits_ahead_of_base // "unknown"' 2>/dev/null)
    unc=$(printf '%s' "$detail" | jq -r '.uncommitted_files // "unknown"' 2>/dev/null)
    work_dir=$(printf '%s' "$detail" | jq -r '.work_dir // "(see mother status)"' 2>/dev/null)
    pr=$(printf '%s' "$detail" | jq -r '.pr_url // ""' 2>/dev/null)
    rref=$(printf '%s' "$detail" | jq -r '.remote_ref // ""' 2>/dev/null)
    rsha=$(printf '%s' "$detail" | jq -r '.remote_sha_at_start // ""' 2>/dev/null)
    la=$(printf '%s' "$detail" | jq -r '.local_advanced // "unknown"' 2>/dev/null)

    case "$sub" in
        nothing_to_reconcile)
            cat <<EOF
Job $id reported success (or ended) but no PR or pushed branch was found, and 'mother reconcile --auto' found nothing to adopt (failure reason: $reason). Mother is holding it instead of escalating the model tier.
Worktree: $work_dir — local commits ahead of base: $commits, uncommitted files: $unc
Options:
  mother resume $id "<instructions, e.g. commit and push the work in the worktree>"
  mother reconcile $id --pr-url <url>     (if a PR exists that detection missed)
  mother cancel $id
EOF
            ;;
        unmerged_dependency)
            {
                echo "Job $id failed with '$reason' and depends on job(s) whose PRs are not merged yet:"
                printf '%s' "$detail" | jq -r '.dependencies // [] | .[] | "  - \(.job_id): \(.pr_url // "(no PR)") [\(.pr_state // "UNKNOWN")]"' 2>/dev/null
                echo "Mother is holding it instead of escalating (a sequencing problem, not a quality one)."
                echo "Merge the dependencies, then:"
                echo "  mother retry $id"
                echo "  mother resume $id \"<instructions>\""
                echo "  mother cancel $id"
            }
            ;;
        rework_no_new_commit)
            cat <<EOF
Job $id's latest run started with an existing PR (${pr:-none}) / origin ref ${rref:-?}@${rsha:-none} and ended without pushing anything new to it, so Mother refused to call it succeeded. Local branch advanced: $la; uncommitted files: $unc.
Options:
  mother resume $id "commit and push the pending work"
  mother reconcile $id                    (if the PR is already complete)
  mother cancel $id
EOF
            ;;
        branch_create_failed|checkout_failed)
            cat <<EOF
Job $id failed during workspace setup ($sub) for branch $branch from base $base. This fails the same way on every retry, so Mother is not retrying or escalating. A common cause is a wrong --base (e.g. the repo default is 'master', not 'origin/main').
Fix: mother cancel $id, then re-add the job with the correct --base.
EOF
            ;;
        retry_exhausted)
            cat <<EOF
Job $id failed with '$reason' again after one automatic as-is retry. Mother is holding it rather than looping.
Options:
  mother retry $id
  mother resume $id "<instructions>"
  mother cancel $id
EOF
            ;;
        *)
            cat <<EOF
Job $id failed with '$reason' and Mother is holding it for you.
Options:
  mother retry $id
  mother resume $id "<instructions>"
  mother cancel $id
EOF
            ;;
    esac
}
