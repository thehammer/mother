#!/usr/bin/env bash
# lib/decision.sh — structured operator decisions on held (`awaiting`) jobs.
#
# A hold that wants a structured answer carries a `.decision` job key:
#   {id, kind, options[{id,label,consequence,takes_text}], opened_at,
#    resolved_at, resolution{option,source,session,agent}}
# Clients answer by option id (`mother resume <id> --option <opt>` or broker
# `answer {job, option}`); plain text still works and means
# `resume_with_guidance`. Mother never selects an option on its own: there are
# no timeouts and no defaults. Contract: docs/design.md "Headless crew
# contract (Phase 1)".
#
# Sourced by bin/mother after lib/state.sh (needs mother_job_update and
# mother_event_append). Functions print errors to stderr and return non-zero;
# they never `exit`, so they are safe to source anywhere.

# ---------------------------------------------------------------------------
# The one option table: id|takes_text|label|consequence
# Labels and consequences are Mother-written constants — one sentence stating
# plainly what happens. Never interpolate repo or worker text into them.
# ---------------------------------------------------------------------------
_decision_option_table() {
    cat <<'EOF'
resume_with_guidance|true|Resume with guidance|Resumes the worker with your written guidance as its next instruction.
escalate|false|Escalate|Re-runs the work one model tier higher than the attempt that just failed.
override_open|false|Open anyway|Opens the PR for review even though these gates are red; the override is recorded on the PR.
cancel|false|Cancel|Cancels the job; the branch and any commits already made are left in place.
EOF
}

# jq fragment that records an answer. Callers supply --arg ts/opt/src/sess/agent.
# Resolving an option also drops the `decision_awaiting` attention reason.
# `.decision` is only touched when an option is being resolved ($opt non-empty),
# so a text answer to a job with no open decision just records `.last_answer`
# (option null) and never rewrites an earlier decision's resolution.
# shellcheck disable=SC2016
MOTHER_DECISION_RESOLVE_JQ='
    (if .decision != null and $opt != "" then
        .decision.resolved_at = $ts
        | .decision.resolution = {option: $opt, source: $src, session: $sess, agent: $agent}
        | (if .attention == null then . else .attention |= map(select(.reason != "decision_awaiting")) end)
     else . end)
    | .last_answer = {source: $src, session: $sess, agent: $agent,
                      option: (if $opt == "" then null else $opt end), at: $ts}'

# mother_decision_open <id> <kind> <options-json>
# <options-json> is a JSON array of option ids; labels/consequences/takes_text
# come from the table above. Sets `.decision`, emits `decision_opened`, and
# prints the new decision id (`d-<epoch>`).
mother_decision_open() {
    local id="$1" kind="$2" ids_json="$3"
    local table opts did
    table=$(_decision_option_table | jq -R -s -c '
        split("\n") | map(select(length > 0) | split("|")
            | {id: .[0], label: .[2], consequence: .[3], takes_text: (.[1] == "true")})') || return 1
    opts=$(jq -nc --argjson ids "$ids_json" --argjson table "$table" '
        $ids | map(. as $i | ($table | map(select(.id == $i)) | .[0]) // error("unknown option: " + $i))') \
        || { echo "mother: decision: unknown option id in $ids_json" >&2; return 1; }
    did="d-$(date +%s)"
    mother_job_update "$id" '
        .decision = {id: $did, kind: $kind, options: $opts,
                     opened_at: $ts, resolved_at: null, resolution: null}' \
        --arg did "$did" --arg kind "$kind" --argjson opts "$opts" --arg ts "$(_iso_now)" || return 1
    mother_event_append "$id" "decision_opened" \
        "$(jq -nc --arg d "$did" --arg k "$kind" --argjson o "$opts" '{decision_id: $d, kind: $k, options: ($o | map(.id))}')"
    echo "$did"
}

# mother_decision_option <id> <opt>
# Prints the option object offered by the job's decision, or fails.
mother_decision_option() {
    local id="$1" opt="$2" found
    found=$(jq -ec --arg o "$opt" '.decision.options // [] | map(select(.id == $o)) | .[0] // empty' \
        "$(_job_path "$id")" 2>/dev/null) || return 1
    [ -n "$found" ] || return 1
    printf '%s\n' "$found"
}

# mother_decision_resolve <id> <opt> <source> <session> <agent>
# Records the resolution and `.last_answer`, and emits `decision_resolved`.
# (cmd_resume's guidance path folds the same jq into its single resume write.)
mother_decision_resolve() {
    local id="$1" opt="$2" src="$3" sess="${4:-}" agent="${5:-}" did
    did=$(jq -r '.decision.id // ""' "$(_job_path "$id")") || return 1
    mother_job_update "$id" "$MOTHER_DECISION_RESOLVE_JQ" \
        --arg ts "$(_iso_now)" --arg opt "$opt" --arg src "$src" --arg sess "$sess" --arg agent "$agent" || return 1
    mother_event_append "$id" "decision_resolved" \
        "$(jq -nc --arg d "$did" --arg o "$opt" --arg s "$src" '{decision_id: $d, option: $o, source: $s}')"
}

# Handlers: a hold kind registers `_decision_handler_<kind>_<opt>` (called with
# the job id) to give `escalate` / `override_open` real behaviour. Without one
# the option is refused and nothing changes. A kind may also register
# `_decision_resume_jq_<kind>` (see _decision_resume_jq) for extra bookkeeping
# on a guidance answer. HC-08 registers `gate_hold`.
_decision_apply() {
    local opt="$1" id="$2" kind handler
    kind=$(jq -r '.decision.kind // ""' "$(_job_path "$id")")
    handler="_decision_handler_${kind}_${opt}"
    if [ -n "$kind" ] && type "$handler" >/dev/null 2>&1; then
        "$handler" "$id"
    else
        echo "mother: resume: invalid_state: not supported for this hold" >&2
        return 1
    fi
}
_decision_apply_escalate()      { _decision_apply escalate "$1"; }
_decision_apply_override_open() { _decision_apply override_open "$1"; }

# _decision_resume_jq <kind> — extra jq that cmd_resume folds into its single
# resume write for a guidance answer to a <kind> hold (one write, so the daemon
# can never dispatch the job half-updated). Prints `.` for kinds without one.
_decision_resume_jq() {
    local fn="_decision_resume_jq_${1:-}"
    if [ -n "${1:-}" ] && type "$fn" >/dev/null 2>&1; then "$fn"; else echo '.'; fi
}

# ---------------------------------------------------------------------------
# gate_hold (HC-08): blocking quality gates still red after the attempt budget.
# The job is `awaiting`/`gate_hold`; mother-run-job opened the decision.
# The answer source comes from cmd_resume's `source` local (bash dynamic
# scope), defaulting to cli.
# ---------------------------------------------------------------------------

# Guidance resumes the held worker session (mother-run-job turns
# .resume_session_id + .pending_answer into a `--resume` spawn) with a fresh
# gate budget.
_decision_resume_jq_gate_hold() {
    echo '.resume_session_id = .session_id | (if .gates != null then .gates.attempt = 0 else . end)'
}

# Operator-chosen escalation (G14's "never escalate" is about Mother acting
# alone): one tier up, a fresh session, a fresh gate budget.
_decision_handler_gate_hold_escalate() {
    local id="$1" job_file cur next esc red summary
    job_file=$(_job_path "$id")
    cur=$(jq -r '.current_tier // "tier_0"' "$job_file")
    case "$cur" in
        tier_0) next=tier_1 ;; tier_1) next=tier_2 ;; tier_2) next=tier_3 ;;
        tier_3) echo "mother: resume: job $id is already at the top tier (tier_3)" >&2; return 1 ;;
        *) next=tier_1 ;;
    esac
    esc=$(jq -r '(.escalation_count // 0) + 1' "$job_file")
    red=$(mother_gates_red_json "$job_file" | jq -r 'join(", ")')
    summary="The operator escalated this job to $next after quality gates stayed red: $red. Fix the cause of each failing gate (run \`mother gates run\` to see them), then commit and push to the same branch. Do not open a second PR."
    mother_job_update "$id" '
        .state = "ready"
        | .current_tier = $tier
        | .escalation_count = ($esc | tonumber)
        | .pending_answer = $pa
        | .resumed_at = $ts
        | .activity = null | .paused_reason = null | .paused_at = null
        | .resume_session_id = null
        | .worker_pid = null | .finished_at = null | .final_result_at = null
        | .cancel_requested = null | .pause_requested = null
        | (if .gates != null then .gates.attempt = 0 | .gates.budget_reset_by = "escalate" else . end)' \
        --arg tier "$next" --arg esc "$esc" --arg pa "$summary" --arg ts "$(_iso_now)" || return 1
    mother_event_append "$id" "escalated" "$(jq -nc --arg from "$cur" --arg to "$next" --argjson esc "$esc" \
        '{from_tier: $from, to_tier: $to, from_state: "awaiting", to_state: "ready", escalation_count: $esc, reason: "gate_hold"}')"
    echo "$id: escalated $cur -> $next after gate hold (worker will spawn on next daemon tick)"
}

# Open the PR for review with the red gates recorded as an operator override,
# then mark the job succeeded.
_decision_handler_gate_hold_override_open() {
    local id="$1" job_file red src url no_pr
    job_file=$(_job_path "$id")
    url=$(jq -r '.pr_url // empty' "$job_file")
    no_pr=$(jq -r '.no_pr // false' "$job_file")
    if [ "$no_pr" != "true" ] && [ -z "$url" ]; then
        echo "mother: resume: invalid_state: job $id has no PR to open; resume with guidance to have the worker open one" >&2
        return 1
    fi
    red=$(mother_gates_red_json "$job_file")
    src="${source:-cli}"
    mother_job_update "$id" '
        .gates.status = "overridden"
        | .gates.override = {at: $ts, source: $src, red: $red}
        | .activity = null | .paused_reason = null | .question = null' \
        --arg ts "$(_iso_now)" --arg src "$src" --argjson red "$red" || return 1
    mother_event_append "$id" "gates_overridden" "$(jq -nc --argjson red "$red" --arg src "$src" '{red: $red, source: $src}')"

    if [ "$no_pr" != "true" ]; then
        mother_prbody_write_gates "$url" "$(jq -c '.gates' "$job_file")" \
            || echo "mother: resume: could not write the override note into $url" >&2
        if gh pr ready "$url" >/dev/null 2>&1; then
            mother_event_append "$id" "pr_marked_ready" "$(jq -nc --arg url "$url" '{reason: "override", pr_url: $url}')"
        else
            mother_event_append "$id" "pr_draft_unverified" "$(jq -nc --arg url "$url" '{pr_url: $url, action: "ready", reason: "override"}')"
            echo "mother: resume: could not mark $url ready; mark it ready by hand" >&2
        fi
    fi
    _job_transition "$id" succeeded "$(jq -nc --arg pr "$url" '{pr_url: $pr, gates: "overridden"}')"
    echo "$id: gates overridden; job succeeded"
}
