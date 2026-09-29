#!/usr/bin/env bash
# autostash.sh — restore the operator's main-dir auto-stash.
#
# `mother-run-job` stashes a dirty main-dir checkout before it creates/checks
# out the job branch ("mother:auto-stash:<id>") and records a marker file at
# $RUNNER_DIR/<id>.stash:
#   line 1: stash message
#   line 2: original branch name (may be empty if HEAD was detached)
#
# mother_autostash_restore is the single implementation of "put the operator's
# working tree back". It is shared by mother-run-job (post-run, early-failure
# and EXIT-trap paths) and mother-runner's orphan reaper. It deliberately emits
# NO events: the two callers use different _append_event signatures, so each
# maps the returned outcome to events itself.
#
# Usage: mother_autostash_restore <work_dir> <marker_file>
# Prints one compact JSON object and returns 0:
#   {outcome, stash_message, original_branch, stash_ref}
# outcome:
#   restored        stash popped cleanly
#   restore_failed  `git stash pop` failed; stash left in place (marker removed)
#   stash_not_found marker existed but no stash matches its message
#   none            no marker file — nothing touched (idempotent second call)

mother_autostash_restore() {
    local work_dir="${1:-}" marker="${2:-}"

    if [ -z "$marker" ] || [ ! -f "$marker" ]; then
        printf '{"outcome":"none"}\n'
        return 0
    fi

    local msg orig ref="" outcome
    msg=$(sed -n '1p' "$marker" 2>/dev/null)
    orig=$(sed -n '2p' "$marker" 2>/dev/null)

    if [ -n "$orig" ] && [ -d "$work_dir" ] \
        && (cd "$work_dir" && git rev-parse --verify "$orig" >/dev/null 2>&1); then
        (cd "$work_dir" && git checkout --quiet "$orig" 2>/dev/null) || true
    fi

    if [ -d "$work_dir" ]; then
        ref=$(cd "$work_dir" && git stash list 2>/dev/null \
            | awk -F: -v msg="$msg" '$0 ~ msg {print $1; exit}')
    fi

    if [ -z "$ref" ]; then
        outcome="stash_not_found"
    elif (cd "$work_dir" && git stash pop --quiet "$ref" >/dev/null 2>&1); then
        outcome="restored"
    else
        outcome="restore_failed"
    fi

    rm -f "$marker"
    jq -nc --arg o "$outcome" --arg m "$msg" --arg b "$orig" --arg r "$ref" \
        '{outcome: $o, stash_message: $m, original_branch: $b, stash_ref: $r}'
    return 0
}

# mother_autostash_event_detail <result-json>
#
# Maps a mother_autostash_restore result to the (event kind, detail JSON)
# pair its caller should emit. Shared by mother-run-job's _restore_auto_stash
# and mother-runner's _orphan_restore_autostash — the only thing that differs
# between those two callers is the arity of the _append_event call they make
# (mother-run-job's job-scoped version vs. mother-runner's id-taking one), so
# each just passes this call's output straight through. Centralizing the
# mapping (including the "git stash pop failed; resolve manually..." note
# text) keeps the two callers from drifting apart.
#
# Prints "<kind>\t<detail-json>" (kind is one of auto_stash_restored /
# auto_stash_restore_failed / auto_stash_not_found) and returns 0. For
# outcome "none" (nothing to restore — see mother_autostash_restore's doc
# comment) there is nothing worth an event for, so it prints nothing and
# returns 1.
mother_autostash_event_detail() {
    local res="$1" outcome msg orig ref kind detail
    outcome=$(printf '%s' "$res" | jq -r '.outcome // "none"' 2>/dev/null)
    msg=$(printf '%s' "$res" | jq -r '.stash_message // ""' 2>/dev/null)
    orig=$(printf '%s' "$res" | jq -r '.original_branch // ""' 2>/dev/null)
    ref=$(printf '%s' "$res" | jq -r '.stash_ref // ""' 2>/dev/null)
    case "$outcome" in
        restored)
            kind="auto_stash_restored"
            detail=$(jq -nc --arg m "$msg" --arg b "$orig" \
                '{stash_message: $m, original_branch: $b}') ;;
        restore_failed)
            kind="auto_stash_restore_failed"
            detail=$(jq -nc --arg m "$msg" --arg r "$ref" \
                '{stash_message: $m, stash_ref: $r, note: "git stash pop failed; resolve manually via git stash list / git stash pop"}') ;;
        stash_not_found)
            kind="auto_stash_not_found"
            detail=$(jq -nc --arg m "$msg" '{stash_message: $m}') ;;
        *)
            return 1 ;;
    esac
    printf '%s\t%s\n' "$kind" "$detail"
}
