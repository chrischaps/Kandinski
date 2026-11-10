# KANDINSKI

**Point and line to horizon.** A high-speed drive through five stages, in the
line of Rad Racer and OutRun, built on the [Flint](https://github.com/chrischaps/Flint)
engine.

You have seventy seconds and a road. Each checkpoint buys more time; the fifth
is the goal. The world is drawn the way the old vector arcades and the
"outrun" posters remembered it: a dark plane ruled with neon, a banded sun on
the horizon, scenery set in glowing glyphs.

| Stage | | |
|---|---|---|
| 1 | **Sunset Coast** | palms, a magenta grid, the striped sun |
| 2 | **Neon City** | a skyline in blue type under a cold moon |
| 3 | **Pine Ridge** | hills that hide the road, teal wire mountains |
| 4 | **Composition** | Kandinsky's circle, triangle and square beside the road; the sun is concentric rings |
| 5 | **Daybreak** | the sky lightens and the sun climbs toward the goal |

A new stage arrives from the horizon: tiles take the next stage's colours as
they come round, so you drive *into* it.

## Play

```
build.bat            # once: builds the engine (engine\target\release)
play.bat             # fullscreen
play_windowed.bat    # 1600 x 900
```

| | Keyboard | Gamepad |
|---|---|---|
| Steer | A D / Left Right | left stick |
| Accelerate | W / Up | RT or A |
| Brake | S / Down | LT or X |
| Start | Enter / Space | Start |
| Pause | P | Back |
| Back to title | R | Y |

Leave the road and you slow to a crawl; hit a palm or rear-end traffic at
speed and you spin. Overtaking close earns a **close pass** bonus.

## How it works

- **The road is a treadmill.** The car stays at the origin; `scripts/drive.rhai`
  lays 64 pooled road tiles ahead of it every frame from per-segment curve and
  height arrays, exactly as a scanline racer lays out its strips. Curves shear
  each tile sideways (Flint has no shear, so a tile is two entities: the SVD of
  the shear), hills pitch it.
- **Nothing is lit.** A flat ambient of 3 makes a material's colour its
  radiance, so `set_material_override` recolours neon at runtime and bloom does
  the rest.
- **The sky is a shader.** `styles/horizon.*` is a Flint user style at the HDR
  stage that paints the gradient, stars, horizon band and the sun, and feeds
  bloom. `styles/crt.*` adds the glass.
- **Scenery is type.** Palms, pines, towers and mountains carry Flint's
  per-entity ASCII style with edge glyphs; `display_bloom` makes them tubes.
- **Everything else is generated**: models by `tools/gen_models.py` and
  `tools/gen_tiles.py`, sound and music by `tools/gen_audio.py` (numpy, no
  samples), the scene by `tools/build_scene.py`.

See `CLAUDE.md` for the layout and the things that bite.

## Credits

Fonts: Monoton (Vernon Adams), Audiowide (Astigmatic), Share Tech Mono
(Carrois Apostrophe), all SIL Open Font License; see `fonts/OFL-*.txt`.
