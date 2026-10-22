"""Effects that run at *cell* resolution and land in the grid.

The distinction against `looks.py` is the whole point. A look is a render: it
works at 3-pixel pitch inside a 768px image, and squashing that back into a
48x48 grid averages red|green|blue straight back to white -- measured at 16.7 of
255 from a plain recolour, which is to say it does nothing.

These are computed on the cells themselves. A scanline darkens every other *row
of cells*; a fringe shifts colour by a whole cell. The result is chunkier and
more stylised than the render, and unlike the render it is pixel art: it is
made of real cells with real palette indices, so you can carry on drawing on it.

New colours are **appended** to the palette. Existing indices never move, so
nothing already on the canvas changes meaning.
"""

from __future__ import annotations

import quantise

EFFECTS = [
    {"id": "scanlines", "name": "Scanlines",
     "note": "Darkens every other row of cells."},
    {"id": "glow", "name": "Glow",
     "note": "Blends each cell toward its brightest neighbour, so bright areas halo."},
    {"id": "fringe", "name": "Colour fringe",
     "note": "Takes red from the cell left and blue from the cell right: chromatic aberration, one cell wide."},
    {"id": "crt", "name": "CRT",
     "note": "Fringe, then glow, then scanlines. Kept to a handful of new colours."},
    # The first, unbounded version of CRT. It was a bug -- 245 new colours and a
    # slam into the 255 cap -- and it looked good enough to keep on purpose, so
    # it is its own effect rather than CRT's failure mode.
    {"id": "prism", "name": "Prism",
     "note": "CRT with the fringe at full strength everywhere and no colour budget. Loud."},
]

MAX_COLOURS = 255
# How many colours an effect may *add*. Without a ceiling `fringe` alone is
# combinatorial -- it invents a colour per (left, centre, right) triple, so ten
# colours can generate a thousand -- and the first CRT run produced 245 new ones
# and slammed into the 255 cap. Bounded, the result is also simply better: a
# handful of deliberate fringe colours reads as a screen, a thousand reads as noise.
BUDGET = 28


class Palette:
    """Append-only palette. Handing back an index for a colour it has not seen
    adds it; asking twice gets the same index, so an effect cannot spend a slot
    per cell."""

    def __init__(self, colors: list[str]):
        self.colors = list(colors)
        self._seen = {c: i for i, c in enumerate(self.colors)}
        self.full = False

    def index(self, rgb) -> int | None:
        hex_ = "#%02x%02x%02x" % tuple(max(0, min(255, int(round(v)))) for v in rgb)
        if hex_ in self._seen:
            return self._seen[hex_]
        if len(self.colors) >= MAX_COLOURS:
            self.full = True
            return None
        self._seen[hex_] = len(self.colors)
        self.colors.append(hex_)
        return self._seen[hex_]


def _rgb(pal: Palette, idx: int):
    return quantise.hex_to_rgb(pal.colors[idx]) if 0 <= idx < len(pal.colors) else None


def _luma(c) -> float:
    return 0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2]


def _mix(a, b, t):
    return tuple(a[i] + (b[i] - a[i]) * t for i in range(3))


def scanlines(grid, pal: Palette, dim: float = 0.55):
    out = [row[:] for row in grid]
    for y in range(1, len(grid), 2):
        for x, v in enumerate(grid[y]):
            c = _rgb(pal, v)
            if c is None:
                continue
            i = pal.index(_mix(c, (0, 0, 0), 1 - dim))
            if i is not None:
                out[y][x] = i
    return out


def glow(grid, pal: Palette, amount: float = 0.42):
    """Each cell moves toward its brightest neighbour. Bright regions bleed a
    halo into what is next to them, which is what a tube does to its own light."""
    n = len(grid)
    out = [row[:] for row in grid]
    for y in range(n):
        for x in range(n):
            here = _rgb(pal, grid[y][x])
            if here is None:
                continue
            best, best_l = None, _luma(here)
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    ny, nx = y + dy, x + dx
                    if not (0 <= ny < n and 0 <= nx < n) or (dy == 0 and dx == 0):
                        continue
                    c = _rgb(pal, grid[ny][nx])
                    if c is not None and _luma(c) > best_l:
                        best, best_l = c, _luma(c)
            if best is None:
                continue
            i = pal.index(_mix(here, best, amount))
            if i is not None:
                out[y][x] = i
    return out


def fringe(grid, pal: Palette, amount: float = 0.55, edges_only: bool = True):
    """Red from the cell to the left, blue from the cell to the right.

    Only where the neighbours actually differ, and mixed rather than swapped
    outright. Applying it everywhere at full strength tints flat areas that have
    no edge to fringe, which is most of a drawing.
    """
    n = len(grid)
    out = [row[:] for row in grid]
    for y in range(n):
        for x in range(n):
            here = _rgb(pal, grid[y][x])
            if here is None:
                continue
            left = _rgb(pal, grid[y][x - 1]) if x > 0 else here
            right = _rgb(pal, grid[y][x + 1]) if x < n - 1 else here
            if edges_only and left == here and right == here:
                continue                      # no edge here, nothing to fringe
            shifted = ((left or here)[0], here[1], (right or here)[2])
            i = pal.index(_mix(here, shifted, amount))
            if i is not None:
                out[y][x] = i
    return out


def _fit_budget(grid, colors: list[str], original: int, budget: int = BUDGET):
    """Reduce the colours an effect added down to a budget, nearest in Lab.

    The originals are untouched -- every index that was on the canvas before
    still means what it meant. Only the invented ones are thinned.
    """
    added = colors[original:]
    if len(added) <= budget:
        return grid, colors

    # Median cut over the invented colours alone, then send each to its nearest
    # survivor. Lab, because RGB distance is hue-blind and would merge a red
    # fringe into a green one.
    from PIL import Image
    strip = Image.new("RGB", (len(added), 1))
    strip.putdata([quantise.hex_to_rgb(c) for c in added])
    kept = strip.quantize(colors=budget, method=Image.MEDIANCUT).convert("RGB")
    keep_hex: list[str] = []
    for c in kept.getdata():
        h = "#%02x%02x%02x" % c
        if h not in keep_hex:
            keep_hex.append(h)

    matcher = quantise.Matcher(keep_hex, "lab")
    remap = {}
    for i, c in enumerate(added):
        remap[original + i] = original + matcher.index(quantise.hex_to_rgb(c))
    out = [[remap.get(v, v) for v in row] for row in grid]
    return out, colors[:original] + keep_hex


def apply(grid, colors: list[str], effect: str, budget: int = BUDGET):
    original = len(colors)
    pal = Palette(colors)
    if effect == "scanlines":
        grid = scanlines(grid, pal)
    elif effect == "glow":
        grid = glow(grid, pal)
    elif effect == "fringe":
        grid = fringe(grid, pal)
    elif effect == "crt":
        grid = fringe(grid, pal)
        grid = glow(grid, pal)
        grid = scanlines(grid, pal)
    elif effect == "prism":
        grid = fringe(grid, pal, amount=1.0, edges_only=False)
        grid = glow(grid, pal)
        grid = scanlines(grid, pal)
        budget = MAX_COLOURS
    else:
        raise ValueError(f"unknown effect: {effect!r}")
    grid, colors = _fit_budget(grid, pal.colors, original, budget)
    return grid, colors, pal.full


# ── Gradient fill ─────────────────────────────────────────────────────────────

BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]


def _field(mode, x, y, x0, y0, x1, y1):
    """Position along the gradient, 0 to 1, measured inside the filled area
    rather than the whole canvas -- so filling a selection gives you the whole
    ramp inside it, not a slice of a bigger one."""
    w = max(1, x1 - x0)
    h = max(1, y1 - y0)
    if mode == "vertical":   return (y - y0) / h
    if mode == "horizontal": return (x - x0) / w
    if mode == "diagonal":   return ((x - x0) / w + (y - y0) / h) / 2
    if mode == "radial":
        dx = (x - (x0 + x1) / 2) / (w / 2 or 1)
        dy = (y - (y0 + y1) / 2) / (h / 2 or 1)
        return min(1.0, (dx * dx + dy * dy) ** 0.5)
    return 0.0


def gradient(grid, colors, rect, c_from, c_to, bands=5, mode="vertical", dither=False):
    """Fill an area with a banded ramp between two colours.

    Bands rather than a smooth ramp, because the output is a palette-indexed
    grid: a "smooth" gradient here would just be a great many bands, and would
    spend the palette to look like something it cannot be. Ordered dither is
    offered as the softener instead -- it trades a colour for a texture, which
    is how pixel art has always done it.
    """
    x0, y0, x1, y1 = rect
    a, b = quantise.hex_to_rgb(c_from), quantise.hex_to_rgb(c_to)
    bands = max(2, min(64, int(bands)))
    pal = Palette(colors)
    out = [row[:] for row in grid]

    for y in range(max(0, y0), min(len(grid), y1 + 1)):
        for x in range(max(0, x0), min(len(grid[y]), x1 + 1)):
            t = _field(mode, x, y, x0, y0, x1, y1) * (bands - 1)
            lo = int(t)
            if dither:
                band = lo + (1 if (t - lo) > (BAYER[y % 4][x % 4] + 0.5) / 16 else 0)
            else:
                band = int(round(t))
            band = max(0, min(bands - 1, band))
            f = band / (bands - 1)
            i = pal.index(tuple(a[c] + (b[c] - a[c]) * f for c in range(3)))
            if i is not None:
                out[y][x] = i
    return out, pal.colors, pal.full
