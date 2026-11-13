"""The touch controls, checked with scripted fingers on phone- and tablet-shaped windows.

Nobody can thumb a build for you, so this plays `touch` / `drag` / `lift`
lines (the player's --input-script: window pixels, one id a finger) into the
game with `--touch-controls always`, and reads what the car did from the
telemetry line and what the screen showed from frames.

    python tools/touch_check.py              # every check, both sizes
    python tools/touch_check.py drive        # the handling checks only (no save involved)
    python tools/touch_check.py flow         # the taps-only menu path only
    python tools/touch_check.py flow phone   # one size

  drive   on the flat handling track (scene keywords as tools/telemetry.py's):
          auto gas with no finger down, the stick alone, the stick with BRAKE,
          with DRIFT, with BOOST (two fingers at once), each as numbers.
  flow    the game's own scene from a clean save, by taps alone: title ->
          HORIZON refuses -> GRAND TOUR -> a locked event and a locked paint
          refuse -> FIRST LIGHT -> briefing BACK -> again -> START -> drive ->
          the menu button -> RESUME -> the menu button -> QUIT -> tour BACK ->
          title -> ARCADE -> drive. A frame every 0.5 s.

Frames land in snapshots/touch/<size>/, logs beside them. Every run keeps its
save in a scratch folder of its own (`--save-dir`, Flint #726), so the flow
starts clean and the player's real save is never read or touched.

Where the fingers land is computed here from the same layout numbers
scripts/hud.rhai draws from (see `Layout`): if a menu moves, change both.
"""
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import build_scene  # noqa: E402

PLAYER = os.path.join(ROOT, "engine", "target", "release", "flint-player.exe")
OUT = os.path.join(ROOT, "snapshots", "touch")
SIZES = {"phone": (844, 390), "tablet": (1180, 820)}
TMIN = 44.0


class Layout:
    """Where things are, in points (= window pixels at --pixels-per-point 1)."""

    def __init__(self, w, h):
        self.w, self.h = w, h
        u = self.u = h / 720.0
        cx = self.cx = w * 0.5
        # config/input.toml [touch_controls]
        self.stick = (112, h - 112)
        self.stick_r = 56
        self.deadzone = 0.12
        self.brake = (w - 88, h - 92)
        self.drift = (w - 190, h - 150)
        self.boost = (w - 84, h - 204)
        self.menu = (cx + 150, 36)
        # hud.rhai: the title's rows
        pitch = max(59 * u, TMIN + 2)
        my = min(h * 0.50, h * 0.905 - 4 * pitch)
        self.title = [(cx, my + i * pitch - 4 * u + (pitch - 2) * 0.5) for i in range(4)]     # the fourth is SETTINGS
        # the tour screen
        x0 = 40 * u
        W = w - 80 * u
        gap = 10 * u
        cw = (W - 4 * gap) / 5
        top = 104 * u
        ch = 78 * u
        self.card = lambda leg, row: (x0 + leg * (cw + gap) + cw * 0.5, top + 48 * u + row * (ch + 8 * u) + ch * 0.5)
        dy = top + 48 * u + 3 * (ch + 8 * u) + 4 * u
        py = dy + 150 * u + 14 * u
        ph = max(34 * u, TMIN)
        pw = 210 * u
        self.paint = lambda k: (x0 + 90 * u + k * (pw + 10 * u) + pw * 0.5, py + ph * 0.5)
        self.tour_back = (x0 + max(104 * u, 2 * TMIN) * 0.5, 54 * u)
        # the briefing card's buttons
        by = h * 0.5 - 200 * u - 20 * u + 400 * u + 12 * u
        bh = max(44 * u, TMIN)
        bw = max(220 * u, 3 * TMIN)
        self.brief_back = (cx - 14 * u - bw * 0.5, by + bh * 0.5)
        self.brief_start = (cx + 14 * u + bw * 0.5, by + bh * 0.5)
        # the pause menu's rows
        rh = max(44 * u, TMIN)
        self.pause = [(cx, h * 0.21 + 110 * u + k * (rh + 12 * u) + rh * 0.5) for k in range(4)]   # RESUME, RESTART, SETTINGS, QUIT

    def stick_dx(self, value):
        """Finger travel from the stick's base for a deflection of `value`."""
        return (self.deadzone + abs(value) * (1 - self.deadzone)) * self.stick_r * (1 if value >= 0 else -1)


def run(scene_kw, script, seconds, size, tag, shots=None):
    """Play a scratch scene with scripted fingers; returns the log's lines."""
    w, h = SIZES[size]
    out = os.path.join(OUT, size)
    os.makedirs(out, exist_ok=True)
    scene = os.path.join(ROOT, "scenes", f"_touch_{tag}_{size}.scene.toml")
    inp = os.path.join(out, f"{tag}.txt")
    with open(scene, "w", newline="\n", encoding="utf-8") as f:
        f.write(build_scene.build(**scene_kw))
    with open(inp, "w", newline="\n") as f:
        f.write(script.strip() + "\n")
    save_dir = tempfile.mkdtemp(prefix="kandinski_touch_")
    cmd = [PLAYER, scene, "--save-dir", save_dir, "--schemas", "engine/schemas", "--schemas", "schemas", "--no-activate",
           "--width", str(w), "--height", str(h), "--pixels-per-point", "1", "--frame-step", "0.0166667",
           "--exit-after", str(seconds), "--music-volume", "0", "--sfx-volume", "0",
           "--touch-controls", "always", "--input-script", inp]
    if shots:
        for old in os.listdir(out):
            if old.startswith(tag + "_") and old.endswith(".png"):
                os.remove(os.path.join(out, old))
        cmd += ["--screenshot", os.path.join(out, f"{tag}.png"), "--screenshot-at", str(shots[0]), "--screenshot-every", str(shots[1])]
    env = dict(os.environ, RUST_LOG="warn,script=info", FLINT_VSYNC="0", FLINT_PACING="0")
    try:
        p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
    finally:
        os.remove(scene)
        save = os.path.join(save_dir, "default.toml")
        if os.path.exists(save):
            shutil.copyfile(save, os.path.join(out, f"{tag}_save.toml"))
        shutil.rmtree(save_dir, ignore_errors=True)
    lines = (p.stdout + p.stderr).splitlines()
    with open(os.path.join(out, f"{tag}.log"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))
    return lines


def telemetry(lines):
    """The TM lines as dicts of floats."""
    rows = []
    for l in lines:
        if " TM " in l:
            rows.append({k: float(v) for k, v in re.findall(r"(\w+)=(-?[\d.eE+-]+)", l.split(" TM ", 1)[1])})
    return rows


def problems(lines):
    """Script warnings, errors and panics (the graphics and gamepad drivers' own warnings aside)."""
    return [l[-220:] for l in lines if ("WARN" in l or "ERROR" in l or "panick" in l) and " TM " not in l
            and "wgpu_hal" not in l and "gilrs" not in l
            and "epaint texture atlas" not in l]      # egui's own, once a run, on the keyboard path too


def at(rows, t):
    return min(rows, key=lambda r: abs(r["t"] - t))


def span(rows, a, b):
    return [r for r in rows if a <= r["t"] <= b]


# ── the handling checks ─────────────────────────────────────────
FLAT = dict(manual=True, telemetry=True, telemetry_hz=30.0, test_track=True, test_wide=True, traffic=False)


def drive(size):
    L = Layout(*SIZES[size])
    sx, sy = L.stick
    ok = True

    def verdict(name, good, text):
        nonlocal ok
        ok = ok and good
        print(f"  {'ok  ' if good else 'FAIL'} {name:<22} {text}")

    # 1. no finger at all: the gas is automatic. Then the stick alone, half over.
    half = L.stick_dx(0.6)
    lines = run(dict(FLAT), f"""
4.0 touch 1 {sx} {sy}
4.0 drag 1 {sx + half:.1f} {sy} 0.15
6.0 drag 1 {sx} {sy} 0.15
6.5 lift 1
""", 7.0, size, "auto_gas")
    tm = telemetry(lines)
    v1, v4 = at(tm, 1.0)["v"], at(tm, 4.0)["v"]
    verdict("auto gas", v4 > v1 + 15 and not problems(lines), f"no finger down: {v1 * 3.6:.0f} km/h at 1 s, {v4 * 3.6:.0f} km/h at 4 s")
    st = at(tm, 5.5)["steer"]
    want = 0.6 * (0.55 + 0.45 * 0.6)
    px4, px6 = at(tm, 4.0)["px"], at(tm, 6.0)["px"]
    verdict("stick, 0.6 over", abs(st - want) < 0.03 and px6 > px4 + 0.5,
            f"steer {st:.3f} (the pad's curve gives {want:.3f}), px {px4:+.2f} -> {px6:+.2f} m, {at(tm, 6.0)['v'] * 3.6:.0f} km/h")

    # 2. full lock is still a stick: the eased curve, not the keyboard's ramp
    full = L.stick_dx(1.0) + 30
    lines = run(dict(FLAT, start_speed=200 / 3.6), f"""
1.0 touch 1 {sx} {sy}
1.0 drag 1 {sx + full:.1f} {sy} 0.05
""", 1.5, size, "full_lock")
    tm = telemetry(lines)
    st = at(tm, 1.2)["steer"]
    verdict("stick, full lock", st > 0.9, f"steer {st:.2f} 0.15 s after the thumb is over (a key's ramp would be at 0.60)")

    # 3. two fingers: the stick held over, BRAKE under the other thumb
    lines = run(dict(FLAT, start_speed=200 / 3.6), f"""
0.5 touch 1 {sx} {sy}
0.5 drag 1 {sx + L.stick_dx(0.3):.1f} {sy} 0.1
2.0 touch 2 {L.brake[0]} {L.brake[1]}
4.0 lift 2
6.0 lift 1
""", 6.0, size, "brake")
    tm = telemetry(lines)
    v2, v4, v6 = at(tm, 2.0)["v"], at(tm, 4.0)["v"], at(tm, 5.9)["v"]
    held = min(abs(r["steer"]) for r in span(tm, 2.0, 4.0))
    verdict("stick + BRAKE", v4 < v2 - 15 and v6 > v4 + 5 and held > 0.1,
            f"{v2 * 3.6:.0f} -> {v4 * 3.6:.0f} km/h braking with steer held at {held:.2f}, back to {v6 * 3.6:.0f} km/h once lifted")

    # 4. a drift: the stick into it, DRIFT for 0.4 s
    lines = run(dict(FLAT, start_speed=200 / 3.6), f"""
1.0 touch 1 {sx} {sy}
1.0 drag 1 {sx + full:.1f} {sy} 0.1
1.3 touch 2 {L.drift[0]} {L.drift[1]}
1.7 lift 2
4.7 lift 1
""", 7.0, size, "drift", shots=(2.6, 10))
    tm = telemetry(lines)
    slip = max(abs(r["slip"]) for r in span(tm, 1.3, 4.7)) * 57.3
    pts = max(r["drift"] for r in tm)
    banked = tm[-1]["banked"]
    verdict("stick + DRIFT", slip > 12 and pts > 100, f"slip to {slip:.0f} deg, {pts:.0f} points building, {banked:.0f} banked, {int(tm[-1]['crashes'])} spins")

    # 5. boost: the meter full, BOOST held with the stick in hand
    lines = run(dict(FLAT, start_speed=200 / 3.6, start_boost=1.0), f"""
0.5 touch 1 {sx} {sy}
2.0 touch 2 {L.boost[0]} {L.boost[1]}
4.0 lift 2
5.0 lift 1
""", 5.0, size, "boost", shots=(3.0, 10))
    tm = telemetry(lines)
    b2, b4 = at(tm, 2.0)["boost"], at(tm, 4.0)["boost"]
    a_before = (at(tm, 2.0)["v"] - at(tm, 1.0)["v"])
    a_during = (at(tm, 3.0)["v"] - at(tm, 2.0)["v"])
    verdict("stick + BOOST", b4 < b2 - 0.2 and a_during > a_before,
            f"meter {b2:.2f} -> {b4:.2f}; +{a_during * 3.6:.0f} km/h in the boosted second against +{a_before * 3.6:.0f} before")
    return ok


# ── the menu path, by taps alone ────────────────────────────────
def flow(size):
    L = Layout(*SIZES[size])
    t = [0.0]
    out = []

    def tap(p, gap=1.0, note=""):
        t[0] += gap
        out.append(f"{t[0]:.2f} touch 1 {p[0]:.0f} {p[1]:.0f}     # {note}")
        out.append(f"{t[0] + 0.1:.2f} lift 1")

    tap(L.title[2], 1.0, "HORIZON: locked, refuses")
    tap(L.title[1], 1.0, "GRAND TOUR")
    tap(L.card(1, 0), 1.0, "leg 2's first event: locked, the cursor goes there, it refuses")
    tap(L.paint(1), 1.0, "COBALT: not earned, refuses")
    tap(L.card(0, 0), 1.0, "FIRST LIGHT -> briefing")
    tap(L.brief_back, 1.0, "BACK -> tour")
    tap(L.card(0, 0), 1.0, "FIRST LIGHT again")
    tap(L.brief_start, 1.0, "START")
    go = t[0] + 2.8                       # the countdown
    sx, sy = L.stick
    out += [f"{go + 1.0:.2f} touch 1 {sx} {sy}     # left thumb: the stick",
            f"{go + 2.0:.2f} drag 1 {sx + L.stick_dx(0.5):.1f} {sy} 0.2",
            f"{go + 2.6:.2f} drag 1 {sx + L.stick_dx(-0.5):.1f} {sy} 0.3",
            f"{go + 3.2:.2f} drag 1 {sx} {sy} 0.2",
            f"{go + 4.0:.2f} touch 2 {L.brake[0]} {L.brake[1]}     # right thumb: BRAKE, the stick still held",
            f"{go + 4.8:.2f} lift 2",
            f"{go + 6.0:.2f} touch 2 {L.menu[0]:.0f} {L.menu[1]}     # the menu button, the stick still held",
            f"{go + 6.1:.2f} lift 2",
            f"{go + 6.5:.2f} lift 1"]
    t[0] = go + 6.5
    tap(L.pause[0], 1.0, "RESUME")
    t[0] += 1.5
    out += [f"{t[0]:.2f} touch 2 {L.menu[0]:.0f} {L.menu[1]}     # the menu button again", f"{t[0] + 0.1:.2f} lift 2"]
    tap(L.pause[3], 1.0, "QUIT TO TOUR")
    tap(L.tour_back, 1.2, "tour BACK -> title")
    tap(L.title[0], 1.2, "ARCADE")
    go = t[0] + 2.8
    out += [f"{go + 1.0:.2f} touch 1 {sx} {sy}",
            f"{go + 2.0:.2f} drag 1 {sx + L.stick_dx(0.4):.1f} {sy} 0.2",
            f"{go + 3.0:.2f} drag 1 {sx} {sy} 0.2",
            f"{go + 4.0:.2f} lift 1"]
    end = go + 5.0
    lines = run(dict(persist=True, telemetry=True, telemetry_hz=2.0), "\n".join(out), end, size, "flow", shots=(0.5, 0.5))
    tm = telemetry(lines)
    bad = problems(lines)
    v = max((r["v"] for r in tm), default=0.0)
    n = len([f for f in os.listdir(os.path.join(OUT, size)) if f.startswith("flow_") and f.endswith(".png")])
    print(f"  flow: {end:.1f} s, {n} frames in snapshots/touch/{size}/, top speed in it {v * 3.6:.0f} km/h, warnings/errors {len(bad)}")
    for l in bad[:10]:
        print("    " + l)
    print("  the script: snapshots/touch/%s/flow.txt (look at the frames: the path is right only if each screen follows)" % size)
    return not bad


if __name__ == "__main__":
    args = sys.argv[1:]
    sizes = [a for a in args if a in SIZES] or list(SIZES)
    what = [a for a in args if a in ("drive", "flow")] or ["drive", "flow"]
    good = True
    for size in sizes:
        print(f"{size}  {SIZES[size][0]} x {SIZES[size][1]} pt")
        if "drive" in what:
            good = drive(size) and good
        if "flow" in what:
            good = flow(size) and good
    sys.exit(0 if good else 1)
