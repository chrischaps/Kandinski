"""Road tiles: one 8 m slice of the world, road + shoulders + neon ground grid.

The road script shears each tile sideways (curves) and pitches it (hills), so a
tile is authored flat: origin at the centre of its near edge, running toward -Z.
Every part is a NAMED material that the script recolours per stage with
set_material_override, and nothing is emissive: the scene is lit by a flat
ambient well above 1, so a material's colour IS its radiance.

  tile_a / tile_b   alternate along the road (shoulder bands and lane dashes
                    strobe past, the oldest speed cue in the genre)
"""
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))
from glb import Model

L = 8.0          # tile length (m)  -- scripts/road.rhai SEG_LEN
OVER = 0.06      # overlap so pitched tiles never show a seam
ROAD = 6.0       # road half width: three 4 m lanes
SHOULDER = 1.2
W = 248.0        # ground half width
GRID = 8.0       # grid pitch
LINE = 0.16


def strip(m, mat, x0, x1, z0, z1, y):
    m.quad(mat, [(x0, y, z0), (x1, y, z0), (x1, y, z1), (x0, y, z1)])


def tile(variant):
    m = Model()
    m.material("ground", (0.010, 0.004, 0.022))
    m.material("road", (0.022, 0.016, 0.040), roughness=0.55)
    m.material("shoulder", (0.9, 0.9, 0.9))
    m.material("edge", (1.0, 1.0, 1.0))
    m.material("lane", (1.0, 1.0, 1.0))
    m.material("grid", (1.0, 1.0, 1.0))
    z1 = -(L + OVER)
    # ground, both sides, under everything
    strip(m, "ground", -W, -ROAD - SHOULDER, 0, z1, -0.03)
    strip(m, "ground", ROAD + SHOULDER, W, 0, z1, -0.03)
    strip(m, "road", -ROAD - SHOULDER, ROAD + SHOULDER, 0, z1, 0.0)
    # shoulder band: lit on one variant, a thin pair of pips on the other
    for s in (-1, 1):
        a, b = sorted((s * (ROAD + 0.25), s * (ROAD + SHOULDER - 0.1)))
        if variant == "a":
            strip(m, "shoulder", a, b, 0, z1, 0.012)
        # solid neon edge line
        a, b = sorted((s * (ROAD - 0.02), s * (ROAD + 0.2)))
        strip(m, "edge", a, b, 0, z1, 0.014)
        # outer rail line where shoulder meets the grid
        a, b = sorted((s * (ROAD + SHOULDER - 0.05), s * (ROAD + SHOULDER + 0.12)))
        strip(m, "grid", a, b, 0, z1, 0.014)
    # lane dashes: 4 m on, 4 m off; both variants so they flow evenly
    for x in (-2.0, 2.0):
        strip(m, "lane", x - 0.09, x + 0.09, -0.5, -4.5, 0.014)
    # grid: lines running with the road...
    x = 16.0
    while x <= W:
        for s in (-1, 1):
            strip(m, "grid", s * x - LINE / 2, s * x + LINE / 2, 0, z1, 0.0)
        x += GRID
    # ...and one across it per tile
    strip(m, "grid", -W, -ROAD - SHOULDER, 0, -LINE, 0.0)
    strip(m, "grid", ROAD + SHOULDER, W, 0, -LINE, 0.0)
    return m


if __name__ == "__main__":
    out = os.path.join(os.path.dirname(__file__), "..", "models")
    for v in ("a", "b"):
        t = tile(v)
        p = t.save(os.path.join(out, f"tile_{v}.glb"))
        print(os.path.normpath(p), t.tri_count(), "tris")
