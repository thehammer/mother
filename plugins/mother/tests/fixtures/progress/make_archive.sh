#!/usr/bin/env bash
# make_archive.sh — deterministic synthetic job history for progress.bats.
#
# Usage: make_archive.sh <MOTHER_ROOT>
#
# Writes finished jobs under <MOTHER_ROOT>/archive/YYYY-MM/<id>.json and
# <id>.events.jsonl (month = finished_at[:7]; the history deliberately spans a
# month boundary), plus <MOTHER_ROOT>/fixture-expected.json: the hand-derivable
# expectations (computed from the construction below, NOT by running any Mother
# code) that progress.bats compares `mother-usage calibrate` output against.
#
# Population
#   Carefeed/big-repo    25 counted jobs (23 succeeded, 2 failed in build)
#                        + 1 cancelled job            (must NOT be counted)
#                        + 1 failed job with no worker (zero active time; must NOT be counted)
#   Carefeed/small-repo   5 counted jobs (all succeeded)
#   fleet                30 counted jobs
#
# Timeline of a succeeded job (every duration below is ACTIVE time in seconds;
# the gaps between them are queue waits / inter-process hand-offs and are
# deliberately inactive):
#
#   queued .. ready                 queue wait
#   worker_spawned .. final_result_observed       build   B
#   gates_started .. gates_completed              gates   G
#   adherence_review_spawned .. adherence_reviewed        review  R
#   [every third big-repo job:
#     adherence_rework_kicked, (queue wait), worker_spawned .. final_result_observed   rework  W
#     adherence_review_spawned .. adherence_reviewed                                    review  R2]
#   pr_marked_ready .. succeeded                  present P
#
# A failed job has only a build interval (worker_spawned .. failed).
#
# Durations (i = index within the repo)
#   big-repo   B = 600 + 30 i   G = 60 + 10 (i mod 5)   R = 120 + 10 (i mod 7)
#              rework iff i mod 3 == 0: W = 200 + 20 i, R2 = 100
#              P = 30 + 5 (i mod 4);  i = 5 and i = 17 are the failed (build-only) jobs
#   small-repo B = 300 + 50 i   G = 45 + 5 i   R = 90 + 10 i   P = 20 + 5 i   (no rework)
set -eu

ROOT="${1:?usage: make_archive.sh <MOTHER_ROOT>}"

exec python3 - "$ROOT" <<'PY'
import json
import os
import statistics
import sys
from datetime import datetime, timedelta, timezone

root = sys.argv[1]
BASE = datetime(2026, 9, 16, 6, 0, 0, tzinfo=timezone.utc)
STAGES = ["build", "rework", "gates", "review", "present"]


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (dt.microsecond // 1000)


class Timeline:
    def __init__(self, start):
        self.start = start
        self.t = 0
        self.events = []
        self.stage_s = {s: 0 for s in STAGES}
        self.stage_first_elapsed = {}  # stage -> active seconds at its first start
        self.active = 0
        self._open = None  # (stage, started_t)

    def at(self):
        return self.start + timedelta(seconds=self.t)

    def ev(self, kind, detail=None):
        self.events.append({"ts": iso(self.at()), "kind": kind, "detail": detail or {}})

    def adv(self, s):
        self.t += s

    def begin(self, stage):
        self.stage_first_elapsed.setdefault(stage, self.active)
        self._open = (stage, self.t)

    def end(self):
        stage, t0 = self._open
        d = self.t - t0
        self.stage_s[stage] += d
        self.active += d
        self._open = None

    def interval(self, stage, seconds, start_kind, end_kind, start_detail=None, end_detail=None):
        self.ev(start_kind, start_detail)
        self.begin(stage)
        self.adv(seconds)
        self.ev(end_kind, end_detail)
        self.end()


def job_record(jid, repo, state, tl, title):
    spawned = next((e["ts"] for e in tl.events if e["kind"] == "worker_spawned"), None)
    finished = tl.events[-1]["ts"]
    return {
        "id": jid, "title": title, "repo": repo, "repo_path": "/tmp/" + repo.split("/")[-1],
        "branch": "feature/" + jid, "base_ref": "origin/main", "isolation": "worktree",
        "executor": "local-tmux", "depends_on": [], "max_cost_usd": None,
        "plan_path": "", "log_path": "", "state": state,
        "created_at": tl.events[0]["ts"], "started_at": spawned, "finished_at": finished,
        "pr_url": None, "actual_cost_usd": 1.25, "retry_count": 0, "escalation_count": 0,
        "adherence_attempts": 1, "current_tier": "tier_0",
    }


def build_succeeded(start, p):
    tl = Timeline(start)
    tl.ev("queued", {"title": "synthetic"})
    tl.adv(10 + (p["i"] % 4) * 5)
    tl.ev("ready")
    tl.adv(5)
    tl.ev("running")
    tl.interval("build", p["B"], "worker_spawned", "final_result_observed",
                {"session_id": "s-build"})
    tl.adv(3)
    names = ["lint", "unit", "static"]
    tl.ev("gates_started", {"attempt": 1, "max_attempts": 3, "head_sha": "abc1234",
                            "mode": "enforce", "posture": "normal", "gates": names})
    tl.begin("gates")
    tl.adv(10)
    tl.ev("gate_result", {"attempt": 1, "name": "lint", "result": "passed", "blocking": True})
    tl.adv(10)
    tl.ev("gate_result", {"attempt": 1, "name": "unit", "result": "passed", "blocking": True})
    tl.adv(p["G"] - 20)
    tl.ev("gate_result", {"attempt": 1, "name": "static", "result": "passed", "blocking": True})
    tl.ev("gates_completed", {"attempt": 1, "status": "passed", "passed": 3, "failed": 0,
                              "unavailable": 0, "not_run": []})
    tl.end()
    tl.adv(2)
    tl.interval("review", p["R"], "adherence_review_spawned", "adherence_reviewed",
                None, {"verdict": "pass" if not p.get("W") else "fail"})
    if p.get("W"):
        tl.ev("adherence_rework_kicked", {"attempt": 1})
        tl.adv(15)
        tl.interval("rework", p["W"], "worker_spawned", "final_result_observed",
                    {"session_id": "s-rework"})
        tl.adv(2)
        tl.interval("review", p["R2"], "adherence_review_spawned", "adherence_reviewed",
                    None, {"verdict": "pass"})
    tl.adv(1)
    tl.ev("pr_marked_ready", {"reason": "gates_passed"})
    tl.begin("present")
    tl.adv(p["P"])
    tl.ev("succeeded")
    tl.end()
    return tl


def build_failed(start, B):
    tl = Timeline(start)
    tl.ev("queued", {"title": "synthetic"})
    tl.adv(20)
    tl.ev("ready")
    tl.adv(5)
    tl.ev("running")
    tl.ev("worker_spawned", {"session_id": "s-build"})
    tl.begin("build")
    tl.adv(B)
    tl.ev("failed", {"reason": "claude_exit_nonzero"})
    tl.end()
    return tl


jobs = []  # (job, events, counted_in_expected, repo, timeline)
k = 0


def next_start():
    global k
    s = BASE + timedelta(hours=14 * k)
    k += 1
    return s


for i in range(25):
    start = next_start()
    jid = "big-%02d" % i
    if i in (5, 17):
        tl = build_failed(start, 600 + 30 * i)
        state = "failed"
    else:
        p = {"i": i, "B": 600 + 30 * i, "G": 60 + 10 * (i % 5), "R": 120 + 10 * (i % 7),
             "P": 30 + 5 * (i % 4)}
        if i % 3 == 0:
            p["W"] = 200 + 20 * i
            p["R2"] = 100
        tl = build_succeeded(start, p)
        state = "succeeded"
    jobs.append((job_record(jid, "Carefeed/big-repo", state, tl, "big job %d" % i), tl, True,
                 "Carefeed/big-repo"))

for i in range(5):
    start = next_start()
    p = {"i": i, "B": 300 + 50 * i, "G": 45 + 5 * i, "R": 90 + 10 * i, "P": 20 + 5 * i}
    tl = build_succeeded(start, p)
    jobs.append((job_record("small-%02d" % i, "Carefeed/small-repo", "succeeded", tl,
                            "small job %d" % i), tl, True, "Carefeed/small-repo"))

# Cancelled mid-build: finished, but never counted.
start = next_start()
tl = Timeline(start)
tl.ev("queued")
tl.adv(20)
tl.ev("ready")
tl.adv(5)
tl.ev("worker_spawned", {"session_id": "s"})
tl.begin("build")
tl.adv(400)
tl.ev("cancelled", {})
tl.end()
jobs.append((job_record("big-cancelled", "Carefeed/big-repo", "cancelled", tl, "cancelled"),
             tl, False, "Carefeed/big-repo"))

# Failed before any worker ever ran: zero active time, never counted.
start = next_start()
tl = Timeline(start)
tl.ev("queued")
tl.adv(20)
tl.ev("ready")
tl.adv(5)
tl.ev("failed", {"reason": "worktree_create_failed"})
jobs.append((job_record("big-noworker", "Carefeed/big-repo", "failed", tl, "never ran"),
             tl, False, "Carefeed/big-repo"))

# ---- write the archive -----------------------------------------------------
for job, tl, _counted, _repo in jobs:
    month = job["finished_at"][:7]
    d = os.path.join(root, "archive", month)
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, job["id"] + ".json"), "w") as fh:
        json.dump(job, fh, indent=2)
    with open(os.path.join(d, job["id"] + ".events.jsonl"), "w") as fh:
        for e in tl.events:
            fh.write(json.dumps(e, ensure_ascii=False) + "\n")


# ---- expectations ----------------------------------------------------------
def scope(selected):
    tls = [tl for (_j, tl, counted, repo) in jobs if counted and selected(repo)]
    out = {"n": len(tls), "stages": {}, "start_p50": {}}
    grand = sum(sum(tl.stage_s.values()) for tl in tls)
    for st in STAGES:
        vals = [tl.stage_s[st] for tl in tls if tl.stage_s[st] > 0]
        if not vals:
            continue
        out["stages"][st] = {
            "n": len(vals),
            "median_s": statistics.median(vals),
            "max_s": max(vals),
            "min_s": min(vals),
            "share": sum(vals) / grand,
        }
        ratios = []
        for tl in tls:
            if tl.stage_s[st] > 0 and tl.stage_first_elapsed.get(st, 0) > 0:
                e = tl.stage_first_elapsed[st]
                ratios.append((tl.active - e) / e)
        if ratios:
            out["start_p50"][st] = {"n": len(ratios), "p50": statistics.median(ratios)}
    return out


expected = {
    "Carefeed/big-repo": scope(lambda r: r == "Carefeed/big-repo"),
    "Carefeed/small-repo": scope(lambda r: r == "Carefeed/small-repo"),
    "fleet": scope(lambda r: True),
}
with open(os.path.join(root, "fixture-expected.json"), "w") as fh:
    json.dump(expected, fh, indent=2)
PY
