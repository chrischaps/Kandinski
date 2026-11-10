"""The GRAND TOUR, driven by the autopilot: does every event complete, how long
does it take, what does it earn. Also the calibration of clocks and targets.

    python tools/tour_check.py                 # all 15 events at skill 0.80 and 1.00, by the rules
    python tools/tour_check.py 3 7             # just these (0-14)
    python tools/tour_check.py --calibrate     # measure, write scripts/lib/tour_cal.rhai, then check
    python tools/tour_check.py --jobs 4        # players side by side (default 6)

Each run is a scratch scene (tools/build_scene.py's `build`, `start_event=n`,
`autopilot=True`) played at --frame-step 1/60 until drive.rhai logs its `EVR`
line (the results screen). Runs keep no save (`persist=false`).

What is measured, and the calibration rules (--calibrate):

  clean   the autopilot as it is (ap_style 0): it neither drifts nor boosts.
  drift   ap_style 1: a handbrake entry on every real bend (DRIFT events).
  shave   ap_style 2: passes traffic 2.7 m off instead of a lane away (RUSH).
  boost   ap_style 3: burns whatever boost it happens to earn, on the straights (RACE).

  SPRINT     clock = the clean 0.80 run's split to each gate x 1.06 (+3 s at
             the start). Bronze: reach the goal. Silver: the time a run
             halfway between the 0.80 and 1.00 runs has left. Gold: what a
             run 1.5% quicker than the clean 1.00 run has left.
  RUSH       clock = the clean 0.80 splits x 1.15. Targets from the shave
             runs' close passes N (the lower of 0.80 and 1.00 for bronze):
             bronze 0.6 N, silver 0.9 N, gold 1.25 N.
  DRIFT      the clock is the event's length. Targets from the drift runs'
             banked points D (the better of 0.80 and 1.00): 0.4 D, 0.8 D,
             1.3 D. The stand-in spins more on the harder roads than a player
             need, so D is never taken below 60 points a second of clock
             (it banks about 80 a second on the first DRIFT event).
  ENDURANCE  clock as SPRINT. Score S = the run's score + 10,000 a second
             left. Bronze 0.97 S(0.80), silver the mean of S(0.80) and
             S(1.00), gold 1.03 S(1.00).
  RACE       no numbers to fit: 3rd / 2nd / 1st. Rival skills are set by
             hand in tour.rhai; this prints each rival's time so they can be.

Results: snapshots/tour/tour_check.json (the table), logs in snapshots/tour/logs/.
"""
import json
import math
import os
import subprocess
import sys
import threading
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import build_scene  # noqa: E402

PLAYER = os.path.join(ROOT, "engine", "target", "release", "flint-player.exe")
OUT = os.path.join(ROOT, "snapshots", "tour")
LOGS = os.path.join(OUT, "logs")
CAL = os.path.join(ROOT, "scripts", "lib", "tour_cal.rhai")
N_EVENTS = 15
DRIFT_FLOOR = 60.0           # points a second: the least a DRIFT event's reference run is taken to be worth
STYLE = {"clean": 0, "drift": 1, "shave": 2, "boost": 3}
MEDAL = ["-", "bronze", "silver", "GOLD"]
_print = threading.Lock()


def kv(line, tag):
    out = {}
    for part in line.split(f" {tag} ")[1].split():
        if "=" in part:
            k, v = part.split("=", 1)
            out[k] = v
    return out


def floats(s):
    return [float(x) for x in s.split(",") if x != ""]


def run(n, skill, style="clean", no_clock=False, limit=1500, ghost=False, **kw):
    """Play event n to its results screen. Returns a dict (or raises)."""
    tag = f"e{n:02d}_{style}_{int(round(skill * 100))}{'_free' if no_clock else ''}{'_ghost' if ghost else ''}{'_x' if kw else ''}"
    os.makedirs(LOGS, exist_ok=True)
    scene = os.path.join(ROOT, "scenes", f"_tc_{tag}.scene.toml")
    with open(scene, "w", newline="\n", encoding="utf-8") as f:
        f.write(build_scene.build(autopilot=True, start_event=n, ap_skill=skill, ap_style=STYLE[style],
                                  no_clock=no_clock, persist=False, ghost_rivals=ghost, **kw))
    cmd = [PLAYER, scene, "--schemas", "engine/schemas", "--schemas", "schemas", "--no-activate",
           "--width", "320", "--height", "180", "--frame-step", "0.0166667", "--exit-after", str(limit),
           "--music-volume", "0", "--sfx-volume", "0"]
    env = dict(os.environ, RUST_LOG="warn,script=info", FLINT_VSYNC="0", FLINT_PACING="0")
    info, res, warns = None, None, []
    log_path = os.path.join(LOGS, tag + ".log")
    p = subprocess.Popen(cmd, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                         text=True, encoding="utf-8", errors="replace")
    with open(log_path, "w", encoding="utf-8") as log:
        for line in p.stdout:
            if " TM " in line or "Loaded" in line:
                continue
            log.write(line)
            if " EVI " in line:
                info = kv(line, "EVI")
            elif " EVR " in line:
                res = kv(line, "EVR")
                break
            elif ("script" in line.lower() and ("WARN" in line or "ERROR" in line)) or "ERROR" in line:
                warns.append(line.strip()[-200:])
    p.kill()
    p.wait()
    try:
        os.remove(scene)
    except OSError:
        pass
    if res is None or info is None:
        raise RuntimeError(f"event {n} ({tag}): no result within {limit} s; see {log_path}\n" + "\n".join(warns[:5]))
    r = dict(n=n, skill=skill, style=style, id=info["id"], name=info["name"].replace("_", " "), type=info["type"],
             km=float(info["km"]), themes=[t.replace("_", " ") for t in info["themes"].split(",") if t],
             cars=int(info["cars"]), rivals=floats(info["rivals"]), targets=floats(info["targets"]),
             time0=float(info["time0"]), ext=floats(info["ext"]), max_crashes=int(info["max_crashes"]),
             why=res["why"], t=float(res["t"]), value=float(res["value"]), medal=int(res["medal"]),
             ok=res["ok"] == "true", left=float(res["left"]), score=float(res["score"]), base=float(res["base"]),
             crashes=int(res["crashes"]), near=int(res["near"]), drift=float(res["drift"]), drifts=int(res["drifts"]),
             air=float(res["air"]), draft=float(res["draft"]), top=float(res["top"]) * 3.6,
             splits=floats(res["splits"]), rival_t=floats(res["rivals"]), warnings=warns)
    with _print:
        print(f"  {r['id']} {r['type']:9s} {style:5s} {skill:.2f}{' free' if no_clock else '     '}"
              f"  t={r['t']:6.1f}  why={r['why']:5s} value={r['value']:9.1f}  medal={MEDAL[r['medal']]:6s}"
              f"  crashes={r['crashes']} near={r['near']} drift={r['drift']:.0f}"
              + (f"  !! {len(warns)} script warnings" if warns else ""), flush=True)
    return r


def run_many(jobs, specs):
    with ThreadPoolExecutor(max_workers=jobs) as ex:
        return list(ex.map(lambda s: run(*s), specs))


# ── calibration ─────────────────────────────────────────────────
def calibrate(events, jobs):
    print("calibrating: clean runs with the clock stopped, and the style runs")
    specs = []
    for n in events:
        specs += [(n, 0.80, "clean", True), (n, 1.00, "clean", True)]
    res = run_many(jobs, specs)
    by = {(r["n"], r["skill"]): r for r in res}
    extra = []
    for n in events:
        ty = by[(n, 0.80)]["type"]
        if ty == "drift":
            extra += [(n, 0.80, "drift", False), (n, 1.00, "drift", False)]     # the clock is the event: let it run
        elif ty == "rush":
            extra += [(n, 0.80, "shave", True), (n, 1.00, "shave", True)]
    st = {(r["n"], r["skill"]): r for r in run_many(jobs, extra)}

    cal = load_cal()
    for n in events:
        a, b = by[(n, 0.80)], by[(n, 1.00)]
        ty, c = a["type"], {}
        if ty in ("sprint", "endurance", "rush"):
            if a["why"] != "goal" or b["why"] != "goal":
                raise RuntimeError(f"{a['id']}: the autopilot did not reach the goal")
            m = 1.15 if ty == "rush" else 1.06
            s = a["splits"]
            c["time0"] = float(math.ceil(m * s[0] + 3.0))
            c["ext"] = [float(round(m * (s[k + 1] - s[k]))) for k in range(len(s) - 1)]
            total = c["time0"] + sum(c["ext"])
            t80, t100 = a["t"], b["t"]
            if ty == "sprint":
                c["targets"] = [0.0, float(math.floor(total - 0.5 * (t80 + t100))), float(math.floor(total - 0.985 * t100))]
            elif ty == "endurance":
                s80 = a["base"] + math.floor((total - t80) * 10) * 1000
                s100 = b["base"] + math.floor((total - t100) * 10) * 1000
                c["targets"] = [float(round(0.97 * s80, -3)), float(round(0.5 * (s80 + s100), -3)), float(round(1.03 * s100, -3))]
            else:
                lo = min(st[(n, 0.80)]["near"], st[(n, 1.00)]["near"])
                hi = max(st[(n, 0.80)]["near"], st[(n, 1.00)]["near"])
                c["targets"] = [float(max(3, round(0.6 * lo))), float(max(4, round(0.9 * 0.5 * (lo + hi)))), float(max(5, round(1.25 * hi)))]
        elif ty == "drift":
            d = max(st[(n, 0.80)]["drift"], st[(n, 1.00)]["drift"], DRIFT_FLOOR * a["time0"])
            c["targets"] = [float(round(0.4 * d, -2)), float(round(0.8 * d, -2)), float(round(1.3 * d, -2))]
        if c:
            cal[a["id"]] = c
    write_cal(cal)
    json.dump(dict(clean=res, style=list(st.values())), open(os.path.join(OUT, "tour_calibration.json"), "w"), indent=1)
    print(f"wrote {CAL}")


def load_cal():
    """The calibration file is Rhai, but a regular one: read it back."""
    cal = {}
    if not os.path.exists(CAL):
        return cal
    import re
    for line in open(CAL, encoding="utf-8"):
        m = re.match(r'\s*"(\w+)": #\{(.*)\},?\s*$', line)
        if not m:
            continue
        c = {}
        t0 = re.search(r"time0: ([-\d.]+)", m.group(2))
        if t0:
            c["time0"] = float(t0.group(1))
        for k in ("ext", "targets"):
            a = re.search(k + r": \[(.*?)\]", m.group(2))
            if a:
                c[k] = [float(x) for x in a.group(1).split(",") if x.strip()]
        cal[m.group(1)] = c
    return cal


def write_cal(cal):
    def f(x):
        return repr(float(x))
    lines = ["// GENERATED by tools/tour_check.py --calibrate: clocks and medal targets",
             "// measured from the autopilot (the rules are in that script's docstring).",
             "// One event a line; the script reads this file back, so keep the shape.",
             "fn cal() {", "    #{"]
    for key in sorted(cal):
        c = cal[key]
        parts = []
        if "time0" in c:
            parts.append(f"time0: {f(c['time0'])}")
        if "ext" in c:
            parts.append("ext: [" + ", ".join(f(x) for x in c["ext"]) + "]")
        if "targets" in c:
            parts.append("targets: [" + ", ".join(f(x) for x in c["targets"]) + "]")
        lines.append(f'        "{key}": #{{ ' + ", ".join(parts) + " },")
    lines += ["    }", "}", ""]
    with open(CAL, "w", newline="\n", encoding="utf-8") as fh:
        fh.write("\n".join(lines))


# ── the check ───────────────────────────────────────────────────
def target_text(r):
    t = r["targets"]
    if r["type"] == "race":
        return "3rd / 2nd / 1st"
    if r["type"] == "sprint":
        return f"goal / {t[1]:.0f} s / {t[2]:.0f} s left"
    if r["type"] == "rush":
        return f"{t[0]:.0f} / {t[1]:.0f} / {t[2]:.0f} passes"
    return f"{t[0]:.0f} / {t[1]:.0f} / {t[2]:.0f} pts"


def value_text(r):
    if r["type"] == "race":
        return f"P{r['value']:.0f}"
    if r["type"] == "sprint":
        return f"{r['value']:.1f}s" if r["ok"] else "timeout"
    if r["type"] == "rush":
        return f"{r['value']:.0f}" + ("" if r["ok"] else " FAIL")
    return f"{r['value']:.0f}" + ("" if r["ok"] else " FAIL")


def check(events, jobs):
    specs = []
    for n in events:
        specs += [(n, 0.80, "clean", False), (n, 1.00, "clean", False)]
    res = run_many(jobs, specs)
    by = {(r["n"], r["skill"]): r for r in res}
    extra = []
    for n in events:
        ty = by[(n, 0.80)]["type"]
        if ty == "drift":
            extra += [(n, 1.00, "drift", False)]
        elif ty == "rush":
            extra += [(n, 1.00, "shave", False)]
        elif ty == "race":
            extra += [(n, 1.00, "boost", False)]
    st = {r["n"]: r for r in run_many(jobs, extra)}

    print()
    hdr = (f"{'#':>2} {'leg':>3} {'event':26s} {'type':9s} {'km':>5} {'cars':>4} {'rivals':>6}  {'bronze / silver / gold':28s}"
           f" {'0.80: time':>10} {'result':>9} {'medal':6s} {'1.00: time':>10} {'result':>9} {'medal':6s}  style run")
    print(hdr)
    print("-" * len(hdr))
    total80 = total100 = 0.0
    bad = []
    rows = []
    for n in events:
        a, b = by[(n, 0.80)], by[(n, 1.00)]
        s = st.get(n)
        total80 += a["t"]
        total100 += b["t"]
        srun = f"{s['style']}: {value_text(s)} {MEDAL[s['medal']]} ({s['t']:.0f} s, {s['crashes']} crashes)" if s else ""
        print(f"{n + 1:>2} {n // 3 + 1:>3} {a['name'][:26]:26s} {a['type']:9s} {a['km']:5.1f} {a['cars']:>4} {len(a['rivals']):>6}  {target_text(a):28s}"
              f" {a['t']:10.1f} {value_text(a):>9} {MEDAL[a['medal']]:6s} {b['t']:10.1f} {value_text(b):>9} {MEDAL[b['medal']]:6s}  {srun}")
        for r in (a, b, s):
            if r is None:
                continue
            if r["warnings"]:
                bad.append(f"{r['id']} {r['style']} {r['skill']}: {len(r['warnings'])} script warnings: {r['warnings'][0]}")
            if r["type"] in ("sprint", "rush", "endurance") and r["style"] == "clean" and r["why"] != "goal":
                bad.append(f"{r['id']} {r['skill']}: did not reach the goal ({r['why']})")
        rows.append(dict(a=a, b=b, style=s))
    print("-" * len(hdr))
    print(f"total at skill 0.80: {total80:.0f} s = {total80 / 60:.1f} min     at 1.00: {total100:.0f} s = {total100 / 60:.1f} min")
    print()
    for n in events:
        a, b, s = by[(n, 0.80)], by[(n, 1.00)], st.get(n)
        if a["type"] == "race":
            for r in (a, b, s):
                rt = ", ".join(f"{x:.1f}" for x in r["rival_t"])
                print(f"  race {r['id']} {r['style']} {r['skill']:.2f}: player {r['t']:.1f} s P{r['value']:.0f}  rivals [{rt}]  draft {r['draft']:.0f} s")
    if len(events) == N_EVENTS:
        json.dump(dict(rows=rows, total80=total80, total100=total100), open(os.path.join(OUT, "tour_check.json"), "w"), indent=1)
    if bad:
        print("\nPROBLEMS:")
        for x in bad:
            print("  " + x)
        return 1
    print("\nevery event completed; no script warnings")
    return 0


if __name__ == "__main__":
    argv = sys.argv[1:]
    jobs = 6
    if "--jobs" in argv:
        i = argv.index("--jobs")
        jobs = int(argv[i + 1])
        del argv[i:i + 2]
    do_cal = "--calibrate" in argv
    events = [int(a) for a in argv if not a.startswith("--")] or list(range(N_EVENTS))
    os.makedirs(OUT, exist_ok=True)
    if do_cal:
        calibrate(events, jobs)
    sys.exit(check(events, jobs))
