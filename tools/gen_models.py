"""Generate every Kandinski prop model into models/*.glb.

    python tools/gen_models.py            # all models
    python tools/gen_models.py palm gate  # only some

Conventions: Y up, metres, forward is -Z, +X is right, origin at ground level in
the centre of the footprint. One node / one mesh / one primitive per named
material (see glb.py) - the material names are a contract with the game, which
recolours parts at runtime with set_material_override().

The world is lit flat (ambient 3.0, no sun): linear base colour x 3 = radiance.
Dark silhouettes sit around 0.004-0.05, neon lines around 0.6-1.0.
"""
import math
import os
import random
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glb import Model  # noqa: E402

OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models"))


# ---------------------------------------------------------------- helpers
def V(p):
    return np.array(p, float)


def unit(v):
    v = V(v)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def face(m, mat, pts, n, lift=0.0):
    """Convex polygon wound so it faces n, optionally lifted along n."""
    n = unit(n)
    pts = [V(p) + n * lift for p in pts]
    if np.dot(np.cross(pts[1] - pts[0], pts[2] - pts[0]), n) < 0:
        pts = pts[::-1]
    m.poly(mat, [tuple(p) for p in pts])


def both_sides(m, *mats):
    """Mark the given materials glTF doubleSided: thin cards are one layer of
    triangles that Flint draws from both sides (#623)."""
    for mat in mats:
        m._mats[mat]["double_sided"] = True
    return m


def tube(m, mat, a, b, r, sides=4):
    """A thin open-ended prism along a->b: a neon line visible from any side."""
    m.cylinder(mat, a, b, r, sides=sides, caps=False)


def polyline(m, mat, pts, r, sides=4, closed=False):
    n = len(pts)
    for i in range(n if closed else n - 1):
        tube(m, mat, pts[i], pts[(i + 1) % n], r, sides)


def disc(m, mat, c, n, r, sides=8, r_in=0.0):
    """A flat disc (or annulus if r_in > 0) centred on c facing n."""
    c = V(c); w = unit(n)
    ref = V([0, 1, 0]) if abs(w[1]) < 0.9 else V([1, 0, 0])
    u = unit(np.cross(ref, w)); v = np.cross(w, u)
    ring = lambda rr: [c + rr * (math.cos(t) * u + math.sin(t) * v)
                       for t in (2 * math.pi * i / sides for i in range(sides))]
    if r_in <= 0:
        m.poly(mat, [tuple(p) for p in ring(r)])
    else:
        ro, ri = ring(r), ring(r_in)
        for i in range(sides):
            j = (i + 1) % sides
            m.quad(mat, [tuple(ri[i]), tuple(ro[i]), tuple(ro[j]), tuple(ri[j])])


def earclip(poly):
    """Triangulate a simple 2D polygon; returns index triples, math-CCW."""
    n = len(poly)
    area = sum(poly[i][0] * poly[(i + 1) % n][1] - poly[(i + 1) % n][0] * poly[i][1] for i in range(n))
    idx = list(range(n)) if area > 0 else list(range(n - 1, -1, -1))
    cross = lambda o, a, b: (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    out = []
    guard = 0
    while len(idx) > 3 and guard < 10000:
        guard += 1
        for k in range(len(idx)):
            i0, i1, i2 = idx[k - 1], idx[k], idx[(k + 1) % len(idx)]
            a, b, c = poly[i0], poly[i1], poly[i2]
            if cross(a, b, c) <= 1e-12:
                continue
            if any(cross(a, b, poly[j]) > 1e-12 and cross(b, c, poly[j]) > 1e-12 and cross(c, a, poly[j]) > 1e-12
                   for j in idx if j not in (i0, i1, i2)):
                continue
            out.append((i0, i1, i2))
            idx.pop(k)
            break
        else:
            break
    if len(idx) == 3:
        out.append(tuple(idx))
    return out


def loft(m, pts, seg_mats, side_mat):
    """A body from a closed side profile [(z, y, half_width), ...].

    Each profile edge becomes a quad spanning -w..+w (material seg_mats[i], or
    None to leave it open); the two sides are capped with side_mat.
    """
    n = len(pts)
    area = sum(pts[i][0] * pts[(i + 1) % n][1] - pts[(i + 1) % n][0] * pts[i][1] for i in range(n))
    for i in range(n):
        mat = seg_mats[i]
        if mat is None:
            continue
        (za, ya, wa), (zb, yb, wb) = pts[i], pts[(i + 1) % n]
        dz, dy = zb - za, yb - ya
        nz, ny = (dy, -dz) if area > 0 else (-dy, dz)
        face(m, mat, [(-wa, ya, za), (wa, ya, za), (wb, yb, zb), (-wb, yb, zb)], (0, ny, nz))
    if side_mat:
        for i, j, k in earclip([(p[0], p[1]) for p in pts]):
            P = lambda q, s: (s * pts[q][2], pts[q][1], pts[q][0])
            m.tri(side_mat, P(i, 1), P(k, 1), P(j, 1))
            m.tri(side_mat, P(i, -1), P(j, -1), P(k, -1))


def side_line(m, mat, pts, r=0.022, out=0.008, sides=3):
    """Neon line along profile points (z, y, w) on both flanks."""
    for s in (1, -1):
        polyline(m, mat, [(s * (w + out), y, z) for z, y, w in pts], r, sides)


def wheel(m, x_out, z, r, width, sides=10):
    for s in (1, -1):
        m.cylinder("wheel", (s * (x_out - width), r, z), (s * x_out, r, z), r, sides=sides)
        disc(m, "rim", (s * (x_out + 0.012), r, z), (s, 0, 0), r * 0.42, sides=8)


def arch(m, x, z, r, y, band=0.05, segs=6):
    """A neon wheel-arch arc on both flanks."""
    for s in (1, -1):
        for i in range(segs):
            a0 = math.pi * i / segs
            a1 = math.pi * (i + 1) / segs
            p = lambda a, rr: (s * x, y + rr * math.sin(a), z + rr * math.cos(a))
            face(m, "trim", [p(a0, r), p(a0, r + band), p(a1, r + band), p(a1, r)], (s, 0, 0))


def car_materials(m, body, trim=(1.0, 0.45, 0.8), tail=(1.0, 0.05, 0.08)):
    m.material("body", body)
    m.material("glass", (0.004, 0.012, 0.035))
    m.material("trim", trim)
    m.material("tail", tail)
    m.material("head", (1.0, 0.95, 0.7))
    m.material("wheel", (0.006, 0.006, 0.008))
    m.material("rim", (0.55, 0.55, 0.65))


# ---------------------------------------------------------------- cars
def car_player():
    m = Model()
    car_materials(m, (0.07, 0.006, 0.022))
    m.material("under", (0.35, 0.02, 0.25))
    W = 0.93
    # lower body: a wedge, low nose (-Z) rising to a high tail (+Z)
    body = [
        (2.14, 0.20, W), (2.20, 0.44, W), (2.20, 0.82, W), (0.90, 0.84, W),
        (-0.70, 0.70, W), (-2.00, 0.42, W), (-2.20, 0.37, 0.84), (-2.20, 0.19, 0.84),
    ]
    loft(m, body, ["body"] * len(body), "body")
    # cabin: narrower and tapered, set forward (mid-engine)
    cab = [(1.00, 0.83, 0.84), (0.42, 1.10, 0.60), (-0.20, 1.10, 0.60), (-1.05, 0.66, 0.82)]
    loft(m, cab, ["glass", "body", "glass", None], "glass")
    # rear wing on two end plates
    m.box("body", (-0.95, 1.13, 1.80), (0.95, 1.17, 2.24))
    for s in (1, -1):
        m.box("body", (s * 0.80 - 0.03, 0.82, 1.86), (s * 0.80 + 0.03, 1.13, 2.16), faces="xXzZ")
    # engine-deck louvres
    for i in range(4):
        z0 = 1.08 + i * 0.17
        face(m, "glass", [(-0.52, 0.84, z0), (0.52, 0.84, z0), (0.52, 0.84, z0 + 0.09), (-0.52, 0.84, z0 + 0.09)],
             (0, 1, 0), 0.012)
    # --- lights
    face(m, "glass", [(-0.89, 0.50, 2.2), (0.89, 0.50, 2.2), (0.89, 0.76, 2.2), (-0.89, 0.76, 2.2)], (0, 0, 1), 0.008)
    face(m, "tail", [(-0.86, 0.56, 2.2), (0.86, 0.56, 2.2), (0.86, 0.70, 2.2), (-0.86, 0.70, 2.2)], (0, 0, 1), 0.018)
    for s in (1, -1):
        face(m, "head", [(s * 0.34, 0.25, -2.2), (s * 0.76, 0.25, -2.2), (s * 0.76, 0.34, -2.2), (s * 0.34, 0.34, -2.2)],
             (0, 0, -1), 0.015)
    # --- trim: beltline, sill, rear outline, roof outline, wing edge, arches
    side_line(m, "trim", [body[2], body[3], body[4], body[5], body[6]])
    side_line(m, "trim", [body[0], body[7]], r=0.018)
    polyline(m, "trim", [(-W, 0.44, 2.21), (W, 0.44, 2.21), (W, 0.82, 2.21), (-W, 0.82, 2.21)], 0.022, 3, closed=True)
    roof = [(-0.60, 1.105, 0.42), (0.60, 1.105, 0.42), (0.60, 1.105, -0.20), (-0.60, 1.105, -0.20)]
    polyline(m, "trim", roof, 0.018, 3, closed=True)
    for s in (1, -1):
        tube(m, "trim", (s * 0.84, 0.835, 1.00), (s * 0.60, 1.105, 0.42), 0.018, 3)
        tube(m, "trim", (s * 0.82, 0.665, -1.05), (s * 0.60, 1.105, -0.20), 0.018, 3)
    polyline(m, "trim", [(-0.95, 1.175, 1.80), (-0.95, 1.175, 2.24), (0.95, 1.175, 2.24), (0.95, 1.175, 1.80)], 0.02, 3)
    wheel(m, 0.965, -1.38, 0.32, 0.26)
    wheel(m, 0.975, 1.32, 0.34, 0.32)
    arch(m, W + 0.012, -1.38, 0.37, 0.30)
    arch(m, W + 0.012, 1.32, 0.39, 0.32)
    # underglow: a pool of light on the road
    ux, uz, c = 1.2, 2.5, 0.45
    m.poly("under", [(-ux + c, 0.02, uz), (ux - c, 0.02, uz), (ux, 0.02, uz - c), (ux, 0.02, -uz + c),
                     (ux - c, 0.02, -uz), (-ux + c, 0.02, -uz), (-ux, 0.02, -uz + c), (-ux, 0.02, uz - c)])
    return m


def car_traffic_a():
    m = Model()
    car_materials(m, (0.005, 0.013, 0.045), trim=(0.3, 0.85, 1.0))
    W = 0.83
    body = [
        (1.96, 0.24, W), (2.00, 0.45, W), (2.00, 0.88, W), (-0.75, 0.86, W),
        (-1.92, 0.70, 0.80), (-2.00, 0.60, 0.78), (-2.00, 0.24, 0.78),
    ]
    loft(m, body, ["body"] * len(body), "body")
    cab = [(1.96, 0.87, 0.80), (1.40, 1.30, 0.66), (-0.15, 1.30, 0.66), (-0.95, 0.85, 0.80)]
    loft(m, cab, ["glass", "body", "glass", None], "glass")
    # two distinct tail lights + dark plate recess between them
    for s in (1, -1):
        face(m, "tail", [(s * 0.36, 0.56, 2.0), (s * 0.78, 0.56, 2.0), (s * 0.78, 0.80, 2.0), (s * 0.36, 0.80, 2.0)],
             (0, 0, 1), 0.015)
        face(m, "head", [(s * 0.36, 0.48, -2.0), (s * 0.72, 0.48, -2.0), (s * 0.72, 0.60, -2.0), (s * 0.36, 0.60, -2.0)],
             (0, 0, -1), 0.015)
    side_line(m, "trim", [body[2], body[3], body[4], body[5]])
    polyline(m, "trim", [(-W, 0.45, 2.01), (W, 0.45, 2.01), (W, 0.88, 2.01), (-W, 0.88, 2.01)], 0.02, 3, closed=True)
    polyline(m, "trim", [(-0.80, 0.875, 1.97), (-0.66, 1.305, 1.40), (0.66, 1.305, 1.40), (0.80, 0.875, 1.97)], 0.018, 3)
    polyline(m, "trim", [(-0.80, 0.855, -0.95), (-0.66, 1.305, -0.15), (0.66, 1.305, -0.15), (0.80, 0.855, -0.95)], 0.018, 3)
    for s in (1, -1):
        tube(m, "trim", (s * 0.66, 1.305, 1.40), (s * 0.66, 1.305, -0.15), 0.018, 3)
    wheel(m, 0.86, -1.25, 0.31, 0.24)
    wheel(m, 0.86, 1.25, 0.31, 0.24)
    return m


def car_traffic_b():
    m = Model()
    car_materials(m, (0.016, 0.014, 0.006), trim=(1.0, 0.7, 0.15))
    W = 1.0
    body = [
        (2.56, 0.32, W), (2.60, 0.50, W), (2.60, 2.30, W), (-1.75, 2.30, W),
        (-2.40, 1.32, W), (-2.60, 1.18, W), (-2.60, 0.32, W),
    ]
    loft(m, body, ["body", "body", "body", "glass", "body", "body", "body"], "body")
    for s in (1, -1):
        # cab side window, following the windscreen rake
        face(m, "glass", [(s * W, 1.36, -2.26), (s * W, 1.36, -1.35), (s * W, 2.05, -1.35), (s * W, 2.05, -1.80)],
             (s, 0, 0), 0.012)
        # tall tail-light stacks
        face(m, "tail", [(s * 0.62, 0.62, 2.6), (s * 0.90, 0.62, 2.6), (s * 0.90, 1.18, 2.6), (s * 0.62, 1.18, 2.6)],
             (0, 0, 1), 0.015)
        face(m, "tail", [(s * 0.62, 2.02, 2.6), (s * 0.90, 2.02, 2.6), (s * 0.90, 2.14, 2.6), (s * 0.62, 2.14, 2.6)],
             (0, 0, 1), 0.015)
        face(m, "head", [(s * 0.50, 0.72, -2.6), (s * 0.90, 0.72, -2.6), (s * 0.90, 0.92, -2.6), (s * 0.50, 0.92, -2.6)],
             (0, 0, -1), 0.015)
        # side stripe
        face(m, "trim", [(s * W, 1.12, 2.55), (s * W, 1.12, -2.45), (s * W, 1.20, -2.45), (s * W, 1.20, 2.55)],
             (s, 0, 0), 0.012)
    # rear outline, door split, roof edges
    polyline(m, "trim", [(-W, 0.50, 2.61), (W, 0.50, 2.61), (W, 2.30, 2.61), (-W, 2.30, 2.61)], 0.028, 3, closed=True)
    face(m, "trim", [(-0.02, 0.52, 2.6), (0.02, 0.52, 2.6), (0.02, 2.28, 2.6), (-0.02, 2.28, 2.6)], (0, 0, 1), 0.012)
    side_line(m, "trim", [body[2], body[3], body[4], body[5]], r=0.025)
    tube(m, "trim", (-W, 2.305, -1.75), (W, 2.305, -1.75), 0.022, 3)
    wheel(m, 1.03, -1.75, 0.38, 0.28)
    wheel(m, 1.03, 1.55, 0.38, 0.28)
    return m


# ---------------------------------------------------------------- roadside
def palm():
    m = Model()
    m.material("trunk", (0.016, 0.007, 0.016))
    # Fronds are a dark silhouette; the script sets `trim` to the land's accent
    # (drive.rhai, with the mountains' wire), so a palm belongs to its sky.
    m.material("frond", (0.006, 0.003, 0.011), double_sided=True)
    m.material("trim", (0.7, 0.12, 0.45))
    rng = random.Random(7)
    H = 8.2
    spine = lambda t: V([-1.1 * t * t + 0.25 * math.sin(t * 3.0), H * t, 0.35 * math.sin(t * 2.2)])
    N = 6
    for i in range(N):
        t0, t1 = i / N, (i + 1) / N
        r0, r1 = 0.26 - 0.12 * t0, 0.26 - 0.12 * t1
        m.cylinder("trunk", spine(t0), spine(t1), r0, r1, sides=5, caps=(i == N - 1))
        if i < N - 1:                                   # bright ring at each joint
            a = spine(t1)
            m.cylinder("trim", a, a + unit(spine(t1 + 0.01) - a) * 0.07, r1 + 0.025, sides=5, caps=False)
    crown = spine(1.0)
    up = V([0, 1, 0])
    nf, segs = 9, 4
    for k in range(nf):
        ang = 2 * math.pi * k / nf + rng.uniform(-0.12, 0.12)
        d = V([math.cos(ang), 0, math.sin(ang)])
        t = np.cross(d, up)
        high = k % 2 == 0                               # alternate: arching up / hanging low
        L = rng.uniform(3.7, 4.2) if high else rng.uniform(4.0, 4.6)
        rise = rng.uniform(1.25, 1.5) if high else rng.uniform(0.55, 0.8)
        drop = 2.1 if high else 2.6
        rib, left, right = [], [], []
        for j in range(segs + 1):
            s = j / segs
            p = crown + d * (L * (s - 0.22 * s ** 3)) + up * (rise * 2 * s - (rise + drop) * s * s + 0.1)
            hw = 0.6 * math.sin(math.pi * (0.2 + 0.8 * s)) ** 0.7 if s < 1 else 0.0
            rib.append(p)
            left.append(p + t * hw - up * hw * 0.7)
            right.append(p - t * hw - up * hw * 0.7)
        for j in range(segs):
            m.quad("frond", [tuple(rib[j]), tuple(left[j]), tuple(left[j + 1]), tuple(rib[j + 1])])
            m.quad("frond", [tuple(rib[j]), tuple(rib[j + 1]), tuple(right[j + 1]), tuple(right[j])])
            if j:                                       # the first span is buried in the crown
                tube(m, "trim", rib[j] + up * 0.03, rib[j + 1] + up * 0.03, 0.05 - 0.007 * j, 3)
    return both_sides(m, "frond")


def pine():
    m = Model()
    m.material("trunk", (0.014, 0.007, 0.006))
    m.material("needles", (0.003, 0.013, 0.011))
    m.material("trim", (0.3, 1.0, 0.85))
    m.cylinder("trunk", (0, 0, 0), (0, 2.4, 0), 0.32, 0.26, sides=6, caps=False)
    tiers = [(1.8, 5.6, 3.0), (4.1, 7.7, 2.4), (6.3, 9.5, 1.8), (8.3, 11.0, 1.2)]
    S = 8
    for n, (y0, y1, r) in enumerate(tiers):
        rot = n * math.pi / S
        ring = [(r * math.cos(rot + 2 * math.pi * i / S), y0, -r * math.sin(rot + 2 * math.pi * i / S)) for i in range(S)]
        for i in range(S):
            m.tri("needles", ring[i], ring[(i + 1) % S], (0, y1, 0))
        m.poly("needles", list(reversed(ring)))
        # bright rim band hugging the base ring
        h = 0.16
        k = 1 - h / (y1 - y0)
        o = 0.03
        for i in range(S):
            a, b = V(ring[i]), V(ring[(i + 1) % S])
            au, bu = V([a[0] * k, y0 + h, a[2] * k]), V([b[0] * k, y0 + h, b[2] * k])
            n_out = unit([a[0] + b[0], r * 0.8, a[2] + b[2]])
            face(m, "trim", [a, b, bu, au], n_out, o)
    return m


def lamp():
    m = Model()
    m.material("pole", (0.02, 0.02, 0.035))
    m.material("lamp", (1.0, 0.85, 0.55))
    m.cylinder("pole", (0, 0, 0), (0, 0.5, 0), 0.16, 0.13, sides=6, caps=False)
    m.cylinder("pole", (0, 0.5, 0), (0, 7.6, 0), 0.10, 0.07, sides=6, caps=False)
    # arm sweeps up and over toward -X (toward the road)
    arm = [(0, 7.6, 0), (-0.35, 8.0, 0), (-1.2, 8.22, 0), (-3.5, 8.3, 0)]
    for a, b in zip(arm, arm[1:]):
        m.cylinder("pole", a, b, 0.07, 0.06, sides=6, caps=(b == arm[-1]))
    # light bar under the end of the arm
    m.box("pole", (-3.5, 8.16, -0.20), (-2.3, 8.24, 0.20), faces="xXYzZ")
    m.box("lamp", (-3.46, 8.07, -0.17), (-2.34, 8.16, 0.17), faces="xXyzZ")
    return m


GATE_INNER = 8.5      # half clear width
GATE_CLEAR = 7.0      # clearance under the beam
GATE_TOP = 9.4


def gate():
    m = Model()
    m.material("frame", (0.015, 0.012, 0.03))
    m.material("neon", (1.0, 0.25, 0.75))
    m.material("banner", (0.10, 0.11, 0.16))
    xi, xo, d = GATE_INNER, GATE_INNER + 1.3, 0.65
    for s in (1, -1):
        lo, hi = (min(s * xi, s * xo), 0, -d), (max(s * xi, s * xo), GATE_TOP, d)
        m.box("frame", lo, hi, faces="xXYzZ")
        for x in (s * xi, s * xo):
            for z in (-d, d):
                tube(m, "neon", (x, 0, z), (x, GATE_TOP, z), 0.07, 4)
        # chevron bands on the pylon faces
        for y in (1.2, 2.0):
            for z, nz in ((d, 1), (-d, -1)):
                face(m, "neon", [(s * xi, y, z), (s * xo, y, z), (s * xo, y + 0.25, z), (s * xi, y + 0.25, z)], (0, 0, nz), 0.015)
    m.box("frame", (-xi, GATE_CLEAR, -0.5), (xi, GATE_TOP, 0.5), faces="yYzZ")
    for z in (-0.5, 0.5):
        for y in (GATE_CLEAR, GATE_TOP):
            tube(m, "neon", (-xi, y, z), (xi, y, z), 0.07, 4)
    for z in (-d, d):
        tube(m, "neon", (-xo, GATE_TOP, z), (xo, GATE_TOP, z), 0.07, 4)
    for z, nz in ((0.5, 1), (-0.5, -1)):
        face(m, "banner", [(-7.5, 7.4, z), (7.5, 7.4, z), (7.5, 9.0, z), (-7.5, 9.0, z)], (0, 0, nz), 0.03)
    return m


def sign():
    m = Model()
    m.material("pole", (0.02, 0.02, 0.035))
    m.material("board", (0.012, 0.008, 0.03))
    m.material("glyph_a", (1.0, 0.75, 0.1))
    m.material("glyph_b", (0.15, 0.6, 1.0))
    m.material("trim", (1.0, 0.3, 0.7))
    y0, y1, hx, hz = 3.5, 6.5, 3.0, 0.1
    for x in (-1.9, 1.9):
        m.cylinder("pole", (x, 0, -0.16), (x, y1 - 0.4, -0.16), 0.13, sides=6, caps=False)
    m.box("board", (-hx, y0, -hz), (hx, y1, hz))
    z = hz
    F = lambda mat, pts, lift=0.02: face(m, mat, [(x, y, z) for x, y in pts], (0, 0, 1), lift)
    # outline
    t = 0.10
    F("trim", [(-hx, y0), (hx, y0), (hx, y0 + t), (-hx, y0 + t)])
    F("trim", [(-hx, y1 - t), (hx, y1 - t), (hx, y1), (-hx, y1)])
    F("trim", [(-hx, y0 + t), (-hx + t, y0 + t), (-hx + t, y1 - t), (-hx, y1 - t)])
    F("trim", [(hx - t, y0 + t), (hx, y0 + t), (hx, y1 - t), (hx - t, y1 - t)])
    # composition: a sun disc, a triangle leaning on it, three bars
    cx, cy, r = -1.35, 5.15, 0.95
    F("glyph_a", [(cx + r * math.cos(2 * math.pi * i / 18), cy + r * math.sin(2 * math.pi * i / 18)) for i in range(18)])
    F("glyph_b", [(-0.75, 3.95), (1.55, 3.95), (0.40, 6.05)], 0.035)
    for i, (w, mat) in enumerate(((1.25, "glyph_a"), (0.95, "glyph_b"), (0.65, "glyph_a"))):
        yb = 4.05 + i * 0.5
        F(mat, [(2.65 - w, yb), (2.65, yb), (2.65, yb + 0.24), (2.65 - w, yb + 0.24)])
    F("glyph_b", [(-2.6, 3.95), (-1.15, 3.95), (-1.15, 4.07), (-2.6, 4.07)], 0.035)
    return m


# ---------------------------------------------------------------- towers
def tower_materials(m, window=(1.0, 0.75, 0.35), cap=(0.2, 0.85, 1.0)):
    m.material("wall", (0.006, 0.006, 0.014))
    # Windows are lamps seen from far off, not floodlights: under the x3 ambient
    # a colour near 1 blooms into one white slab and the skyline outshines the road.
    m.material("window", tuple(c * 0.20 for c in window))
    m.material("cap", tuple(c * 0.45 for c in cap))


def block(m, rng, x0, x1, z0, z1, y0, y1, lit=0.5, pitch=3.2, floor=4.0, ww=1.5, wh=1.9, cap_r=0.16,
          corners=True):
    """A box storey-stack: walls, a seeded grid of lit windows, neon roofline."""
    m.box("wall", (x0, y0, z0), (x1, y1, z1), faces="xXYzZ")
    floors = int((y1 - y0 - 1.0) // floor)
    yb = y0 + (y1 - y0 - floors * floor) / 2 + (floor - wh) / 2

    def wall(a0, a1, mk, n):
        cols = int((a1 - a0 - 1.2) // pitch)
        if cols < 1:
            return
        ab = (a0 + a1) / 2 - cols * pitch / 2 + (pitch - ww) / 2
        for f in range(floors):
            for c in range(cols):
                if rng.random() > lit:
                    continue
                u0, v0 = ab + c * pitch, yb + f * floor
                face(m, "window", [mk(u0, v0), mk(u0 + ww, v0), mk(u0 + ww, v0 + wh), mk(u0, v0 + wh)], n, 0.03)

    wall(x0, x1, lambda u, v: (u, v, z1), (0, 0, 1))
    wall(x0, x1, lambda u, v: (u, v, z0), (0, 0, -1))
    wall(z0, z1, lambda u, v: (x1, v, u), (1, 0, 0))
    wall(z0, z1, lambda u, v: (x0, v, u), (-1, 0, 0))
    polyline(m, "cap", [(x0, y1, z0), (x1, y1, z0), (x1, y1, z1), (x0, y1, z1)], cap_r, 4, closed=True)
    if corners:
        for x in (x0, x1):
            for z in (z0, z1):
                tube(m, "cap", (x, y0, z), (x, y1, z), cap_r * 0.8, 4)


def tower_a():
    """~30 m: a broad slab with an offset penthouse and a rooftop frame."""
    m = Model(); tower_materials(m)
    rng = random.Random(101)
    block(m, rng, -11, 11, -8, 8, 0, 22, lit=0.5)
    block(m, rng, -9, 1, -6, 6, 22, 30, lit=0.6)
    # rooftop billboard frame on the low wing
    polyline(m, "cap", [(3, 22, 0), (3, 27, 0), (10, 27, 0), (10, 22, 0)], 0.14, 4)
    tube(m, "cap", (3, 24.5, 0), (10, 24.5, 0), 0.10, 4)
    return m


def tower_b():
    """~55 m: three setbacks and an antenna mast."""
    m = Model(); tower_materials(m, window=(0.55, 0.85, 1.0), cap=(1.0, 0.3, 0.75))
    rng = random.Random(202)
    block(m, rng, -9, 9, -9, 9, 0, 26, lit=0.42)
    block(m, rng, -7, 7, -7, 7, 26, 42, lit=0.5)
    block(m, rng, -5, 5, -5, 5, 42, 50, lit=0.6)
    m.cylinder("wall", (0, 50, 0), (0, 52, 0), 1.6, 0.5, sides=6, caps=False)
    tube(m, "cap", (0, 52, 0), (0, 58, 0), 0.14, 4)
    tube(m, "cap", (-1.2, 54.5, 0), (1.2, 54.5, 0), 0.10, 4)
    return m


def tower_c():
    """~85 m: a slender shaft with a stepped crown and a spire."""
    m = Model(); tower_materials(m, window=(1.0, 0.55, 0.8), cap=(1.0, 0.8, 0.25))
    rng = random.Random(303)
    block(m, rng, -8, 8, -8, 8, 0, 60, lit=0.5)
    block(m, rng, -6, 6, -6, 6, 60, 72, lit=0.55)
    block(m, rng, -3.6, 3.6, -3.6, 3.6, 72, 78, lit=0.0)
    # pyramid crown + spire
    r, y0, y1 = 3.6, 78, 83
    base = [(-r, y0, r), (r, y0, r), (r, y0, -r), (-r, y0, -r)]
    for i in range(4):
        m.tri("wall", base[i], base[(i + 1) % 4], (0, y1, 0))
        tube(m, "cap", base[i], (0, y1, 0), 0.13, 4)
    tube(m, "cap", (0, y1, 0), (0, 88, 0), 0.12, 4)
    # vertical fins up the shaft faces
    for x, z in ((0, 8.02), (0, -8.02), (8.02, 0), (-8.02, 0)):
        tube(m, "cap", (x, 0, z), (x, 60, z), 0.13, 4)
    return m


# ---------------------------------------------------------------- mountains
def mountain(seed, peaks, rough=0.22, nx=14, nz=5, width=700.0, depth=200.0, wire_w=2.2):
    """A ridgeline heightfield seen from +Z. peaks = [(x_centre, height, half_width), ...]."""
    m = Model()
    m.material("rock", (0.008, 0.004, 0.02))
    m.material("wire", (0.9, 0.25, 0.8), double_sided=True)
    rng = random.Random(seed)
    rowf = [0.0, 0.38, 0.78, 1.0, 0.55, 0.0]          # front (z=+depth/2) -> back
    assert len(rowf) == nz + 1

    def ridge(x):
        h = 0.0
        for cx, ph, pw in peaks:
            h = max(h, ph * max(0.0, 1 - abs(x - cx) / pw) ** 1.25)
        return h

    P = [[None] * (nz + 1) for _ in range(nx + 1)]
    for i in range(nx + 1):
        edge = i in (0, nx)
        col_j = 0.0 if edge else rng.uniform(-0.3, 0.3) * width / nx
        for k in range(nz + 1):
            x = -width / 2 + width * i / nx + (col_j if k not in (0, nz) else 0) + (0 if edge else rng.uniform(-6, 6))
            z = depth / 2 - depth * k / nz + (0 if k in (0, nz) else rng.uniform(-10, 10))
            h = 0.0 if edge else ridge(x) * rowf[k] * (1 + rng.uniform(-rough, rough))
            if not edge and 0 < k < nz:
                h += rng.uniform(0, 10)
            P[i][k] = V([x, h, z])
    edges = set()
    for i in range(nx):
        for k in range(nz):
            a, b, c, d = (i, k), (i + 1, k), (i + 1, k + 1), (i, k + 1)
            if (i + k) % 2:
                tris = [(a, b, c), (a, c, d)]
            else:
                tris = [(a, b, d), (b, c, d)]
            for t in tris:
                m.tri("rock", *[tuple(P[q[0]][q[1]]) for q in t])
                for e in ((t[0], t[1]), (t[1], t[2]), (t[2], t[0])):
                    edges.add(tuple(sorted(e)))
    zf = V([0, 0, 1])
    for qa, qb in sorted(edges):
        a, b = P[qa[0]][qa[1]], P[qb[0]][qb[1]]
        if a[1] == 0 and b[1] == 0 and not (qa[1] == 0 and qb[1] == 0):
            continue                                   # hidden base edges (keep the front base line)
        if qa[1] >= nz - 1 and qb[1] >= nz - 1:
            continue                                   # behind the ridge
        side = np.cross(b - a, zf)
        if np.linalg.norm(side) < 1e-6:
            continue
        side = unit(side) * wire_w / 2
        off = zf * 3.0 + V([0, 0.3, 0])                # stand clear of the faces (depth precision at 1 km)
        face(m, "wire", [a - side + off, b - side + off, b + side + off, a + side + off], zf)
    return m


def mountain_a():   # one dominant horn, left of centre, with shoulders
    return mountain(11, [(-90, 255, 190), (130, 150, 150), (-260, 95, 90), (255, 80, 95)])


def mountain_b():   # twin peaks with a saddle
    return mountain(23, [(-140, 185, 150), (120, 205, 140), (0, 95, 120), (270, 70, 80)], rough=0.18)


def mountain_c():   # a long low sawtooth
    return mountain(37, [(-250, 95, 80), (-150, 135, 75), (-40, 105, 70), (60, 150, 80), (170, 110, 70), (265, 125, 80)],
                    rough=0.28)


# ---------------------------------------------------------------- Kandinsky shapes
SHAPE_CY = 6.0


def shape_materials(m, shape, fill):
    m.material("shape", shape, double_sided=True)
    m.material("fill", fill, double_sided=True)
    m.material("leg", (0.04, 0.04, 0.05))


def leg(m, top):
    m.box("leg", (-0.07, 0, -0.07), (0.07, top, 0.07), faces="xXzZ")


def shape_circle():
    m = Model(); shape_materials(m, (0.06, 0.28, 1.0), (1.0, 0.15, 0.1))
    disc(m, "shape", (0, SHAPE_CY, 0), (0, 0, 1), 3.0, sides=32, r_in=2.5)
    disc(m, "fill", (0.75, SHAPE_CY - 0.55, 0), (0, 0, 1), 1.05, sides=20)
    leg(m, SHAPE_CY - 2.98)
    return both_sides(m, "shape", "fill")


def shape_triangle():
    m = Model(); shape_materials(m, (1.0, 0.72, 0.04), (0.06, 0.28, 1.0))
    R, bar = 3.45, 0.45
    cy = SHAPE_CY - 0.6                                  # visual centre of an upright triangle
    ang = [math.pi / 2 + 2 * math.pi * i / 3 for i in range(3)]
    o = [(R * math.cos(a), cy + R * math.sin(a), 0) for a in ang]
    Ri = R - 2 * bar
    n = [(Ri * math.cos(a), cy + Ri * math.sin(a), 0) for a in ang]
    for i in range(3):
        j = (i + 1) % 3
        m.quad("shape", [o[i], o[j], n[j], n[i]])
    # a smaller solid triangle, inverted and off-centre
    r, fx, fy = 0.95, 0.35, cy - 0.35
    m.poly("fill", [(fx + r * math.cos(a + math.pi), fy + r * math.sin(a + math.pi), 0) for a in ang])
    leg(m, cy - R / 2 + 0.02)
    return both_sides(m, "shape", "fill")


def shape_square():
    m = Model(); shape_materials(m, (1.0, 0.07, 0.05), (1.0, 0.72, 0.04))
    s, bar, rot = 2.6, 0.45, math.radians(12)
    R = lambda x, y, a=rot: (x * math.cos(a) - y * math.sin(a), SHAPE_CY + x * math.sin(a) + y * math.cos(a))
    co = [(-s, -s), (s, -s), (s, s), (-s, s)]
    ci = [(x * (s - bar) / s, y * (s - bar) / s) for x, y in co]
    for i in range(4):
        j = (i + 1) % 4
        m.quad("shape", [(*R(*co[i]), 0), (*R(*co[j]), 0), (*R(*ci[j]), 0), (*R(*ci[i]), 0)])
    # parallel bars crossing the frame at a counter-angle, on both faces
    a2 = math.radians(-33)
    for off, half, th in ((1.15, 3.2, 0.09), (0.55, 3.7, 0.20), (-0.75, 2.9, 0.07)):
        for z in (0.05, -0.05):
            pts = [(-half, off - th), (half, off - th), (half, off + th), (-half, off + th)]
            face(m, "fill", [(*R(x, y, a2), z) for x, y in pts], (0, 0, z))
    leg(m, SHAPE_CY - s * (math.cos(rot) + math.sin(rot)) + 0.05)
    return both_sides(m, "shape")


MODELS = dict(
    car_player=car_player, car_traffic_a=car_traffic_a, car_traffic_b=car_traffic_b,
    palm=palm, pine=pine, lamp=lamp, gate=gate, sign=sign,
    tower_a=tower_a, tower_b=tower_b, tower_c=tower_c,
    mountain_a=mountain_a, mountain_b=mountain_b, mountain_c=mountain_c,
    shape_circle=shape_circle, shape_triangle=shape_triangle, shape_square=shape_square,
)


def main(argv):
    os.makedirs(OUT, exist_ok=True)
    names = argv or list(MODELS)
    for name in names:
        m = MODELS[name]()
        m.save(os.path.join(OUT, name + ".glb"))
        lo, hi = m.bounds()
        mats = [k for k in m._order if m._tris.get(k)]
        print(f"{name:15s} tris={m.tri_count():5d}  min=({lo[0]:8.2f},{lo[1]:7.2f},{lo[2]:8.2f})"
              f"  max=({hi[0]:8.2f},{hi[1]:7.2f},{hi[2]:8.2f})  {','.join(mats)}")


if __name__ == "__main__":
    main(sys.argv[1:])
