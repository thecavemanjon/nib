"""Export looks: a palette and a screen filter, applied on the way out.

A look never touches the grid. It changes how a sprite is *photographed*, not
what it is, which is why `Export PNG` stays exactly as clean as it has always
been and these sit beside it rather than replacing it. Anything destined for a
game engine wants the clean one; anything destined for a feed wants these.

Two things had to be right, and both were wrong on the first attempt:

1. **The phosphor mask lives in screen space at a fixed pitch**, not one triad
   per cell. A real tube's grille is far finer than the picture it is showing,
   which is why triads fuse into colour rather than reading as stripes. Tying
   the triad to the cell turns every white cell into a red|green|blue bar.
2. **The filter needs a dark ground to have anything to bloom.** On white paper
   it is nearly invisible. That is what the duotones are for: they give the
   sprite somewhere dark to glow against without touching its grid.
"""

from __future__ import annotations

from PIL import Image, ImageFilter

import quantise

try:
    import numpy as np
    _READY, _WHY = True, ""
except ImportError:  # pragma: no cover - the app greys the menu out instead
    np = None
    _READY, _WHY = False, "numpy is not installed"


def available() -> dict:
    return {"ready": _READY, "note": "Ready." if _READY else f"Not available: {_WHY}"}


# ── The looks ─────────────────────────────────────────────────────────────────
#
# `duotone` re-lights the palette between two colours by luminance, so a
# two-colour sprite lands exactly on the endpoints and a sixteen-colour one
# becomes sixteen shades of the same phosphor. `screen` is the filter itself.

LOOKS = [
    {"id": "clean", "name": "Clean", "duotone": None, "screen": None},
    {"id": "screen", "name": "Screen", "duotone": None,
     "screen": {"strength": 0.50, "radius": 2.6, "amount": 0.9}},
    {"id": "terminal", "name": "Terminal", "duotone": ("#081008", "#33ff88"),
     "screen": {"strength": 0.62, "radius": 3.2, "amount": 1.5}},
    {"id": "amber", "name": "Amber", "duotone": ("#100a04", "#ffb03a"),
     "screen": {"strength": 0.62, "radius": 3.2, "amount": 1.5}},
    {"id": "night", "name": "Night", "duotone": ("#0a0a14", "#e8e8f0"),
     "screen": {"strength": 0.58, "radius": 3.6, "amount": 1.7}},
]


def find(look_id: str) -> dict | None:
    return next((l for l in LOOKS if l["id"] == look_id), None)


def _luma(rgb) -> float:
    r, g, b = rgb
    return 0.299 * r + 0.587 * g + 0.114 * b


def duotone(palette: list[str], dark: str, light: str, invert: bool = True) -> list[str]:
    """Re-light a palette between two colours.

    Normalised against the palette's own darkest and lightest entries rather
    than against 0-255, so a two-colour palette lands exactly on the endpoints
    instead of somewhere in the middle of the ramp.

    `invert` is on by default and it is the whole point. On a scanned drawing
    index 0 is the *paper*, and paper is the brightest colour in the palette.
    On a screen the paper is the part that is **not lit**: a terminal is black
    with glowing text, not green with black text. Mapping tone straight through
    gave a green page with a black castle on it, which looked wrong immediately.
    """
    lums = [_luma(quantise.hex_to_rgb(c)) for c in palette]
    lo, hi = min(lums), max(lums)
    span = (hi - lo) or 1.0
    d, l = quantise.hex_to_rgb(dark), quantise.hex_to_rgb(light)
    out = []
    for v in lums:
        t = (v - lo) / span
        if invert:
            t = 1.0 - t
        out.append("#%02x%02x%02x" % tuple(int(round(d[i] + (l[i] - d[i]) * t)) for i in range(3)))
    return out


# ── The filter ────────────────────────────────────────────────────────────────

def _grille(arr, pitch=3, strength=0.5, gain=1.30):
    """Aperture grille: every column favours one phosphor.

    `strength` attenuates the other two channels rather than killing them. At
    1.0 you get pure stripes and no whites; around 0.5 a white cell still reads
    white while the grille stays visible, which is the whole trick.
    """
    w = arr.shape[1]
    mask = np.full((1, w, 3), 1.0 - strength, dtype=np.float32)
    for k in range(3):
        mask[0, k::pitch, k] = 1.0
    return arr * mask * gain


def _scanlines(arr, period=3, dim=0.62):
    out = arr.copy()
    out[::period, :, :] *= dim
    return out


def _bloom(arr, radius=2.6, amount=0.9):
    """A tube smears light into its neighbours. Without this the mask reads as a
    grid of dots rather than as something lit from behind."""
    img = Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8))
    glow = np.asarray(img.filter(ImageFilter.GaussianBlur(radius)), dtype=np.float32)
    base = np.asarray(img, dtype=np.float32)
    return 255 - (255 - base) * (255 - glow * amount) / 255      # screen blend


def _fringe(arr, px=1):
    out = arr.copy()
    out[:, px:, 0] = arr[:, :-px, 0]
    out[:, :-px, 2] = arr[:, px:, 2]
    return out


def render(grid, palette, scale: int, look_id: str) -> Image.Image:
    """A grid through a look. Falls back to the plain render for `clean`, for an
    unknown id, and whenever numpy is missing: an export must always produce a
    file, even when the decoration cannot."""
    look = find(look_id) or LOOKS[0]
    pal = palette
    if look["duotone"]:
        pal = duotone(palette, *look["duotone"], invert=look.get("invert", True))

    flat = quantise.render(grid, pal, scale=scale)
    if not look["screen"] or not _READY:
        return flat

    # Transparency has no meaning once a screen is involved: an unlit cell is
    # the tube's own black, so flatten onto the darkest colour in the palette.
    ground = min(pal, key=lambda c: _luma(quantise.hex_to_rgb(c)))
    bg = Image.new("RGB", flat.size, quantise.hex_to_rgb(ground))
    bg.paste(flat, (0, 0), flat)

    a = np.asarray(bg, dtype=np.float32)
    s = look["screen"]
    a = _grille(a, strength=s["strength"])
    a = _scanlines(a)
    a = _bloom(a, radius=s["radius"], amount=s["amount"])
    a = _fringe(a)
    return Image.fromarray(np.clip(a, 0, 255).astype(np.uint8))
