#!/usr/bin/env bash
# tools/shot.sh <scene-stem> <seconds> <out.png> [extra flint-player flags]
# One deterministic frame of the running game (scripts, HUD and all).
# --frame-step and --pixels-per-point have defaults here that a flag of your
# own replaces (the player refuses a flag given twice).
cd "$(dirname "$0")/.."
scene=$1; t=$2; out=$3; shift 3
end=$(python -c "print($t + 0.2)")
ppp="--pixels-per-point 1"; step="--frame-step 0.0166667"
for a in "$@"; do
  case $a in
    --pixels-per-point*) ppp="";;
    --frame-step*) step="";;
  esac
done
RUST_LOG=warn,script=info engine/target/release/flint-player.exe scenes/$scene.scene.toml \
  --schemas engine/schemas --schemas schemas --no-activate $step $ppp \
  --screenshot "$out" --screenshot-at "$t" --exit-after "$end" \
  --music-volume 0 --sfx-volume 0 "$@" 2>&1 | grep -E "script|ERROR|error|perf\] avg" | grep -v "Loaded:\| TM " | sort | uniq -c | head -20
