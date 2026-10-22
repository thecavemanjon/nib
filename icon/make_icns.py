"""Build Resources/AppIcon.icns from icon/nib-icon-32.png.

    python3 icon/make_icns.py

The source is the 32x32 pixel art itself: four paint chips on a dark tile,
drawn in Nib (`icon/nib-icon.nibart`). 32 divides every icon size, so from
32px up each size is an exact nearest-neighbour enlargement; smaller than
that is filtered down from a large exact enlargement.

Written with Pillow, not iconutil. iconutil stores 16px and 32px at 1x in a
legacy run-length format that comes back with corrupted pixels (3 at 16px, a
whole row at 32px), and hand-written PNG entries for those two tags are not
read back at all. Pillow omits the 1x 16 and 32 entries; macOS scales from the
Retina ones, which round-trip exactly.
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
src = Image.open(ROOT / "icon" / "nib-icon-32.png").convert("RGB")
big = src.resize((src.width * 22, src.height * 22), Image.NEAREST)


def at(px: int) -> Image.Image:
    if px >= 512:
        return src.resize((px, px), Image.NEAREST).convert("RGBA")
    return big.resize((px, px), Image.LANCZOS).convert("RGBA")


at(1024).save(ROOT / "Resources" / "AppIcon.icns", format="ICNS",
              append_images=[at(p) for p in (16, 32, 64, 128, 256, 512)])
at(1024).save(ROOT / "icon" / "nib-icon.png")
print("wrote Resources/AppIcon.icns and icon/nib-icon.png")
