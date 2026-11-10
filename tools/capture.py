"""One deterministic frame of a scripted moment: scene keywords + timed inputs.

tools/shot.sh takes a frame of a scene that exists; this builds a scratch
variant first (tools/build_scene.py's `build` keywords), so a capture can ask
for a full boost meter, a stage, no traffic, or the handling test track.

    python tools/capture.py out.png 9.3 autopilot=True start_stage=2 start_speed=70 \
        --inputs "7.0 down KeyD; 7.2 down Space; 7.6 up Space" [--size 1280x720] [--fps 60]

Prints the script's log lines that are not telemetry, as shot.sh does.
"""
import os
import subprocess
import sys

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, os.path.dirname(__file__))
import build_scene  # noqa: E402


def parse(v):
    if v in ("True", "true"):
        return True
    if v in ("False", "false"):
        return False
    try:
        return int(v)
    except ValueError:
        try:
            return float(v)
        except ValueError:
            return v


def capture(out, t, kw, inputs="", size="1280x720", fps=60, extra=()):
    stem = "_cap_" + os.path.splitext(os.path.basename(out))[0]
    scene = os.path.join(ROOT, "scenes", stem + ".scene.toml")
    with open(scene, "w", newline="\n", encoding="utf-8") as f:
        f.write(build_scene.build(**kw))
    inp = os.path.join(ROOT, "scenes", stem + ".txt")
    with open(inp, "w", newline="\n") as f:
        f.write("\n".join(s.strip() for s in inputs.split(";")) + "\n")
    w, h = size.split("x")
    cmd = [os.path.join(ROOT, "engine", "target", "release", "flint-player.exe"), scene,
           "--schemas", "engine/schemas", "--schemas", "schemas", "--no-activate",
           "--width", w, "--height", h, "--pixels-per-point", "1", "--frame-step", repr(1.0 / fps),
           "--screenshot", out, "--screenshot-at", str(t), "--exit-after", str(t + 0.2),
           "--music-volume", "0", "--sfx-volume", "0", "--input-script", inp, *extra]
    env = dict(os.environ, RUST_LOG="warn,script=info")
    p = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True, encoding="utf-8", errors="replace")
    os.remove(scene)
    os.remove(inp)
    lines = [l for l in (p.stdout + p.stderr).splitlines()
             if ("script" in l or "ERROR" in l or "perf]" in l) and " TM " not in l and "Loaded:" not in l]
    return lines


if __name__ == "__main__":
    a = sys.argv[1:]
    opts = {"--inputs": "", "--size": "1280x720", "--fps": "60"}
    for k in list(opts):
        if k in a:
            i = a.index(k)
            opts[k] = a[i + 1]
            del a[i:i + 2]
    kw = {k: parse(v) for k, v in (x.split("=", 1) for x in a[2:])}
    for line in capture(a[0], float(a[1]), kw, opts["--inputs"], opts["--size"], int(opts["--fps"])):
        print(line[-200:])
