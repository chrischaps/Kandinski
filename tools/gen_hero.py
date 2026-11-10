"""Generate the Kandinski hero car: models/car_player.glb (body) + models/car_wheel.glb.

    python tools/gen_hero.py            # write both GLBs, print stats
    python tools/gen_hero.py --check    # also print the wheel-arch clearance table

An original late-80s mid-engine wedge: long flat nose with pop-up lamp lids,
raked screen, strakes along the doors into a forward-facing side intake, wide
haunches, flying buttresses either side of a louvred deck, a full-width black
slatted tail grille with the lamps behind it, quad exhausts.

Contract (the driving script depends on it):
  Y up, metres, forward is -Z, +X right, body origin on the road under the car.
  Hubs: front (+-0.80, 0.33, -1.32), rear (+-0.80, 0.33, +1.28).
  The body has NO wheels; car_wheel.glb is one wheel, hub at the origin, axle
  along X, styled face toward +X, radius 0.33, width 0.28.
  One node / one mesh / a primitive per named material (glb.py), flat shaded.

The world is unlit (ambient 3, no sun): faces carry no shading, so form is
drawn with three paint tones (body, body_hi, body_shade), dark recesses and
thin `trim` lines on the character edges.

The body skin is a loft: ~50 stations along Z, each a half cross-section of 11
points (sill, door, strake recess, shoulder, top), mirrored about x = 0. Wheel
arches are real openings (section points are clamped onto the arch circle) with
a modelled dark tub behind each. Detail geometry is laid over the skin; where
it has to follow the surface it is placed by ray-casting onto the skin.
"""
import math
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from glb import Model  # noqa: E402

OUT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "models"))

# ---------------------------------------------------------------- contract
HUB_Y = 0.33
HUB_X = 0.80
Z_FRONT, Z_REAR = -1.32, 1.28
WHEEL_R, WHEEL_W = 0.33, 0.28

ZN, ZT = -2.21, 2.225          # nose face / tail face (splitter and grille slats reach +-2.25)
R_OPEN = 0.41                  # arch opening radius in the outer skin (front and rear)
R_TUB_F, R_TUB_R = 0.47, 0.47  # inner tub radius
X_TUB_IN = 0.47                # tub inner wall
X_TUB_OUT = 0.94               # back of the fender lip
CAB_Z0, CAB_Z1 = -0.79, 0.68   # cabin tub (stations inside are sunk to the interior floor)
REC_Z0, REC_Z1 = -0.55, 0.78   # strake recess along the door; the intake mouth is at REC_Z1
REC_DEPTH = 0.13
FLOOR_Y = 0.58                 # interior floor

BODY = (0.030, 0.003, 0.010)
HI_K, SHADE_K = 2.0, 0.36


# ---------------------------------------------------------------- helpers
def V(p):
    return np.array(p, float)


def unit(v):
    v = V(v)
    n = np.linalg.norm(v)
    return v / n if n > 1e-12 else v


def face(m, mat, pts, hint, lift=0.0):
    """Convex polygon wound to face `hint`, optionally lifted along its normal."""
    pts = [V(p) for p in pts]
    n = None
    for i in range(1, len(pts) - 1):
        c = np.cross(pts[i] - pts[0], pts[i + 1] - pts[0])
        if np.linalg.norm(c) > 1e-10:
            n = unit(c)
            break
    if n is None:
        return
    if np.dot(n, V(hint)) < 0:
        pts = pts[::-1]
        n = -n
    if lift:
        pts = [p + n * lift for p in pts]
    for i in range(1, len(pts) - 1):
        a, b, c = pts[0], pts[i], pts[i + 1]
        if np.linalg.norm(np.cross(b - a, c - a)) > 1e-10:
            m.tri(mat, a, b, c)


def box(m, mat, lo, hi, faces="xXyYzZ", mats=None):
    """Axis box; `mats` maps a face letter to another material."""
    mats = mats or {}
    for f in faces:
        m.box(mats.get(f, mat), lo, hi, faces=f)


def tube(m, mat, a, b, r, sides=3):
    m.cylinder(mat, a, b, r, sides=sides, caps=False)


def polyline(m, mat, pts, r, sides=3):
    for i in range(len(pts) - 1):
        tube(m, mat, pts[i], pts[i + 1], r, sides)


def curve(keys):
    """Monotone cubic (Fritsch-Carlson) through (x, y) keys; flat outside."""
    xs = np.array([k[0] for k in keys], float)
    ys = np.array([k[1] for k in keys], float)
    h = np.diff(xs)
    d = np.diff(ys) / h
    s = np.zeros(len(xs))
    s[0], s[-1] = d[0], d[-1]
    for i in range(1, len(xs) - 1):
        s[i] = 0.0 if d[i - 1] * d[i] <= 0 else 2 * d[i - 1] * d[i] / (d[i - 1] + d[i])

    def f(x):
        x = min(max(x, xs[0]), xs[-1])
        i = min(int(np.searchsorted(xs, x, side="right")) - 1, len(xs) - 2)
        t = (x - xs[i]) / h[i]
        return float((2 * t ** 3 - 3 * t ** 2 + 1) * ys[i] + (t ** 3 - 2 * t ** 2 + t) * h[i] * s[i]
                     + (-2 * t ** 3 + 3 * t ** 2) * ys[i + 1] + (t ** 3 - t ** 2) * h[i] * s[i + 1])
    return f


def mirror_into(dst, half):
    """Merge a right-half model and its mirror image (winding flipped)."""
    mx = lambda p: (-p[0], p[1], p[2])
    for mat in half._order:
        if mat not in dst._order:
            dst._order.append(mat)
    for mat, tris in half._tris.items():
        out = dst._tris.setdefault(mat, [])
        for a, b, c in tris:
            out.append((a, b, c))
            out.append((mx(a), mx(c), mx(b)))


# ---------------------------------------------------------------- body shape
W_OF = curve([(ZN, 0.80), (-2.12, 0.885), (-1.95, 0.925), (-1.6, 0.945), (-1.32, 0.95), (-0.9, 0.945),
              (-0.5, 0.935), (0.3, 0.945), (0.9, 0.955), (1.28, 0.955), (1.9, 0.955), (2.12, 0.942), (ZT, 0.915)])
YBOT = curve([(ZN, 0.15), (-1.95, 0.13), (1.75, 0.13), (ZT, 0.24)])
YSH = curve([(ZN, 0.50), (-1.9, 0.60), (-1.6, 0.745), (-1.32, 0.815), (-1.0, 0.836), (-0.7, 0.848),
             (0.5, 0.855), (0.9, 0.885), (1.28, 0.905), (1.8, 0.897), (ZT, 0.875)])
DISH_A = curve([(ZN, 0.0), (-1.95, 0.03), (1.95, 0.03), (ZT, 0.0)])
DISH_B = curve([(ZN, 0.0), (-1.9, 0.05), (-1.32, 0.065), (-0.8, 0.04), (0.69, 0.03), (1.95, 0.03), (ZT, 0.0)])
FR = [0.0, 0.22, 0.32, 0.34, 0.74, 0.76, 0.94, 1.0]
NP = 11                         # points per half section


def recess(z):
    if REC_Z0 < z <= REC_Z1 + 1e-9:
        return REC_DEPTH * (z - REC_Z0) / (REC_Z1 - REC_Z0)
    return 0.0


def in_cabin(z):
    return CAB_Z0 - 1e-9 <= z <= CAB_Z1 + 1e-9


def bow(x):
    return 0.08 * (min(x, 0.8) / 0.8) ** 2


def stations():
    zs = {ZN, -2.14, -2.02, -1.88, -0.80, CAB_Z0, REC_Z0, -0.10, 0.35, CAB_Z1, 0.69, REC_Z1, REC_Z1 + 0.002,
          1.95, 2.12, ZT}
    for zc, rt in ((Z_FRONT, R_TUB_F), (Z_REAR, R_TUB_R)):
        zs |= {zc - rt, zc + rt, zc - R_OPEN - 0.002, zc + R_OPEN + 0.002}
        for k in range(13):
            zs.add(zc + R_OPEN * math.cos(math.pi * k / 12))
    out = sorted(round(z, 5) for z in zs)
    return [z for i, z in enumerate(out) if i == 0 or z - out[i - 1] > 1e-4]


def arch_of(z):
    for zc in (Z_FRONT, Z_REAR):
        if abs(z - zc) <= R_OPEN + 1e-6:
            return zc
    return None


def raw_section(z):
    """Half section at z before the arch cut: 11 (x, y), sill bottom -> centreline."""
    W, y0, ys = W_OF(z), YBOT(z), YSH(z)
    H = ys - y0
    d = recess(z)
    xo = [W - 0.06, W - 0.012, W, W - d, W - d - 0.004, W - 0.004, W - 0.016, W - 0.055]
    pts = [(xo[i], y0 + FR[i] * H) for i in range(8)]
    if in_cabin(z):
        pts += [(0.80, ys), (0.74, FLOOR_Y), (0.0, FLOOR_Y)]
    else:
        a, b = DISH_A(z), DISH_B(z)
        pts += [(W - 0.22, ys - a), (0.42, ys - b), (0.0, ys - b + (0.008 * min(1.0, b / 0.03) if z < 0 else 0.0))]
    return pts


def section(z):
    """Half section at z as 3D points, with the arch cut, the flare and end rakes."""
    pts = raw_section(z)
    clamped = [False] * NP
    zc = arch_of(z)
    if zc is not None:
        ylow = HUB_Y + math.sqrt(max(0.0, R_OPEN ** 2 - (z - zc) ** 2))
        side = pts[:8]
        assert ylow < side[7][1] - 0.02, f"arch reaches the shoulder at z={z}"
        k = max(i for i in range(8) if side[i][1] < ylow) if side[0][1] < ylow else -1
        if k >= 0:
            (xa, ya), (xb, yb) = side[k], side[k + 1]
            t = (ylow - ya) / (yb - ya)
            edge = (xa + (xb - xa) * t, ylow)
            for i in range(k + 1):
                pts[i] = edge
                clamped[i] = True
    out = []
    for i, (x, y) in enumerate(pts):
        zz = z
        if i <= 6:                                    # flare round the arch lips
            for c in (Z_FRONT, Z_REAR):
                dist = math.hypot(z - c, y - HUB_Y) - R_OPEN
                if -1e-6 <= dist < 0.12:
                    x += 0.022 * (1 - max(dist, 0.0) / 0.12) ** 2
        if abs(z - ZT) < 1e-6 and y < 0.40:           # tail valance tucks forward
            zz -= (0.40 - y) * 0.5
        if i >= 8 and (abs(z + 0.80) < 1e-6 or abs(z - CAB_Z0) < 1e-6):   # bowed screen base
            zz += bow(x)
        out.append((x, y, zz))
    return out, clamped


def strip_mat(i, za, zb):
    cab = in_cabin(za) or in_cabin(zb)
    rec = recess(za) > 0 or recess(zb) > 0
    if i == 0:
        return "body_shade"
    if i in (2, 3, 4) and rec:
        return "dark"
    if i == 6:
        return "body_hi"
    if i == 7:
        return "body"
    if i >= 8:
        return "interior" if cab else "body_hi"
    return "body"


class Skin:
    """The lofted right half, plus ray queries onto it."""

    def __init__(self):
        self.zs = stations()
        self.P, self.C = [], []
        for z in self.zs:
            p, c = section(z)
            self.P.append([V(q) for q in p])
            self.C.append(c)
        self.tris = []      # (mat, a, b, c)
        for j in range(len(self.zs) - 1):
            for i in range(NP - 1):
                mat = strip_mat(i, self.zs[j], self.zs[j + 1])
                a, b, c, d = self.P[j][i], self.P[j][i + 1], self.P[j + 1][i + 1], self.P[j + 1][i]
                for t in ((a, b, c), (a, c, d)):
                    if np.linalg.norm(np.cross(t[1] - t[0], t[2] - t[0])) > 1e-9:
                        self.tris.append((mat, *t))
        T = np.array([[t[1], t[2], t[3]] for t in self.tris])
        self.A, self.E1, self.E2 = T[:, 0], T[:, 1] - T[:, 0], T[:, 2] - T[:, 0]

    def _cast(self, o, d):
        o, d = V(o), V(d)
        p = np.cross(d, self.E2)
        det = np.einsum("ij,ij->i", self.E1, p)
        ok = np.abs(det) > 1e-12
        inv = np.where(ok, 1.0 / np.where(ok, det, 1.0), 0.0)
        s = o - self.A
        u = np.einsum("ij,ij->i", s, p) * inv
        q = np.cross(s, self.E1)
        v = (q @ d) * inv
        t = np.einsum("ij,ij->i", self.E2, q) * inv
        hit = ok & (u >= -1e-7) & (v >= -1e-7) & (u + v <= 1 + 1e-7) & (t > 0)
        return t[hit]

    def top(self, x, z, default=None):
        """Height of the skin's upper surface at (x, z)."""
        t = self._cast((abs(x), 5.0, z), (0, -1, 0))
        if not len(t):
            assert default is not None, f"no skin under ({x}, {z})"
            return default
        return 5.0 - float(t.min())

    def side(self, y, z):
        """Outermost x of the right flank at (y, z)."""
        t = self._cast((5.0, y, z), (-1, 0, 0))
        assert len(t), f"no flank at ({y}, {z})"
        return 5.0 - float(t.min())

    def zsplit(self, z0, z1):
        return [z0] + [z for z in self.zs if z0 + 1e-4 < z < z1 - 1e-4] + [z1]

    def band(self, m, mat, a, b, width, lift=0.005, zmin=-9, zmax=9):
        """A strip of `width` on the skin, running along point a toward point b."""
        i = min(a, b)
        for j in range(len(self.zs) - 1):
            if self.zs[j] < zmin - 1e-6 or self.zs[j + 1] > zmax + 1e-6:
                continue
            if self.C[j][a] or self.C[j + 1][a]:
                continue
            A0, B0, A1, B1 = self.P[j][a], self.P[j][b], self.P[j + 1][a], self.P[j + 1][b]
            n = np.cross(self.P[j][i + 1] - self.P[j][i], self.P[j + 1][i] - self.P[j][i])
            if np.linalg.norm(n) < 1e-10:
                n = np.cross(self.P[j + 1][i + 1] - self.P[j + 1][i], self.P[j + 1][i] - self.P[j][i])
            n = unit(n)
            l0, l1 = np.linalg.norm(B0 - A0), np.linalg.norm(B1 - A1)
            if l0 < 1e-6 or l1 < 1e-6:
                continue
            I0 = A0 + (B0 - A0) * min(1.0, width / l0)
            I1 = A1 + (B1 - A1) * min(1.0, width / l1)
            face(m, mat, [A0 + n * lift, I0 + n * lift, I1 + n * lift, A1 + n * lift], n)


# ---------------------------------------------------------------- body parts
def add_skin(h, sk):
    for mat, a, b, c in sk.tris:
        h.tri(mat, a, b, c)
    # end caps: full-width bands between consecutive section points
    for j, hint, shade_to in ((0, (0, 0, -1), 1), (len(sk.zs) - 1, (0, 0, 1), 1)):
        P = sk.P[j]
        for i in range(7):
            mat = "body_shade" if i < shade_to else "body"
            face(h, mat, [(0, P[i][1], P[i][2]), P[i], P[i + 1], (0, P[i + 1][1], P[i + 1][2])], hint)


def add_floor(h, sk):
    for j in range(len(sk.zs) - 1):
        za, zb = sk.zs[j], sk.zs[j + 1]
        zm = (za + zb) / 2
        xa, xb = raw_section(za)[0][0], raw_section(zb)[0][0]
        if abs(zm - Z_FRONT) < R_TUB_F or abs(zm - Z_REAR) < R_TUB_R:
            xa = xb = X_TUB_IN
        ya, yb = YBOT(za), YBOT(zb)
        zb_ = zb - (0.40 - yb) * 0.5 if abs(zb - ZT) < 1e-6 else zb
        face(h, "dark", [(0, ya, za), (xa, ya, za), (xb, yb, zb_), (0, yb, zb_)], (0, -1, 0))


def arch_profile(zc, r, n=12):
    pts = [(zc - r, None)]
    for k in range(n + 1):
        t = math.pi - math.pi * k / n
        pts.append((zc + r * math.cos(t), HUB_Y + r * math.sin(t)))
    pts.append((zc + r, None))
    return [(z, YBOT(z) if y is None else y) for z, y in pts]


def add_tub(h, sk, zc, rt):
    """Dark inner arch: a half-drum behind the opening, kept under the skin."""
    def under(x, y, z):
        zq = min(max(z, ZN + 0.01), ZT - 0.01)
        t = min(sk.top(x, zq, 9.0), sk.top(x - 0.05, zq, 9.0))
        return (x, min(y, t - 0.012), z)

    tub = arch_profile(zc, rt)
    opn = arch_profile(zc, R_OPEN)
    hub = V((0, HUB_Y, zc))
    n = len(tub)
    for i in range(n - 1):
        (za, ya), (zb, yb) = tub[i], tub[i + 1]
        mid = V((0, (ya + yb) / 2, (za + zb) / 2))
        hint = hub - mid
        hint[0] = 0
        face(h, "dark", [under(X_TUB_IN, ya, za), under(X_TUB_OUT, ya, za),
                         under(X_TUB_OUT, yb, zb), under(X_TUB_IN, yb, zb)], hint)
        # inner wall
        face(h, "dark", [(X_TUB_IN, HUB_Y, zc), under(X_TUB_IN, ya, za), under(X_TUB_IN, yb, zb)], (1, 0, 0))
        # back of the fender lip, between the opening and the tub
        (zc0, yc0), (zc1, yc1) = opn[i], opn[i + 1]
        face(h, "dark", [(X_TUB_OUT, yc0, zc0), under(X_TUB_OUT, ya, za),
                         under(X_TUB_OUT, yb, zb), (X_TUB_OUT, yc1, zc1)], (-1, 0, 0))
    face(h, "dark", [(X_TUB_IN, HUB_Y, zc), (X_TUB_IN, tub[-1][1], tub[-1][0]), (X_TUB_IN, tub[0][1], tub[0][0])],
         (1, 0, 0))
    # lip return: the skin's cut edge back to X_TUB_OUT, and the arch trim on the lip
    edge = [(j, sk.P[j][0]) for j, z in enumerate(sk.zs) if abs(z - zc) <= R_OPEN + 1e-6]
    for (ja, a), (jb, b) in zip(edge[:-1], edge[1:]):
        mid = (a + b) / 2
        hint = hub - mid
        hint[0] = 0
        face(h, "body_shade", [a, b, (X_TUB_OUT, b[1], b[2]), (X_TUB_OUT, a[1], a[2])], hint)
        ra, rb = unit((0, a[1] - HUB_Y, a[2] - zc)), unit((0, b[1] - HUB_Y, b[2] - zc))
        o = V((0.006, 0, 0))
        face(h, "trim", [a + o, b + o, b + o + rb * 0.010, a + o + ra * 0.010], (1, 0, 0))
    for (j, a), sgn in ((edge[0], -1), (edge[-1], 1)):
        yb = YBOT(a[2])
        xb = sk.P[j + sgn][0][0]
        face(h, "body_shade", [a, (xb, yb, a[2]), (X_TUB_OUT, yb, a[2]), (X_TUB_OUT, a[1], a[2])], (0, 0, -sgn))


def drape_rect(h, sk, mat, x0, x1, z0, z1, lift, split=True):
    zs = sk.zsplit(z0, z1) if split else [z0, z1]
    for za, zb in zip(zs[:-1], zs[1:]):
        face(h, mat, [(x0, sk.top(x0, za) + lift, za), (x1, sk.top(x1, za) + lift, za),
                      (x1, sk.top(x1, zb) + lift, zb), (x0, sk.top(x0, zb) + lift, zb)], (0, 1, 0))


def side_rect(h, sk, mat, z0, z1, y0, y1, lift=0.004):
    face(h, mat, [(sk.side(y0, z0) + lift, y0, z0), (sk.side(y0, z1) + lift, y0, z1),
                  (sk.side(y1, z1) + lift, y1, z1), (sk.side(y1, z0) + lift, y1, z0)], (1, 0, 0))


def add_glasshouse(h, sk):
    jh = sk.zs.index(-0.80)
    jc = sk.zs.index(round(CAB_Z0, 5))
    H10, H9, H8 = sk.P[jh][10], sk.P[jh][9], sk.P[jh][8]
    A0 = sk.P[jc][8]
    base = [H10, H9, H8, A0]
    top = [V((0, 1.125, -0.06)), V((0.30, 1.122, -0.05)), V((0.52, 1.111, -0.02)), V((0.57, 1.108, -0.01))]
    A1 = top[3]
    zr = 0.69
    rear = [V((0, 1.13, zr)), V((0.30, 1.127, zr)), V((0.52, 1.116, zr)), V((0.585, 1.112, zr))]
    R1 = rear[3]
    S1f, S1r = V((0.635, 1.070, 0.03)), V((0.65, 1.075, zr))
    Sg = V((0.648, 1.073, 0.50))
    B0r = V((0.80, YSH(0.60) - 0.01, 0.60))
    A0s = A0 - V((0, 0.01, 0))
    for i in range(3):                                           # windscreen
        face(h, "glass", [base[i], base[i + 1], top[i + 1], top[i]], (0, 1, -1))
    for i in range(3):                                           # roof
        face(h, "body_hi", [top[i], top[i + 1], rear[i + 1], rear[i]], (0, 1, 0))
    face(h, "body", [A1, R1, S1r, S1f], (1, 1, 0))               # roof rail
    face(h, "body", [A0, S1f, A1], (1, 0.5, -1))                 # A-pillar
    face(h, "glass", [A0s, B0r, Sg, S1f], (1, 0.4, 0))           # side glass
    # buttress: sail panel, crest, inner face
    ze = 2.02
    E = V((0.86, sk.top(0.86, ze) - 0.004, ze))
    Ei = V((0.80, sk.top(0.80, ze) - 0.004, ze))
    face(h, "body", [B0r, E, S1r], (1, 0.3, 0))
    face(h, "body", [B0r, S1r, Sg], (1, 0.3, 0))
    for v in (0.30, 0.43, 0.56):                                 # three gill slits on the sail panel
        q = lambda u, vv: B0r + (E - B0r) * u + (S1r - B0r) * vv
        u0 = 0.10 + 0.10 * v
        face(h, "dark", [q(u0, v), q(u0 + 0.21, v), q(u0 + 0.20, v + 0.05), q(u0 - 0.01, v + 0.05)], (1, 0.3, 0), 0.005)
    face(h, "body_hi", [S1r, E, Ei, R1], (0, 1, 0))
    D = V((0.585, sk.top(0.585, zr + 0.01) - 0.01, zr))
    face(h, "body_shade", [R1, Ei, D], (-1, 0, 0))
    # rear bulkhead with the little vertical rear screen
    yd = D[1]
    gx, gy0, gy1 = 0.47, 0.905, 1.085
    face(h, "glass", [(0, gy0, zr), (gx, gy0, zr), (gx, gy1, zr), (0, gy1, zr)], (0, 0, 1))
    face(h, "body_shade", [(0, yd, zr), (0.585, yd, zr), (gx, gy0, zr), (0, gy0, zr)], (0, 0, 1))
    face(h, "body_shade", [(0.585, yd, zr), R1, (gx, gy1, zr), (gx, gy0, zr)], (0, 0, 1))
    face(h, "body_shade", [(0, gy1, zr), (gx, gy1, zr), R1, rear[2]], (0, 0, 1))
    face(h, "body_shade", [(0, gy1, zr), rear[2], rear[1], rear[0]], (0, 0, 1))
    # the neon line: up the screen pillar, along the roof edge, down the buttress crest
    up = V((0.004, 0.007, 0))
    polyline(h, "trim", [A0 + up, A1 + up, (R1 + S1r) / 2 + up, (E + Ei) / 2 + V((0, 0.008, 0))], 0.0075)
    # B-pillar and screen-top shut lines, dark
    polyline(h, "dark", [B0r + V((0.003, 0.012, 0)), Sg + V((0.003, 0, 0))], 0.008)


def add_interior(h):
    seat = "seat"
    box(h, seat, (0.14, FLOOR_Y, -0.22), (0.60, FLOOR_Y + 0.09, 0.30), faces="XYzZx")       # cushion
    box(h, seat, (0.16, FLOOR_Y, 0.24), (0.58, 0.935, 0.40), faces="XYzZx")                 # back
    box(h, seat, (0.27, 0.935, 0.28), (0.47, 1.035, 0.38), faces="XYzZx")                   # headrest
    box(h, "interior", (0.0, FLOOR_Y, -0.30), (0.10, FLOOR_Y + 0.16, 0.45), faces="XYzZ")   # tunnel
    box(h, "interior", (0.0, 0.70, -0.74), (0.76, 0.80, -0.52), faces="XYZ")                # dash


def add_strakes(h, sk):
    zs = [-0.52, -0.05, 0.40, REC_Z1 + 0.004]
    for k in range(5):
        for za, zb in zip(zs[:-1], zs[1:]):
            def pt(z, dy, dx):
                y0, H = YBOT(z), YSH(z) - YBOT(z)
                lo, hi = y0 + FR[2] * H, y0 + FR[5] * H
                return (W_OF(z) + 0.002 - dx, lo + (hi - lo) * (k + 1) / 6 + dy, z)
            t = 0.011
            face(h, "body_hi", [pt(za, -t, 0), pt(zb, -t, 0), pt(zb, t, 0), pt(za, t, 0)], (1, 0, 0))
            face(h, "body", [pt(za, t, 0), pt(zb, t, 0), pt(zb, t, 0.03), pt(za, t, 0.03)], (0, 1, 0))
            face(h, "body_shade", [pt(za, -t, 0), pt(zb, -t, 0), pt(zb, -t, 0.03), pt(za, -t, 0.03)], (0, -1, 0))


def add_deck(h, sk):
    # louvre panel: a dark bed with nine flat slats
    drape_rect(h, sk, "dark", 0.0, 0.50, 0.86, 1.92, 0.004)
    for k in range(6):
        z0 = 0.90 + k * 0.17
        drape_rect(h, sk, "body_hi", 0.0, 0.47, z0, z0 + 0.105, 0.010, split=False)
    drape_rect(h, sk, "body", 0.0, 0.016, 0.86, 1.92, 0.013)          # spine
    # hood: pop-up lamp lid and front-lid shut lines
    w = 0.007
    for x0, x1, z0, z1 in ((0.44, 0.78, -2.02, -2.02 + w), (0.44, 0.78, -1.78, -1.78 + w),
                           (0.44, 0.44 + w, -2.02, -1.78), (0.78 - w, 0.78, -2.02, -1.78),
                           (0.36, 0.36 + w, -2.08, -0.98), (0.0, 0.36 + w, -0.98, -0.98 + w),
                           (0.60, 0.60 + w, 0.78, 2.08), (0.0, 0.60 + w, 2.08, 2.08 + w)):
        drape_rect(h, sk, "dark", x0, x1, z0, z1, 0.004)
    # door shut lines above and below the strakes
    for z in (-0.64, 0.56):
        y0, ys = YBOT(z), YSH(z)
        H = ys - y0
        side_rect(h, sk, "dark", z, z + 0.007, y0 + 0.02, y0 + FR[2] * H - 0.012)
        side_rect(h, sk, "dark", z, z + 0.007, y0 + FR[5] * H + 0.012, y0 + FR[6] * H)


def add_trim(h, sk):
    sk.band(h, "trim", 7, 6, 0.010)                 # shoulder crest, flank side
    sk.band(h, "trim", 7, 8, 0.010)                 # shoulder crest, top side
    sk.band(h, "trim", 1, 2, 0.011)                 # sill line


def add_tail(h, sk):
    z = ZT
    P = sk.P[-1]
    hint = (0, 0, 1)
    R = lambda mat, x0, x1, y0, y1, dz: face(h, mat, [(x0, y0, z + dz), (x1, y0, z + dz), (x1, y1, z + dz),
                                                      (x0, y1, z + dz)], hint)
    # top edge line, joining the two shoulder lines
    R("trim", 0.0, P[7][0] - 0.004, P[7][1] - 0.014, P[7][1] - 0.003, 0.006)
    # the grille: dark bed, lamp panel behind, six proud slats across the whole width
    gx = 0.82
    R("dark", 0.0, gx, 0.595, 0.805, 0.004)
    R("tail", 0.25, 0.785, 0.612, 0.788, 0.008)
    for k in range(6):
        yc = 0.610 + k * 0.036
        box(h, "dark", (0.0, yc - 0.007, z + 0.004), (gx, yc + 0.007, z + 0.025), faces="XYyZ")
    for x in (0.25, 0.52, 0.785):                                   # lamp dividers
        box(h, "dark", (x - 0.008, 0.600, z + 0.004), (x + 0.008, 0.800, z + 0.025), faces="xXZ")
    # bumper bar with the plate recess
    box(h, "body", (0.0, 0.445, z), (0.875, 0.545, z + 0.022), faces="XYyZ",
        mats={"Y": "body_hi", "y": "body_shade"})
    R("dark", 0.0, 0.17, 0.458, 0.532, 0.024)
    R("dark", 0.17, 0.875, 0.490, 0.498, 0.024)
    # quad exhausts in a dark cut-out of the valance
    zr = lambda y: z - (0.40 - y) * 0.5
    face(h, "dark", [(0.31, 0.262, zr(0.262) + 0.004), (0.62, 0.262, zr(0.262) + 0.004),
                     (0.62, 0.372, zr(0.372) + 0.004), (0.31, 0.372, zr(0.372) + 0.004)], hint)
    for x in (0.06, 0.18):                                          # diffuser fins
        box(h, "dark", (x - 0.008, 0.245, z - 0.10), (x + 0.008, 0.36, zr(0.30) + 0.012), faces="xXZY")
    for x in (0.395, 0.535):
        y, r, n = 0.317, 0.047, 10
        z0, z1 = z - 0.13, z + 0.012
        h.cylinder("chrome", (x, y, z0), (x, y, z1), r, sides=n, caps=False)
        ring = lambda rr, zz: [(x + rr * math.cos(2 * math.pi * i / n), y + rr * math.sin(2 * math.pi * i / n), zz)
                               for i in range(n)]
        ro, ri = ring(r, z1), ring(r * 0.74, z1)
        for i in range(n):
            j = (i + 1) % n
            face(h, "chrome", [ro[i], ro[j], ri[j], ri[i]], hint)
        face(h, "dark", ring(r * 0.74, z1 - 0.004), hint)


def add_nose(h, sk):
    z = ZN
    P = sk.P[0]
    hint = (0, 0, -1)
    R = lambda mat, x0, x1, y0, y1, dz: face(h, mat, [(x0, y0, z - dz), (x1, y0, z - dz), (x1, y1, z - dz),
                                                      (x0, y1, z - dz)], hint)
    R("trim", 0.0, P[7][0] - 0.004, P[7][1] - 0.014, P[7][1] - 0.003, 0.006)
    R("dark", 0.0, 0.30, 0.19, 0.30, 0.004)                # intake slot
    for y in (0.222, 0.258):
        R("body", 0.0, 0.30, y, y + 0.012, 0.008)
    R("dark", 0.36, 0.72, 0.19, 0.30, 0.004)               # lamp surround
    R("head", 0.385, 0.53, 0.212, 0.278, 0.008)            # twin driving lamps
    R("head", 0.555, 0.70, 0.212, 0.278, 0.008)
    R("dark", 0.0, 0.775, 0.345, 0.357, 0.004)             # rub strip
    # chin splitter
    out = [(0.0, -2.25), (0.72, -2.25), (0.86, -2.15), (0.92, -1.95), (0.0, -1.95)]
    y0, y1 = 0.12, 0.15
    face(h, "dark", [(x, y1, zz) for x, zz in out], (0, 1, 0))
    face(h, "dark", [(x, y0, zz) for x, zz in out], (0, -1, 0))
    for (xa, za), (xb, zb) in zip(out[:3], out[1:4]):
        nrm = (zb - za, 0, -(xb - xa))
        nrm = nrm if nrm[2] < 0 or nrm[0] > 0 else (-nrm[0], 0, -nrm[2])
        face(h, "dark", [(xa, y0, za), (xb, y0, zb), (xb, y1, zb), (xa, y1, za)], (xb - xa + 0.3, 0, -1))


def add_mirror(h):
    box(h, "body_shade", (0.83, 0.835, -0.655), (0.90, 0.905, -0.605), faces="XYyzZ")       # stalk
    lo, hi = (0.865, 0.892, -0.665), (1.0, 0.978, -0.59)
    box(h, "body", lo, hi, faces="xXYyz", mats={"Y": "body_hi", "y": "body_shade"})
    box(h, "dark", lo, hi, faces="Z")
    face(h, "chrome", [(lo[0] + 0.012, lo[1] + 0.012, hi[2]), (hi[0] - 0.012, lo[1] + 0.012, hi[2]),
                       (hi[0] - 0.012, hi[1] - 0.012, hi[2]), (lo[0] + 0.012, hi[1] - 0.012, hi[2])], (0, 0, 1), 0.003)


def body_materials(m):
    c = BODY
    m.material("body", c)
    m.material("body_hi", tuple(v * HI_K for v in c))
    m.material("body_shade", tuple(v * SHADE_K for v in c))
    m.material("dark", (0.0035, 0.0035, 0.005))
    m.material("interior", (0.009, 0.007, 0.012))
    m.material("seat", (0.030, 0.016, 0.014))
    m.material("chrome", (0.13, 0.15, 0.21))
    m.material("trim", (0.6, 0.1, 0.37))
    m.material("tail", (0.55, 0.012, 0.03))
    m.material("head", (1.0, 0.95, 0.7))
    m.material("glass", (0.004, 0.012, 0.035), alpha=0.6)


def car_body():
    sk = Skin()
    h = Model()
    add_skin(h, sk)
    add_floor(h, sk)
    add_tub(h, sk, Z_FRONT, R_TUB_F)
    add_tub(h, sk, Z_REAR, R_TUB_R)
    add_interior(h)
    add_strakes(h, sk)
    add_deck(h, sk)
    add_trim(h, sk)
    add_tail(h, sk)
    add_nose(h, sk)
    add_mirror(h)
    add_glasshouse(h, sk)       # glass last: it is alpha-blended over what is behind it
    m = Model()
    body_materials(m)
    mirror_into(m, h)
    # steering wheel (left-hand drive), the one asymmetric part
    c, r = V((-0.37, 0.80, -0.47)), 0.15
    ax = unit((0, 0.35, 1.0))
    u = V((1, 0, 0))
    v = np.cross(ax, u)
    n = 10
    ring = lambda rr: [c + rr * (math.cos(2 * math.pi * i / n) * u + math.sin(2 * math.pi * i / n) * v)
                       for i in range(n)]
    ro, ri = ring(r), ring(r - 0.03)
    for i in range(n):
        j = (i + 1) % n
        face(m, "interior", [ro[i], ro[j], ri[j], ri[i]], ax)
    # move glass to the end of the draw order
    m._order.remove("glass")
    m._order.append("glass")
    # No underglow pool. The first car had a flat `under` octagon 2 cm above
    # the road; as part of the body mesh it tilted with roll, cut through the
    # road and z-fought with it, and one flat slab did not suit this model.
    # (drive.rhai may still set an `under` override: with no such material it
    # does nothing.)
    return m, sk


# ---------------------------------------------------------------- wheel
def car_wheel(n=20):
    m = Model()
    m.material("wheel", (0.010, 0.010, 0.013))
    m.material("rim", (0.22, 0.22, 0.27))
    m.material("dark", (0.0035, 0.0035, 0.005))
    hw = WHEEL_W / 2
    ang = [2 * math.pi * i / n for i in range(n)]

    def ring(x, r, off=0.0):
        return [V((x, r * math.cos(a + off), r * math.sin(a + off))) for a in ang]

    def band(mat, a, b, hx, hr):
        ra, rb = ring(*a), ring(*b)
        for i in range(n):
            j = (i + 1) % n
            am = (ang[i] + ang[i] + 2 * math.pi / n) / 2
            face(m, mat, [ra[i], ra[j], rb[j], rb[i]], (hx, hr * math.cos(am), hr * math.sin(am)))

    r_rim = 0.235
    prof = [(-hw, r_rim), (-hw, 0.300), (-hw + 0.028, WHEEL_R), (hw - 0.028, WHEEL_R), (hw, 0.300), (hw, r_rim)]
    hints = [(-1, 0), (-0.7, 0.7), (0, 1), (0.7, 0.7), (1, 0)]
    for (a, b), (hx, hr) in zip(zip(prof[:-1], prof[1:]), hints):
        band("wheel", a, b, hx, hr)
    face(m, "dark", ring(-hw, r_rim), (-1, 0, 0))                        # inner side
    band("rim", (hw, r_rim), (hw - 0.010, 0.214), 1, -0.5)               # rim lip
    band("dark", (hw - 0.010, 0.214), (0.015, 0.200), 0.1, -1)           # barrel
    face(m, "dark", ring(0.015, 0.200), (1, 0, 0))                       # back plate
    # five-spoke star: wide at the hub, tapering to the rim, dished
    for k in range(5):
        a = 2 * math.pi * k / 5 + math.pi / 2
        rad = V((0, math.cos(a), math.sin(a)))
        tan = V((0, -math.sin(a), math.cos(a)))
        X = V((1, 0, 0))
        r0, r1, w0, w1, x0, x1, dep = 0.050, 0.214, 0.052, 0.020, 0.098, hw - 0.012, 0.040
        f = [rad * r0 - tan * w0 + X * x0, rad * r0 + tan * w0 + X * x0,
             rad * r1 + tan * w1 + X * x1, rad * r1 - tan * w1 + X * x1]
        b = [p - X * dep for p in f]
        face(m, "rim", f, X)
        face(m, "rim", [f[1], b[1], b[2], f[2]], tan)
        face(m, "rim", [f[0], f[3], b[3], b[0]], -tan)
    face(m, "rim", ring(0.099, 0.082, math.pi / 2 + math.pi / n)[::2], (1, 0, 0))   # hub disc
    cap = [V((0.118, 0.034 * math.cos(2 * math.pi * i / 10), 0.034 * math.sin(2 * math.pi * i / 10)))
           for i in range(10)]
    face(m, "rim", cap, (1, 0, 0))
    for i in range(10):
        j = (i + 1) % 10
        o = V((0.018, 0, 0))
        mid = (cap[i] + cap[j]) / 2
        face(m, "dark", [cap[i], cap[j], cap[j] - o, cap[i] - o], (0, mid[1], mid[2]))
    return m


# ---------------------------------------------------------------- clearance
def clearance(sk, verbose=True):
    """Worst tyre-into-body overlap (m, <= 0 is clear) per wheel pose."""
    hw = WHEEL_W / 2
    loc = []
    for a in np.linspace(0, 2 * math.pi, 96, endpoint=False):
        for x, r in ((-hw, 0.30), (-hw + 0.028, 0.33), (0, 0.33), (hw - 0.028, 0.33), (hw, 0.30)):
            loc.append((x, r * math.sin(a), r * math.cos(a)))
    loc = np.array(loc)

    def worst(zc, rt, steer, travel, roll, pitch, side=1):
        s, c = math.sin(math.radians(steer)), math.cos(math.radians(steer))
        p = np.stack([loc[:, 0] * c + loc[:, 2] * s, loc[:, 1], -loc[:, 0] * s + loc[:, 2] * c], 1)
        p += (side * HUB_X, HUB_Y + travel, zc)
        # the body rolls (about Z) and pitches (about X) about the ground origin: take the
        # tyre into the body's frame with the inverse rotation
        rr, pp = math.radians(-roll), math.radians(-pitch)
        x, y, z = p[:, 0], p[:, 1], p[:, 2]
        x, y = x * math.cos(rr) - y * math.sin(rr), x * math.sin(rr) + y * math.cos(rr)
        y, z = y * math.cos(pp) - z * math.sin(pp), y * math.sin(pp) + z * math.cos(pp)
        x = x * side
        rad = np.where(y > HUB_Y, np.hypot(z - zc, y - HUB_Y), np.abs(z - zc))
        pen_open = np.where(x > X_TUB_OUT, rad - R_OPEN, -9)
        pen_tub = np.where((x <= X_TUB_OUT) & (x >= X_TUB_IN), rad - rt, -9)
        pen_wall = X_TUB_IN - x
        skin = -9.0
        for xi, yi, zi in zip(x, y, z):
            if X_TUB_IN < xi < 0.90 and yi > 0.60:
                skin = max(skin, yi - sk.top(xi, zi, 9.0))
        return float(max(pen_open.max(), pen_tub.max(), pen_wall.max())), float(pen_open.max()), skin

    rows = []
    cases = [("rest", 0, 0, 0, 0), ("travel +0.06", 0, 0.06, 0, 0), ("roll 4", 0, 0, 4, 0), ("pitch 3", 0, 0, 0, 3),
             ("travel + roll", 0, 0.06, 4, 0), ("roll + pitch", 0, 0, 4, 3), ("travel + roll + pitch", 0, 0.06, 4, 3)]
    for name, st, tr, ro, pi in cases:
        for axle, zc, rt, steers in (("front", Z_FRONT, R_TUB_F, (0, 28, -28)), ("rear", Z_REAR, R_TUB_R, (0,))):
            w = max(worst(zc, rt, s, tr, r_, p_, sd) for s in steers for r_ in (ro, -ro) for p_ in (pi, -pi)
                    for sd in (1, -1))
            sk_ = max(worst(zc, rt, s, tr, r_, p_, 1)[2] for s in steers for r_ in (ro, -ro) for p_ in (pi, -pi))
            rows.append((name, axle, w[0], w[1], sk_))
    if verbose:
        print("  arch clearance (negative = clear, metres; 'lip' is the part of the tyre outboard of the fender lip)")
        for name, axle, w, lip, skn in rows:
            print(f"    {name:24s} {axle:5s} tub {w:+.3f}   lip {lip:+.3f}   through the painted skin {skn:+.3f}")
    return rows


# ---------------------------------------------------------------- main
def report(name, m):
    lo, hi = m.bounds()
    print(f"{name}: {m.tri_count()} tris, bounds x[{lo[0]:.3f},{hi[0]:.3f}] y[{lo[1]:.3f},{hi[1]:.3f}] "
          f"z[{lo[2]:.3f},{hi[2]:.3f}]")
    for mat in m._order:
        if m._tris.get(mat):
            c = m._mats[mat]["color"]
            print(f"    {mat:11s} {len(m._tris[mat]):5d}  ({c[0]:.4g}, {c[1]:.4g}, {c[2]:.4g})")


def main():
    os.makedirs(OUT, exist_ok=True)
    body, sk = car_body()
    body.save(os.path.join(OUT, "car_player.glb"))
    report("car_player", body)
    wheel = car_wheel()
    wheel.save(os.path.join(OUT, "car_wheel.glb"))
    report("car_wheel", wheel)
    if "--check" in sys.argv:
        clearance(sk)


if __name__ == "__main__":
    main()
