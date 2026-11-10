# AFTERGLOW

*Working name: Kandinski, which the folder, repo and code keep.*

**Outrun the dark.** A high-speed drive in the line of Rad Racer and
OutRun, built on the [Flint](https://github.com/chrischaps/Flint) engine.

The world is drawn the way the old vector arcades and the "outrun" posters
remembered it: a dark plane ruled with neon, a banded sun on the horizon,
scenery set in glowing glyphs. A new land arrives from the horizon: tiles take
its colours as they come round, so you drive *into* it.

## Three ways to drive

| | |
|---|---|
| **ARCADE** | The original run: seventy seconds, five stages, each checkpoint buys more time, the fifth is the goal. About five minutes. |
| **GRAND TOUR** | Fifteen events in five legs, each with a bronze, a silver and a gold to win. Medals open the next event, the next leg, HORIZON and new paint. About fifty minutes of road at a bronze pace, before retries. |
| **HORIZON** | A road that does not end: the eight lands in turn, each section a little harder and busier than the last. No clock; the run is over at the third crash. Opens when leg 1 is cleared. |

### The GRAND TOUR

Five kinds of event, all on the same road:

| | The rule | The medal |
|---|---|---|
| **SPRINT** | a clock, gates that extend it, a goal | seconds left at the goal |
| **RACE** | a standing start behind five rivals (GELB, ROT, BLAU, GRUN, WEISS) | 3rd, 2nd, 1st |
| **DRIFT** | a fixed time on a road of bends | drift points banked |
| **RUSH** | heavy traffic, a clock, a distance | close passes (and no medal past the crash limit) |
| **ENDURANCE** | eight lands on one road, gates that extend the clock | the score at the goal |

| Leg | Events | Lands |
|---|---|---|
| 1 **COASTLINE** | FIRST LIGHT (sprint) · SHORE RUN (race) · PALM SLALOM (drift) | Sunset Coast, Moonlit Shore |
| 2 **CITY LIMITS** | RUSH HOUR (rush) · UNDERPASS (sprint) · BOULEVARD CUP (race) | Neon City, Ultraviolet |
| 3 **HIGH COUNTRY** | SWITCHBACK (drift) · RIDGE RACE (race) · NORTHERN LINE (sprint) | Pine Ridge, Aurora Plain |
| 4 **ABSTRACTION** | POINT AND LINE (rush) · YELLOW RED BLUE (drift) · SEVERAL CIRCLES (race) | Composition, Ultraviolet, Aurora Plain |
| 5 **HORIZON** | LAST EXIT (rush) · GRAND FINAL (race) · POINT AND LINE TO HORIZON (endurance) | all eight |

**Unlocks.** A leg opens when the leg before it has a medal in its finale. A
leg's first two events open with the leg; its finale needs a medal in both.
HORIZON opens when leg 1 is cleared. Paint: COBALT at 4 medals, VIRIDIAN at 8,
CHROME YELLOW at 12 (chosen on the tour screen's bottom row).

**Rivals** draft like traffic does: tuck in behind one to fill the boost
meter, then pull out and use it. They are held lightly to you (3% of pace
either way once 300 m apart), so a bad start is not the end of the race.

### The eight lands

| | |
|---|---|
| **Sunset Coast** | palms, a magenta grid, the striped sun |
| **Neon City** | a skyline in blue type under a cold moon |
| **Pine Ridge** | hills that hide the road, teal wire mountains |
| **Composition** | Kandinsky's circle, triangle and square beside the road; the sun is concentric rings |
| **Daybreak** | the sky lightens and the sun climbs toward the goal |
| **Moonlit Shore** | palms on the land side only, open water on the other, a full pale moon |
| **Aurora Plain** | a green band under a violet sky, a few far pines, the biggest crests |
| **Ultraviolet** | a boulevard of palms and lamps under violet towers |

## Play

```
build.bat            # once: builds the engine (engine\target\release)
play.bat             # fullscreen
play_windowed.bat    # 1600 x 900
```

| | Keyboard | Gamepad |
|---|---|---|
| Steer | A D / Left Right | left stick |
| Accelerate | W / Up | RT |
| Brake | S / Down | LT |
| Handbrake | Space | A |
| Boost | Shift | X / RB |
| Menus | arrows / WASD, Enter, Backspace | stick / d-pad, A or Start, B |
| Pause (resume, restart, quit) | P | Back |
| Restart the event (arcade: back to the title) | R | Y |

Escape closes the window (it is the player's key, not the game's).

Leave the road and you slow to a crawl; hit a palm or rear-end traffic at
speed and you spin. A handbrake entry with the wheel held into the bend is a
drift, scored by angle x speed x time and banked when it ends cleanly.
Overtaking close is a **close pass**. Drifts, close passes, slipstreams and
air over a crest all fill the boost meter.

The save is `save/persist.toml` (medals, bests, paint, the arcade and HORIZON
high scores); delete it to start again.

## How it works

- **The road is a treadmill.** The car stays at the origin; `scripts/drive.rhai`
  lays 64 pooled road tiles ahead of it every frame from per-segment curve and
  height arrays, exactly as a scanline racer lays out its strips. Curves shear
  each tile sideways (Flint has no shear, so a tile is two entities: the SVD of
  the shear), hills pitch it.
- **Every road is generated.** One generator turns a seed and a list of
  sections (land, length, how hard the bends, how high the hills) into a road.
  The arcade run, the fifteen events and HORIZON's unending road are all rows
  of numbers in `scripts/lib/tour.rhai`.
- **The clocks and targets are measured, not guessed.** `python
  tools/tour_check.py --calibrate` drives every event with the autopilot at two
  skills and writes each event's clock and medal targets from what it did
  (`scripts/lib/tour_cal.rhai`); without `--calibrate` it is the regression
  test: every event must reach its results screen.
- **Nothing is lit.** A flat ambient of 3 makes a material's colour its
  radiance, so `set_material_override` recolours neon at runtime and bloom does
  the rest.
- **The sky is a shader.** `styles/horizon.*` is a Flint user style at the HDR
  stage that paints the gradient, stars, horizon band and the sun, and feeds
  bloom. A land is a row of its numbers. `styles/crt.*` adds the glass.
- **Scenery is type.** Palms, pines, towers and mountains carry Flint's
  per-entity ASCII style with edge glyphs; `display_bloom` makes them tubes.
- **Everything else is generated**: models by `tools/gen_models.py` and
  `tools/gen_tiles.py`, sound and music by `tools/gen_audio.py` (numpy, no
  samples), the scene by `tools/build_scene.py`.

See `CLAUDE.md` for the layout, how to add an event or a land, and the things
that bite.

## Credits

Fonts: Monoton (Vernon Adams), Audiowide (Astigmatic), Share Tech Mono
(Carrois Apostrophe), all SIL Open Font License; see `fonts/OFL-*.txt`.
