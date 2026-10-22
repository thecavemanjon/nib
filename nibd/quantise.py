"""Turn a source image into a palette-indexed pixel grid.

This is the whole of Nib's v1. No model is involved: downscale, then snap every
pixel to the nearest palette colour. Measured against an LLM painting the same
doodle pixel by pixel, this was ~0.1s versus 7m20s, and the result was better.

The one thing worth getting right is *nearest*. Euclidean distance in raw RGB is
hue-blind: a mid grey can land closer to a cream than to a grey, which speckled a
black-and-white line drawing with yellow. Lab distance fixes that and costs a page
of arithmetic rather than a dependency.
"""

from __future__ import annotations

import io
from typing import Iterable, Sequence

from PIL import Image, ImageChops, ImageFilter

RGB = tuple[int, int, int]


# ── Colour space ──────────────────────────────────────────────────────────────

def _srgb_to_linear(c: float) -> float:
    c /= 255.0
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def _f(t: float) -> float:
    return t ** (1 / 3) if t > 216 / 24389 else (841 / 108) * t + 4 / 29


def rgb_to_lab(rgb: Sequence[int]) -> tuple[float, float, float]:
    """sRGB (0-255) to CIE Lab, D65. Enough precision for palette matching."""
    r, g, b = (_srgb_to_linear(float(v)) for v in rgb[:3])
    # sRGB -> XYZ (D65), then normalised by the white point.
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = (0.2126 * r + 0.7152 * g + 0.0722 * b) / 1.00000
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883
    fx, fy, fz = _f(x), _f(y), _f(z)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def hex_to_rgb(h: str) -> RGB:
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16))


# ── Matching ──────────────────────────────────────────────────────────────────

class Matcher:
    """Nearest-palette-colour lookup, with a cache because source images repeat
    colours heavily once downscaled."""

    def __init__(self, palette: Sequence[str], metric: str = "lab"):
        self.rgb = [hex_to_rgb(c) for c in palette]
        self.metric = metric
        self._pts = [rgb_to_lab(c) for c in self.rgb] if metric == "lab" else [
            (float(r), float(g), float(b)) for r, g, b in self.rgb
        ]
        self._cache: dict[RGB, int] = {}

    def index(self, rgb: RGB) -> int:
        hit = self._cache.get(rgb)
        if hit is not None:
            return hit
        p = rgb_to_lab(rgb) if self.metric == "lab" else (float(rgb[0]), float(rgb[1]), float(rgb[2]))
        best, best_d = 0, float("inf")
        for i, q in enumerate(self._pts):
            d = (p[0] - q[0]) ** 2 + (p[1] - q[1]) ** 2 + (p[2] - q[2]) ** 2
            if d < best_d:
                best_d, best = d, i
                if d == 0.0:
                    break
        self._cache[rgb] = best
        return best


# ── Pipeline ──────────────────────────────────────────────────────────────────

def quantise(
    image: Image.Image,
    size: int,
    palette: Sequence[str],
    metric: str = "lab",
    dither: bool = False,
    ink_bias: float = 0.0,
    alpha_threshold: int = 128,
    adaptive: bool = False,
) -> list[list[int]]:
    """Downscale to size x size and snap to the palette. -1 means transparent.

    `dither` is Floyd-Steinberg over the palette. It helps photographs and hurts
    line art, so it is off by default: the first subjects here are doodles.
    """
    src = image.convert("RGBA")
    small = _downscale(src, size, ink_bias, adaptive=adaptive)
    m = Matcher(palette, metric)

    px = small.load()
    # Working copy in float so error diffusion has somewhere to accumulate.
    buf = [[[float(v) for v in px[x, y][:3]] for x in range(size)] for y in range(size)]
    alpha = [[px[x, y][3] for x in range(size)] for y in range(size)]

    grid: list[list[int]] = [[-1] * size for _ in range(size)]
    for y in range(size):
        for x in range(size):
            if alpha[y][x] < alpha_threshold:
                grid[y][x] = -1
                continue
            old = buf[y][x]
            idx = m.index((_clamp(old[0]), _clamp(old[1]), _clamp(old[2])))
            grid[y][x] = idx
            if not dither:
                continue
            new = m.rgb[idx]
            err = [old[c] - new[c] for c in range(3)]
            for dx, dy, w in ((1, 0, 7 / 16), (-1, 1, 3 / 16), (0, 1, 5 / 16), (1, 1, 1 / 16)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < size and 0 <= ny < size:
                    for c in range(3):
                        buf[ny][nx][c] += err[c] * w
    return grid


def centre_box(image: Image.Image) -> tuple[int, int, int]:
    """The largest centred square, as (left, top, side)."""
    side = min(image.width, image.height)
    return (image.width - side) // 2, (image.height - side) // 2, side


def default_crop(image: Image.Image) -> tuple[int, int, int]:
    """Where the crop frame starts: the largest centred square, always.

    It used to start tight around the drawing for line art, which meant the
    options were a zoomed-in version of the original sitting next to them, with
    no sign of why. The frame is the place to decide framing, and it starts
    showing everything it can."""
    return centre_box(image)


def clamp_crop(image: Image.Image, crop) -> tuple[int, int, int]:
    """A requested (left, top, side) made square, inside the image, and at
    least 8px, whatever arrives."""
    left, top, side = (int(v) for v in crop)
    side = max(8, min(side, image.width, image.height))
    left = min(max(left, 0), image.width - side)
    top = min(max(top, 0), image.height - side)
    return left, top, side


def crop(image: Image.Image, box) -> Image.Image:
    left, top, side = box
    return image.crop((left, top, left + side, top + side))


def trim(image: Image.Image, margin: float = 0.04) -> Image.Image:
    """Crop to the drawing, square, with a small margin. See content_box."""
    box = content_box(image, margin)
    return crop(image, box) if box else image


def content_box(image: Image.Image, margin: float = 0.04) -> tuple[int, int, int] | None:
    """The square around the drawing, keeping a small even margin.

    Measured over hand-drawn doodles, the subject fills 59-84% of the canvas and
    the rest is paper. At 32x32 that wasted third is the difference between
    features that separate and features that merge, so cropping is worth about
    1.5x of grid size and costs nothing.
    """
    grey = image.convert("L")
    # Content is dark on light, so invert before asking where the ink is.
    box = ImageChops.invert(grey).getbbox()
    if box is None:
        return None

    x0, y0, x1, y1 = box
    side = max(x1 - x0, y1 - y0)
    side += int(side * margin) * 2
    # Square and centred, so the aspect of the output never depends on the crop.
    cx, cy = (x0 + x1) // 2, (y0 + y1) // 2

    # Never larger than the source, and never outside it. This used to paste onto
    # a fresh white canvas of the padded size, which crops a scanned page (the
    # subject is smaller than the paper) but *grows* a full-bleed photograph,
    # painting a white border round it and then offering that border to the
    # palette extractor as if it were a colour in the picture. A control called
    # "crop to content" must never add content.
    side = min(side, image.width, image.height)
    half = side // 2
    left = min(max(cx - half, 0), image.width - side)
    top = min(max(cy - half, 0), image.height - side)
    return left, top, side


def analyse(image: Image.Image) -> dict:
    """Decide what kind of picture this is, so the app can pick a palette.

    Two numbers separate the cases with a lot of room to spare, measured over
    hand-drawn doodles, colour gradients and real pixel art:

        line art   saturation 0.0-0.3   extremity 0.94-0.96
        colour     saturation  44-126   extremity 0.02-0.53
        pixel art  saturation  25-58    extremity 0.59-0.82

    Saturation alone would do it, but a greyscale photograph also scores zero,
    so line art additionally has to be mostly pinned at black or white.
    Extremity is what tells a pen drawing from a black-and-white photo.
    """
    small = image.convert("RGB").resize((128, 128), Image.Resampling.LANCZOS)
    px = list(small.getdata())
    n = len(px)

    saturation = sum(max(q) - min(q) for q in px) / n
    extremity = sum(
        1 for r, g, b in px
        if (0.299 * r + 0.587 * g + 0.114 * b) < 40 or (0.299 * r + 0.587 * g + 0.114 * b) > 215
    ) / n

    line_art = saturation < 10 and extremity > 0.85
    return {
        "kind": "line_art" if line_art else "colour",
        "saturation": round(saturation, 1),
        "extremity": round(extremity, 3),
        "suggest_colors": 2 if line_art else 16,
    }


def extract_palette(image: Image.Image, n: int = 16, vivid: float = 6.0) -> list[str]:
    """A palette taken from the image itself, favouring the colours that carry it.

    Measured against fixed palettes on colour sources this is not a small
    improvement, it is the difference between the result reading as the picture
    and reading as something else entirely: Pico-8 turned a green and purple
    gradient into yellow and cyan. A palette that came out of the image cannot
    make that class of mistake.

    Also beat a neural pixel-art model on the same inputs, which is a good
    reminder that the cheap step was the one worth doing well.

    **Weighted k-means in Lab, not median cut.** Median cut splits by population
    and averages each box, so a small vivid thing loses every time: a painted
    bunting's blue head, lime back and red belly all came back grey-green at 24
    colours (2026-09-20, sheets in ~/.nib/sweep). Clustering in Lab, with each
    pixel weighted `1 + vivid * chroma**1.5`, keeps all three at four colours.
    `vivid` is how many times over a fully saturated pixel counts; past about 12
    the result goes garish and shading flattens.

    The darkest and lightest colours are always kept, whatever the weighting
    decides: at 4 to 6 colours five bright blobs would otherwise outbid the
    black outline and the white paper, and a doodle came back brown on cream.
    """
    n = max(2, n)
    try:
        import numpy as np
    except ImportError:
        return _median_cut_palette(image, n)     # numpy is not a hard dependency

    small = image.convert("RGB")
    small.thumbnail((160, 160), Image.Resampling.LANCZOS)
    rgb = np.asarray(small, dtype=np.float64).reshape(-1, 3)
    lab = _to_lab(np, rgb)
    chroma = np.hypot(lab[:, 1], lab[:, 2])
    w = 1.0 + vivid * (chroma / max(chroma.max(), 1e-6)) ** 1.5

    centres = _kmeans(np, lab, rgb, n, w)
    centres = _keep_extremes(np, centres, rgb, lab)
    return ["#%02x%02x%02x" % tuple(int(round(min(255, max(0, v)))) for v in c) for c in centres]


def _median_cut_palette(image: Image.Image, n: int) -> list[str]:
    q = image.convert("RGB").quantize(colors=n, method=Image.Quantize.MEDIANCUT)
    pal = q.getpalette() or []
    out = ["#%02x%02x%02x" % (pal[i * 3], pal[i * 3 + 1], pal[i * 3 + 2])
           for i in range(min(n, len(pal) // 3))]
    return out or ["#000000", "#ffffff"]


def _to_lab(np, rgb):
    c = rgb / 255.0
    c = np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)
    m = np.array([[0.4124, 0.3576, 0.1805], [0.2126, 0.7152, 0.0722], [0.0193, 0.1192, 0.9505]])
    xyz = c @ m.T / np.array([0.95047, 1.0, 1.08883])
    f = np.where(xyz > 216 / 24389, np.cbrt(xyz), (24389 / 27 * xyz + 16) / 116)
    return np.stack([116 * f[:, 1] - 16, 500 * (f[:, 0] - f[:, 1]), 200 * (f[:, 1] - f[:, 2])], 1)


def _kmeans(np, lab, rgb, k, w, iters: int = 12, seed: int = 0):
    """Weighted k-means++ in Lab, reporting each cluster's mean *RGB*.

    Mean RGB rather than converting the Lab centre back: the centre of a cluster
    of real colours is a colour the picture actually contains a version of.
    """
    rng = np.random.default_rng(seed)
    p = w / w.sum()
    cent = [lab[rng.choice(len(lab), p=p)]]
    for _ in range(k - 1):
        d = np.min(((lab[:, None] - np.array(cent)[None]) ** 2).sum(-1), 1) * w
        total = d.sum()
        cent.append(lab[rng.choice(len(lab), p=d / total)] if total > 0 else lab[rng.choice(len(lab))])
    cent = np.array(cent)
    for _ in range(iters):
        lbl = np.argmin(((lab[:, None] - cent[None]) ** 2).sum(-1), 1)
        for j in range(k):
            m = lbl == j
            if m.any():
                cent[j] = (lab[m] * w[m, None]).sum(0) / w[m].sum()
    lbl = np.argmin(((lab[:, None] - cent[None]) ** 2).sum(-1), 1)
    out, use = [], []
    for j in range(k):
        m = lbl == j
        if m.any():
            out.append((rgb[m] * w[m, None]).sum(0) / w[m].sum())
            use.append(float(w[m].sum()))
    order = np.argsort(use)                       # least used first, for replacing
    return np.array(out)[order][::-1]


def _keep_extremes(np, centres, rgb, lab):
    """Make sure the palette spans the image's own darkest and lightest tones.

    `centres` arrives most-used first, so the last entries are the cheapest to
    give up. A tone counts as covered if some palette colour is within 10 of it
    in lightness, which is about where a black outline stops looking black.
    """
    ls = lab[:, 0]
    sample = max(1, len(ls) // 200)          # the darkest and lightest 0.5%
    for order in (np.argsort(ls)[:sample], np.argsort(ls)[-sample:]):
        target = rgb[order].mean(0)
        target_l = _to_lab(np, target[None])[0, 0]
        have = _to_lab(np, centres)[:, 0]
        if np.min(np.abs(have - target_l)) > 10:
            centres = np.vstack([centres[:-1], target[None]])
    return centres


def otsu_threshold(gray: Image.Image) -> int:
    """Otsu's method: the grey level that best separates ink from paper."""
    h = gray.histogram()
    total = sum(h)
    sum_all = sum(i * h[i] for i in range(256))
    sum_b = 0.0
    w_b = 0
    best, thr = 0.0, 128
    for i in range(256):
        w_b += h[i]
        if w_b == 0:
            continue
        w_f = total - w_b
        if w_f == 0:
            break
        sum_b += i * h[i]
        between = w_b * w_f * ((sum_b / w_b) - ((sum_all - sum_b) / w_f)) ** 2
        if between > best:
            best, thr = between, i
    return thr


def line_art(
    image: Image.Image,
    size: int,
    cuts: list[float] | None = None,
    coverage: float = 0.25,
    grey: float | None = None,
    bridge_gaps: bool = True,
    alpha_threshold: int = 128,
) -> list[list[int]]:
    """Reduce a pen drawing by thresholding, not averaging: 0 is paper, the
    last index is ink, anything between is a partly covered cell.

    The ordinary path averages colours and then snaps to a palette, which is
    wrong for a pen drawing: the source has two tones, and averaging invents a
    spread of greys that were never in it. Those greys are what put a halo round
    every edge.

    Here the image is thresholded at *full* resolution, where a 4px stroke is
    unambiguous, and only the resulting mask is reduced. Averaging a mask gives
    the fraction of each destination cell that was ink, which is a number worth
    thresholding: each cut in `cuts` is literally "how much of this cell must be
    ink to reach this tone", descending, so [0.35] is two tones and
    [0.35, 0.15] is three.

    What this cannot do is separate features closer together than one cell. At
    32x32 a castle's eyes merge into its walls because in the source they are
    less than a thirty-second of the image apart. That is a resolution limit,
    not something a better reduction or a cleverer model can recover.
    """
    if cuts is None:                       # older callers passed coverage/grey
        cuts = [coverage] if grey is None else [coverage, grey]
    cuts = sorted((max(0.001, c) for c in cuts), reverse=True)

    gray = image.convert("L")
    thr = otsu_threshold(gray)
    mask = gray.point(lambda v: 255 if v <= thr else 0, mode="L")
    small = mask.resize((size, size), Image.Resampling.BOX)
    alpha = image.convert("RGBA").getchannel("A").resize((size, size), Image.Resampling.BOX)

    def tone(x: int, y: int) -> int:
        if alpha.getpixel((x, y)) < alpha_threshold:
            return -1
        v = small.getpixel((x, y)) / 255
        for i, c in enumerate(cuts):
            if v >= c:
                return len(cuts) - i
        return 0

    grid = [[tone(x, y) for x in range(size)] for y in range(size)]
    return _bridge(grid, small, size) if bridge_gaps else grid


def _bridge(grid: list[list[int]], coverage: Image.Image, size: int,
            floor: float = 0.04) -> list[list[int]]:
    """Reconnect a stroke that the threshold broke.

    A cell the pen only clips falls under every cut and becomes paper, so a
    thin line arrives dotted: at 32x32 a balloon string, a pair of glasses and
    half an outline all came apart. A paper cell with ink on both sides, left
    and right or above and below, that has some ink of its own, is a gap in a
    stroke and is filled. Nothing else thickens, and an empty cell is never
    filled, so an eye or any other enclosed white stays white.
    """
    out = [row[:] for row in grid]
    for y in range(size):
        for x in range(size):
            if grid[y][x] != 0 or coverage.getpixel((x, y)) / 255 < floor:
                continue
            lr = 0 < x < size - 1 and grid[y][x - 1] > 0 and grid[y][x + 1] > 0
            ud = 0 < y < size - 1 and grid[y - 1][x] > 0 and grid[y + 1][x] > 0
            if lr or ud:
                out[y][x] = max(grid[y][x - 1] if lr else 1, grid[y - 1][x] if ud else 1)
    return out


def _downscale(img: Image.Image, size: int, ink_bias: float,
               adaptive: bool = False) -> Image.Image:
    """Reduce to size x size, optionally biased toward the darkest ink.

    A 4px black line in a 2048px drawing covers a sixteenth of a pixel at 32x32,
    so plain area-averaging greys it out and the drawing arrives washed.

    The bias is a halving pyramid: min-filter with a 3x3 kernel, halve, repeat.
    The darkest pixel in each neighbourhood survives every step, so thin lines
    reach the bottom intact. Done as one big kernel at full resolution instead
    (a 25x25 filter over 2048x2048) this took ~10 seconds and stalled the UI on
    every slider tick; the pyramid is the same idea for a fraction of the work.

    `ink_bias` then blends between the plain reduction and the biased one, so the
    dial is continuous rather than a switch. Pointless on photographs, essential
    on doodles, hence a dial and not a default.

    With `adaptive`, the blend varies per cell instead of being one number for
    the whole image -- see `coverage_bias`. `ink_bias` becomes a ceiling: how
    hard to thicken where thickening is safe.
    """
    plain = img.resize((size, size), Image.Resampling.LANCZOS)
    if ink_bias <= 0:
        return plain

    rgb = img.convert("RGB")
    while max(rgb.width, rgb.height) > size * 2:
        rgb = rgb.filter(ImageFilter.MinFilter(3)).reduce(2)
    thick = rgb.resize((size, size), Image.Resampling.LANCZOS).convert("RGBA")
    thick.putalpha(plain.getchannel("A"))

    bias = min(max(ink_bias, 0.0), 1.0)
    if not adaptive:
        return Image.blend(plain, thick, bias)
    return Image.composite(thick, plain, coverage_bias(img, size, bias))


def coverage(image: Image.Image, size: int) -> Image.Image:
    """Per-cell ink fraction, as an L image: 255 means the cell is entirely ink.

    Binarise at full resolution, then box-downscale the mask, so each output
    cell carries the exact proportion of it that was ink.
    """
    grey = image.convert("L")
    t = otsu_threshold(grey)
    mask = grey.point(lambda v: 255 if v < t else 0)
    return mask.resize((size, size), Image.Resampling.BOX)


def coverage_bias(image: Image.Image, size: int, ceiling: float,
                  knee: float = 0.30, radius: int = 8) -> Image.Image:
    """How much to thicken each cell, from how crowded its *neighbourhood* is.

    One global bias cannot serve a drawing: at 0.8 the castle's outline is crisp
    and its scroll collapses into a blob; at 0.4 the scroll survives and the
    outline goes grey. The sweet spot moves within one image, so the dial has to.

    The signal has to be regional, and the first attempt got that wrong. Ink
    fraction *per cell* cannot tell one bold stroke from several crowded ones --
    both fill a similar share of the cells they touch -- so it read the castle's
    outline as crowded, refused to thicken it, and broke it up. Blurring the
    coverage over a few cells separates them properly: a lone stroke sits in a
    mostly empty neighbourhood, and fine detail sits in a busy one.

        outline, empty around it   low regional ink   thicken, it will vanish
        the scroll's fine detail   high               leave it, it will merge
        blank paper                zero               nothing to rescue

    Note the third row: a cell with no ink anywhere near it must get *no* bias,
    or the min-filter pulls in whatever is closest and the paper speckles. So the
    curve is a hump, not a slope -- it rises off zero, peaks at a lone stroke,
    and falls away again as the neighbourhood fills up.
    """
    cov = coverage(image, size).filter(ImageFilter.BoxBlur(radius))
    top = ceiling * 255.0
    k = max(0.01, knee)
    lo = 0.02                      # below this there is no ink to rescue

    def curve(v: int) -> int:
        c = v / 255.0
        if c <= lo:
            return 0
        if c >= k:
            return 0
        # rise steeply off the floor, then fall to nothing by the knee
        t = (c - lo) / (k - lo)
        return int(round(top * min(1.0, (1.0 - t) * 1.6)))

    return cov.point(curve)


def _clamp(v: float) -> int:
    return 0 if v < 0 else (255 if v > 255 else int(round(v)))


def drop_background(grid: list[list[int]], index: int) -> list[list[int]]:
    """Replace one palette index with transparency everywhere it touches an edge
    and everything connected to it. Flood fill from the border, so an enclosed
    region of the same colour (the inside of a tower) survives."""
    size = len(grid)
    out = [row[:] for row in grid]
    seen = [[False] * size for _ in range(size)]
    stack = [(x, y) for x in range(size) for y in (0, size - 1)]
    stack += [(x, y) for y in range(size) for x in (0, size - 1)]
    while stack:
        x, y = stack.pop()
        if not (0 <= x < size and 0 <= y < size) or seen[y][x]:
            continue
        seen[y][x] = True
        if out[y][x] != index:
            continue
        out[y][x] = -1
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    return out


def render(grid: list[list[int]], palette: Sequence[str], scale: int = 1) -> Image.Image:
    """Grid back to an image, nearest-neighbour so the pixels stay pixels."""
    size = len(grid)
    rgb = [hex_to_rgb(c) for c in palette]
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    for y, row in enumerate(grid):
        for x, idx in enumerate(row):
            if 0 <= idx < len(rgb):
                r, g, b = rgb[idx]
                img.putpixel((x, y), (r, g, b, 255))
    if scale > 1:
        img = img.resize((size * scale, size * scale), Image.Resampling.NEAREST)
    return img


def gif_frame(grid: list[list[int]], palette: Sequence[str], scale: int = 1) -> Image.Image:
    """One animation frame as a paletted image, with a transparency index.

    P mode rather than RGBA: GIF is paletted anyway, and going through P hands
    the encoder the exact indices the editor was working in rather than letting
    it re-quantise and invent colours between frames. Transparency gets the slot
    just past the palette, which is why the palette is capped at 255.
    """
    size = len(grid)
    clear = len(palette)
    img = Image.new("P", (size, size), clear)
    img.putdata([v if 0 <= v < clear else clear for row in grid for v in row])
    table: list[int] = []
    for c in palette:
        table.extend(hex_to_rgb(c))
    table.extend((0, 0, 0) * (256 - clear))
    img.putpalette(table)
    if scale > 1:
        img = img.resize((size * scale, size * scale), Image.Resampling.NEAREST)
    return img


def png_bytes(img: Image.Image) -> bytes:
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def usage(grid: Iterable[Iterable[int]]) -> dict[int, int]:
    counts: dict[int, int] = {}
    for row in grid:
        for v in row:
            counts[v] = counts.get(v, 0) + 1
    return counts
