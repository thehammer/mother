"""limiter_core — Mother's backpressure control law (observe-only slice, L1).

PURE: no file, clock, process or network I/O. `now` is always a parameter and
every input is a plain dict/list, so a future coordinator can host this module
unchanged. The I/O shell is bin/mother-limiter. Stdlib `math`/`re` only; a unit
test scans the imports to keep it that way.

Units: used_pct is 0..100, k is "% of window per USD of Mother spend", burn is
USD/min, rates of window use are %/min (budget) or %/hour (interactive).
"""

import math
import re

WINDOW_S = {"5h": 5 * 3600, "7d": 7 * 86400}
WINDOW_KEY = {"5h": "five_hour", "7d": "seven_day"}
BUDGET_CODES = ("budget_pace", "reserve", "interactive_personal")
K_SAMPLE_CAP = 200
K_USD_FLOOR = 0.05          # a calibration sample needs at least this much Mother spend
PINNED_PCT = 99             # at/above this a window can't tell us how much was used
MAX_PAUSE_S = 3600

DEFAULTS = {
    "ceiling": 2,
    "reserve_pct": 15,
    "burn_window_s": 600,
    "default_burn_usd_per_min": 0.5,
    "history_n": 20,
    "history_min": 3,
    "calm_s": 900,
    "coalesce_s": 120,
    "ramp_start": 2,
    "ramp_step_s": 300,
    "interactive_pct_h": 10,
    "interactive_sustain_s": 600,
    "k_min_samples": 12,
    "k_interval_s": {"5h": 600, "7d": 3600},
}


def make_cfg(overrides=None):
    cfg = dict(DEFAULTS)
    cfg["k_interval_s"] = dict(DEFAULTS["k_interval_s"])
    cfg.update(overrides or {})
    return cfg


# ---------- distress classification (bet B4) ----------

_OVERLOAD = (429, 503, 529)
_RETRY_AFTER_RE = re.compile(r"retry[- ]after[:= ]+(\d+)", re.I)


def _status_int(v):
    if isinstance(v, bool):
        return None
    try:
        return int(v)
    except (TypeError, ValueError):
        return None


def classify_log_event(ev):
    """One stream-json event -> None (not distress) or
    {kind, status, retry_after_s}. Overage-only rejections and a null
    error_status (no-response timeout) are NOT distress."""
    if not isinstance(ev, dict):
        return None
    t = ev.get("type")
    if t == "rate_limit_event":
        info = ev.get("rate_limit_info")
        if not isinstance(info, dict) or info.get("status") != "rejected":
            return None
        if info.get("isUsingOverage") or info.get("overageInUse"):
            return None
        return {"kind": "rate_limit_rejected", "status": info.get("rateLimitType") or "rejected",
                "retry_after_s": None}
    if t == "system" and ev.get("subtype") == "api_retry":
        code = _status_int(ev.get("error_status"))
        if code in _OVERLOAD:
            ms = ev.get("retry_delay_ms")
            ra = int(ms // 1000) if isinstance(ms, (int, float)) and not isinstance(ms, bool) and ms >= 1000 else None
            return {"kind": "api_retry", "status": code, "retry_after_s": ra}
        return None
    if t == "result":
        code = _status_int(ev.get("api_error_status"))
        if code in _OVERLOAD:
            ra = None
            for key in ("retry_after_s", "retry_after", "retry-after"):
                n = _status_int(ev.get(key))
                if n and n > 0:
                    ra = n
                    break
            if ra is None:
                m = _RETRY_AFTER_RE.search(str(ev.get("result") or ""))
                if m and int(m.group(1)) > 0:
                    ra = int(m.group(1))
            return {"kind": "result_error", "status": code, "retry_after_s": ra}
    return None


def classify_mother_event(ev):
    """One events/<id>.jsonl line ({ts, kind, detail}) -> distress dict or None."""
    if not isinstance(ev, dict) or ev.get("kind") != "failure_routed":
        return None
    d = ev.get("detail") or {}
    reason = d.get("reason") if isinstance(d, dict) else None
    if reason in ("rate_limited", "api_overloaded"):
        ra = _status_int(d.get("retry_after_s")) if isinstance(d, dict) else None
        return {"kind": "failure_routed", "status": reason, "retry_after_s": ra if ra and ra > 0 else None}
    return None


# ---------- burn estimation (MC-38) and fleet burn ----------

def _percentile(values, pct):
    s = sorted(values)
    if not s:
        return None
    k = min(len(s), max(1, int(round(pct / 100.0 * len(s)))))
    return s[k - 1]


def _median(values):
    s = sorted(values)
    n = len(s)
    if not n:
        return None
    return s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2.0


def estimate_burn(repo, actor, finished, cfg, now_iso):
    """finished: [{repo, actor, usd_per_min, finished_at}] of finished jobs.
    Median of the last history_n same-repo+actor jobs when >= history_min; else the
    fleet 75th percentile; else the configured default."""
    basis = "%s+%s" % (repo, actor)
    same = sorted((r for r in finished if r.get("repo") == repo and r.get("actor") == actor),
                  key=lambda r: r.get("finished_at") or "")[-int(cfg["history_n"]):]
    if len(same) >= int(cfg["history_min"]):
        return {"usd_per_min": _median([r["usd_per_min"] for r in same]), "source": "history",
                "basis": basis, "samples": len(same), "computed_at": now_iso}
    if finished:
        return {"usd_per_min": _percentile([r["usd_per_min"] for r in finished], 75),
                "source": "fleet_p75", "basis": basis, "samples": len(finished), "computed_at": now_iso}
    return {"usd_per_min": float(cfg["default_burn_usd_per_min"]), "source": "default",
            "basis": basis, "samples": 0, "computed_at": now_iso}


def advance_cumulative(seen, costs):
    """seen: {job_id: last cost}, costs: {job_id: cost now}. Returns (delta_usd, new_seen).
    A job seen for the first time contributes nothing (its history is not new spend)."""
    delta = 0.0
    for jid, c in costs.items():
        if jid in seen:
            delta += max(0.0, c - seen[jid])
    return delta, dict(costs)


def fleet_rate(samples, now, window_s):
    """samples: [[ts, cum_usd], ...]. USD/min slope over the window, None under 60s of history."""
    pts = [s for s in samples if now - s[0] <= window_s]
    if len(pts) < 2:
        return None
    t0, c0 = pts[0][0], pts[0][1]
    t1, c1 = pts[-1][0], pts[-1][1]
    if t1 - t0 < 60:
        return None
    return max(0.0, (c1 - c0) / ((t1 - t0) / 60.0))


# ---------- reset detection, k calibration ----------

def detect_reset(prev_win, cur_win, window_s):
    """True when resets_at moved forward by more than half the window, or used_pct fell >= 20 points."""
    if not prev_win or not cur_win:
        return False
    p_at, c_at = prev_win.get("resets_at") or 0, cur_win.get("resets_at") or 0
    if p_at and c_at and c_at - p_at > window_s / 2.0:
        return True
    return (prev_win.get("used_pct") or 0) - (cur_win.get("used_pct") or 0) >= 20


def calibrate_k(calib, point, now, interval_s, min_samples):
    """calib: {last: {ts, used_pct, resets_at, usd}|None, ratios: [..]}; point: {used_pct,
    resets_at, usd}. Takes a sample once >= interval_s has passed since `last`, discarding
    it when a reset fell in between, when used_pct >= PINNED_PCT at either end, or when
    Mother spent under the floor. k = 25th percentile of the kept ratios once there are
    min_samples of them. Returns (new_calib, k|None)."""
    calib = {"last": (calib or {}).get("last"), "ratios": list((calib or {}).get("ratios") or [])}
    last = calib["last"]
    if last is None:
        calib["last"] = dict(point, ts=now)
    elif now - last["ts"] >= interval_s:
        d_usd = point["usd"] - last["usd"]
        d_pct = point["used_pct"] - last["used_pct"]
        reset = point["used_pct"] < last["used_pct"] or bool(
            last.get("resets_at") and point.get("resets_at") and point["resets_at"] != last["resets_at"])
        pinned = last["used_pct"] >= PINNED_PCT or point["used_pct"] >= PINNED_PCT
        if not reset and not pinned and d_usd >= K_USD_FLOOR and d_pct >= 0:
            calib["ratios"].append(d_pct / d_usd)
            calib["ratios"] = calib["ratios"][-K_SAMPLE_CAP:]
        calib["last"] = dict(point, ts=now)
    return calib, k_from_ratios(calib["ratios"], min_samples)


def k_from_ratios(ratios, min_samples):
    """25th percentile of the ratios once there are min_samples; None before, or when not positive."""
    k = _percentile(ratios, 25) if len(ratios) >= max(1, min_samples) else None
    return k if k and k > 0 else None


# ---------- interactive demand (MC-34) ----------

def interactive_demand(samples, k5, stale, now, window_s):
    """samples: [[ts, cum_usd, used_pct_5h], ...]. %/hour of the 5h window not explained by
    Mother's own spend, or None (unknown) when the feed is stale, the window is pinned at
    >= 99%, k is uncalibrated, the history is under 60s, or the window dropped (a reset)."""
    if stale or not k5 or not samples:
        return None
    pts = [s for s in samples if now - s[0] <= window_s]
    if len(pts) < 2 or pts[-1][0] - pts[0][0] < 60:
        return None
    if pts[-1][2] >= PINNED_PCT or pts[0][2] >= PINNED_PCT:
        return None
    if any(b[2] < a[2] for a, b in zip(pts, pts[1:])):
        return None
    hours = (pts[-1][0] - pts[0][0]) / 3600.0
    return (pts[-1][2] - pts[0][2]) / hours - k5 * (pts[-1][1] - pts[0][1]) / hours


def interactive_state(prev, rate, now, threshold, sustain_s):
    """prev: {high_since}. -> {pct_per_hour, state: ok|high|unknown, high_since}."""
    if rate is None:
        return {"pct_per_hour": None, "state": "unknown", "high_since": None}
    if rate <= threshold:
        return {"pct_per_hour": rate, "state": "ok", "high_since": None}
    since = (prev or {}).get("high_since")
    if since is None:
        since = now
    return {"pct_per_hour": rate, "state": "high" if now - since >= sustain_s else "ok",
            "high_since": since}


# ---------- distress, backoff and ramp (MC-35, MC-36) ----------

def backoff_step(bo, events, allowed_now, ceiling, now, cfg):
    """bo: {level|None, last_cut_at, last_distress_at, last_raise_at}. Distress events within
    coalesce_s of the last cut count as that cut. A cut sets level = max(1, allowed_now // 2).
    After calm_s with no distress the level rises by ONE per calm_s up to the ceiling."""
    bo = dict(bo or {})
    bo.setdefault("level", None)
    for key in ("last_cut_at", "last_distress_at", "last_raise_at"):
        bo.setdefault(key, None)
    cut = False
    if events:
        bo["last_distress_at"] = now
        lc = bo["last_cut_at"]
        if lc is None or now - lc >= cfg["coalesce_s"]:
            bo["level"] = max(1, int(allowed_now) // 2)
            bo["last_cut_at"] = now
            bo["last_raise_at"] = now
            cut = True
    elif bo["level"] is not None:
        if bo["level"] >= ceiling:
            bo["level"] = None
        else:
            base = max(bo["last_distress_at"] or 0, bo["last_raise_at"] or 0)
            if now - base >= cfg["calm_s"]:
                bo["level"] += 1
                bo["last_raise_at"] = now
                if bo["level"] >= ceiling:
                    bo["level"] = None
    return bo, cut


def backoff_level(bo, ceiling):
    lv = (bo or {}).get("level")
    return ceiling if lv is None else min(ceiling, lv)


def ramp_step(rp, reset, ceiling, now, cfg):
    """rp: {active, level, last_step_at}. A detected reset restarts the ramp at ramp_start;
    +1 per ramp_step_s (never two in one tick) until the ceiling."""
    rp = dict(rp or {})
    rp.setdefault("active", False)
    rp.setdefault("level", ceiling)
    rp.setdefault("last_step_at", None)
    if reset:
        rp.update(active=True, level=min(int(cfg["ramp_start"]), ceiling), last_step_at=now)
    elif rp["active"] and now - (rp["last_step_at"] or now) >= cfg["ramp_step_s"]:
        rp["level"] += 1
        rp["last_step_at"] = now
    if rp["active"] and rp["level"] >= ceiling:
        rp.update(active=False, level=ceiling)
    return rp


# ---------- priority ----------

def effective_rank(job):
    base = 0 if job.get("data_class") == "company" else 1
    adj = job.get("priority_adjust") or 0
    adj = adj if adj in (-1, 0, 1) else 0
    return max(0, min(1, base - adj))


def priority_key(job):
    return (effective_rank(job), job.get("created_at") or "", job.get("id") or "")


# ---------- budget terms (MC-32, MC-33) ----------

def window_budget(name, win, k, reserve_pct, fleet_usd_per_min, candidate_usd_per_min, now):
    """Sustainable vs projected use of one window (%/min). pace None when it can't be computed."""
    out = {"used_pct": win.get("used_pct"), "resets_at": win.get("resets_at"), "k": k,
           "sustainable_pct_per_min": None, "projected_pct_per_min": None, "pace": None}
    at = win.get("resets_at") or 0
    if at <= now:
        return out
    minutes = max((at - now) / 60.0, 1.0)
    avail = 100.0 - (win.get("used_pct") or 0) - (reserve_pct if name == "5h" else 0)
    out["sustainable_pct_per_min"] = max(avail, 0.0) / minutes
    if k is not None and fleet_usd_per_min is not None:
        out["projected_pct_per_min"] = k * (fleet_usd_per_min + candidate_usd_per_min)
        sus, proj = out["sustainable_pct_per_min"], out["projected_pct_per_min"]
        out["pace"] = (proj / sus) if sus > 0 else (math.inf if proj > 0 else 0.0)
    return out


def pace_decision(budgets):
    """The tighter window decides. -> (code, reason) when pace >= 1.0, else None."""
    worst, wname = None, None
    for name, b in budgets.items():
        if b["pace"] is not None and (worst is None or b["pace"] > worst):
            worst, wname = b["pace"], name
    if worst is None or round(worst, 6) < 1.0:
        return None
    if math.isinf(worst):
        return "budget_pace", "throttled: %s window exhausted" % wname
    return "budget_pace", "throttled: %s window pace %.1f×" % (wname, worst)


# ---------- the tick ----------

def _slot_code(allowed, ceiling, bo_level, ramp):
    if ramp["active"] and ramp["level"] <= min(ceiling, bo_level):
        return "ramp", "ramp-up after window reset (%d allowed)" % allowed
    if bo_level < ceiling:
        return "backoff", "backed off after rate-limit distress (%d allowed)" % allowed
    return "concurrency_full", "concurrency full (%d of %d)" % (allowed, ceiling)


def tick(inp, prev, now, cfg):
    """One control-law evaluation. Returns the new state dict (state.json minus I/O offsets,
    which the shell adds). `prev` is the previous return value (or {}/None)."""
    prev = prev or {}
    cfg = dict(cfg)
    ceiling = max(1, int(inp["ceiling"]))
    feed = inp["feed"]
    gate = inp.get("gate") or "on"
    stale = bool(feed.get("stale"))
    reserve = float(cfg["reserve_pct"])
    wins = {"5h": feed["five_hour"], "7d": feed["seven_day"]}
    cum = float(inp.get("mother_cum_usd") or 0.0)

    # reset detection
    pw = prev.get("windows") or {}
    reset = any(detect_reset(pw.get(n), wins[n], WINDOW_S[n]) for n in wins) and not stale
    reset_at = now if reset else prev.get("last_reset_at")

    # k calibration, one per window (skipped while the feed is stale)
    calib, ks = {}, {}
    for n in wins:
        c = (prev.get("calib") or {}).get(n)
        if stale:
            calib[n] = c or {"last": None, "ratios": []}
            ks[n] = k_from_ratios(calib[n]["ratios"], cfg["k_min_samples"])
            continue
        pt = {"used_pct": wins[n]["used_pct"], "resets_at": wins[n].get("resets_at") or 0, "usd": cum}
        calib[n], ks[n] = calibrate_k(c, pt, now, cfg["k_interval_s"][n], cfg["k_min_samples"])

    # burn samples: [ts, cum_usd, used_pct_5h]
    window_s = float(cfg["burn_window_s"])
    samples = [s for s in (prev.get("samples") or []) if now - s[0] <= window_s + 60]
    samples.append([now, cum, wins["5h"]["used_pct"]])
    fleet = fleet_rate([[s[0], s[1]] for s in samples], now, window_s)

    # interactive demand
    ir = interactive_demand(samples, ks["5h"], stale, now, window_s)
    inter = interactive_state(prev.get("interactive"), ir, now, cfg["interactive_pct_h"],
                              cfg["interactive_sustain_s"])

    # distress, backoff, ramp
    events = list(inp.get("distress") or [])
    prev_allowed = prev.get("allowed")
    pbo = prev.get("backoff")
    running = list(inp.get("running") or [])
    ramp_prev = prev.get("ramp") or {}
    allowed_before = min(ceiling, backoff_level(pbo, ceiling),
                         ramp_prev.get("level", ceiling) if ramp_prev.get("active") else ceiling)
    bo, cut = backoff_step(pbo, events, allowed_before, ceiling, now, cfg)
    rp = ramp_step(ramp_prev, reset, ceiling, now, cfg)
    bo_lv = backoff_level(bo, ceiling)
    allowed = min(ceiling, bo_lv, rp["level"] if rp["active"] else ceiling)
    paused_until = prev.get("admissions_paused_until") or 0
    for e in events:
        ra = e.get("retry_after_s")
        if ra:
            paused_until = max(paused_until, now + min(int(ra), MAX_PAUSE_S))
    if paused_until <= now:
        paused_until = 0
    last_d = prev.get("last_distress")
    if events:
        e = events[-1]
        last_d = {"at": now, "job_id": e.get("job_id"), "kind": e.get("kind"), "status": e.get("status")}
    d24 = [t for t in (prev.get("distress_log") or []) if now - t < 86400] + [now] * len(events)

    # budget advisory (bet B3)
    advisory = gate in ("off", "off_until_reset") or stale
    reserve_held = (not stale) and (100.0 - wins["5h"]["used_pct"]) <= reserve
    ibudget = {n: window_budget(n, wins[n], ks[n], reserve, fleet, 0.0, now) for n in wins}

    # running jobs: would_hold / would_preempt
    # lowest class first, then newest first
    run_sorted = sorted(running, key=lambda j: (effective_rank(j), j.get("started_at") or j.get("created_at") or "",
                                                  j.get("id") or ""), reverse=True)
    excess = max(0, len(running) - min(ceiling, bo_lv)) if bo_lv < ceiling else 0
    hold_ids = {j["id"] for j in run_sorted[:excess]}
    breach = False
    if ks["5h"] is not None and fleet is not None and (wins["5h"].get("resets_at") or 0) > now:
        mins = (wins["5h"]["resets_at"] - now) / 60.0
        proj = wins["5h"]["used_pct"] + (ks["5h"] * fleet + max(inter["pct_per_hour"] or 0, 0) / 60.0) * mins
        breach = proj > 100.0 - reserve
    preempt_on = inter["state"] == "high" and breach
    running_out = []
    for j in run_sorted:
        pre = preempt_on and j.get("data_class") != "company" and effective_rank(j) == 1
        running_out.append({"id": j["id"], "class": "company" if effective_rank(j) == 0 else "personal",
                            "would_hold": j["id"] in hold_ids, "would_preempt": bool(pre),
                            "advisory": bool(pre and advisory)})

    # ready jobs in priority order
    taken = 0
    admitted_burn = 0.0
    admit_ids = []
    ready_out = []
    n_running = len(running)
    for j in sorted(inp.get("ready") or [], key=priority_key):
        cls = "company" if effective_rank(j) == 0 else "personal"
        burn = float(j.get("usd_per_min") if j.get("usd_per_min") is not None else cfg["default_burn_usd_per_min"])
        forced = bool(j.get("force_start"))
        row = {"id": j["id"], "class": cls, "decision": "admit", "code": None, "reason": "", "advisory": False}
        code = reason = None
        if paused_until and now < paused_until:
            code, reason = "retry_after", "provider asked for a pause for %ds" % (paused_until - now)
        elif n_running + taken >= allowed:
            code, reason = _slot_code(allowed, ceiling, bo_lv, rp)
        elif not forced:
            if reserve_held:
                code, reason = "reserve", "reserve held for interactive work"
            elif inter["state"] == "high" and cls == "personal":
                code, reason = "interactive_personal", "interactive demand is high: personal work waits"
            else:
                pd = None
                if fleet is not None:
                    pd = pace_decision({n: window_budget(n, wins[n], ks[n], reserve, fleet + admitted_burn, burn, now)
                                        for n in wins})
                if pd:
                    code, reason = pd
        if code is None:
            row["code"], row["reason"] = "admit", "admitted"
            taken += 1
            admitted_burn += burn
            admit_ids.append(j["id"])
        else:
            row.update(decision="hold", code=code, reason=reason)
            if code in BUDGET_CODES and advisory:
                # Advisory budget terms never hold work (bet B3): enforcement admits it, so it
                # takes a slot and adds its burn like any admitted candidate (cumulative list).
                row["advisory"] = True
                taken += 1
                admitted_burn += burn
                admit_ids.append(j["id"])
        ready_out.append(row)

    st = {
        "v": 1, "ts": now, "ceiling": ceiling, "allowed": allowed,
        "admissions_paused_until": paused_until,
        "components": {
            "backoff_level": bo_lv, "ramp_level": rp["level"] if rp["active"] else ceiling,
            "ramp_active": rp["active"], "last_cut_at": bo.get("last_cut_at"),
            "last_distress": last_d, "distress_24h": len(d24), "cut": cut,
        },
        "budget": {
            "gate": gate, "stale": stale, "advisory": advisory,
            "overage_in_use": bool(inp.get("overage_in_use")), "reserve_pct": reserve,
            "fleet_usd_per_min": fleet,
            "five_hour": dict(ibudget["5h"], k_samples=len(calib["5h"]["ratios"]), calibrated=ks["5h"] is not None),
            "seven_day": dict(ibudget["7d"], k_samples=len(calib["7d"]["ratios"]), calibrated=ks["7d"] is not None),
        },
        "interactive": inter,
        "ready": ready_out, "running": running_out,
        # ordered ids enforcement may start: cumulative, never more than allowed - running
        "admit": admit_ids,
        # carried between ticks
        "backoff": bo, "ramp": rp, "windows": {n: {"used_pct": wins[n]["used_pct"], "resets_at": wins[n].get("resets_at") or 0}
                                               for n in wins},
        "last_reset_at": reset_at, "calib": calib, "samples": samples, "distress_log": d24,
    }
    return st


def would_summary(st):
    """The `would` block of a decisions.jsonl line, from a tick result."""
    ready = st["ready"]
    return {
        "admit": [r["id"] for r in ready if r["decision"] == "admit"],
        "hold": [{"id": r["id"], "code": r["code"]} for r in ready if r["decision"] == "hold" and not r["advisory"]],
        "advisory": [{"id": r["id"], "code": r["code"]} for r in ready if r["advisory"]],
        "hold_running": [r["id"] for r in st["running"] if r["would_hold"]],
        "preempt": [r["id"] for r in st["running"] if r["would_preempt"] and not r["advisory"]],
    }
