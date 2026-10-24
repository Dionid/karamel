#!/usr/bin/env python3
"""
slot_finder.py — deterministic core of the find-meeting-slot skill.

The agent does all the MCP work:
  1. resolve participants: calendar/Slack MCP -> email, tz, name
  2. pull busy time: freebusy per participant, ONE AT A TIME (one broken
     calendar must not fail the whole batch), busy comes back in UTC
  3. assemble payload.json and call this script

This script never touches the network. It only computes (so the LLM does
not do date/timezone arithmetic by hand):
  - expands "this_week" / "next_week" / an explicit range into concrete
    workdays (relative to now_utc, in base_tz — default from MEETING_TZ,
    else UTC)
  - for each day, builds the working window = base window ∩ each
    participant's local working window (their 10-18 / 9-19 in their own
    tz) — a slot must be within hours both in base_tz and locally for
    everyone
  - subtracts busy time and finds free slots >= duration
  - ranks: everyone free first, then the ideal window (10-18) over the
    extended one (9-19), then earlier is better
  - separately reports near-misses: slots where exactly one participant is
    busy (who could be moved, or the meeting held without them)

Input:  --input payload.json   (or stdin)
Output: a human-readable report (stdout) plus a machine JSON block between
        markers ===JSON=== ... ===END=== (the agent parses it to format a
        message)

payload.json:
{
  "now_utc": "2026-07-07T10:25:00Z",
  "base_tz": "Europe/Moscow",           # optional, default MEETING_TZ env or UTC
  "range": "next_week",                  # this_week | next_week | today |
                                         #   tomorrow | {"from":"2026-07-14","to":"2026-07-16"}
  "duration_min": 30,                    # optional, default 30
  "ideal_window":    [10, 18],           # optional
  "extended_window": [9, 19],            # optional
  "grid_min": 30,                        # optional, slot-start grid step, default 30
  "workdays_only": true,                 # optional, default true
  "max_results": 6,                      # optional
  "participants": [
    { "name":"Alice", "email":"alice@example.com",
      "tz":"Europe/Moscow",
      "busy":[["2026-07-14T07:00:00Z","2026-07-14T08:00:00Z"], ...] },
    { "name":"Bob", "email":"bob@example.com", "tz":"America/New_York",
      "busy":null }                      # null / absent = calendar unavailable
  ]
}
"""

import argparse
import datetime as dt
import json
import os
import sys
from zoneinfo import ZoneInfo


def load_env():
    """Load the workspace root .env into this process. MEETING_TZ usually
    only lives in .env — nothing else loads it into our environment for
    us before this script reads it."""
    here = os.path.dirname(os.path.abspath(__file__))
    d = here
    while True:
        if os.path.exists(os.path.join(d, "harness.json")) or \
           os.path.exists(os.path.join(d, "workspace.json")):
            env_path = os.path.join(d, ".env")
            if os.path.exists(env_path):
                with open(env_path) as f:
                    for line in f:
                        line = line.strip()
                        if not line or line.startswith("#") or "=" not in line:
                            continue
                        key, _, val = line.partition("=")
                        key = key.strip()
                        val = val.strip()
                        if len(val) >= 2 and val[0] == val[-1] and val[0] in "\"'":
                            val = val[1:-1]
                        os.environ.setdefault(key, val)
            return
        parent = os.path.dirname(d)
        if parent == d:
            return
        d = parent


load_env()

UTC = ZoneInfo("UTC")
WEEKDAY_RU = ["Пн", "Вт", "Ср", "Чт", "Пт", "Сб", "Вс"]
MONTH_RU = ["", "янв", "фев", "мар", "апр", "мая", "июн",
            "июл", "авг", "сен", "окт", "ноя", "дек"]


# ---------- time parsing ----------

def parse_utc(s):
    """ISO string (usually with Z) -> aware datetime in UTC."""
    s = s.strip()
    if s.endswith("Z"):
        s = s[:-1] + "+00:00"
    d = dt.datetime.fromisoformat(s)
    if d.tzinfo is None:
        d = d.replace(tzinfo=UTC)
    return d.astimezone(UTC)


def fmt_hhmm(d, tz):
    return d.astimezone(tz).strftime("%H:%M")


# ---------- date range expansion ----------

def resolve_days(now_utc, base_tz, rng, workdays_only):
    """Return a list of date objects (in base_tz) to search."""
    today = now_utc.astimezone(base_tz).date()

    if isinstance(rng, dict):
        start = dt.date.fromisoformat(rng["from"])
        end = dt.date.fromisoformat(rng["to"])
    elif rng in ("this_week", "next_week"):
        monday = today - dt.timedelta(days=today.weekday())
        if rng == "next_week":
            monday = monday + dt.timedelta(days=7)
        start, end = monday, monday + dt.timedelta(days=6)
    elif rng in ("today",):
        start = end = today
    elif rng in ("tomorrow",):
        start = end = today + dt.timedelta(days=1)
    else:
        raise ValueError(f"unknown range: {rng!r}")

    days = []
    d = start
    while d <= end:
        is_weekend = d.weekday() >= 5
        if d >= today and not (workdays_only and is_weekend):
            days.append(d)
        d += dt.timedelta(days=1)
    return days, today


# ---------- working window per day ----------

def window_for_day(day, base_tz, participants, win):
    """
    Intersection of working windows [win.lo, win.hi) for base_tz and each
    participant's local one -> (start_utc, end_utc), or None if empty.
    win = (lo_hour, hi_hour).
    """
    lo, hi = win

    def local_window(tz):
        s = dt.datetime.combine(day, dt.time(lo), tzinfo=tz).astimezone(UTC)
        e = dt.datetime.combine(day, dt.time(hi), tzinfo=tz).astimezone(UTC)
        return s, e

    start, end = local_window(base_tz)
    for p in participants:
        tz = p.get("_tz") or base_tz
        s, e = local_window(tz)
        start = max(start, s)
        end = min(end, e)
    if start >= end:
        return None
    return start, end


# ---------- busy time ----------

def is_free(person, s, e):
    """Is person free in [s,e)? None (unknown) if calendar unavailable."""
    busy = person.get("_busy")
    if busy is None:
        return None
    for (bs, be) in busy:
        if s < be and bs < e:   # interval overlap
            return False
    return True


# ---------- slot search ----------

def find_slots(day, win_kind, window, participants, duration, grid_min,
               base_tz, not_before=None):
    """All candidate slots in the window (grid aligned to half-hours of
    base_tz). not_before (UTC) cuts slots starting earlier (past + lead
    buffer)."""
    start, end = window
    dur = dt.timedelta(minutes=duration)
    grid = dt.timedelta(minutes=grid_min)

    start_local = start.astimezone(base_tz)
    minute = (start_local.minute // grid_min) * grid_min
    aligned = start_local.replace(minute=minute, second=0, microsecond=0)
    if aligned < start_local:
        aligned += grid
    cur = aligned.astimezone(UTC)

    slots = []
    while cur + dur <= end + dt.timedelta(seconds=1):
        s, e = cur, cur + dur
        if not_before is not None and s < not_before:
            cur += grid
            continue
        free, busy_names, unknown_names = [], [], []
        for p in participants:
            st = is_free(p, s, e)
            if st is True:
                free.append(p["name"])
            elif st is False:
                busy_names.append(p["name"])
            else:
                unknown_names.append(p["name"])
        known = [p for p in participants if p.get("_busy") is not None]
        slots.append({
            "day": day,
            "start_utc": s,
            "end_utc": e,
            "win_kind": win_kind,
            "free": free,
            "busy": busy_names,
            "unknown": unknown_names,
            "n_known": len(known),
            "n_busy": len(busy_names),
            "all_free": len(busy_names) == 0 and len(known) > 0,
        })
        cur += grid
    return slots


# ---------- assembly ----------

def build(payload):
    default_tz = payload.get("base_tz") or os.environ.get("MEETING_TZ") or "UTC"
    base_tz = ZoneInfo(default_tz)
    now_utc = parse_utc(payload["now_utc"])
    duration = int(payload.get("duration_min", 30))
    ideal = tuple(payload.get("ideal_window", [10, 18]))
    extended = tuple(payload.get("extended_window", [9, 19]))
    grid_min = int(payload.get("grid_min", 30))
    workdays_only = payload.get("workdays_only", True)
    max_results = int(payload.get("max_results", 6))
    lead_min = int(payload.get("lead_min", 60))
    not_before = now_utc + dt.timedelta(minutes=lead_min)

    participants = []
    for p in payload["participants"]:
        q = dict(p)
        q["_tz"] = ZoneInfo(p["tz"]) if p.get("tz") else base_tz
        busy = p.get("busy")
        q["_busy"] = None if busy is None else [
            (parse_utc(a), parse_utc(b)) for a, b in busy
        ]
        participants.append(q)

    days, today = resolve_days(now_utc, base_tz, payload["range"], workdays_only)

    ideal_slots, ext_only_slots = [], []
    for day in days:
        wi = window_for_day(day, base_tz, participants, ideal)
        if wi:
            ideal_slots += find_slots(day, "ideal", wi, participants,
                                      duration, grid_min, base_tz, not_before)
        we = window_for_day(day, base_tz, participants, extended)
        if we:
            ext = find_slots(day, "extended", we, participants,
                             duration, grid_min, base_tz, not_before)
            # only the part of extended that lies outside ideal
            for s in ext:
                if not wi or not (wi[0] <= s["start_utc"] and s["end_utc"] <= wi[1]):
                    ext_only_slots.append(s)

    return {
        "base_tz": base_tz, "today": today, "days": days,
        "duration": duration, "ideal": ideal, "extended": extended,
        "participants": participants,
        "ideal_slots": ideal_slots, "ext_only_slots": ext_only_slots,
        "max_results": max_results,
    }


def rank(slots):
    """all_free > fewer busy > earlier is better."""
    return sorted(slots, key=lambda s: (
        not s["all_free"], s["n_busy"], s["start_utc"]))


# ---------- output ----------

def slot_label(s, base_tz, part_tzs):
    day = s["day"]
    head = f"{WEEKDAY_RU[day.weekday()]} {day.day} {MONTH_RU[day.month]}"
    base = f"{fmt_hhmm(s['start_utc'], base_tz)}-{fmt_hhmm(s['end_utc'], base_tz)} {base_tz.key}"
    hints = []
    for name, tz in part_tzs:
        if tz.key != base_tz.key:
            hints.append(f"{name} {fmt_hhmm(s['start_utc'], tz)}")
    tail = f"  ({', '.join(hints)})" if hints else ""
    return head, base, tail


def render(res):
    base_tz = res["base_tz"]
    parts = res["participants"]
    part_tzs = [(p["name"], p["_tz"]) for p in parts]
    out = []

    out.append("MEETING SLOT SEARCH\n")
    rng_days = res["days"]
    if rng_days:
        d0, d1 = rng_days[0], rng_days[-1]
        out.append(f"Range: {d0.day} {MONTH_RU[d0.month]} - "
                   f"{d1.day} {MONTH_RU[d1.month]}  ·  "
                   f"duration {res['duration']} min  ·  "
                   f"window {res['ideal'][0]}-{res['ideal'][1]} {base_tz.key} "
                   f"(extended {res['extended'][0]}-{res['extended'][1]})")
    out.append("")

    out.append("Participants:")
    for p in parts:
        tz = p["_tz"]
        off = "" if tz.key == base_tz.key else f"  · {tz.key}"
        if p.get("_busy") is None:
            note = "  ⚠ calendar unavailable — NOT counted in the intersection"
        else:
            note = f"  · busy blocks: {len(p['_busy'])}"
        out.append(f"  • {p['name']} <{p.get('email','?')}>{off}{note}")
    out.append("")

    ideal_ranked = rank([s for s in res["ideal_slots"] if s["all_free"]])
    ext_ranked = rank([s for s in res["ext_only_slots"] if s["all_free"]])
    n = res["max_results"]

    def emit(title, slots):
        out.append(title)
        if not slots:
            out.append("  — none")
            return
        for s in slots[:n]:
            head, base, tail = slot_label(s, base_tz, part_tzs)
            out.append(f"  OK {head}  {base}{tail}")

    emit(f"Everyone free — ideal window ({res['ideal'][0]}-{res['ideal'][1]} {base_tz.key}):", ideal_ranked)
    out.append("")
    if len(ideal_ranked) < 3:
        emit(f"Everyone free — extended window ({res['extended'][0]}-{res['extended'][1]} {base_tz.key}):", ext_ranked)
        out.append("")

    if len(ideal_ranked) < 3:
        near = rank([s for s in res["ideal_slots"]
                     if not s["all_free"] and s["n_busy"] == 1])
        seen, near_u = set(), []
        for s in near:
            key = (s["day"], tuple(s["busy"]))
            if key in seen:
                continue
            seen.add(key)
            near_u.append(s)
        if near_u:
            out.append("Near miss (exactly one busy — could move them or skip):")
            for s in near_u[:n]:
                head, base, tail = slot_label(s, base_tz, part_tzs)
                out.append(f"  ~ {head}  {base}  — busy: {', '.join(s['busy'])}{tail}")
            out.append("")

    if not ideal_ranked and not ext_ranked:
        out.append("No full intersection of free windows. "
                   "See near-misses above, or narrow participants / widen dates.")
        out.append("")

    def slot_json(s):
        return {
            "date": s["day"].isoformat(),
            "weekday": WEEKDAY_RU[s["day"].weekday()],
            "start_base": fmt_hhmm(s["start_utc"], base_tz),
            "end_base": fmt_hhmm(s["end_utc"], base_tz),
            "start_utc": s["start_utc"].isoformat(),
            "win": s["win_kind"], "free": s["free"], "busy": s["busy"],
            "unknown": s["unknown"], "all_free": s["all_free"],
        }
    machine = {
        "base_tz": base_tz.key,
        "ideal_all_free": [slot_json(s) for s in ideal_ranked[:n]],
        "extended_all_free": [slot_json(s) for s in ext_ranked[:n]],
        "participants": [
            {"name": p["name"], "email": p.get("email"),
             "tz": p["_tz"].key,
             "calendar_available": p.get("_busy") is not None}
            for p in parts
        ],
    }
    out.append("===JSON===")
    out.append(json.dumps(machine, ensure_ascii=False))
    out.append("===END===")
    return "\n".join(out)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="payload.json (otherwise stdin)")
    args = ap.parse_args()
    raw = open(args.input, encoding="utf-8").read() if args.input else sys.stdin.read()
    payload = json.loads(raw)
    res = build(payload)
    print(render(res))


if __name__ == "__main__":
    main()
