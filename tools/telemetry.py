"""Handling telemetry: scripted manoeuvres, run headlessly, measured and plotted.

Nobody can hand-drive a change for you, so the car is measured instead. Each
manoeuvre is a generated scratch scene (tools/build_scene.py's `build`) plus a
timed input script; the game logs `TM key=value ...` lines (game_state's
`telemetry` switch) and this reads them back.

    python tools/telemetry.py                 # every manoeuvre at 60 fps, plots + table
    python tools/telemetry.py --rates         # the core set at 30, 60 and 144 fps, overlaid
    python tools/telemetry.py drift slalom    # just these (see MANOEUVRES)
    python tools/telemetry.py stages          # the autopilot through each stage, and the full run
    python tools/telemetry.py --list

Plots land in snapshots/handling/, raw logs in snapshots/handling/logs/, and
the numbers in snapshots/handling/results.json.
"""
import json
import os
import subprocess
import sys

import numpy as np

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import build_scene  # noqa: E402

OUT = os.path.join(ROOT, "snapshots", "handling")
LOGS = os.path.join(OUT, "logs")
PLAYER = os.path.join(ROOT, "engine", "target", "release", "flint-player.exe")
G = 9.81
KMH = 3.6

FLAT = dict(manual=True, telemetry=True, telemetry_hz=50.0, test_track=True, test_wide=True, traffic=False)
BEND = dict(telemetry=True, telemetry_hz=50.0, test_track=True, test_curve=0.13, traffic=False)


def kmh(v):
    return v / KMH


# name -> scene keywords, input script, seconds. Times are on 1/30 s
# boundaries where it matters, so 30, 60 and 144 fps see the same inputs.
MANOEUVRES = {
    "launch": dict(scene=dict(FLAT), seconds=45, inputs="0.5 down KeyW"),
    "boost": dict(scene=dict(FLAT, start_speed=kmh(300), cruise=kmh(300), start_boost=1.0), seconds=9,
                  inputs="0.0 down KeyW\n2.0 down ShiftLeft\n8.0 up ShiftLeft"),
    "brake": dict(scene=dict(FLAT, start_speed=kmh(250), cruise=kmh(250)), seconds=7, inputs="1.0 down KeyS"),
    "step100": dict(scene=dict(FLAT, start_speed=kmh(100), cruise=kmh(100)), seconds=3.6,
                    inputs="1.0 axis LeftStickX 0.6\n3.2 axis LeftStickX 0"),
    "step200": dict(scene=dict(FLAT, start_speed=kmh(200), cruise=kmh(200)), seconds=3.6,
                    inputs="1.0 axis LeftStickX 0.6\n3.2 axis LeftStickX 0"),
    "step280": dict(scene=dict(FLAT, start_speed=kmh(280), cruise=kmh(280)), seconds=3.6,
                    inputs="1.0 axis LeftStickX 0.6\n3.2 axis LeftStickX 0"),
    "keylock200": dict(scene=dict(FLAT, start_speed=kmh(200), cruise=kmh(200)), seconds=3.6,
                       inputs="1.0 down KeyD\n2.6 up KeyD"),
    "slalom": dict(scene=dict(FLAT, start_speed=kmh(200), cruise=kmh(200)), seconds=8,
                   inputs="\n".join(f"{1.0 + 0.7 * i:.1f} down {'KeyD' if i % 2 == 0 else 'KeyA'}\n"
                                    f"{1.7 + 0.7 * i:.1f} up {'KeyD' if i % 2 == 0 else 'KeyA'}" for i in range(7))),
    "slalom_long": dict(scene=dict(FLAT, start_speed=kmh(200), cruise=kmh(200)), seconds=14,
                   inputs="\n".join(f"{1.0 + 0.7 * i:.1f} down {'KeyD' if i % 2 == 0 else 'KeyA'}\n"
                                    f"{1.7 + 0.7 * i:.1f} up {'KeyD' if i % 2 == 0 else 'KeyA'}" for i in range(16))),
    "drift": dict(scene=dict(FLAT, start_speed=kmh(200), cruise=kmh(200)), seconds=9,
                  inputs="0.5 down KeyW\n1.0 down KeyD\n1.3 down Space\n1.7 up Space\n4.7 up KeyD"),
    # A drift is cornering at the limit, so it wants a bend that asks for the limit:
    # curve 0.17 at 250 km/h is 1.3 g. The autopilot drives in and takes the car back after.
    "drift_bend": dict(scene=dict(BEND, test_curve=0.17, autopilot=True, start_speed=kmh(235)), seconds=16,
                       inputs="5.6 down KeyW\n7.0 down KeyD\n7.2 down Space\n7.6 up Space\n10.6 up KeyD\n10.6 up KeyW"),
    "liftoff": dict(scene=dict(FLAT, start_speed=kmh(250), cruise=kmh(250)), seconds=7,
                    inputs="1.0 axis LeftStickX 0.9\n3.5 pull LeftTrigger2 0.02\n5.0 pull LeftTrigger2 0\n"
                           "6.2 axis LeftStickX 0"),
    "power": dict(scene=dict(FLAT, start_speed=10.0), seconds=6,
                  inputs="0.5 axis LeftStickX 0.8\n1.5 down KeyW\n4.0 up KeyW\n4.0 axis LeftStickX 0"),
    # the same inputs to the old point-slide model and to the new car
    "bend_nosteer": dict(scene=dict(BEND, manual=True, start_speed=kmh(250)), seconds=9,
                         inputs="0.0 down KeyW\n5.5 down KeyD"),
    "before_bend": dict(scene=dict(BEND, manual=True, start_speed=kmh(250), script="_before_drive.rhai"), seconds=9,
                        inputs="0.0 down KeyW\n5.5 down KeyD"),
    "before_step": dict(scene=dict(FLAT, start_speed=kmh(200), script="_before_drive.rhai"), seconds=3.6,
                        inputs="0.0 down KeyW\n1.0 down KeyD\n2.6 up KeyD"),
}
for _n in range(5):
    MANOEUVRES[f"stage{_n + 1}"] = dict(scene=dict(autopilot=True, telemetry=True, start_stage=_n, start_speed=70.0),
                                        seconds=100, inputs="")
MANOEUVRES["fullrun"] = dict(scene=dict(autopilot=True, telemetry=True, start_stage=0, start_speed=70.0),
                             seconds=330, inputs="")

CORE = ["launch", "brake", "step100", "step200", "step280", "slalom", "drift", "liftoff"]
EVERYTHING = ["launch", "boost", "brake", "step100", "step200", "step280", "keylock200", "slalom", "drift",
              "drift_bend", "liftoff", "power", "bend_nosteer"]
STAGES = [f"stage{n}" for n in range(1, 6)] + ["fullrun"]


# ── running ─────────────────────────────────────────────────────
def run(name, fps=60, force=True):
    """Play one manoeuvre; returns (columns as arrays, script warnings)."""
    m = MANOEUVRES[name]
    os.makedirs(LOGS, exist_ok=True)
    log_path = os.path.join(LOGS, f"{name}_{fps}.log")
    if force or not os.path.exists(log_path):
        scene = os.path.join(ROOT, "scenes", f"_tm_{name}.scene.toml")
        with open(scene, "w", newline="\n", encoding="utf-8") as f:
            f.write(build_scene.build(**m["scene"]))
        inp = os.path.join(LOGS, f"{name}.txt")
        with open(inp, "w", newline="\n") as f:
            f.write(m["inputs"] + "\n")
        cmd = [PLAYER, scene, "--schemas", "engine/schemas", "--schemas", "schemas", "--no-activate",
               "--width", "640", "--height", "360", "--frame-step", repr(1.0 / fps),
               "--exit-after", str(m["seconds"]), "--music-volume", "0", "--sfx-volume", "0",
               "--input-script", inp]
        env = dict(os.environ, RUST_LOG="warn,script=info", FLINT_VSYNC="0", FLINT_PACING="0")
        p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
        with open(log_path, "w", encoding="utf-8") as f:
            f.write(p.stdout + p.stderr)
        os.remove(scene)
    rows, warns = [], []
    for line in open(log_path, encoding="utf-8"):
        if " TM " in line:
            rows.append({k: float(v) for k, v in (kv.split("=") for kv in line.split(" TM ")[1].split())})
        elif ("script" in line.lower() and ("WARN" in line or "ERROR" in line)) or "ERROR" in line:
            warns.append(line.strip())
    if not rows:
        raise SystemExit(f"{name}: no telemetry (see {log_path})")
    cols = {k: np.array([r.get(k, np.nan) for r in rows]) for k in rows[0]}
    return cols, warns


def t_cross(t, y, level):
    """First time y crosses `level` upward, interpolated; nan if never."""
    i = np.nonzero((y[1:] >= level) & (y[:-1] < level))[0]
    if len(i) == 0:
        return float("nan")
    i = i[0]
    return float(t[i] + (level - y[i]) / (y[i + 1] - y[i]) * (t[i + 1] - t[i]))


def win(d, a, b):
    return (d["t"] >= a) & (d["t"] <= b)


# ── measuring ───────────────────────────────────────────────────
def measure(name, d):
    t, v = d["t"], d["v"]
    r = {}
    if name == "launch":
        for k in (100, 200, 250):
            r[f"0-{k} km/h s"] = t_cross(t, v * KMH, k) - 0.5
        r["top km/h"] = float(v[-1] * KMH)
        r["top still rising km/h/s"] = float((v[-1] - v[-51]) * KMH)
        r["peak launch g"] = float(np.max(d["ax"]) / G)
    elif name == "boost":
        r["before boost km/h"] = float(v[win(d, 1.8, 2.0)].mean() * KMH)
        r["peak km/h"] = float(v.max() * KMH)
        r["boost lasts s"] = float(t[np.nonzero(d["boost"] <= 0.001)[0][0]] - 2.0) if (d["boost"] <= 0.001).any() else float("nan")
    elif name == "brake":
        i0 = np.nonzero(t >= 1.0)[0][0]
        stop = np.nonzero(v < 0.05)[0]
        i1 = stop[0] if len(stop) else len(t) - 1
        r["from km/h"] = float(v[i0] * KMH)
        r["distance m"] = float(d["pos"][i1] - d["pos"][i0])
        r["time s"] = float(t[i1] - t[i0])
        r["peak g"] = float(-d["ax"].min() / G)
        r["mean g"] = float(v[i0] / (t[i1] - t[i0]) / G)
    elif name.startswith("step") or name == "before_step":
        if "r" in d:
            steady = float(d["r"][win(d, 2.6, 3.15)].mean())
            y = d["r"]
            t10, t90 = t_cross(t, y, 0.1 * steady), t_cross(t, y, 0.9 * steady)
            r["steady yaw rate deg/s"] = float(np.degrees(steady))
            r["rise 10-90% s"] = t90 - t10
            r["to 90% from input s"] = t90 - 1.0
            r["overshoot %"] = float((y[win(d, 1.0, 3.15)].max() / steady - 1.0) * 100.0)
            r["steady lat g"] = float(d["ay"][win(d, 2.6, 3.15)].mean() / G)
            r["steady slip deg"] = float(np.degrees(d["slip"][win(d, 2.6, 3.15)].mean()))
            dr = np.diff(y[win(d, 1.6, 3.15)])
            r["sign flips of d(yaw rate) after settling"] = int(np.sum(np.diff(np.sign(dr[np.abs(dr) > 1e-5])) != 0))
        else:
            r["lateral speed m/s (constant: no heading)"] = float(d["vlat"][win(d, 1.5, 1.6)].mean())
            r["px after 0.6 s m"] = float(d["px"][win(d, 1.58, 1.62)].mean())
    elif name == "keylock200":
        r["peak lat g"] = float(np.abs(d["ay"]).max() / G)
        r["steady lat g"] = float(d["ay"][win(d, 2.0, 2.6)].mean() / G)
        r["max slip deg"] = float(np.degrees(np.abs(d["slip"]).max()))
        r["yaw rate deg/s"] = float(np.degrees(d["r"][win(d, 2.0, 2.6)].mean()))
        r["slip 0.5 s after release deg"] = float(np.degrees(d["slip"][win(d, 3.08, 3.12)].mean()))
    elif name == "slalom_long":
        r["max slip deg"] = float(np.degrees(np.abs(d["slip"]).max()))
        r["max slip in the last 3 swings deg"] = float(np.degrees(np.abs(d["slip"][win(d, 10.1, 12.2)]).max()))
        r["spins"] = int(d["crashes"][-1])
    elif name == "slalom":
        w = win(d, 1.7, 5.9)
        r["peak lat g"] = float(np.abs(d["ay"][w]).max() / G)
        r["max slip deg"] = float(np.degrees(np.abs(d["slip"][w]).max()))
        r["px swing m"] = float(d["px"][w].max() - d["px"][w].min())
        # lag of yaw rate behind the steering, by cross-correlation
        dtm = float(np.median(np.diff(t)))
        a, b = d["steer"][w] - d["steer"][w].mean(), d["r"][w] - d["r"][w].mean()
        lags = range(0, int(0.6 / dtm))
        cc = [float(np.sum(a[: len(a) - k] * b[k:])) for k in lags]
        r["yaw rate lags steering by s"] = float(np.argmax(cc) * dtm)
        r["speed lost km/h"] = float((v[w][0] - v[w].min()) * KMH)
        r["slip 1.5 s after the last swing deg"] = float(np.degrees(np.abs(d["slip"][win(d, 7.3, 7.5)]).max()))
        r["spins"] = int(d["crashes"][-1])
    elif name in ("drift", "drift_bend"):
        a, b, rel = (2.2, 4.7, 4.7) if name == "drift" else (8.2, 10.6, 10.6)
        s = np.degrees(d["slip"])
        r["peak slip deg"] = float(np.abs(s).max())
        r["held slip mean deg"] = float(s[win(d, a, b)].mean())
        r["held slip min..max deg"] = f"{s[win(d, a, b)].min():.1f}..{s[win(d, a, b)].max():.1f}"
        after = np.nonzero((t > rel) & (np.abs(s) < 3.0))[0]
        r["recovered (slip < 3 deg) after release s"] = float(t[after[0]] - rel) if len(after) else float("nan")
        r["opposite swing after recovery deg"] = float(-s[t > rel].min()) if s[win(d, a, b)].mean() > 0 else float(s[t > rel].max())
        r["speed in / out km/h"] = f"{v[win(d, a - 1.3, a - 1.1)].mean() * KMH:.0f} / {v[win(d, b - 0.1, b)].mean() * KMH:.0f}"
        r["drift banked"] = float(d["banked"][-1])
        r["boost earned"] = float(d["boost"].max() - d["boost"][0])
        r["spins"] = int(d["crashes"][-1])
        r["px min..max m"] = f"{d['px'].min():.1f}..{d['px'].max():.1f}"
        r["off-road s"] = float(d["off"][-1])
    elif name == "liftoff":
        s = np.degrees(d["slip"])
        r["slip on throttle deg"] = float(s[win(d, 3.0, 3.5)].mean())
        r["peak slip after lift deg"] = float(s[win(d, 3.5, 5.0)].max())
        r["yaw rate on throttle deg/s"] = float(np.degrees(d["r"][win(d, 3.0, 3.5)].mean()))
        r["peak yaw rate after lift deg/s"] = float(np.degrees(d["r"][win(d, 3.5, 5.0)].max()))
        r["lat g on throttle"] = float(d["ay"][win(d, 3.0, 3.5)].mean() / G)
        r["slip back on throttle deg"] = float(s[win(d, 5.8, 6.2)].mean())
        r["spins"] = int(d["crashes"][-1])
    elif name == "power":
        s = np.degrees(d["slip"])
        r["slip before throttle deg"] = float(s[win(d, 1.2, 1.5)].mean())
        r["peak slip on throttle deg"] = float(s[win(d, 1.5, 4.0)].max())
        r["peak wheelspin"] = float(d["wspin"].max())
        r["slip 1.5 s after lifting deg"] = float(s[win(d, 5.4, 5.6)].mean())
        r["spins"] = int(d["crashes"][-1])
    elif name in ("bend_nosteer", "before_bend"):
        r["px at 5.5 s m"] = float(d["px"][win(d, 5.4, 5.5)].mean())
        r["px min..max m"] = f"{d['px'].min():.1f}..{d['px'].max():.1f}"
    elif name.startswith("stage") or name == "fullrun":
        st = d["stage"]
        if name == "fullrun":
            done = np.nonzero(st >= 5)[0]
        else:
            done = np.nonzero(st > st[0])[0]
        i1 = done[0] if len(done) else len(t) - 1
        r["finished"] = bool(len(done))
        r["time s"] = float(t[i1])
        r["distance m"] = float(d["pos"][i1] - d["pos"][0])
        r["mean km/h"] = float((d["pos"][i1] - d["pos"][0]) / t[i1] * KMH)
        r["min km/h"] = float(v[: i1 + 1].min() * KMH)
        r["top km/h"] = float(v[: i1 + 1].max() * KMH)
        r["crashes + spins"] = int(d["crashes"][i1])
        r["off-road s"] = float(d["off"][i1])
        r["max |px| m"] = float(np.abs(d["px"][: i1 + 1]).max())
        r["max |slip| deg"] = float(np.degrees(np.abs(d["slip"][: i1 + 1]).max()))
        r["peak lat g"] = float(np.abs(d["ay"][: i1 + 1]).max() / G)
        r["air s"] = float(d["air"][i1])
        r["close passes"] = int(d["near"][i1])
    return r


# ── drawing ─────────────────────────────────────────────────────
INK = {30: "#ff4fa3", 60: "#5ee6ff", 144: "#ffd45e"}
BG, PANEL, GRID, TEXT = "#0b0714", "#120b22", "#2a1f44", "#cfc8e8"

PANELS = {
    "launch": [("v", KMH, "speed  km/h"), ("ax", 1 / G, "longitudinal  g"), ("gear", 1, "gear"), ("wspin", 1, "wheelspin")],
    "boost": [("v", KMH, "speed  km/h"), ("boost", 1, "boost meter"), ("ax", 1 / G, "longitudinal  g")],
    "brake": [("v", KMH, "speed  km/h"), ("ax", 1 / G, "longitudinal  g"), ("pitch", 57.3, "body pitch  deg")],
    "step": [("steer", 1, "steering input"), ("r", 57.3, "yaw rate  deg/s"), ("ay", 1 / G, "lateral  g"),
             ("slip", 57.3, "slip angle  deg"), ("roll", 57.3, "body roll  deg")],
    "slalom": [("steer", 1, "steering input"), ("r", 57.3, "yaw rate  deg/s"), ("ay", 1 / G, "lateral  g"),
               ("slip", 57.3, "slip angle  deg"), ("px", 1, "lateral offset  m")],
    "drift": [("steer", 1, "steering input"), ("wheel", 57.3, "front wheel angle  deg"), ("slip", 57.3, "slip angle  deg"),
              ("r", 57.3, "yaw rate  deg/s"), ("v", KMH, "speed  km/h"), ("drift", 1, "live drift score")],
    "drift_bend": [("steer", 1, "steering input"), ("slip", 57.3, "slip angle  deg"), ("px", 1, "lateral offset  m"),
                   ("v", KMH, "speed  km/h"), ("drift", 1, "live drift score"), ("boost", 1, "boost meter")],
    "liftoff": [("ax", 1 / G, "longitudinal  g"), ("r", 57.3, "yaw rate  deg/s"), ("slip", 57.3, "slip angle  deg"),
                ("ay", 1 / G, "lateral  g"), ("v", KMH, "speed  km/h")],
    "power": [("ax", 1 / G, "longitudinal  g"), ("wspin", 1, "wheelspin"), ("slip", 57.3, "slip angle  deg"),
              ("r", 57.3, "yaw rate  deg/s"), ("v", KMH, "speed  km/h")],
    "stage": [("v", KMH, "speed  km/h"), ("px", 1, "lateral offset  m"), ("slip", 57.3, "slip angle  deg"),
              ("ay", 1 / G, "lateral  g"), ("load", 1, "vertical load"), ("c0", 1, "road curve")],
}
TITLES = {
    "launch": "Standing start to top speed", "boost": "Boost from 300 km/h", "brake": "Braking from 250 km/h",
    "step100": "Step steer at 100 km/h (stick 0.6)", "step200": "Step steer at 200 km/h (stick 0.6)",
    "step280": "Step steer at 280 km/h (stick 0.6)", "keylock200": "Full lock on the keyboard at 200 km/h",
    "slalom": "Slalom at 200 km/h, full keyboard lock every 0.7 s",
    "drift": "Handbrake drift at 200 km/h: entry, 3 s held, release",
    "drift_bend": "Handbrake drift through a 1.3 g bend at 250 km/h, then handed back to the autopilot",
    "liftoff": "Lift off mid-corner at 250 km/h", "power": "Flooring it at low speed with lock on",
}


def style_axes(ax):
    ax.set_facecolor(PANEL)
    for s in ax.spines.values():
        s.set_color(GRID)
    ax.tick_params(colors=TEXT, labelsize=8)
    ax.grid(True, color=GRID, linewidth=0.6)
    ax.yaxis.label.set_color(TEXT)
    ax.xaxis.label.set_color(TEXT)


def plot(name, runs, path, title=None):
    """runs: {label: (cols, colour)}"""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    key = "slalom" if name == "slalom_long" else "step" if name.startswith("step") or name == "keylock200" else "stage" if name.startswith("stage") or name == "fullrun" else name
    panels = PANELS[key]
    fig, axes = plt.subplots(len(panels), 1, figsize=(9.6, 1.55 * len(panels) + 0.9), sharex=True)
    fig.patch.set_facecolor(BG)
    for ax, (col, k, label) in zip(np.atleast_1d(axes), panels):
        style_axes(ax)
        for lab, (d, ink) in runs.items():
            if col in d:
                ax.plot(d["t"], d[col] * k, color=ink, linewidth=1.3, label=lab, alpha=0.95)
        ax.set_ylabel(label, fontsize=8)
    np.atleast_1d(axes)[-1].set_xlabel("seconds")
    if len(runs) > 1:
        leg = np.atleast_1d(axes)[0].legend(loc="upper right", fontsize=8, facecolor=PANEL, edgecolor=GRID, ncol=len(runs))
        for txt in leg.get_texts():
            txt.set_color(TEXT)
    fig.suptitle(title or TITLES.get(name, name), color="#ffffff", fontsize=12, x=0.02, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(path, dpi=110, facecolor=BG)
    plt.close(fig)


def plot_before_after(before, after, path, kind):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, axes = plt.subplots(3, 1, figsize=(9.6, 5.6), sharex=True)
    fig.patch.set_facecolor(BG)
    rows = [("px", 1, "lateral offset  m"), ("yaw", 57.3, "heading vs road  deg"), ("v", KMH, "speed  km/h")]
    for ax, (col, k, label) in zip(axes, rows):
        style_axes(ax)
        ax.plot(before["t"], before[col] * k, color="#ff4fa3", linewidth=1.4, label="before: point that slides")
        ax.plot(after["t"], after[col] * k, color="#5ee6ff", linewidth=1.4, label="after: car with heading and slip")
        ax.set_ylabel(label, fontsize=8)
    leg = axes[0].legend(loc="lower left", fontsize=8, facecolor=PANEL, edgecolor=GRID)
    for txt in leg.get_texts():
        txt.set_color(TEXT)
    axes[-1].set_xlabel("seconds")
    fig.suptitle(kind, color="#ffffff", fontsize=12, x=0.02, ha="left")
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(path, dpi=110, facecolor=BG)
    plt.close(fig)


def show(name, fps, r, warns):
    print(f"\n== {name} @ {fps} fps ==")
    for k, v in r.items():
        print(f"  {k:44s} {v:.3f}" if isinstance(v, float) else f"  {k:44s} {v}")
    for w in warns[:5]:
        print("  !!", w[-160:])


def main(argv):
    if "--list" in argv:
        print("\n".join(MANOEUVRES))
        return
    rates = "--rates" in argv
    names = [a for a in argv if not a.startswith("--")]
    if names == ["stages"]:
        names = STAGES
    if not names:
        names = CORE if rates else EVERYTHING
    fpss = [30, 60, 144] if rates else [60]
    os.makedirs(OUT, exist_ok=True)
    res_path = os.path.join(OUT, "results.json")
    results = json.load(open(res_path)) if os.path.exists(res_path) else {}
    for name in names:
        runs = {}
        for fps in fpss:
            d, warns = run(name, fps)
            r = measure(name, d)
            r["script warnings"] = len(warns)
            show(name, fps, r, warns)
            results.setdefault(name, {})[str(fps)] = r
            runs[f"{fps} fps"] = (d, INK[fps])
        if name.startswith("before") or name == "bend_nosteer":
            continue
        suffix = "_rates" if rates else ""
        if not rates:
            runs = {k: (d, "#5ee6ff") for k, (d, _) in runs.items()}
        plot(name, runs, os.path.join(OUT, f"{name}{suffix}.png"))
    json.dump(results, open(res_path, "w"), indent=1)

    # before / after. The old point-slide model's script is not kept in the
    # repo; its two runs are cached in logs/before_*_60.log and re-plotted from there.
    if "--before" in argv:
        have = os.path.exists(os.path.join(ROOT, "scripts", "_before_drive.rhai"))
        b, _ = run("before_bend", force=have)
        a, _ = run("bend_nosteer")
        plot_before_after(b, a, os.path.join(OUT, "before_after_bend.png"),
                          "Into a bend at 250 km/h with no steering, then full lock at 5.5 s")
        b, _ = run("before_step", force=have)
        a, _ = run("keylock200")
        plot_before_after(b, a, os.path.join(OUT, "before_after_step.png"),
                          "Full keyboard lock at 200 km/h, 1.0 s to 2.6 s")


if __name__ == "__main__":
    main(sys.argv[1:])
