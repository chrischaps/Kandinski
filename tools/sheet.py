"""tools/sheet.py out.png a.png b.png ...  -> a 2-column contact sheet at 640x360 a cell."""
import sys
from PIL import Image
out, *ins = sys.argv[1:]
ims = [Image.open(p).convert("RGB").resize((640, 360), Image.LANCZOS) for p in ins]
cols = 2
rows = (len(ims) + cols - 1) // cols
sheet = Image.new("RGB", (640 * cols, 360 * rows))
for i, im in enumerate(ims):
    sheet.paste(im, ((i % cols) * 640, (i // cols) * 360))
sheet.save(out)
