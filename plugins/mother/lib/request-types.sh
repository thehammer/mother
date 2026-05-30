# request-types.sh — request-type registry and helpers for the SDLC pipeline.
#
# Sourced by the pipeline driver (W4) and any phase-aware worker.
# Do not invoke directly.
#
# The registry enumerates every {agent, request_type} pair the pipeline can
# dispatch, along with its declared inputs and a one-line output-contract
# description. All helpers use case statements — no associative arrays, so
# this file is safe under bash 3.2 (see CLAUDE.md shell conventions).

# ---------- registry ----------
#
# Minimum set required by the PRD (docs/prds/mother-sdlc-pipeline.md):
#
#   ada:prd            ada:plan_feedback   ada:review
#   archie:plan        archie:review
#   perri:review
#   redd:test          cody:implement      marty:refactor

# rt_exists <agent> <request_type>
# Returns 0 if the pair is in the registry, non-zero otherwise.
rt_exists() {
    local agent="$1" rtype="$2"
    case "${agent}:${rtype}" in
        ada:prd|ada:plan_feedback|ada:review|\
        archie:plan|archie:review|\
        perri:review|\
        redd:test|cody:implement|marty:refactor)
            return 0 ;;
        *) return 1 ;;
    esac
}

# rt_inputs <agent> <request_type>
# Echoes the newline-separated list of input keys the spawn prompt should
# supply for this request type (e.g. plan, prd, tests, diff, findings).
# Returns non-zero for an unregistered pair.
rt_inputs() {
    local agent="$1" rtype="$2"
    case "${agent}:${rtype}" in
        ada:prd)
            echo "prd_brief" ;;
        ada:plan_feedback)
            printf "plan\nprd" ;;
        ada:review)
            printf "plan\ndiff\ntests\npr_comments" ;;
        archie:plan)
            echo "prd" ;;
        archie:review)
            printf "plan\ndiff\npr_comments" ;;
        perri:review)
            printf "diff\npr_comments\ntests" ;;
        redd:test)
            printf "prd\nplan\ntests" ;;
        cody:implement)
            printf "plan\ntests" ;;
        marty:refactor)
            printf "plan\ndiff\ntests" ;;
        *)
            return 1 ;;
    esac
}

# rt_contract <agent> <request_type>
# Echoes a one-line description of the expected output for this request type.
# Returns non-zero for an unregistered pair.
rt_contract() {
    local agent="$1" rtype="$2"
    case "${agent}:${rtype}" in
        ada:prd)
            echo "Structured PRD with goals, requirements, and success criteria" ;;
        ada:plan_feedback)
            echo "Structured feedback on plan completeness and alignment with PRD" ;;
        ada:review)
            echo "Structured findings on AC coverage and behavioral correctness" ;;
        archie:plan)
            echo "Self-contained implementation plan with files-to-change and acceptance criteria" ;;
        archie:review)
            echo "Structured findings on plan adherence and scope compliance" ;;
        perri:review)
            echo "Structured findings on code quality and PR-level concerns" ;;
        redd:test)
            echo "Behavioral test suite covering the plan's acceptance criteria" ;;
        cody:implement)
            echo "Working implementation that makes Redd's tests pass" ;;
        marty:refactor)
            echo "Refactored code that reduces complexity without changing behavior" ;;
        *)
            return 1 ;;
    esac
}

# rt_agent_for_phase <phase>
# Maps a forward pipeline phase name (redd|cody|marty) to its
# canonical "agent:request_type" token. Used by the pipeline driver (W2/W4)
# to parameterize worker spawns.
# Returns non-zero for an unrecognized phase name.
rt_agent_for_phase() {
    local phase="$1"
    case "$phase" in
        redd)  echo "redd:test" ;;
        cody)  echo "cody:implement" ;;
        marty) echo "marty:refactor" ;;
        *)     return 1 ;;
    esac
}
