#!/usr/bin/env bash
# contract-check.sh — validate broker NDJSON against the headless-crew client contract.
#
# Usage:
#   contract-check.sh FILE [FILE...]     check each file
#   contract-check.sh < stream.ndjson    check a stream on stdin (also: contract-check.sh -)
#
# One broker message per line, the envelope {v,dir,t,id,ts,data} (broker/envelope.go).
# Exit 0 when every line conforms, 1 otherwise, printing `file:line: reason` for each
# violation (`<stdin>` for a stream). The contract is documented in docs/design.md,
# "Headless crew contract (Phase 1)"; this table must match that section exactly.
# Later PRs extend the contract by editing ONLY the table below (and the doc).

set -u

# ---------------------------------------------------------------------------
# THE CONTRACT TABLE — kinds, required detail keys, enums, forbidden keys.
# ---------------------------------------------------------------------------
read -r -d '' CONTRACT_TABLE <<'JSON'
{
  "broker_types": ["hello", "ping", "snapshot", "current_activity", "output"],
  "commands": ["subscribe", "unsubscribe", "query.list", "query.get", "answer", "cancel", "retry", "force-start", "ack"],
  "error_codes": ["no_such_job", "invalid_state", "malformed", "unavailable", "version_mismatch", "unauthorized", "internal"],
  "existing_kinds": [
    "queued", "ready", "running", "awaiting", "succeeded", "failed", "cancelled",
    "awaiting_input", "auto_resumed", "pause_requested", "paused_for_quota",
    "adherence_capped", "adherence_review_spawned", "adherence_reviewed", "adherence_rework_kicked", "adherence_skipped",
    "auto_stash_failed", "auto_stash_restore_deferred", "auto_stashed", "awaiting_notified",
    "branch_checked_out", "cancel_requested", "continuation_queued", "cost_cap_breached", "cost_cap_forced_pause",
    "dependency_blocked", "dependency_gate_bypassed", "dependency_satisfied", "dependency_waiting",
    "escalated", "failure_reason_missing", "failure_routed", "final_result_observed", "force_start_requested",
    "held_for_operator", "max_cost_raised", "no_pr_commits_verified", "no_pr_url_but_branch_pushed",
    "phase_completed", "phase_started", "pipeline_blocked", "pipeline_cap_hit", "pipeline_cycle_continued",
    "pipeline_error", "pipeline_phase_advance", "pipeline_phase_spawn", "pipeline_review_started", "pipeline_shipped",
    "posture_bias_applied", "pr_branch_mismatch_accepted", "pr_branch_mismatch_unverified", "pr_opened",
    "pr_url_branch_mismatch", "pr_url_rejected", "pr_url_unresolved", "pr_url_unverified", "pr_url_updated",
    "preview_ready", "preview_stop", "preview_up", "pushed_to_other_branch",
    "reaping_after_idle_timeout", "reaping_after_result_grace", "reconciled", "resume_not_yet_acted_on",
    "resumed", "resumed_from_input", "retried", "review_cycle_completed", "review_cycle_started",
    "review_no_findings_block", "review_parse_error", "review_spawned", "review_workdir_missing", "reviewed",
    "rework_advance_verified", "route_error", "rwx_sandbox_reset", "rwx_sandbox_stop",
    "teardown_completed", "teardown_needs_attention", "teardown_residue", "teardown_skipped", "teardown_started",
    "token_alert", "worker_exited_paused", "worker_spawned"
  ],
  "new_kinds": {
    "gates_started":        ["attempt", "max_attempts", "head_sha", "mode", "posture", "gates"],
    "gate_result":          ["attempt", "name", "result", "blocking", "duration_s", "exit_code"],
    "gates_completed":      ["attempt", "status", "passed", "failed", "unavailable", "not_run"],
    "gate_fix_started":     ["attempt", "session_id", "red"],
    "gates_exhausted":      ["attempts", "red"],
    "gates_overridden":     ["red", "source"],
    "pr_marked_draft":      ["reason"],
    "pr_marked_ready":      ["reason"],
    "pr_draft_unverified":  [],
    "criterion_checked":    ["id", "status", "has_evidence"],
    "lens_skipped":         ["reviewer", "lens", "reason"],
    "claims_verified":      ["verified", "refuted", "unverified"],
    "review_wave_completed": ["cycles", "status"],
    "review_rework_started": ["cycle", "session_id", "findings"],
    "decision_opened":      ["decision_id", "kind", "options"],
    "decision_resolved":    ["decision_id", "option", "source"],
    "attention_raised":     ["reason"],
    "attention_cleared":    ["reason"],
    "attention_acked":      ["reason", "source"],
    "progress_updated":     ["v", "pct", "label", "stage", "signals", "eta", "paused", "flags", "updated_at"],
    "progress_half":        ["eta_lo_s", "eta_hi_s", "elapsed_active_s"]
  },
  "extended_kinds": {
    "awaiting_input":         ["question", "paused_reason"],
    "reviewed":               ["reviewer", "finding_count", "decision"],
    "review_cycle_started":   ["cycle", "reviewers"],
    "review_cycle_completed": ["cycle", "decision", "findings_count"],
    "resumed":                []
  },
  "category_of": { "progress_updated": "progress", "progress_half": "progress" },
  "enums": {
    "gate_result":   ["passed", "failed", "skipped", "unavailable"],
    "skip_reason":   ["path_scope", "posture", "budget", "removed_by_plan"],
    "attention":     ["progress_stalled", "burn_ahead", "gates_incomplete", "decision_awaiting"],
    "option":        ["resume_with_guidance", "escalate", "override_open", "cancel"],
    "source":        ["nostromo_app", "cli", "broker_client"],
    "criteria_source": ["checklist", "ledger"],
    "crew_activity_running":  ["gating", "gate_fix", "review_wave", "review_rework"],
    "crew_activity_awaiting": ["gate_hold", "review_hold"]
  },
  "job_required": ["id", "state", "repo", "isolation", "title", "created_at"],
  "job_timestamps": ["created_at", "started_at", "finished_at"],
  "new_job_keys": {
    "crew": [], "gates": ["mode", "status", "attempt", "max_attempts"],
    "review_wave": ["mode", "cycle", "status"], "decision": ["id", "kind", "options", "opened_at"],
    "attention": [], "last_answer": ["source", "at"], "progress": ["v", "pct", "stage"], "criteria_source": []
  },
  "forbidden_keys": ["excerpt", "output", "detail_text", "summary", "quote", "text", "criterion_text"]
}
JSON

# ---------------------------------------------------------------------------
# jq checker: one input line (-R) in, zero or more "LINE<TAB>reason" lines out.
# ---------------------------------------------------------------------------
read -r -d '' JQ_PROG <<'JQ'
def ms_z: test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}\\.[0-9]{3}Z$");
def missing($o; $keys): [$keys[] | select(. as $k | ($o | type) != "object" or ($o | has($k) | not))];
def forbidden_found($allow): [.. | objects | keys[]]
    | map(select(. as $k | ($tbl.forbidden_keys | any(. == $k)) and ($allow | any(. == $k) | not))) | unique;
def in_enum($v; $name): $tbl.enums[$name] | any(. == $v);

. as $raw
| input_line_number as $ln
| def err($r): "\($ln)\t\($r)";
  def need($o; $keys; $what): (missing($o; $keys)) as $m
      | if ($m | length) > 0 then err("\($what): missing required key(s): \($m | join(","))") else empty end;
  def enum($o; $key; $name; $what):
      if ($o | type) == "object" and ($o | has($key)) and ($o[$key] != null) and (in_enum($o[$key]; $name) | not)
      then err("\($what): \($key)=\($o[$key] | tojson) is not one of \($tbl.enums[$name] | join("|"))") else empty end;
  def leak($v; $allow; $what): ($v | forbidden_found($allow)) as $f
      | if ($f | length) > 0 then err("\($what): forbidden free-text key(s): \($f | join(","))") else empty end;

  if ($raw | test("^\\s*$")) then empty
  else (try ($raw | fromjson) catch "\u0000invalid") as $m
  | if $m == "\u0000invalid" then err("line is not valid JSON")
    elif ($m | type) != "object" then err("line is not a JSON object")
    else (["v", "dir", "t", "id", "ts"] | map(select(. as $k | $m | has($k) | not))) as $miss
    | if ($miss | length) > 0 then err("missing envelope key(s): \($miss | join(","))")
      else
        $m.t as $t | $m.dir as $dir | ($m.data // {}) as $d
        | (if ($m.ts | type) == "string" and ($m.ts | ms_z) then empty else err("envelope ts is not ISO-8601 millisecond Z") end),
          (if $dir == "event" then
              if ($tbl.broker_types | any(. == $t)) then
                (if $t == "hello" then need($d; ["protocol_version", "capabilities"]; "hello") else empty end),
                (if $t == "snapshot" then
                    (if ($d.jobs | type) != "array" then err("snapshot: data.jobs must be an array")
                     else $d.jobs | to_entries[] | .key as $i | .value as $j
                       | ("snapshot job[\($i)]") as $w
                       | need($j; $tbl.job_required; $w),
                         ($tbl.job_timestamps[] | . as $k
                            | if ($j[$k] | type) == "string" and ($j[$k] | ms_z | not)
                              then err("\($w): \($k) is not ISO-8601 millisecond Z") else empty end),
                         ($tbl.new_job_keys | to_entries[] | select(.key as $k | $j | has($k)) | .key as $k
                            | need($j[$k]; .value; "\($w).\($k)"), leak($j[$k]; []; "\($w).\($k)")),
                         (if ($j | has("progress")) then leak($j.progress; []; "\($w).progress") else empty end),
                         enum($j; "criteria_source"; "criteria_source"; $w),
                         ((($j.attention // [])[]?) as $a | enum($a; "reason"; "attention"; "\($w).attention")),
                         enum($j.last_answer; "source"; "source"; "\($w).last_answer"),
                         enum($j.last_answer; "option"; "option"; "\($w).last_answer"),
                         (($j.decision.options // [])[]? | need(.; ["id", "label", "consequence", "takes_text"]; "\($w).decision.options[]")),
                         (($j.decision.options // [])[]? | enum(.; "id"; "option"; "\($w).decision.options[]")),
                         (if ($tbl.enums.crew_activity_running | any(. == $j.activity)) and $j.state != "running"
                          then err("\($w): activity \($j.activity) requires state running") else empty end),
                         (if ($tbl.enums.crew_activity_awaiting | any(. == $j.activity))
                             and ($j.state != "awaiting" or $j.paused_reason != $j.activity)
                          then err("\($w): activity \($j.activity) requires state awaiting and paused_reason \($j.activity)") else empty end)
                     end)
                  else empty end)
              else
                ($tbl.new_kinds | has($t)) as $isnew
                | ($tbl.extended_kinds | has($t)) as $isext
                | if ($isnew | not) and ($isext | not) and (($tbl.existing_kinds | any(. == $t)) | not)
                  then err("unknown event kind '\($t)' (not an existing kind and not listed in the contract)")
                  else
                    (if $isnew then need($d; $tbl.new_kinds[$t]; $t) else empty end),
                    (if $isext then need($d; $tbl.extended_kinds[$t]; $t) else empty end),
                    (if $isnew or $isext then leak($d; []; $t) else empty end),
                    (if $tbl.category_of | has($t) then
                        (if $d.category != $tbl.category_of[$t] then err("\($t): category must be \($tbl.category_of[$t])") else empty end)
                     else empty end),
                    (if $t == "gate_result" then enum($d; "result"; "gate_result"; $t) else empty end),
                    (if $t == "lens_skipped" then enum($d; "reason"; "skip_reason"; $t) else empty end),
                    (if $t == "attention_raised" or $t == "attention_cleared" or $t == "attention_acked"
                     then enum($d; "reason"; "attention"; $t) else empty end),
                    (if $t == "attention_acked" or $t == "decision_resolved" or $t == "gates_overridden" or $t == "resumed"
                     then enum($d; "source"; "source"; $t) else empty end),
                    (if $t == "decision_resolved" or $t == "resumed" then enum($d; "option"; "option"; $t) else empty end),
                    (if $t == "decision_opened" then ($d.options // [])[]? as $o
                        | if ($o | type) == "string" and in_enum($o; "option") then empty
                          else err("decision_opened: option \($o | tojson) is not one of \($tbl.enums.option | join("|"))") end
                     else empty end),
                    (if $t == "resumed" and ($d | has("option")) then need($d; ["source"]; "resumed with option") else empty end),
                    (if $t == "review_cycle_started" and $d.wave == true then need($d; ["pending_reviewers"]; "review_cycle_started wave") else empty end)
                  end
              end
           elif $dir == "cmd" then
              if ($tbl.commands | any(. == $t) | not) then err("unknown command '\($t)'")
              else
                leak($d; (if $t == "answer" then ["text"] else [] end); "cmd \($t)"),
                (if $t == "answer" then need($d; ["job"]; "cmd answer"), enum($d; "option"; "option"; "cmd answer"), enum($d; "source"; "source"; "cmd answer") else empty end),
                (if $t == "ack" then need($d; ["job", "reason"]; "cmd ack"), enum($d; "reason"; "attention"; "cmd ack") else empty end)
              end
           elif $dir == "ack" then
              (if ($d.ok | type) != "boolean" then err("ack: data.ok must be a boolean")
               elif $d.ok == false then
                 (if ($d.error.code | type) != "string" or (($tbl.error_codes | any(. == $d.error.code)) | not)
                  then err("ack: data.error.code must be one of \($tbl.error_codes | join("|"))") else empty end)
               else empty end)
           else err("dir must be event, cmd or ack") end)
      end
    end
  end
JQ

_check_stream() {
    # $1 = display name; NDJSON on stdin. Prints violations; returns 1 if any.
    local name="$1" out
    out=$(jq -rR --argjson tbl "$CONTRACT_TABLE" "$JQ_PROG") || {
        echo "$name: jq failed while checking" >&2
        return 1
    }
    [ -z "$out" ] && return 0
    printf '%s\n' "$out" | while IFS="$(printf '\t')" read -r ln reason; do
        printf '%s:%s: %s\n' "$name" "$ln" "$reason"
    done
    return 1
}

main() {
    command -v jq >/dev/null 2>&1 || { echo "contract-check: jq is required" >&2; exit 2; }
    local rc=0 f
    if [ "$#" -eq 0 ]; then
        _check_stream "<stdin>" || rc=1
    else
        for f in "$@"; do
            if [ "$f" = "-" ]; then
                _check_stream "<stdin>" || rc=1
            elif [ -r "$f" ]; then
                _check_stream "$f" < "$f" || rc=1
            else
                echo "$f: cannot read file" >&2
                rc=1
            fi
        done
    fi
    exit "$rc"
}

main "$@"
