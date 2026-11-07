"""Behavioural tests for lib/limiter_core.py, the backpressure limiter's pure control law (L1, observe-only).

Written from the acceptance criteria (L1-1 .. L1-6, L1-12, L1-13 and the ordering / force-start /
estimate rules), not from the implementation. The core is pure: every test builds an input dict,
passes the previous result as `prev`, and reads the state dict that comes back.

Run:  python3 -m unittest -v plugins/mother/tests/limiter_core_test.py
"""

import ast
import copy
import json
import os
import re
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(os.path.dirname(HERE), "lib")
FIXTURES = os.path.join(HERE, "fixtures", "limiter")
sys.path.insert(0, LIB)
import limiter_core as core  # noqa: E402

T0 = 1_800_000_000          # an arbitrary "now"
H5 = 5 * 3600
D7 = 7 * 86400
CFG = core.make_cfg({})


# ---------------------------------------------------------------------------
# builders
# ---------------------------------------------------------------------------

def feed(u5=0.0, r5=None, u7=0.0, r7=None, stale=False):
    return {"five_hour": {"used_pct": u5, "resets_at": T0 + H5 if r5 is None else r5},
            "seven_day": {"used_pct": u7, "resets_at": T0 + D7 if r7 is None else r7},
            "stale": stale}


def rjob(jid, cls="personal", created="2026-01-01T00:00:00Z", usd=0.1, **kw):
    j = {"id": jid, "data_class": cls, "created_at": created, "usd_per_min": usd}
    j.update(kw)
    return j


def runjob(jid, cls="personal", started="2026-01-01T00:00:00Z", **kw):
    j = {"id": jid, "data_class": cls, "created_at": started, "started_at": started}
    j.update(kw)
    return j


def make_inp(f=None, ready=(), running=(), ceiling=4, gate="on", cum=0.0, distress=(), overage=False):
    return {"feed": f or feed(), "gate": gate, "ceiling": ceiling, "overage_in_use": overage,
            "running": list(running), "ready": list(ready), "mother_cum_usd": cum,
            "distress": list(distress)}


def calibrated(now, k5=None, k7=None, fleet=None, cum=0.0, pct5=0.0, pct7=0.0, n=12):
    """A `prev` in which k is calibrated (n samples of ratio k) and, when `fleet` is given, Mother has
    been spending `fleet` USD/min for the last two minutes (the burn the next tick will observe)."""
    prev = {"calib": {}}
    for name, k, pct in (("5h", k5, pct5), ("7d", k7, pct7)):
        prev["calib"][name] = {"last": {"ts": now - 1, "used_pct": pct, "resets_at": 0, "usd": cum},
                               "ratios": [k] * n if k else []}
    if fleet is not None:
        prev["samples"] = [[now - 120, cum - fleet * 2.0, pct5]]
    return prev


def dist(status=429, job="j", retry_after=None, kind="api_retry"):
    return {"kind": kind, "status": status, "retry_after_s": retry_after, "job_id": job}


def by_id(rows):
    return {r["id"]: r for r in rows}


def admitted(st):
    return [r["id"] for r in st["ready"] if r["decision"] == "admit"]


def held(st):
    return {r["id"]: r["code"] for r in st["ready"] if r["decision"] == "hold"}


# ---------------------------------------------------------------------------
# L1-1  budget pace
# ---------------------------------------------------------------------------

class BudgetPaceTests(unittest.TestCase):
    """5h used 40%, 150 min to reset, reserve 15 => 45 points sustainable = 0.3 %/min.
    k = 0.2 %/USD, so the fleet may burn at most 1.5 USD/min including the candidate."""

    def _tick(self, candidate, fleet=0.9, k5=0.2, **kw):
        prev = calibrated(T0, k5=k5, k7=kw.pop("k7", None), fleet=fleet, cum=10.0, pct5=40)
        f = kw.pop("f", None) or feed(u5=40, r5=T0 + 150 * 60)
        inp = make_inp(f, ready=[rjob("cand", usd=candidate)], cum=10.0, **kw)
        return core.tick(inp, prev, T0, CFG)

    def test_candidate_that_reaches_the_sustainable_pace_is_held(self):
        st = self._tick(0.6)
        row = by_id(st["ready"])["cand"]
        self.assertEqual(row["decision"], "hold")
        self.assertEqual(row["code"], "budget_pace")
        self.assertRegex(row["reason"], r"^throttled: 5h window pace [0-9.]+×$")
        self.assertFalse(row["advisory"])
        self.assertEqual(admitted(st), [])

    def test_candidate_under_the_pace_is_admitted(self):
        st = self._tick(0.59)
        self.assertEqual(admitted(st), ["cand"])

    def test_zero_burn_candidate_is_admitted(self):
        st = self._tick(0.0)
        self.assertEqual(admitted(st), ["cand"])

    def test_pace_well_over_one_names_the_multiple(self):
        st = self._tick(2.1)    # (0.9 + 2.1) * 0.2 = 0.6 %/min against 0.3 sustainable
        row = by_id(st["ready"])["cand"]
        self.assertEqual(row["code"], "budget_pace")
        self.assertIn("2.0×", row["reason"])

    def test_admitting_one_job_counts_against_the_next_in_the_same_tick(self):
        prev = calibrated(T0, k5=0.2, fleet=0.9, cum=10.0, pct5=40)
        inp = make_inp(feed(u5=40, r5=T0 + 150 * 60),
                       ready=[rjob("a", created="2026-01-01T00:00:01Z", usd=0.3),
                              rjob("b", created="2026-01-01T00:00:02Z", usd=0.3)], cum=10.0)
        st = core.tick(inp, prev, T0, CFG)
        self.assertEqual(admitted(st), ["a"])
        self.assertEqual(held(st), {"b": "budget_pace"})

    def test_seven_day_window_decides_when_it_is_the_tighter_one(self):
        # 5h is loose; the 7d window is at 90% with a day left.
        prev = calibrated(T0, k5=0.2, k7=0.2, fleet=0.2, cum=10.0, pct5=0, pct7=90)
        f = feed(u5=0, r5=T0 + H5, u7=90, r7=T0 + 86400)
        st = core.tick(make_inp(f, ready=[rjob("cand", usd=0.1)], cum=10.0), prev, T0, CFG)
        row = by_id(st["ready"])["cand"]
        self.assertEqual(row["code"], "budget_pace")
        self.assertRegex(row["reason"], r"^throttled: 7d window pace [0-9.]+×$")

    def test_uncalibrated_k_never_holds_on_pace_however_heavy_the_burn(self):
        for n in (0, 5, 11):
            with self.subTest(samples=n):
                prev = calibrated(T0, k5=0.2, fleet=50.0, cum=10.0, pct5=40, n=n)
                st = core.tick(make_inp(feed(u5=40, r5=T0 + 150 * 60),
                                        ready=[rjob("cand", usd=50.0)], cum=10.0), prev, T0, CFG)
                self.assertEqual(admitted(st), ["cand"])
                self.assertFalse(st["budget"]["five_hour"]["calibrated"])

    def test_calibrated_once_enough_samples_exist_and_then_holds(self):
        prev = calibrated(T0, k5=0.2, fleet=50.0, cum=10.0, pct5=40, n=12)
        st = core.tick(make_inp(feed(u5=40, r5=T0 + 150 * 60),
                                ready=[rjob("cand", usd=50.0)], cum=10.0), prev, T0, CFG)
        self.assertTrue(st["budget"]["five_hour"]["calibrated"])
        self.assertEqual(held(st), {"cand": "budget_pace"})

    def test_no_burn_history_yet_means_no_pace_hold(self):
        # fleet_rate is unknown under 60 s of samples: first tick ever.
        prev = calibrated(T0, k5=0.2, fleet=None, cum=10.0, pct5=40)
        st = core.tick(make_inp(feed(u5=40, r5=T0 + 150 * 60),
                                ready=[rjob("cand", usd=50.0)], cum=10.0), prev, T0, CFG)
        self.assertEqual(admitted(st), ["cand"])
        self.assertIsNone(st["budget"]["fleet_usd_per_min"])

    def test_state_reports_pace_k_and_calibration(self):
        st = self._tick(0.6)
        b5 = st["budget"]["five_hour"]
        self.assertTrue(b5["calibrated"])
        self.assertAlmostEqual(b5["k"], 0.2)
        self.assertIsNotNone(b5["pace"])


# ---------------------------------------------------------------------------
# L1-2  reserve for interactive work
# ---------------------------------------------------------------------------

class ReserveTests(unittest.TestCase):
    def _ready(self, used, gate="on", **kw):
        return core.tick(make_inp(feed(u5=used), ready=[rjob("a", created="2026-01-01T00:00:01Z"),
                                                        rjob("b", cls="company", created="2026-01-01T00:00:02Z")],
                                  gate=gate, ceiling=4, **kw), {}, T0, CFG)

    def test_at_the_reserve_every_ready_job_is_held_for_interactive_work(self):
        st = self._ready(85)
        self.assertEqual(admitted(st), [])
        for r in st["ready"]:
            self.assertEqual(r["decision"], "hold")
            self.assertEqual(r["code"], "reserve")
            self.assertEqual(r["reason"], "reserve held for interactive work")
            self.assertFalse(r["advisory"])

    def test_just_under_the_reserve_jobs_are_admitted(self):
        st = self._ready(84)
        self.assertEqual(sorted(admitted(st)), ["a", "b"])

    def test_reserve_follows_the_configured_percentage(self):
        cfg = core.make_cfg({"reserve_pct": 30})
        st = core.tick(make_inp(feed(u5=71), ready=[rjob("a")]), {}, T0, cfg)
        self.assertEqual(held(st), {"a": "reserve"})
        st = core.tick(make_inp(feed(u5=69), ready=[rjob("a")]), {}, T0, cfg)
        self.assertEqual(admitted(st), ["a"])

    def test_with_the_gate_off_the_reserve_hold_is_advisory_only(self):
        for gate in ("off", "off_until_reset"):
            with self.subTest(gate=gate):
                st = self._ready(90, gate=gate)
                for r in st["ready"]:
                    self.assertEqual(r["code"], "reserve")
                    self.assertTrue(r["advisory"])
                s = core.would_summary(st)
                self.assertEqual(s["hold"], [])
                self.assertEqual(sorted(a["id"] for a in s["advisory"]), ["a", "b"])
                self.assertTrue(st["budget"]["advisory"])

    def test_with_the_gate_on_reserve_holds_appear_in_would_summary(self):
        st = self._ready(90)
        s = core.would_summary(st)
        self.assertEqual(sorted(h["id"] for h in s["hold"]), ["a", "b"])
        self.assertEqual({h["code"] for h in s["hold"]}, {"reserve"})
        self.assertEqual(s["advisory"], [])
        self.assertFalse(st["budget"]["advisory"])

    def test_gate_off_does_not_make_slot_limits_advisory(self):
        st = core.tick(make_inp(feed(u5=0), ready=[rjob("a")], running=[runjob("r1"), runjob("r2")],
                                ceiling=2, gate="off"), {}, T0, CFG)
        row = by_id(st["ready"])["a"]
        self.assertEqual((row["decision"], row["code"], row["advisory"]), ("hold", "concurrency_full", False))
        self.assertEqual(core.would_summary(st)["hold"], [{"id": "a", "code": "concurrency_full"}])

    def test_a_stale_feed_never_holds_for_reserve_and_is_advisory(self):
        st = core.tick(make_inp(feed(u5=0, r5=0, stale=True), ready=[rjob("a")]), {}, T0, CFG)
        self.assertEqual(admitted(st), ["a"])
        self.assertTrue(st["budget"]["stale"])
        self.assertTrue(st["budget"]["advisory"])


# ---------------------------------------------------------------------------
# L1-3  interactive demand
# ---------------------------------------------------------------------------

class InteractiveDemandTests(unittest.TestCase):
    """Used% climbs 0.5 points every 120 s (15 %/h) with Mother spending nothing, k calibrated:
    unexplained, so interactive. The threshold is 10 %/h, sustained for 600 s."""

    STEP = 120

    def _drive(self, until, ready=(), running=(), u_start=60.0, r5=None, gate="on", rise=0.5, flat_after=None,
               ceiling=4, cum_step=0.0, stale=False, k7=None):
        r5 = T0 + 150 * 60 if r5 is None else r5
        prev = calibrated(T0, k5=0.2, k7=k7, fleet=None, cum=0.0, pct5=u_start)
        st, t, i, used, cum = None, T0, 0, u_start, 0.0
        while t <= T0 + until:
            if flat_after is None or t - T0 <= flat_after:
                used = u_start + rise * i
            cum += cum_step
            st = core.tick(make_inp(feed(u5=used, r5=r5, stale=stale), ready=ready, running=running,
                                    ceiling=ceiling, gate=gate, cum=cum), prev, t, CFG)
            prev, t, i = st, t + self.STEP, i + 1
        return st

    def test_demand_above_threshold_for_less_than_the_sustain_period_changes_nothing(self):
        st = self._drive(480, ready=[rjob("p"), rjob("c", cls="company")])
        self.assertGreater(st["interactive"]["pct_per_hour"], 10)
        self.assertEqual(sorted(admitted(st)), ["c", "p"])

    def test_sustained_demand_holds_personal_ready_jobs_but_admits_company(self):
        st = self._drive(840, ready=[rjob("p"), rjob("c", cls="company")])
        self.assertEqual(st["interactive"]["state"], "high")
        rows = by_id(st["ready"])
        self.assertEqual((rows["p"]["decision"], rows["p"]["code"]), ("hold", "interactive_personal"))
        self.assertEqual(rows["c"]["decision"], "admit")

    def test_interactive_hold_is_advisory_with_the_gate_off(self):
        st = self._drive(840, ready=[rjob("p")], gate="off")
        row = by_id(st["ready"])["p"]
        self.assertEqual(row["code"], "interactive_personal")
        self.assertTrue(row["advisory"])
        self.assertEqual(core.would_summary(st)["hold"], [])

    def test_demand_at_or_below_threshold_is_never_interactive(self):
        st = self._drive(1800, ready=[rjob("p")], rise=0.2)   # 6 %/h
        self.assertEqual(st["interactive"]["state"], "ok")
        self.assertEqual(admitted(st), ["p"])

    def test_personal_job_released_again_once_demand_subsides(self):
        st = self._drive(840 + 1800, ready=[rjob("p")], flat_after=840)
        self.assertNotEqual(st["interactive"]["state"], "high")
        self.assertEqual(admitted(st), ["p"])

    def test_motherss_own_spend_is_not_interactive_demand(self):
        # 15 %/h of window growth, fully explained by 2.5 USD per 120 s at k = 0.2 %/USD.
        st = self._drive(1200, running=[runjob("r")], cum_step=2.5)
        self.assertNotEqual(st["interactive"]["state"], "high")
        self.assertEqual(core.would_summary(st)["preempt"], [])

    def test_unknown_when_the_feed_is_stale(self):
        st = self._drive(1200, ready=[rjob("p")], stale=True)
        self.assertEqual(st["interactive"]["state"], "unknown")
        self.assertEqual(admitted(st), ["p"])

    def test_preempt_only_personal_running_jobs_and_only_when_use_at_reset_breaches_the_reserve(self):
        running = [runjob("p-run", cls="personal", started="2026-01-01T00:00:01Z"),
                   runjob("c-run", cls="company", started="2026-01-01T00:00:02Z")]
        st = self._drive(840, running=running, u_start=60.0)    # ~63% now, 15 %/h, 138 min left: ~97% at reset
        self.assertEqual(st["interactive"]["state"], "high")
        rows = by_id(st["running"])
        self.assertTrue(rows["p-run"]["would_preempt"])
        self.assertFalse(rows["c-run"]["would_preempt"])
        self.assertEqual(core.would_summary(st)["preempt"], ["p-run"])

    def test_no_preempt_when_projected_use_at_reset_stays_under_the_reserve(self):
        running = [runjob("p-run", cls="personal")]
        st = self._drive(840, running=running, u_start=20.0)    # ~23% + 15%/h * 2.3h = ~57%
        self.assertEqual(st["interactive"]["state"], "high")
        self.assertFalse(by_id(st["running"])["p-run"]["would_preempt"])
        self.assertEqual(core.would_summary(st)["preempt"], [])

    def test_no_preempt_before_the_demand_has_been_sustained(self):
        st = self._drive(480, running=[runjob("p-run")], u_start=60.0)
        self.assertFalse(by_id(st["running"])["p-run"]["would_preempt"])

    def test_a_company_job_is_never_preempted(self):
        st = self._drive(1200, running=[runjob("c1", cls="company"), runjob("c2", cls="company")], u_start=70.0)
        self.assertEqual(st["interactive"]["state"], "high")
        self.assertTrue(all(not r["would_preempt"] for r in st["running"]))
        self.assertEqual(core.would_summary(st)["preempt"], [])

    def test_preempt_is_advisory_with_the_gate_off(self):
        st = self._drive(840, running=[runjob("p-run")], u_start=60.0, gate="off")
        row = by_id(st["running"])["p-run"]
        self.assertTrue(row["would_preempt"])
        self.assertTrue(row["advisory"])
        self.assertEqual(core.would_summary(st)["preempt"], [])


# ---------------------------------------------------------------------------
# L1-4  backoff on distress
# ---------------------------------------------------------------------------

class BackoffTests(unittest.TestCase):
    def _cut(self, ceiling=6, events=None, ready=(), running=()):
        return core.tick(make_inp(feed(), ready=ready, running=running, ceiling=ceiling,
                                  distress=events if events is not None else [dist()]), {}, T0, CFG)

    def test_one_distress_event_halves_the_allowed_slots_in_the_same_tick(self):
        st = self._cut()
        self.assertEqual(st["allowed"], 3)
        self.assertEqual(st["components"]["backoff_level"], 3)
        self.assertEqual(st["components"]["distress_24h"], 1)

    def test_distress_limits_admissions_and_names_backoff(self):
        ready = [rjob("j%d" % i, created="2026-01-01T00:00:0%dZ" % i) for i in range(5)]
        st = self._cut(ready=ready)
        self.assertEqual(admitted(st), ["j0", "j1", "j2"])
        self.assertEqual(held(st), {"j3": "backoff", "j4": "backoff"})

    def test_five_events_in_one_tick_are_one_cut(self):
        st = self._cut(events=[dist(job="j%d" % i) for i in range(5)])
        self.assertEqual(st["allowed"], 3)
        self.assertEqual(st["components"]["distress_24h"], 5)

    def test_events_within_the_coalesce_window_do_not_cut_again(self):
        st = self._cut()
        for dt in (30, 60, 100):
            st = core.tick(make_inp(feed(), ceiling=6, distress=[dist()]), st, T0 + dt, CFG)
            self.assertEqual(st["allowed"], 3, "tick +%ds" % dt)

    def test_a_distress_after_the_coalesce_window_cuts_again_never_below_one(self):
        st = self._cut()
        st = core.tick(make_inp(feed(), ceiling=6, distress=[dist()]), st, T0 + 130, CFG)
        self.assertEqual(st["allowed"], 1)
        st = core.tick(make_inp(feed(), ceiling=6, distress=[dist()]), st, T0 + 400, CFG)
        self.assertEqual(st["allowed"], 1)

    def test_calm_period_raises_one_step_at_a_time_to_the_ceiling(self):
        st = self._cut()
        series = []
        for dt in range(60, 3000, 60):
            st = core.tick(make_inp(feed(), ceiling=6), st, T0 + dt, CFG)
            series.append((dt, st["allowed"]))
        prev = 3
        for dt, a in series:
            self.assertLessEqual(a - prev, 1, "two steps in one tick at +%ds" % dt)
            self.assertGreaterEqual(a, prev, "allowed fell without distress at +%ds" % dt)
            prev = a

        def first(n):
            return min(dt for dt, a in series if a >= n)
        self.assertEqual(max(a for dt, a in series if dt < 900), 3)
        self.assertTrue(900 <= first(4) < 960, first(4))
        self.assertTrue(1800 <= first(5) < 1860, first(5))
        self.assertTrue(2700 <= first(6) < 2760, first(6))
        self.assertEqual(series[-1][1], 6)
        self.assertEqual(st["components"]["backoff_level"], 6)

    def test_a_long_gap_between_ticks_still_raises_only_one_step(self):
        st = self._cut()
        st = core.tick(make_inp(feed(), ceiling=6), st, T0 + 100_000, CFG)
        self.assertEqual(st["allowed"], 4)

    def test_ongoing_distress_postpones_the_recovery(self):
        st = self._cut()
        st = core.tick(make_inp(feed(), ceiling=6, distress=[dist()]), st, T0 + 100, CFG)   # coalesced
        st = core.tick(make_inp(feed(), ceiling=6), st, T0 + 950, CFG)
        self.assertEqual(st["allowed"], 3)
        st = core.tick(make_inp(feed(), ceiling=6), st, T0 + 1010, CFG)
        self.assertEqual(st["allowed"], 4)

    def test_distress_is_remembered_for_status(self):
        st = self._cut(events=[dist(status=529, job="jx")])
        self.assertEqual(st["components"]["last_distress"]["job_id"], "jx")

    def test_retry_after_pauses_all_admissions_even_forced_ones(self):
        ready = [rjob("a"), rjob("f", force_start=True)]
        st = core.tick(make_inp(feed(), ready=ready, ceiling=4,
                                distress=[dist(retry_after=300)]), {}, T0, CFG)
        self.assertEqual(admitted(st), [])
        self.assertEqual(held(st), {"a": "retry_after", "f": "retry_after"})
        # the pause lapses by itself
        st2 = core.tick(make_inp(feed(), ready=ready, ceiling=4), st, T0 + 400, CFG)
        self.assertNotIn("retry_after", held(st2).values())

    def test_running_jobs_over_the_backed_off_allowance_would_be_held_lowest_class_then_newest_first(self):
        running = [runjob("c-old", "company", "2026-01-01T00:00:01Z"),
                   runjob("p-old", "personal", "2026-01-01T00:00:02Z"),
                   runjob("p-new", "personal", "2026-01-01T00:00:03Z")]
        st = core.tick(make_inp(feed(), running=running, ceiling=4, distress=[dist()]), {}, T0, CFG)
        self.assertEqual(st["allowed"], 2)
        self.assertEqual(core.would_summary(st)["hold_running"], ["p-new"])
        running.append(runjob("c-new", "company", "2026-01-01T00:00:04Z"))
        st = core.tick(make_inp(feed(), running=running, ceiling=4, distress=[dist()]), {}, T0, CFG)
        self.assertEqual(sorted(core.would_summary(st)["hold_running"]), ["p-new", "p-old"])

    def test_cut_from_four_to_two_with_two_personal_two_company_holds_exactly_the_personal_pair(self):
        running = [runjob("c1", "company", "2026-01-01T00:00:01Z"), runjob("c2", "company", "2026-01-01T00:00:02Z"),
                   runjob("p1", "personal", "2026-01-01T00:00:03Z"), runjob("p2", "personal", "2026-01-01T00:00:04Z")]
        st = core.tick(make_inp(feed(), running=running, ceiling=4, distress=[dist()]), {}, T0, CFG)
        self.assertEqual(st["allowed"], 2)
        self.assertEqual(sorted(core.would_summary(st)["hold_running"]), ["p1", "p2"])

    def test_four_company_jobs_cut_to_two_hold_the_two_newest(self):
        running = [runjob("c%d" % i, "company", "2026-01-01T00:00:0%dZ" % i) for i in range(1, 5)]
        st = core.tick(make_inp(feed(), running=running, ceiling=4, distress=[dist()]), {}, T0, CFG)
        self.assertEqual(sorted(core.would_summary(st)["hold_running"]), ["c3", "c4"])

    def test_held_running_rows_carry_a_code_and_reason(self):
        running = [runjob("p1", "personal"), runjob("p2", "personal", "2026-01-01T00:00:02Z")]
        st = core.tick(make_inp(feed(), running=running, ceiling=2, distress=[dist()]), {}, T0, CFG)
        row = by_id(st["running"])["p2"]
        self.assertTrue(row["would_hold"])
        self.assertEqual(row["hold"]["code"], "backoff")
        self.assertTrue(row["hold"]["reason"])
        self.assertNotIn("hold", by_id(st["running"])["p1"])

    def test_no_distress_means_no_running_job_is_held(self):
        running = [runjob("a"), runjob("b")]
        st = core.tick(make_inp(feed(), running=running, ceiling=2), {}, T0, CFG)
        self.assertEqual(core.would_summary(st)["hold_running"], [])


# ---------------------------------------------------------------------------
# L1-5  ramp after a window reset
# ---------------------------------------------------------------------------

class RampTests(unittest.TestCase):
    R_OLD = T0 + 600
    R_NEW = R_OLD + H5

    def _before(self, ceiling=6):
        return core.tick(make_inp(feed(u5=70, r5=self.R_OLD), ceiling=ceiling), {}, T0, CFG)

    def _after(self, prev, t, ready, running=(), ceiling=6, u5=2, r5=None):
        return core.tick(make_inp(feed(u5=u5, r5=self.R_NEW if r5 is None else r5), ready=ready,
                                  running=running, ceiling=ceiling), prev, t, CFG)

    def _jobs(self, n=8):
        return [rjob("j%d" % i, created="2026-01-01T00:00:%02dZ" % i, usd=0.01) for i in range(n)]

    def test_reset_detected_by_resets_at_moving_forward_starts_the_ramp_at_two(self):
        st = self._after(self._before(), T0 + 700, self._jobs())
        self.assertEqual(st["allowed"], 2)
        self.assertEqual(len(admitted(st)), 2)
        self.assertEqual(set(held(st).values()), {"ramp"})
        self.assertTrue(st["components"]["ramp_active"])

    def test_reset_detected_by_a_used_pct_drop_of_twenty_points(self):
        prev = core.tick(make_inp(feed(u5=70, r5=self.R_OLD), ceiling=6), {}, T0, CFG)
        st = core.tick(make_inp(feed(u5=50, r5=self.R_OLD), ready=self._jobs(), ceiling=6), prev, T0 + 60, CFG)
        self.assertEqual(st["allowed"], 2)

    def test_a_smaller_drop_is_not_a_reset(self):
        prev = core.tick(make_inp(feed(u5=70, r5=self.R_OLD), ceiling=6), {}, T0, CFG)
        st = core.tick(make_inp(feed(u5=51, r5=self.R_OLD), ready=self._jobs(), ceiling=6), prev, T0 + 60, CFG)
        self.assertEqual(st["allowed"], 6)
        self.assertFalse(st["components"]["ramp_active"])

    def test_resets_at_creeping_forward_slightly_is_not_a_reset(self):
        prev = core.tick(make_inp(feed(u5=30, r5=self.R_OLD), ceiling=6), {}, T0, CFG)
        st = core.tick(make_inp(feed(u5=31, r5=self.R_OLD + 60), ready=self._jobs(), ceiling=6), prev, T0 + 60, CFG)
        self.assertEqual(st["allowed"], 6)

    def test_a_stale_feed_reading_zero_is_not_a_reset(self):
        prev = self._before()
        st = core.tick(make_inp(feed(u5=0, r5=0, u7=0, r7=0, stale=True), ready=self._jobs(), ceiling=6),
                       prev, T0 + 60, CFG)
        self.assertEqual(st["allowed"], 6)
        self.assertFalse(st["components"]["ramp_active"])

    def test_allowed_rises_one_per_ramp_step_up_to_the_ceiling(self):
        st = self._after(self._before(), T0 + 700, self._jobs())
        t_reset = T0 + 700
        seen = []
        for dt in range(100, 1500, 100):
            st = self._after(st, t_reset + dt, self._jobs())
            seen.append((dt, st["allowed"]))
        prev = 2
        for dt, a in seen:
            self.assertLessEqual(a - prev, 1, "two steps in one tick at +%ds" % dt)
            self.assertGreaterEqual(a, prev)
            prev = a
        by_dt = dict(seen)
        self.assertEqual((by_dt[200], by_dt[300], by_dt[500], by_dt[600]), (2, 3, 3, 4))
        self.assertEqual((by_dt[900], by_dt[1200]), (5, 6))
        self.assertEqual(by_dt[1400], 6)
        self.assertFalse(st["components"]["ramp_active"])

    def test_a_long_gap_still_raises_only_one_step(self):
        st = self._after(self._before(), T0 + 700, self._jobs())
        st = self._after(st, T0 + 700 + 50_000, self._jobs())
        self.assertEqual(st["allowed"], 3)

    def test_admissions_never_exceed_allowed_minus_running(self):
        running = [runjob("busy")]
        st = self._after(self._before(), T0 + 700, self._jobs(), running=running)
        self.assertEqual(st["allowed"], 2)
        self.assertEqual(len(admitted(st)), 1)

    def test_admissions_are_zero_when_running_already_fills_the_ramp(self):
        running = [runjob("a"), runjob("b")]
        st = self._after(self._before(), T0 + 700, self._jobs(), running=running)
        self.assertEqual(admitted(st), [])

    def test_ramp_start_follows_the_configuration(self):
        cfg = core.make_cfg({"ramp_start": 1})
        prev = self._before()
        st = core.tick(make_inp(feed(u5=2, r5=self.R_NEW), ready=self._jobs(), ceiling=6), prev, T0 + 700, cfg)
        self.assertEqual(st["allowed"], 1)

    def test_ramp_never_exceeds_a_ceiling_lower_than_ramp_start(self):
        prev = self._before(ceiling=1)
        st = self._after(prev, T0 + 700, self._jobs(), ceiling=1)
        self.assertEqual(st["allowed"], 1)

    def test_the_tighter_of_backoff_and_ramp_wins(self):
        prev = self._before(ceiling=8)
        st = core.tick(make_inp(feed(u5=2, r5=self.R_NEW), ceiling=8, distress=[dist()]), prev, T0 + 700, CFG)
        self.assertEqual(st["allowed"], 2)      # backoff would be 4, the ramp starts at 2
        prev = self._before(ceiling=2)
        st = core.tick(make_inp(feed(u5=2, r5=self.R_NEW), ceiling=2, distress=[dist()]), prev, T0 + 700, CFG)
        self.assertEqual(st["allowed"], 1)


# ---------------------------------------------------------------------------
# L1-6  distress classification
# ---------------------------------------------------------------------------

def _lines(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as fh:
        return [json.loads(l) for l in fh if l.strip()]


class ClassifierTests(unittest.TestCase):
    def test_overage_only_rejection_is_not_distress(self):
        ev = {"type": "rate_limit_event", "rate_limit_info": {
            "status": "rejected", "rateLimitType": "five_hour", "isUsingOverage": True, "overageInUse": True}}
        self.assertIsNone(core.classify_log_event(ev))

    def test_non_overage_rejection_is_distress(self):
        ev = {"type": "rate_limit_event", "rate_limit_info": {
            "status": "rejected", "rateLimitType": "five_hour", "isUsingOverage": False}}
        self.assertIsNotNone(core.classify_log_event(ev))

    def test_allowed_and_warning_rate_limit_events_are_not_distress(self):
        for status in ("allowed", "allowed_warning"):
            with self.subTest(status=status):
                ev = {"type": "rate_limit_event", "rate_limit_info": {"status": status, "isUsingOverage": False}}
                self.assertIsNone(core.classify_log_event(ev))

    def test_api_retry_with_null_status_is_not_distress(self):
        ev = {"type": "system", "subtype": "api_retry", "attempt": 1, "error_status": None, "error": "unknown"}
        self.assertIsNone(core.classify_log_event(ev))

    def test_api_retry_429_and_529_are_distress(self):
        for code in (429, 529):
            with self.subTest(code=code):
                d = core.classify_log_event({"type": "system", "subtype": "api_retry", "error_status": code})
                self.assertIsNotNone(d)
                self.assertEqual(d["status"], code)

    def test_result_with_api_error_status_429_is_distress(self):
        d = core.classify_log_event({"type": "result", "subtype": "success", "is_error": True,
                                     "api_error_status": 429, "result": "API Error: rate limit"})
        self.assertIsNotNone(d)

    def test_result_without_api_error_is_not_distress(self):
        self.assertIsNone(core.classify_log_event({"type": "result", "subtype": "success", "is_error": False,
                                                   "result": "done"}))

    def test_a_retry_after_hint_in_the_result_is_surfaced(self):
        d = core.classify_log_event({"type": "result", "is_error": True, "api_error_status": 429,
                                     "retry_after_s": 120, "result": "slow down"})
        self.assertEqual(d["retry_after_s"], 120)

    def test_failure_routed_rate_limited_is_distress(self):
        d = core.classify_mother_event({"ts": "2026-11-06T00:00:00Z", "kind": "failure_routed",
                                        "detail": {"reason": "rate_limited", "action": "backed_off"}})
        self.assertIsNotNone(d)

    def test_failure_routed_for_other_reasons_is_not_distress(self):
        for reason in ("no_pr_no_push", "branch_create_failed", "billing", None):
            with self.subTest(reason=reason):
                self.assertIsNone(core.classify_mother_event(
                    {"kind": "failure_routed", "detail": {"reason": reason}}))

    def test_other_mother_events_are_not_distress(self):
        self.assertIsNone(core.classify_mother_event({"kind": "queued", "detail": {"reason": "rate_limited"}}))

    def test_junk_never_raises(self):
        for junk in (None, "x", 3, [], {}, {"type": "system"}, {"type": "rate_limit_event"},
                     {"type": "rate_limit_event", "rate_limit_info": "no"}, {"kind": "failure_routed"},
                     {"kind": "failure_routed", "detail": "s"}):
            with self.subTest(junk=junk):
                self.assertIsNone(core.classify_log_event(junk))
                self.assertIsNone(core.classify_mother_event(junk))

    def test_fixture_logs_line_by_line(self):
        expect = {"overage_only.jsonl": 0, "api_retry_null.jsonl": 0, "api_retry_429.jsonl": 1,
                  "rejected_not_overage.jsonl": 1, "result_429.jsonl": 1}
        for name, n in expect.items():
            with self.subTest(fixture=name):
                got = [core.classify_log_event(ev) for ev in _lines(name)]
                self.assertEqual(len([g for g in got if g]), n)


# ---------------------------------------------------------------------------
# L1-12  k calibration
# ---------------------------------------------------------------------------

STEP_S = 600


def _run(points, min_samples=12, interval=STEP_S, t0=T0, gap=STEP_S):
    """Feed calibrate_k one point per `gap` seconds; returns (calib, k_after_each)."""
    calib, ks = {"last": None, "ratios": []}, []
    for i, p in enumerate(points):
        calib, k = core.calibrate_k(calib, p, t0 + i * gap, interval, min_samples)
        ks.append(k)
    return calib, ks


def pt(used, usd, resets=T0 + H5):
    return {"used_pct": used, "usd": usd, "resets_at": resets}


class CalibrationTests(unittest.TestCase):
    def test_a_sample_is_the_pct_gained_per_usd_spent(self):
        _, ks = _run([pt(10, 0), pt(20, 5)], min_samples=1)
        self.assertAlmostEqual(ks[-1], 2.0)

    def test_k_stays_unknown_until_k_min_samples_are_kept(self):
        points = [pt(1 + i * 0.5, i * 1.0) for i in range(13)]     # 12 samples of 0.5 %/USD
        _, ks = _run(points[:12])                                   # 11 samples
        self.assertIsNone(ks[-1])
        _, ks = _run(points)
        self.assertAlmostEqual(ks[-1], 0.5)

    def test_k_is_the_25th_percentile_not_the_mean_or_the_median(self):
        ratios = list(range(1, 101))                               # 1..100 per USD
        pts, used, usd = [pt(0.0, 0.0)], 0.0, 0.0
        for r in ratios[::-1]:                                      # unsorted on purpose
            usd += 0.1
            used += 0.1 * r / 100.0
            pts.append(pt(used, usd))
        _, ks = _run(pts)
        self.assertGreaterEqual(ks[-1] * 100, 24.0)
        self.assertLessEqual(ks[-1] * 100, 26.0)

    def test_sample_spanning_a_reset_by_resets_at_is_discarded(self):
        _, ks = _run([pt(10, 0), pt(30, 1)], min_samples=1)
        self.assertAlmostEqual(ks[-1], 20.0)
        _, ks = _run([pt(10, 0), pt(30, 1), pt(35, 2, resets=T0 + 2 * H5)], min_samples=1)
        self.assertAlmostEqual(ks[-1], 20.0)       # the reset sample added nothing

    def test_sample_spanning_a_reset_is_discarded_even_if_used_pct_rose(self):
        _, ks = _run([pt(10, 0), pt(40, 1, resets=T0 + 2 * H5)], min_samples=1)
        self.assertIsNone(ks[-1])

    def test_sample_where_used_pct_fell_is_discarded(self):
        _, ks = _run([pt(60, 0), pt(5, 1)], min_samples=1)
        self.assertIsNone(ks[-1])

    def test_sample_collection_resumes_after_the_discarded_reset_sample(self):
        _, ks = _run([pt(10, 0), pt(30, 1), pt(5, 2, resets=T0 + 2 * H5), pt(7, 3, resets=T0 + 2 * H5)],
                     min_samples=1)
        # kept ratios are 20 and 2; the 25th percentile of two is the lower one
        self.assertAlmostEqual(ks[-1], 2.0)

    def test_pinned_samples_are_discarded(self):
        for a, b in ((50, 99.5), (100, 100), (99, 99.5)):
            with self.subTest(start=a, end=b):
                _, ks = _run([pt(a, 0), pt(b, 1)], min_samples=1)
                self.assertIsNone(ks[-1])

    def test_samples_with_negligible_mother_spend_are_discarded(self):
        _, ks = _run([pt(10, 0), pt(12, 0.01)], min_samples=1)
        self.assertIsNone(ks[-1])

    def test_points_arriving_before_the_interval_take_no_sample(self):
        calib, _ = core.calibrate_k({"last": None, "ratios": []}, pt(10, 0), T0, STEP_S, 1)
        calib, k = core.calibrate_k(calib, pt(20, 5), T0 + 100, STEP_S, 1)
        self.assertIsNone(k)

    def test_only_the_two_hundred_most_recent_samples_are_kept(self):
        pts, used, usd = [pt(0.0, 0.0)], 0.0, 0.0
        for i in range(1, 251):                                    # ratios 0.01 .. 2.50 %/USD
            usd += 0.1
            used += 0.1 * i / 100.0
            pts.append(pt(used, usd))
        self.assertLess(used, 90)
        calib, ks = _run(pts)
        self.assertEqual(len(calib["ratios"]), 200)
        # the oldest 50 (0.01..0.50) are gone: the 25th percentile of 0.51..2.50 is ~1.0, not ~0.63
        self.assertGreaterEqual(ks[-1], 0.95)
        self.assertLessEqual(ks[-1], 1.05)

    def test_tick_reports_calibration_progress_per_window(self):
        st = core.tick(make_inp(feed()), calibrated(T0, k5=0.2, n=11), T0, CFG)
        self.assertFalse(st["budget"]["five_hour"]["calibrated"])
        self.assertFalse(st["budget"]["seven_day"]["calibrated"])
        st = core.tick(make_inp(feed()), calibrated(T0, k5=0.2, k7=0.1, n=12), T0, CFG)
        self.assertTrue(st["budget"]["five_hour"]["calibrated"])
        self.assertTrue(st["budget"]["seven_day"]["calibrated"])

    def test_the_configured_minimum_is_honoured(self):
        cfg = core.make_cfg({"k_min_samples": 3})
        st = core.tick(make_inp(feed()), calibrated(T0, k5=0.2, n=3), T0, cfg)
        self.assertTrue(st["budget"]["five_hour"]["calibrated"])


# ---------------------------------------------------------------------------
# L1-13  purity
# ---------------------------------------------------------------------------

class PurityTests(unittest.TestCase):
    FORBIDDEN = {"os", "subprocess", "time", "pathlib", "io", "sys", "shutil", "socket", "tempfile", "glob"}

    def _tree(self):
        with open(os.path.join(LIB, "limiter_core.py"), encoding="utf-8") as fh:
            return ast.parse(fh.read())

    def test_imports_nothing_that_touches_the_outside_world(self):
        mods = set()
        for node in ast.walk(self._tree()):
            if isinstance(node, ast.Import):
                mods.update(a.name.split(".")[0] for a in node.names)
            elif isinstance(node, ast.ImportFrom) and node.module:
                mods.add(node.module.split(".")[0])
        self.assertEqual(mods & self.FORBIDDEN, set())

    def test_never_calls_open(self):
        for node in ast.walk(self._tree()):
            if isinstance(node, ast.Call):
                f = node.func
                self.assertFalse(isinstance(f, ast.Name) and f.id in ("open", "__import__", "exec", "eval"),
                                 "call to %s at line %d" % (getattr(f, "id", "?"), node.lineno))

    def test_tick_does_not_mutate_its_inputs_and_is_deterministic(self):
        prev = calibrated(T0, k5=0.2, fleet=0.9, cum=10.0, pct5=40)
        inp = make_inp(feed(u5=40, r5=T0 + 150 * 60), ready=[rjob("a", usd=0.6), rjob("b", "company")],
                       running=[runjob("r")], cum=10.0, distress=[dist(retry_after=30)])
        prev0, inp0 = copy.deepcopy(prev), copy.deepcopy(inp)
        one = core.tick(inp, prev, T0, CFG)
        two = core.tick(inp, prev, T0, CFG)
        self.assertEqual(inp, inp0)
        self.assertEqual(prev, prev0)
        self.assertEqual(json.dumps(one, sort_keys=True), json.dumps(two, sort_keys=True))

    def test_tick_result_is_json_serialisable_and_feeds_back_in(self):
        st = core.tick(make_inp(feed(), ready=[rjob("a")]), {}, T0, CFG)
        again = core.tick(make_inp(feed(), ready=[rjob("a")]), json.loads(json.dumps(st)), T0 + 10, CFG)
        self.assertEqual(admitted(again), ["a"])


# ---------------------------------------------------------------------------
# priority ordering and force-start
# ---------------------------------------------------------------------------

class PriorityTests(unittest.TestCase):
    def _order(self, jobs, **kw):
        st = core.tick(make_inp(feed(), ready=jobs, ceiling=20, **kw), {}, T0, CFG)
        return [r["id"] for r in st["ready"]]

    def test_company_before_personal_then_oldest_then_id(self):
        jobs = [rjob("p1", "personal", "2026-01-01T00:00:01Z"),
                rjob("c2", "company", "2026-01-01T00:00:03Z"),
                rjob("c1", "company", "2026-01-01T00:00:02Z"),
                rjob("b-tie", "personal", "2026-01-01T00:00:05Z"),
                rjob("a-tie", "personal", "2026-01-01T00:00:05Z")]
        self.assertEqual(self._order(jobs), ["c1", "c2", "p1", "a-tie", "b-tie"])

    def test_priority_adjust_plus_one_promotes_a_personal_job_to_the_company_class(self):
        jobs = [rjob("c", "company", "2026-01-01T00:00:02Z"),
                rjob("promoted", "personal", "2026-01-01T00:00:01Z", priority_adjust=1),
                rjob("p", "personal", "2026-01-01T00:00:00Z")]
        self.assertEqual(self._order(jobs), ["promoted", "c", "p"])

    def test_priority_adjust_minus_one_demotes_a_company_job_to_the_personal_class(self):
        jobs = [rjob("demoted", "company", "2026-01-01T00:00:00Z", priority_adjust=-1),
                rjob("p", "personal", "2026-01-01T00:00:01Z"),
                rjob("c", "company", "2026-01-01T00:00:02Z")]
        self.assertEqual(self._order(jobs), ["c", "demoted", "p"])

    def test_a_scarce_slot_goes_to_the_company_job(self):
        jobs = [rjob("p", "personal", "2026-01-01T00:00:00Z"), rjob("c", "company", "2026-01-01T00:00:09Z")]
        st = core.tick(make_inp(feed(), ready=jobs, ceiling=1), {}, T0, CFG)
        self.assertEqual(admitted(st), ["c"])
        self.assertEqual(held(st), {"p": "concurrency_full"})

    def test_each_ready_row_carries_its_class(self):
        st = core.tick(make_inp(feed(), ready=[rjob("p", "personal"), rjob("c", "company")]), {}, T0, CFG)
        rows = by_id(st["ready"])
        self.assertEqual((rows["p"]["class"], rows["c"]["class"]), ("personal", "company"))


class ForceStartTests(unittest.TestCase):
    def test_force_start_bypasses_the_reserve(self):
        st = core.tick(make_inp(feed(u5=90), ready=[rjob("f", force_start=True), rjob("n")]), {}, T0, CFG)
        self.assertEqual(admitted(st), ["f"])
        self.assertEqual(held(st), {"n": "reserve"})

    def test_force_start_bypasses_budget_pace(self):
        prev = calibrated(T0, k5=0.2, fleet=0.9, cum=10.0, pct5=40)
        st = core.tick(make_inp(feed(u5=40, r5=T0 + 150 * 60), ready=[rjob("f", usd=5.0, force_start=True)],
                                cum=10.0), prev, T0, CFG)
        self.assertEqual(admitted(st), ["f"])

    def test_force_start_bypasses_interactive_personal(self):
        prev = calibrated(T0, k5=0.2, cum=0.0, pct5=60)
        t, st = T0, prev
        for i in range(8):
            st = core.tick(make_inp(feed(u5=60 + 0.5 * i, r5=T0 + 9000),
                                    ready=[rjob("f", force_start=True), rjob("n")]), st, t, CFG)
            t += 120
        self.assertEqual(st["interactive"]["state"], "high")
        self.assertEqual(admitted(st), ["f"])
        self.assertEqual(held(st), {"n": "interactive_personal"})

    def test_force_start_does_not_bypass_the_concurrency_ceiling(self):
        st = core.tick(make_inp(feed(), ready=[rjob("f", force_start=True)],
                                running=[runjob("a"), runjob("b")], ceiling=2), {}, T0, CFG)
        self.assertEqual(held(st), {"f": "concurrency_full"})

    def test_force_start_does_not_bypass_backoff(self):
        st = core.tick(make_inp(feed(), ready=[rjob("f", force_start=True)], running=[runjob("a")],
                                ceiling=4, distress=[dist()]), {}, T0, CFG)
        self.assertEqual(st["allowed"], 2)
        self.assertEqual(admitted(st), ["f"])             # one slot left under the backed-off allowance
        st = core.tick(make_inp(feed(), ready=[rjob("f", force_start=True)], running=[runjob("a"), runjob("b")],
                                ceiling=4, distress=[dist()]), {}, T0, CFG)
        self.assertEqual(held(st), {"f": "backoff"})

    def test_force_start_does_not_bypass_the_ramp(self):
        before = core.tick(make_inp(feed(u5=70, r5=T0 + 600), ceiling=6), {}, T0, CFG)
        st = core.tick(make_inp(feed(u5=2, r5=T0 + 600 + H5), ready=[rjob("f", force_start=True)],
                                running=[runjob("a"), runjob("b")], ceiling=6), before, T0 + 700, CFG)
        self.assertEqual(held(st), {"f": "ramp"})


# ---------------------------------------------------------------------------
# burn estimates, cumulative spend, fleet rate
# ---------------------------------------------------------------------------

def fin(repo, actor, upm, at):
    return {"repo": repo, "actor": actor, "usd_per_min": upm, "finished_at": at}


NOW_ISO = "2026-11-06T12:00:00Z"


class EstimateBurnTests(unittest.TestCase):
    def test_history_is_the_median_of_the_same_repo_and_actor(self):
        rows = [fin("r", "cody", v, "2026-10-0%dT00:00:00Z" % (i + 1)) for i, v in enumerate([0.2, 0.9, 0.4])]
        rows.append(fin("other", "cody", 9.0, "2026-10-09T00:00:00Z"))
        e = core.estimate_burn("r", "cody", rows, CFG, NOW_ISO)
        self.assertEqual(e["source"], "history")
        self.assertAlmostEqual(e["usd_per_min"], 0.4)
        self.assertEqual(e["samples"], 3)

    def test_history_uses_only_the_most_recent_n_jobs(self):
        rows = [fin("r", "cody", 100.0, "2026-01-%02dT00:00:00Z" % (i + 1)) for i in range(5)]
        rows += [fin("r", "cody", 1.0, "2026-02-%02dT00:00:00Z" % (i + 1)) for i in range(20)]
        e = core.estimate_burn("r", "cody", rows, core.make_cfg({"history_n": 20}), NOW_ISO)
        self.assertEqual(e["source"], "history")
        self.assertAlmostEqual(e["usd_per_min"], 1.0)
        self.assertEqual(e["samples"], 20)

    def test_two_same_repo_jobs_are_not_enough_for_history(self):
        rows = [fin("r", "cody", 0.2, "2026-10-01T00:00:00Z"), fin("r", "cody", 0.3, "2026-10-02T00:00:00Z"),
                fin("x", "cody", 1.0, "2026-10-03T00:00:00Z")]
        self.assertEqual(core.estimate_burn("r", "cody", rows, CFG, NOW_ISO)["source"], "fleet_p75")

    def test_three_same_repo_jobs_are_enough(self):
        rows = [fin("r", "cody", 0.2, "2026-10-0%dT00:00:00Z" % i) for i in (1, 2, 3)]
        self.assertEqual(core.estimate_burn("r", "cody", rows, CFG, NOW_ISO)["source"], "history")

    def test_the_actor_is_part_of_the_history_key(self):
        rows = [fin("r", "pipeline", 3.0, "2026-10-0%dT00:00:00Z" % i) for i in (1, 2, 3)]
        e = core.estimate_burn("r", "cody", rows, CFG, NOW_ISO)
        self.assertEqual(e["source"], "fleet_p75")
        e = core.estimate_burn("r", "pipeline", rows, CFG, NOW_ISO)
        self.assertEqual(e["source"], "history")

    def test_without_repo_history_the_fleet_75th_percentile_is_used(self):
        rows = [fin("x%d" % i, "cody", float(i), "2026-10-%02dT00:00:00Z" % i) for i in (1, 2, 3, 4)]
        e = core.estimate_burn("new", "cody", rows, CFG, NOW_ISO)
        self.assertEqual(e["source"], "fleet_p75")
        self.assertGreaterEqual(e["usd_per_min"], 3.0)
        self.assertLessEqual(e["usd_per_min"], 3.5)
        self.assertEqual(e["samples"], 4)

    def test_with_no_history_anywhere_the_configured_default_is_used(self):
        e = core.estimate_burn("new", "cody", [], core.make_cfg({"default_burn_usd_per_min": 0.77}), NOW_ISO)
        self.assertEqual(e["source"], "default")
        self.assertAlmostEqual(e["usd_per_min"], 0.77)
        self.assertEqual(e["samples"], 0)

    def test_the_estimate_records_when_it_was_computed(self):
        self.assertEqual(core.estimate_burn("r", "cody", [], CFG, NOW_ISO)["computed_at"], NOW_ISO)


class CumulativeSpendTests(unittest.TestCase):
    def test_delta_is_the_growth_of_jobs_already_seen(self):
        delta, seen = core.advance_cumulative({"a": 1.0, "b": 2.0}, {"a": 1.5, "b": 2.0})
        self.assertAlmostEqual(delta, 0.5)
        self.assertEqual(seen, {"a": 1.5, "b": 2.0})

    def test_a_job_seen_for_the_first_time_contributes_nothing(self):
        delta, seen = core.advance_cumulative({"a": 1.0}, {"a": 1.0, "new": 40.0})
        self.assertEqual(delta, 0)
        self.assertEqual(seen["new"], 40.0)
        delta, _ = core.advance_cumulative(seen, {"a": 1.0, "new": 41.0})
        self.assertAlmostEqual(delta, 1.0)

    def test_a_cost_that_goes_down_never_subtracts(self):
        delta, _ = core.advance_cumulative({"a": 5.0, "b": 1.0}, {"a": 0.0, "b": 2.0})
        self.assertAlmostEqual(delta, 1.0)

    def test_vanished_jobs_are_forgotten(self):
        delta, seen = core.advance_cumulative({"a": 1.0, "gone": 9.0}, {"a": 2.0})
        self.assertAlmostEqual(delta, 1.0)
        self.assertNotIn("gone", seen)

    def test_inputs_are_not_mutated(self):
        seen, costs = {"a": 1.0}, {"a": 2.0}
        core.advance_cumulative(seen, costs)
        self.assertEqual((seen, costs), ({"a": 1.0}, {"a": 2.0}))


class FleetRateTests(unittest.TestCase):
    def test_none_with_under_sixty_seconds_of_history(self):
        self.assertIsNone(core.fleet_rate([[T0, 0.0], [T0 + 59, 5.0]], T0 + 59, 600))

    def test_none_with_a_single_sample(self):
        self.assertIsNone(core.fleet_rate([[T0, 1.0]], T0, 600))
        self.assertIsNone(core.fleet_rate([], T0, 600))

    def test_usd_per_minute_slope_over_the_window(self):
        self.assertAlmostEqual(core.fleet_rate([[T0, 0.0], [T0 + 120, 3.0]], T0 + 120, 600), 1.5)

    def test_samples_older_than_the_window_are_ignored(self):
        samples = [[T0, 0.0], [T0 + 1000, 100.0], [T0 + 1120, 101.0]]
        self.assertAlmostEqual(core.fleet_rate(samples, T0 + 1120, 600), 0.5)

    def test_never_negative(self):
        self.assertEqual(core.fleet_rate([[T0, 5.0], [T0 + 120, 1.0]], T0 + 120, 600), 0.0)

    def test_the_tick_measures_the_fleet_rate_from_its_own_samples(self):
        prev = core.tick(make_inp(feed(), cum=0.0), {}, T0, CFG)
        self.assertIsNone(prev["budget"]["fleet_usd_per_min"])
        st = core.tick(make_inp(feed(), cum=6.0), prev, T0 + 120, CFG)
        self.assertAlmostEqual(st["budget"]["fleet_usd_per_min"], 3.0)


class AdmitListTests(unittest.TestCase):
    """L3: state["admit"] is the ordered, cumulative list enforcement may start."""

    def test_admit_is_the_ordered_admitted_ids(self):
        st = core.tick(make_inp(ready=[rjob("b", created="2026-01-02T00:00:00Z"),
                                       rjob("a", created="2026-01-01T00:00:00Z")], ceiling=4), {}, T0, CFG)
        self.assertEqual(st["admit"], ["a", "b"])

    def test_admit_never_exceeds_allowed_minus_running(self):
        ready = [rjob("r%d" % i, created="2026-01-01T00:00:0%dZ" % i) for i in range(5)]
        st = core.tick(make_inp(ready=ready, running=[runjob("x")], ceiling=3), {}, T0, CFG)
        self.assertEqual(len(st["admit"]), 2)

    def test_each_admitted_burn_counts_before_the_next_is_judged(self):
        # k = 0.2 %/USD; 150 minutes left at 40% used and a 15% reserve: sustainable 0.3 %/min.
        prev = calibrated(T0, k5=0.2, fleet=0.0, pct5=40.0)
        f = feed(u5=40.0, r5=T0 + 9000)
        ready = [rjob("a", usd=0.8, created="2026-01-01T00:00:01Z"),
                 rjob("b", usd=0.8, created="2026-01-01T00:00:02Z")]
        st = core.tick(make_inp(f, ready=ready), prev, T0, CFG)
        self.assertEqual(st["admit"], ["a"])
        self.assertEqual(held(st), {"b": "budget_pace"})

    def test_advisory_budget_holds_are_admitted_and_take_a_slot(self):
        ready = [rjob("a", created="2026-01-01T00:00:01Z"), rjob("b", created="2026-01-01T00:00:02Z"),
                 rjob("c", created="2026-01-01T00:00:03Z")]
        st = core.tick(make_inp(feed(u5=90), ready=ready, ceiling=2, gate="off_until_reset"), {}, T0, CFG)
        self.assertEqual(st["admit"], ["a", "b"])
        self.assertEqual(held(st)["c"], "concurrency_full")
        self.assertTrue(all(r["advisory"] for r in st["ready"][:2]))

    def test_a_held_job_is_not_in_the_admit_list(self):
        st = core.tick(make_inp(feed(u5=90), ready=[rjob("a")]), {}, T0, CFG)
        self.assertEqual(st["admit"], [])


if __name__ == "__main__":
    unittest.main()
