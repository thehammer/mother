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
# `.decision` is only touched when an option is being resolved ($opt non-empty),
# so a text answer to a job with no open decision just records `.last_answer`
# (option null) and never rewrites an earlier decision's resolution.
# shellcheck disable=SC2016
MOTHER_DECISION_RESOLVE_JQ='
    (if .decision != null and $opt != "" then
        .decision.resolved_at = $ts
        | .decision.resolution = {option: $opt, source: $src, session: $sess, agent: $agent}
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
# the option is refused and nothing changes. HC-08 registers `gate_hold`.
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
