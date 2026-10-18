#!/usr/bin/env python3
"""findings_merge.py -- merge a wave of lens results (HC-13).

Usage: findings_merge.py merge <wave_dir> <work_dir> <head_sha> <changed_files.json>

Reads every <lens>.json in <wave_dir> ({findings, examined, ...}), then writes
<wave_dir>/merged.json and <wave_dir>/summary.json and prints the summary.

Rules (all mechanical, zero tokens):

* Claim verification at <head_sha> via `git show <sha>:<path>`:
    verified    quote found (whitespace-normalised) within +-15 lines of the cited line
    refuted     the file does not exist at the sha, or the quote is nowhere in it
    unverified  quote found only elsewhere in the file
  "verified" means "citation found at the cited location" -- it says nothing
  about whether the finding is correct. A finding with asserts_existing_code
  true and no claims is `unverified`. Findings with neither are `none`.
  MOTHER_CLAIM_VERIFY_ENABLED=0 makes every claim `unverified` (no git calls).
  A source finding's verification: refuted if any of its claims is refuted, else
  unverified if any is unverified, else verified. A merged finding is refuted
  only when every source finding is refuted (one lens's false claim never
  removes another lens's finding); it is downgraded only when no source is
  verified or non-asserting.

* Dedup: same location path, line ranges overlapping or within 3 lines, same
  target -> one finding with the highest severity, `lenses` = union, and every
  source id in `merged_from`. (So findings that differ only in severity merge.)

* Conflict: lenses cannot see each other, so the rule is an approximation:
  two non-refuted findings with the same path and overlapping ranges but a
  different target are both marked `conflict: true` with `conflicts_with`
  holding the other ids. Findings without a location never dedup or conflict.

* Coverage: each changed file absent from the union of `examined` becomes an
  advisory `coverage_gap` finding (id cov-N, target human).

* Routing view: `actionable` = findings minus refuted; unverified findings are
  downgraded to advisory there (`findings` keeps the original severity).
"""
import json
import os
import re
import subprocess
import sys

WINDOW = 15
ADJACENT = 3
RANK = {"advisory": 0, "blocking": 1}


def norm(s):
    return re.sub(r"\s+", " ", s).strip()


def parse_location(loc):
    """'path:10-12' / 'path:10' / 'path' -> (path, start, end); lines None if absent."""
    if not isinstance(loc, str) or not loc:
        return None
    m = re.match(r"^(.*?):(\d+)(?:-(\d+))?$", loc)
    if m:
        a = int(m.group(2))
        b = int(m.group(3)) if m.group(3) else a
        return m.group(1), min(a, b), max(a, b)
    return loc, None, None


class Verifier:
    def __init__(self, work_dir, sha, enabled):
        self.work_dir, self.sha, self.enabled = work_dir, sha, enabled
        self._cache = {}

    def _file(self, path):
        if path not in self._cache:
            r = subprocess.run(["git", "-C", self.work_dir, "show", "%s:%s" % (self.sha, path)],
                               capture_output=True)
            self._cache[path] = r.stdout.decode("utf-8", "replace") if r.returncode == 0 else None
        return self._cache[path]

    def claim(self, c):
        if not self.enabled:
            return "unverified"
        text = self._file(c["path"])
        if text is None:
            return "refuted"
        quote = norm(c.get("quote", ""))
        lines = text.splitlines()
        line = int(c.get("line", 0))
        lo, hi = max(0, line - 1 - WINDOW), min(len(lines), line + WINDOW)
        if quote in norm("\n".join(lines[lo:hi])):
            return "verified"
        return "unverified" if quote in norm(text) else "refuted"


def overall(finding, statuses):
    if not statuses:
        return "unverified" if finding.get("asserts_existing_code") else "none"
    for s in ("refuted", "unverified"):
        if s in statuses:
            return s
    return "verified"


def combine(member_status):
    """One source finding's refuted claim must not remove another lens's finding:
    refuted only when every source is refuted; a source with no assertion
    (`none`) or a verified one keeps the merged finding un-downgraded."""
    live = [s for s in member_status if s != "refuted"]
    if not live:
        return "refuted"
    for s in ("verified", "none"):
        if s in live:
            return s
    return "unverified"


def overlaps(a, b, slack):
    return a[0] == b[0] and a[1] is not None and b[1] is not None \
        and a[1] <= b[2] + slack and b[1] <= a[2] + slack


def load_lenses(wave_dir):
    """(lenses, errors): readable side files, and the lenses whose side file
    could not be read. An unreadable side file is a lens that did not report,
    never a lens with nothing to say."""
    out, errors = [], []
    for name in sorted(os.listdir(wave_dir)):
        # Dotfiles are Mother's own scratch (e.g. .changed.<pid>.json), not lens side files.
        if not name.endswith(".json") or name.startswith(".") or name in ("merged.json", "summary.json"):
            continue
        try:
            with open(os.path.join(wave_dir, name)) as f:
                data = json.load(f)
        except (OSError, ValueError):
            errors.append({"lens": name[:-5], "reason": "unreadable"})
            continue
        if isinstance(data, dict):
            out.append((name[:-5], data))
        else:
            errors.append({"lens": name[:-5], "reason": "unreadable"})
    return out, errors


def dedup(raw):
    groups = []
    for f in raw:
        loc = parse_location(f.get("location"))
        for g in groups:
            if loc and g["loc"] and g["target"] == f.get("target") and overlaps(loc, g["loc"], ADJACENT):
                g["members"].append(f)
                g["loc"] = (loc[0], min(loc[1], g["loc"][1]), max(loc[2], g["loc"][2]))
                break
        else:
            groups.append({"loc": loc if loc and loc[1] is not None else None,
                           "target": f.get("target"), "members": [f]})
    return groups


def build(group, idx, verifier):
    ms = group["members"]
    first = dict(ms[0])
    first.pop("reviewer", None)
    claims, member_status = [], []
    for m in ms:
        statuses = []
        for c in m.get("claims") or []:
            st = verifier.claim(c)
            claims.append(dict(c, claim_status=st, lens=m.get("lens")))
            statuses.append(st)
        member_status.append(overall(m, statuses))
    asserts = any(m.get("asserts_existing_code") for m in ms)
    lenses = sorted({m["lens"] for m in ms if m.get("lens")})
    f = dict(first)
    f.update({
        "id": "f%d" % idx,
        "severity": max((m.get("severity", "advisory") for m in ms), key=lambda s: RANK.get(s, 0)),
        "lenses": lenses,
        "reviewers": sorted({m["reviewer"] for m in ms if m.get("reviewer")}),
        "merged_from": [m["_orig_id"] for m in ms],
        "claims": claims,
        "verification": combine(member_status),
        "conflict": False,
        "conflicts_with": [],
    })
    if asserts:
        f["asserts_existing_code"] = True
    f.pop("_orig_id", None)
    return f, group["loc"]


def mark_conflicts(items):
    live = [(f, loc) for f, loc in items if f["verification"] != "refuted" and loc]
    for i, (a, la) in enumerate(live):
        for b, lb in live[i + 1:]:
            if a["target"] != b["target"] and overlaps(la, lb, 0):
                for x, y in ((a, b), (b, a)):
                    x["conflict"] = True
                    x["conflicts_with"].append(y["id"])


def merge(wave_dir, work_dir, sha, changed):
    verifier = Verifier(work_dir, sha, os.environ.get("MOTHER_CLAIM_VERIFY_ENABLED", "1") != "0")
    raw, examined = [], set()
    lenses, lens_errors = load_lenses(wave_dir)
    for lens, data in lenses:
        # A lens that errored (HC-12 writes state/decision "error") did not
        # review: surface it on its own, never infer it from coverage gaps.
        if data.get("state") == "error" or data.get("decision") == "error":
            lens_errors.append({"lens": lens, "reason": str(data.get("error_reason") or "error")})
            continue
        examined.update(e for e in data.get("examined") or [] if isinstance(e, str))
        for i, f in enumerate(data.get("findings") or []):
            if not isinstance(f, dict):
                continue
            f = dict(f)
            f.setdefault("lens", lens)
            f["_orig_id"] = "%s:%s" % (lens, f.get("id") or i + 1)
            raw.append(f)

    items = [build(g, n + 1, verifier) for n, g in enumerate(dedup(raw))]
    mark_conflicts(items)
    findings = [f for f, _ in items]

    gaps = []
    for n, path in enumerate(p for p in changed if p not in examined):
        gaps.append({"id": "cov-%d" % (n + 1), "target": "human", "severity": "advisory",
                     "kind": "coverage_gap", "location": path, "lenses": [], "merged_from": [],
                     "claims": [], "verification": "none", "conflict": False, "conflicts_with": []})
    findings += gaps

    lens_errors.sort(key=lambda e: e["lens"])
    errs = []
    for n, e in enumerate(lens_errors):
        errs.append({"id": "lens-err-%d" % (n + 1), "target": "human", "severity": "blocking",
                     "kind": "lens_error", "location": e["lens"], "reason": e["reason"],
                     "lenses": [e["lens"]], "merged_from": [], "claims": [], "verification": "none",
                     "conflict": False, "conflicts_with": []})
    findings += errs

    refuted = [f for f in findings if f["verification"] == "refuted"]
    actionable = []
    for f in findings:
        if f["verification"] == "refuted":
            continue
        a = dict(f)
        if f["verification"] == "unverified":
            a["severity"] = "advisory"
            a["downgraded"] = f["severity"] != "advisory"
        actionable.append(a)

    counts = {k: sum(1 for f in findings if f["verification"] == k)
              for k in ("verified", "refuted", "unverified")}
    merged = {"findings": findings, "actionable": actionable, "refuted": refuted,
              "coverage_gaps": gaps, "lens_errors": lens_errors, "claims": counts}
    summary = {"findings": len(findings),
               "blocking": sum(1 for f in actionable if f["severity"] == "blocking"),
               "advisory": sum(1 for f in actionable if f["severity"] == "advisory"),
               "conflicts": sum(1 for f in findings if f["conflict"]),
               "coverage_gaps": len(gaps), "lens_errors": len(lens_errors), "claims": counts}
    for name, doc in (("merged.json", merged), ("summary.json", summary)):
        tmp = os.path.join(wave_dir, "%s.tmp.%d" % (name, os.getpid()))
        with open(tmp, "w") as fh:
            json.dump(doc, fh, indent=2)
        os.replace(tmp, os.path.join(wave_dir, name))
    return summary


def main(argv):
    if len(argv) != 6 or argv[1] != "merge":
        sys.stderr.write("usage: findings_merge.py merge <wave_dir> <work_dir> <head_sha> <changed_files.json>\n")
        return 2
    _, _, wave_dir, work_dir, sha, changed_path = argv
    if not os.path.isdir(wave_dir):
        sys.stderr.write("findings_merge: no such wave dir: %s\n" % wave_dir)
        return 1
    with open(changed_path) as f:
        changed = json.load(f)
    print(json.dumps(merge(wave_dir, work_dir, sha, changed)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
