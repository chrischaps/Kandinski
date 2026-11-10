"""pump.py <frames_dir> : how much does the picture jump frame to frame?

For consecutive frames, find the vertical and horizontal shift of the sky and
horizon band (top 48% of the frame, HUD rows skipped) by matching row and
column luminance profiles at sub-pixel precision. A steady camera gives a
smooth shift series; a sawtooth shows as a slow drift with periodic snaps.
Prints the series' statistics and the frame-to-frame *change* of the shift
(jerk), which is what the eye reads as bumpiness.
"""
import glob
import sys

import numpy as np
from PIL import Image


def profile_shift(a, b, max_shift=12):
    """Sub-pixel shift of 1-D profile b relative to a."""
    a = a - a.mean(); b = b - b.mean()
    best, scores = 0, []
    for s in range(-max_shift, max_shift + 1):
        if s >= 0:
            x, y = a[s:], b[:len(b) - s]
        else:
            x, y = a[:s], b[-s:]
        scores.append(-np.mean((x - y) ** 2))
    scores = np.array(scores)
    i = int(scores.argmax())
    if 0 < i < len(scores) - 1:
        l, c, r = scores[i - 1], scores[i], scores[i + 1]
        d = (l - r) / (2 * (l - 2 * c + r) + 1e-12)
    else:
        d = 0.0
    return (i - max_shift) + d


files = sorted(glob.glob(sys.argv[1] + "/*.png"))
rows, cols = [], []
for f in files:
    im = np.asarray(Image.open(f).convert("L"), dtype=np.float32)
    h, w = im.shape
    band = im[int(h * 0.14):int(h * 0.48), :]
    rows.append(band.mean(axis=1))
    cols.append(band.mean(axis=0))
dy = np.array([profile_shift(rows[i], rows[i + 1]) for i in range(len(rows) - 1)])
dx = np.array([profile_shift(cols[i], cols[i + 1], 24) for i in range(len(cols) - 1)])
h = Image.open(files[0]).size[1]
for name, d in (("vertical", dy), ("horizontal", dx)):
    jerk = np.diff(d)
    print(f"{name:10s} shift px/frame: mean {d.mean():+.3f}  sd {d.std():.3f}  max |{np.abs(d).max():.2f}|   "
          f"jerk sd {jerk.std():.3f}  max |{np.abs(jerk).max():.2f}|  (frame height {h})")
np.save(sys.argv[1] + "/dy.npy", dy)
np.save(sys.argv[1] + "/dx.npy", dx)
print("vertical shift, first 40 frames:", " ".join(f"{v:+.1f}" for v in dy[:40]))
