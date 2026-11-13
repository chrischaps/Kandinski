"""A short film of the pulse with its music, to judge it away from the game.

    python tools/pulse_film.py <out.mp4> <stage 0-4> <from s> <seconds> [pulse=1.0] [key=value ...]

The game is stepped at 1/60 s (`--frame-step`), so the script's music clock
is exactly the game time, and a frame is written every 1/30 s. ffmpeg then
lays audio/music_drive.ogg under the frames from the same game time, held
back by drive.rhai's PULSE_LAG (the picture waits that long for a sound
card). Picture and sound are in step by construction here; in the running
game they are two clocks (see CLAUDE.md, "The pulse"). No engine, tyres or
effects are in the sound: only the music.

Frames go to snapshots/pulse/film_<name>/ and are removed after the encode.
"""
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(__file__))
import build_scene  # noqa: E402
from capture import parse  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(__file__), ".."))
PULSE_LAG = 0.03
LOOP = 6272000 / 44100.0     # music_drive's length, s


def film(out, stage, t0, secs, kw):
    name = os.path.splitext(os.path.basename(out))[0]
    frames = os.path.join(ROOT, "snapshots", "pulse", f"film_{name}")
    shutil.rmtree(frames, ignore_errors=True)
    os.makedirs(frames)
    scene = os.path.join(ROOT, "scenes", f"_film_{name}.scene.toml")
    with open(scene, "w", newline="\n", encoding="utf-8") as f:
        f.write(build_scene.build(autopilot=True, start_stage=stage, start_speed=70.0, **kw))
    cmd = [os.path.join(ROOT, "engine", "target", "release", "flint-player.exe"), scene,
           "--schemas", "engine/schemas", "--schemas", "schemas", "--no-activate",
           "--pixels-per-point", "1", "--frame-step", repr(1.0 / 60.0),
           "--screenshot", os.path.join(frames, "f.png"), "--screenshot-at", repr(t0),
           "--screenshot-every", repr(1.0 / 30.0), "--exit-after", repr(t0 + secs + 0.05),
           "--music-volume", "0", "--sfx-volume", "0"]
    p = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True, encoding="utf-8", errors="replace",
                       env=dict(os.environ, RUST_LOG="warn,script=info"))
    os.remove(scene)
    for line in (p.stdout + p.stderr).splitlines():
        if "ERROR" in line or "rror:" in line:
            print(line[-200:])
    n = len([f for f in os.listdir(frames) if f.endswith(".png")])
    first = sorted(os.listdir(frames))[0]
    start = int(first.split("_")[1].split(".")[0])
    a0 = (t0 - PULSE_LAG) % LOOP
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-framerate", "30", "-start_number", str(start),
                    "-i", os.path.join(frames, "f_%04d.png"),
                    "-stream_loop", "-1", "-ss", repr(a0), "-i", os.path.join(ROOT, "audio", "music_drive.ogg"),
                    "-t", repr(n / 30.0), "-c:v", "libx264", "-pix_fmt", "yuv420p", "-crf", "21", "-preset", "slow",
                    "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", out], check=True)
    shutil.rmtree(frames, ignore_errors=True)
    print(f"{out}: {n} frames, {n / 30.0:.2f} s from game time {t0}, {os.path.getsize(out) / 1e6:.1f} MB")


if __name__ == "__main__":
    a = sys.argv[1:]
    film(os.path.abspath(a[0]), int(a[1]), float(a[2]), float(a[3]),
         {k: parse(v) for k, v in (x.split("=", 1) for x in a[4:])})
