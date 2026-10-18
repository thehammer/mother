#!/usr/bin/env bash
# criteria.sh — per-job acceptance-criteria checklist ("ledger-lite", HC-10).
#
# The ONLY read path for criteria is `mother_criteria_view`. The Phase 3 task
# ledger will replace the checklist behind the same view; a job's source is
# fixed at add time (`.criteria_source`, absent = checklist) and never changed.
#
# Checklist file: $MOTHER_ROOT/checklists/<id>.json
#   {v:1, items:[{id, text, status:"open"|"done", evidence:null|string}]}
# Criterion text lives only in that local file — never in job JSON, events,
# progress or broker payloads.

mother_criteria_path() { printf '%s/checklists/%s.json' "$MOTHER_ROOT" "$1"; }

# mother_criteria_seed <id> <plan_file>
# Parses criteria under a heading starting with "Acceptance criteria" (any
# level) up to the next heading of the same or higher level, and writes the
# checklist atomically. A plan with no criteria gets an empty checklist.
mother_criteria_seed() {
    local id="$1" plan="$2" out tmp
    out=$(mother_criteria_path "$id")
    mkdir -p "$(dirname "$out")" || return 1
    tmp="${out}.tmp.$$"
    python3 -I - "$plan" > "$tmp" <<'PY' || { rm -f "$tmp"; return 1; }
import json, re, sys
try:
    lines = open(sys.argv[1], encoding="utf-8", errors="replace").read().splitlines()
except OSError:
    lines = []
head = re.compile(r'^(#{1,6})\s+(.*?)\s*$')
item = re.compile(r'^\s*[-*]\s+(?:\[[ xX]\]\s+)?\*\*([A-Za-z][A-Za-z0-9_-]*[0-9])\b[^*]*\*\*\s*(.*?)\s*$')
level = None
fence = False
items, seen = [], set()
for line in lines:
    if line.lstrip().startswith("```"):
        fence = not fence
        continue
    if fence:
        continue
    m = head.match(line)
    if m:
        lv = len(m.group(1))
        if level is not None and lv <= level:
            level = None
        if level is None and m.group(2).lower().startswith("acceptance criteria"):
            level = lv
        continue
    if level is None:
        continue
    m = item.match(line)
    if m and m.group(1) not in seen:
        seen.add(m.group(1))
        items.append({"id": m.group(1), "text": m.group(2), "status": "open", "evidence": None})
print(json.dumps({"v": 1, "items": items}))
PY
    mv "$tmp" "$out"
}

# mother_criteria_view <id>
# Prints {source, items:[{id,status,evidence}]|null}, never text. items is null
# when the source has nothing readable (missing/corrupt file, ledger before
# Phase 3); consumers treat null and [] as "unavailable", never 0%.
mother_criteria_view() {
    local id="$1" src file
    src=$(jq -r '.criteria_source // "checklist"' "$JOBS_DIR/$id.json" 2>/dev/null) || src="checklist"
    [ -n "$src" ] || src="checklist"
    if [ "$src" != "checklist" ]; then
        jq -nc --arg s "$src" '{source: $s, items: null}'
        return 0
    fi
    file=$(mother_criteria_path "$id")
    jq -c '{source: "checklist",
            items: (if (.items | type) == "array"
                    then [.items[] | {id, status: (.status // "open"), evidence: (.evidence // null)}]
                    else null end)}' "$file" 2>/dev/null \
        || jq -nc '{source: "checklist", items: null}'
}
