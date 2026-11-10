"""A scripted path through the menus, with frames: the menu regression test.

Plays the real game scene (title first, the save on) from a timed input
script, with `ap_assist` so the autopilot drives once an event starts and a
scripted path can reach a results screen. Frames are written every `--every`
seconds from `--at`; the save the run leaves behind is copied next to them.
The player's own save (save/persist.toml) is put aside first and put back
after, whatever happens.

    python tools/menu_flow.py first --save clean --inputs snapshots/tour/flow_first.txt --until 20 --every 0.5
    python tools/menu_flow.py second --save snapshots/tour/flow/first_save.toml --inputs ... --until 12
    python tools/menu_flow.py tour --save snapshots/tour/fixtures/leg1_clear.toml --inputs ... --shots 2.5,4.0

  --save clean | <file>   the save the run starts from
  --shots a,b,c           frames at exactly these times (one run each: the player takes one --screenshot-at)
  --every S [--at T]      or a frame every S seconds from T (one run)
  --size WxH              default 1280x720
  --player "flags"        extra flint-player flags, e.g. "--touch-controls always" (a touch path: its
                          input script is `touch` / `drag` / `lift` lines, and ap_assist=False lets
                          the fingers drive)
  key=value ...           extra scene keywords (tools/build_scene.py `build`), e.g. ap_skill=0.8 ap_style=3

Frames land in snapshots/tour/flow/<name>_*.png; the log's script lines are printed.
"""
import os
import shutil
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import build_scene  # noqa: E402
from capture import parse  # noqa: E402

PLAYER = os.path.join(ROOT, "engine", "target", "release", "flint-player.exe")
SAVE = os.path.join(ROOT, "save", "persist.toml")
OUT = os.path.join(ROOT, "snapshots", "tour", "flow")


def play(name, scene, inputs, until, size, shot_args, extra=()):
    w, h = size.split("x")
    cmd = [PLAYER, scene, "--schemas", "engine/schemas", "--schemas", "schemas", "--no-activate",
           "--width", w, "--height", h, "--pixels-per-point", "1", "--frame-step", "0.0166667",
           "--exit-after", str(until), "--music-volume", "0", "--sfx-volume", "0", "--input-script", inputs, *shot_args, *extra]
    env = dict(os.environ, RUST_LOG="warn,script=info", FLINT_VSYNC="0", FLINT_PACING="0")
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
    return [l for l in (p.stdout + p.stderr).splitlines()
            if ("script" in l or "ERROR" in l or "persist" in l.lower()) and " TM " not in l and "Loaded:" not in l
            and "Script system" not in l]


def main(argv):
    opts = {"--save": "clean", "--inputs": "", "--until": "20", "--every": "", "--at": "0", "--size": "1280x720", "--shots": "", "--player": ""}
    for k in list(opts):
        if k in argv:
            i = argv.index(k)
            opts[k] = argv[i + 1]
            del argv[i:i + 2]
    name = argv[0]
    kw = {k: parse(v) for k, v in (x.split("=", 1) for x in argv[1:])}
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.dirname(SAVE), exist_ok=True)
    aside = SAVE + ".aside"
    had = os.path.exists(SAVE)
    if had:
        shutil.copyfile(SAVE, aside)
    scene = os.path.join(ROOT, "scenes", f"_flow_{name}.scene.toml")
    with open(scene, "w", newline="\n", encoding="utf-8") as f:
        f.write(build_scene.build(**{"ap_assist": True, "persist": True, **kw}))
    try:
        runs = []
        if opts["--shots"]:
            for t in opts["--shots"].split(","):
                runs.append((float(t) + 0.2, ["--screenshot", os.path.join(OUT, f"{name}_{float(t):07.2f}.png"), "--screenshot-at", t]))
        elif opts["--every"]:
            runs.append((float(opts["--until"]), ["--screenshot", os.path.join(OUT, f"{name}.png"), "--screenshot-at", opts["--at"],
                                                  "--screenshot-every", opts["--every"]]))
        else:
            runs.append((float(opts["--until"]), []))
        for until, shot_args in runs:
            # every run starts from the same save
            if opts["--save"] == "clean":
                if os.path.exists(SAVE):
                    os.remove(SAVE)
            else:
                shutil.copyfile(os.path.join(ROOT, opts["--save"]), SAVE)
            lines = play(name, scene, os.path.join(ROOT, opts["--inputs"]), until, opts["--size"], shot_args, opts["--player"].split())
        for l in lines:
            print(l[-260:])
        left = os.path.join(OUT, f"{name}_save.toml")
        if os.path.exists(SAVE):
            shutil.copyfile(SAVE, left)
            print("save left by the run ->", left)
            print(open(left, encoding="utf-8").read())
        else:
            print("the run left no save")
    finally:
        os.remove(scene)
        if had:
            shutil.copyfile(aside, SAVE)
            os.remove(aside)
        elif os.path.exists(SAVE):
            os.remove(SAVE)


if __name__ == "__main__":
    main(sys.argv[1:])
