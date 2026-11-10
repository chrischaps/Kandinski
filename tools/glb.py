"""A minimal GLB writer: ONE node, ONE mesh, one primitive per material.

Flint expands a multi-node glTF into one child entity per node, which would
multiply the entity count of every pooled prop. Everything Kandinski draws is
therefore a single mesh whose primitives differ only by material, so a prop is
one entity and `set_material_override(id, "<material>", r, g, b, a)` can
recolour any named part at runtime.

    from glb import Model
    m = Model()
    m.quad("road", [(-6, 0, 0), (6, 0, 0), (6, 0, -8), (-6, 0, -8)])   # CCW seen from the normal side
    m.box("body", (-1, 0, -2), (1, 1, 2))
    m.material("road", (0.02, 0.02, 0.03), roughness=0.9)
    m.material("lamp", (1, 1, 1), emissive=(1, 0.2, 0.8), emissive_strength=6)
    m.save("models/tile.glb")

Colours are LINEAR rgb (glTF baseColorFactor). Flat shading: every face gets
its own vertices and its geometric normal.
"""
import json
import math
import struct

import numpy as np


class Model:
    def __init__(self):
        self._tris = {}       # material -> list of (p0, p1, p2)
        self._mats = {}       # material -> dict
        self._order = []

    # ---- materials -------------------------------------------------
    def material(self, name, color, roughness=1.0, metallic=0.0, emissive=None,
                 emissive_strength=1.0, double_sided=False, alpha=1.0):
        self._mats[name] = dict(color=tuple(color), roughness=roughness, metallic=metallic,
                                emissive=emissive, emissive_strength=emissive_strength,
                                double_sided=double_sided, alpha=alpha)
        if name not in self._order:
            self._order.append(name)
        return self

    # ---- geometry --------------------------------------------------
    def tri(self, mat, a, b, c):
        if mat not in self._order:
            self._order.append(mat)
        self._tris.setdefault(mat, []).append((tuple(map(float, a)), tuple(map(float, b)), tuple(map(float, c))))
        return self

    def quad(self, mat, pts):
        a, b, c, d = pts
        self.tri(mat, a, b, c)
        self.tri(mat, a, c, d)
        return self

    def poly(self, mat, pts):
        """Convex polygon fan, CCW seen from its normal side."""
        for i in range(1, len(pts) - 1):
            self.tri(mat, pts[0], pts[i], pts[i + 1])
        return self

    def box(self, mat, lo, hi, faces="xXyYzZ"):
        x0, y0, z0 = lo
        x1, y1, z1 = hi
        if "X" in faces: self.quad(mat, [(x1, y0, z1), (x1, y0, z0), (x1, y1, z0), (x1, y1, z1)])
        if "x" in faces: self.quad(mat, [(x0, y0, z0), (x0, y0, z1), (x0, y1, z1), (x0, y1, z0)])
        if "Y" in faces: self.quad(mat, [(x0, y1, z1), (x1, y1, z1), (x1, y1, z0), (x0, y1, z0)])
        if "y" in faces: self.quad(mat, [(x0, y0, z0), (x1, y0, z0), (x1, y0, z1), (x0, y0, z1)])
        if "Z" in faces: self.quad(mat, [(x0, y0, z1), (x1, y0, z1), (x1, y1, z1), (x0, y1, z1)])
        if "z" in faces: self.quad(mat, [(x1, y0, z0), (x0, y0, z0), (x0, y1, z0), (x1, y1, z0)])
        return self

    def prism(self, mat, profile, x0, x1, cap=True):
        """Extrude a CCW (z, y) side profile (seen from +X) from x0 to x1."""
        n = len(profile)
        for i in range(n):
            (za, ya), (zb, yb) = profile[i], profile[(i + 1) % n]
            self.quad(mat, [(x0, ya, za), (x0, yb, zb), (x1, yb, zb), (x1, ya, za)])
        if cap:
            self.poly(mat, [(x1, y, z) for z, y in profile])
            self.poly(mat, [(x0, y, z) for z, y in reversed(profile)])
        return self

    def cylinder(self, mat, a, b, r0, r1=None, sides=8, caps=True):
        """A (tapered) cylinder from point a to point b."""
        r1 = r0 if r1 is None else r1
        a = np.array(a, float); b = np.array(b, float)
        axis = b - a
        length = np.linalg.norm(axis)
        if length < 1e-9:
            return self
        w = axis / length
        ref = np.array([0.0, 1.0, 0.0]) if abs(w[1]) < 0.9 else np.array([1.0, 0.0, 0.0])
        u = np.cross(ref, w); u /= np.linalg.norm(u)
        v = np.cross(w, u)
        ring = lambda c, r: [c + r * (math.cos(t) * u + math.sin(t) * v)
                             for t in (2 * math.pi * i / sides for i in range(sides))]
        ra, rb = ring(a, r0), ring(b, r1)
        for i in range(sides):
            j = (i + 1) % sides
            self.quad(mat, [ra[i], ra[j], rb[j], rb[i]])
        if caps:
            if r1 > 1e-6: self.poly(mat, rb)
            if r0 > 1e-6: self.poly(mat, list(reversed(ra)))
        return self

    def transformed(self, fn):
        """A copy with every vertex passed through fn((x, y, z)) -> (x, y, z)."""
        out = Model()
        out._mats = dict(self._mats)
        out._order = list(self._order)
        for mat, tris in self._tris.items():
            out._tris[mat] = [tuple(tuple(map(float, fn(p))) for p in t) for t in tris]
        return out

    def merge(self, other, fn=None):
        for mat in other._order:
            if mat not in self._order:
                self._order.append(mat)
        for mat, d in other._mats.items():
            self._mats.setdefault(mat, d)
        for mat, tris in other._tris.items():
            for t in tris:
                if fn:
                    t = tuple(tuple(map(float, fn(p))) for p in t)
                self._tris.setdefault(mat, []).append(t)
        return self

    def bounds(self):
        pts = np.array([p for tris in self._tris.values() for t in tris for p in t])
        return pts.min(axis=0), pts.max(axis=0)

    def tri_count(self):
        return sum(len(t) for t in self._tris.values())

    # ---- export ----------------------------------------------------
    def save(self, path):
        buf = bytearray()
        views, accessors, prims, materials = [], [], [], []

        def push(arr, target):
            while len(buf) % 4:
                buf.append(0)
            off = len(buf)
            buf.extend(arr.tobytes())
            views.append(dict(buffer=0, byteOffset=off, byteLength=arr.nbytes, target=target))
            return len(views) - 1

        used_ext = False
        for mat in self._order:
            tris = self._tris.get(mat)
            if not tris:
                continue
            pos = np.array(tris, dtype=np.float32).reshape(-1, 3)
            tri = pos.reshape(-1, 3, 3)
            nrm = np.cross(tri[:, 1] - tri[:, 0], tri[:, 2] - tri[:, 0])
            ln = np.linalg.norm(nrm, axis=1, keepdims=True)
            ln[ln < 1e-12] = 1.0
            nrm = np.repeat(nrm / ln, 3, axis=0).astype(np.float32)
            idx = np.arange(len(pos), dtype=np.uint32)

            pv = push(pos, 34962)
            accessors.append(dict(bufferView=pv, componentType=5126, count=len(pos), type="VEC3",
                                  min=pos.min(axis=0).tolist(), max=pos.max(axis=0).tolist()))
            pa = len(accessors) - 1
            nv = push(nrm, 34962)
            accessors.append(dict(bufferView=nv, componentType=5126, count=len(nrm), type="VEC3"))
            na = len(accessors) - 1
            iv = push(idx, 34963)
            accessors.append(dict(bufferView=iv, componentType=5125, count=len(idx), type="SCALAR"))
            ia = len(accessors) - 1

            d = self._mats.get(mat, dict(color=(0.8, 0.8, 0.8), roughness=1.0, metallic=0.0, emissive=None,
                                         emissive_strength=1.0, double_sided=False, alpha=1.0))
            m = dict(name=mat,
                     pbrMetallicRoughness=dict(baseColorFactor=[*d["color"][:3], d["alpha"]],
                                               metallicFactor=d["metallic"], roughnessFactor=d["roughness"]),
                     doubleSided=bool(d["double_sided"]))
            if d["alpha"] < 1.0:
                m["alphaMode"] = "BLEND"
            if d["emissive"] is not None:
                m["emissiveFactor"] = [min(1.0, float(c)) for c in d["emissive"]]
                if d["emissive_strength"] != 1.0:
                    m["extensions"] = {"KHR_materials_emissive_strength": {"emissiveStrength": d["emissive_strength"]}}
                    used_ext = True
            materials.append(m)
            prims.append(dict(attributes=dict(POSITION=pa, NORMAL=na), indices=ia, material=len(materials) - 1))

        while len(buf) % 4:
            buf.append(0)
        gltf = dict(asset=dict(version="2.0", generator="kandinski tools/glb.py"),
                    scene=0, scenes=[dict(nodes=[0])], nodes=[dict(mesh=0, name="root")],
                    meshes=[dict(name="mesh", primitives=prims)], materials=materials,
                    accessors=accessors, bufferViews=views, buffers=[dict(byteLength=len(buf))])
        if used_ext:
            gltf["extensionsUsed"] = ["KHR_materials_emissive_strength"]
        js = json.dumps(gltf, separators=(",", ":")).encode()
        while len(js) % 4:
            js += b" "
        total = 12 + 8 + len(js) + 8 + len(buf)
        with open(path, "wb") as f:
            f.write(struct.pack("<III", 0x46546C67, 2, total))
            f.write(struct.pack("<II", len(js), 0x4E4F534A)); f.write(js)
            f.write(struct.pack("<II", len(buf), 0x004E4942)); f.write(bytes(buf))
        return path
