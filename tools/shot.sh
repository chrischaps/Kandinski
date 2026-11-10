#!/usr/bin/env bash
# tools/shot.sh <scene-stem> <seconds> <out.png> [extra flint-player flags]
# One deterministic frame of the running game (scripts, HUD and all).
cd "$(dirname "$0")/.."
scene=$1; t=$2; out=$3; shift 3
end=$(python -c "print($t + 0.2)")
RUST_LOG=warn,script=info engine/target/release/flint-player.exe scenes/$scene.scene.toml \
  --schemas engine/schemas --schemas schemas --no-activate --frame-step 0.0166667 \
  --screenshot "$out" --screenshot-at "$t" --exit-after "$end" --pixels-per-point 1 \
  --music-volume 0 --sfx-volume 0 "$@" 2>&1 | grep -E "script|ERROR|error|perf\] avg" | grep -v "Loaded:" | sort | uniq -c | head -20
