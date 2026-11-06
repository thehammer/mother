#!/usr/bin/env bash
# Read-only collector for a finished (or running) spike run.
#   spikes/rwx-worker/collect.sh <run-id> [task-key]      (task-key default: duration)
# Downloads that task's log into a FRESH temp dir (treated as untrusted data, only read with grep/python -I),
# then prints: final status, heartbeat count, first/last heartbeat time, the CLAUDE_CALL results, DONE line,
# and the compute cost estimated from RWX's own task runtime x vCPUs x $0.00007 (general purpose, 1 min minimum).
# Uses the default `rwx` login (Carefeed org). Never prints vault values; RWX masks them in logs.
set -euo pipefail

run="${1:?usage: collect.sh <run-id> [task-key]}"
key="${2:-duration}"
dir="$(mktemp -d "${TMPDIR:-/tmp}/rwx-collect.XXXXXX")"
echo "log dir: $dir"

info="$(rwx runs show "$run" --json | python3 -I -c '
import json, sys
r = json.load(sys.stdin)
key = sys.argv[1]
for t in r["Tasks"]:
    if t["Key"] == key:
        cpus = (t.get("Agent") or {}).get("Cpus") or 0
        secs = t.get("ExecutionRuntimeSeconds")
        cost = (max(secs, 60) * cpus * 0.00007) if secs is not None else None
        print(t["ID"], t["Status"]["Execution"], t["Status"]["Result"], cpus, secs if secs is not None else "n/a",
              ("%.4f" % cost) if cost is not None else "n/a")
        break
else:
    print("NOTFOUND")
' "$key")"
if [ "$info" = "NOTFOUND" ]; then echo "task '$key' not found in run $run" >&2; exit 1; fi
read -r task_id execution result cpus secs cost <<<"$info"
echo "task=$key id=$task_id execution=$execution result=$result vcpus=$cpus runtime_s=$secs est_cost_usd=$cost"

rwx logs "$task_id" --output "$dir" >/dev/null
log="$(ls "$dir"/*.log | head -1)"

hb="$(grep -c 'stdout	HEARTBEAT' "$log" || true)"
echo "heartbeats: $hb"
echo "first heartbeat: $(grep 'stdout	HEARTBEAT' "$log" | head -1 | sed 's/.*t=//' | cat -v)"
echo "last heartbeat:  $(grep 'stdout	HEARTBEAT' "$log" | tail -1 | sed 's/.*t=//' | cat -v)"
echo "claude -p results:"
grep 'stdout	CLAUDE_CALL' "$log" | sed 's/^[^	]*	stdout	/  /' | cat -v || true
grep 'stdout	DONE' "$log" | sed 's/^[^	]*	stdout	/  /' | cat -v || true
echo "(log kept at $dir)"
