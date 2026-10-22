"""The project model and every operation the MCP tools expose, with no MCP in it.

Kept apart from `server.py` so each operation can be tested as a plain function,
and so the file format lives in one place. The format is the app's `.nibart`
(see `Sources/Nib/Project.swift`): layers bottom to top, one cel per layer per
frame, cels are square grids of palette indices, -1 is transparent.

Several operations are ports of Swift code (fill, flip/rotate, shade). They
are small and pure, and each says which Swift function it mirrors, because two
copies of one behaviour drift unless someone knows there are two.
"""
from __future__ import annotations

import copy
import io
import json
import math
import os
import sys
import uuid
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "nibd"))
import quantise  # noqa: E402

Cell = tuple[int, int]
Mask = set[Cell]


# ---------------------------------------------------------------- colours

def hex_rgb(h: str) -> tuple[int, int, int]:
    h = h.lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def rgb_hex(c) -> str:
    return "#%02x%02x%02x" % tuple(max(0, min(255, round(v))) for v in c[:3])


def shade(h: str, darker: bool) -> str:
    """One shading step. Mirrors `Palettes.shade` in Palettes.swift: darker also
    leans 8 degrees toward blue and gains saturation, lighter leans toward
    yellow; anything under 0.15 saturation counts as grey and stays neutral."""
    r, g, b = (v / 255 for v in hex_rgb(h))
    mx, mn = max(r, g, b), min(r, g, b)
    d = mx - mn
    hue = 0.0
    if d > 0:
        if mx == r:
            hue = ((g - b) / d) % 6
        elif mx == g:
            hue = (b - r) / d + 2
        else:
            hue = (r - g) / d + 4
        hue *= 60
    sat = 0 if mx == 0 else d / mx
    val = mx
    if sat >= 0.15:
        target = 240.0 if darker else 60.0
        delta = (target - hue) % 360
        if delta > 180:
            delta -= 360
        hue = (hue + max(-8, min(8, delta))) % 360
        sat = sat + (1 - sat) * 0.12 if darker else sat * 0.85
    val = val * 0.78 if darker else val + (1 - val) * 0.4
    c = val * sat
    x = c * (1 - abs((hue / 60) % 2 - 1))
    m = val - c
    r1, g1, b1 = [(c, x, 0), (x, c, 0), (0, c, x), (0, x, c), (x, 0, c), (c, 0, x)][int(hue // 60) % 6]
    return rgb_hex(((r1 + m) * 255, (g1 + m) * 255, (b1 + m) * 255))


# ---------------------------------------------------------------- project

class NibError(Exception):
    """A mistake the agent can fix: bad layer name, cell off the canvas."""


class Project:
    def __init__(self, data: dict, path: str | None = None):
        self.data = data
        self.path = path
        self.mtime = os.path.getmtime(path) if path and os.path.exists(path) else None
        self.history: list[tuple[str, dict]] = []

    # -- file

    @classmethod
    def open(cls, path: str) -> "Project":
        path = os.path.expanduser(path)
        with open(path) as f:
            data = json.load(f)
        if "layers" not in data:  # v1: one cel per frame, no layer list
            data["layers"] = [{"id": str(uuid.uuid4()).upper(), "name": "Layer 1", "visible": True}]
            for fr in data["frames"]:
                if "grid" in fr:
                    fr["cels"] = [fr.pop("grid")]
        return cls(data, path)

    @classmethod
    def blank(cls, size: int, palette: list[str] | None = None) -> "Project":
        return cls({
            "version": 2,
            "layers": [{"id": str(uuid.uuid4()).upper(), "name": "Layer 1", "visible": True}],
            "palette": palette or ["#ffffff", "#000000"],
            "paletteName": "Mono",
            "selectedIndex": 1,
            "frames": [_blank_frame(size, 1)],
            "fps": 8,
        })

    def save(self, path: str | None = None, overwrite: bool = False) -> str:
        """Refuses to overwrite a file that changed on disk since it was opened:
        that is the person's unsaved-then-saved work in the app, and losing it
        is the one thing this must never do."""
        dest = os.path.expanduser(path) if path else self.path
        if not dest:
            raise NibError("No path: this project was never saved. Pass one.")
        if not dest.endswith(".nibart"):
            dest += ".nibart"
        if os.path.exists(dest) and not overwrite:
            same = self.path and os.path.samefile(dest, self.path)
            if not same:
                raise NibError(f"{dest} exists. Pass overwrite=true to replace it.")
            if self.mtime is not None and os.path.getmtime(dest) != self.mtime:
                raise NibError(f"{dest} changed on disk since it was opened (probably "
                               "saved from the app). Save elsewhere, or pass overwrite=true "
                               "if replacing that work is intended.")
        tmp = dest + ".tmp"
        with open(tmp, "w") as f:
            json.dump(self.data, f, separators=(",", ":"), sort_keys=True)
        os.replace(tmp, dest)
        self.path, self.mtime = dest, os.path.getmtime(dest)
        return dest

    # -- shape

    @property
    def size(self) -> int:
        return len(self.data["frames"][0]["cels"][0])

    @property
    def palette(self) -> list[str]:
        return self.data["palette"]

    @property
    def layers(self) -> list[dict]:
        return self.data["layers"]

    @property
    def frames(self) -> list[dict]:
        return self.data["frames"]

    def layer_index(self, layer: str | int | None) -> int:
        """Name or index; None means the top layer, which is where the app draws."""
        if layer is None:
            return len(self.layers) - 1
        if isinstance(layer, int) or (isinstance(layer, str) and layer.lstrip("-").isdigit()):
            i = int(layer)
            if not -len(self.layers) <= i < len(self.layers):
                raise NibError(f"No layer {i}; there are {len(self.layers)}.")
            return i % len(self.layers)
        for i, l in enumerate(self.layers):
            if l["name"] == layer:
                return i
        raise NibError(f"No layer called {layer!r}. Layers: {[l['name'] for l in self.layers]}")

    def frame(self, i: int) -> dict:
        if not 0 <= i < len(self.frames):
            raise NibError(f"No frame {i}; there are {len(self.frames)}.")
        return self.frames[i]

    def cel(self, frame: int, layer) -> list[list[int]]:
        return self.frame(frame)["cels"][self.layer_index(layer)]

    def composite(self, frame: int = 0) -> list[list[int]]:
        n = self.size
        out = [[-1] * n for _ in range(n)]
        for cel, info in zip(self.frame(frame)["cels"], self.layers):
            if not info.get("visible", True):
                continue
            for y in range(n):
                for x in range(n):
                    if cel[y][x] >= 0:
                        out[y][x] = cel[y][x]
        return out

    def colour(self, c) -> int:
        """A palette index from an index or a hex colour. A new hex is appended,
        never inserted, so no existing index changes meaning."""
        if isinstance(c, int) or (isinstance(c, str) and c.lstrip("-").isdigit()):
            i = int(c)
            if i != -1 and not 0 <= i < len(self.palette):
                raise NibError(f"No palette index {i}; the palette has {len(self.palette)}.")
            return i
        if isinstance(c, str) and c.lower() in ("transparent", "clear", "none"):
            return -1
        h = rgb_hex(hex_rgb(c))
        if h in self.palette:
            return self.palette.index(h)
        if len(self.palette) >= 255:
            raise NibError("The palette is full (255, the GIF limit).")
        self.palette.append(h)
        self._palette_edited()
        return len(self.palette) - 1

    def _palette_edited(self):
        name = self.data.get("paletteName", "Custom")
        if not name.endswith(" (edited)"):
            self.data["paletteName"] = name + " (edited)"

    # -- history

    def checkpoint(self, label: str):
        self.history.append((label, copy.deepcopy(self.data)))
        del self.history[:-50]

    def undo(self, steps: int = 1) -> list[str]:
        undone = []
        for _ in range(steps):
            if not self.history:
                break
            label, data = self.history.pop()
            self.data = data
            undone.append(label)
        return undone

    def usage(self) -> dict[int, int]:
        counts: dict[int, int] = {}
        for fr in self.frames:
            for cel in fr["cels"]:
                for row in cel:
                    for v in row:
                        counts[v] = counts.get(v, 0) + 1
        return counts

    def summary(self) -> str:
        u = self.usage()
        pal = ", ".join(f"{i}:{h}({u.get(i, 0)})" for i, h in enumerate(self.palette))
        layers = ", ".join(f"{i}:{l['name']}{'' if l.get('visible', True) else ' (hidden)'}"
                           for i, l in enumerate(self.layers))
        return (f"{self.size}x{self.size}, {len(self.frames)} frame(s) at {self.data.get('fps', 8)}fps\n"
                f"Layers, bottom to top: {layers}\n"
                f"Palette index:hex(cells using it): {pal}\n"
                f"File: {self.path or '(unsaved)'}")


def _blank_frame(size: int, layers: int) -> dict:
    return {"id": str(uuid.uuid4()).upper(), "hold": 1,
            "cels": [[[-1] * size for _ in range(size)] for _ in range(layers)]}


# ---------------------------------------------------------------- selection

def select(p: Project, by: str, frame: int = 0, layer=None, rect=None, colour=None) -> Mask:
    n = p.size
    everything = {(x, y) for y in range(n) for x in range(n)}
    if by == "all":
        return everything
    if by == "rect":
        if not rect or len(rect) != 4:
            raise NibError("rect needs [x0, y0, x1, y1], inclusive.")
        x0, y0, x1, y1 = rect
        return {(x, y) for (x, y) in everything
                if min(x0, x1) <= x <= max(x0, x1) and min(y0, y1) <= y <= max(y0, y1)}
    if by == "colour":
        # One colour or several: stars in three tints are still one selection.
        idx = {p.colour(c) for c in (colour if isinstance(colour, list) else [colour])}
        g = p.cel(frame, layer) if layer is not None else p.composite(frame)
        return {(x, y) for (x, y) in everything if g[y][x] in idx}
    if by == "layer":
        g = p.cel(frame, layer)
        return {(x, y) for (x, y) in everything if g[y][x] >= 0}
    if by in ("outside", "inside"):
        # Flood from the edges through cells that look like background in the
        # composite, ignoring any full-canvas backdrop layer: transparent, or the
        # colour that fills the corners. The subject's outline is the wall.
        g = _composite_without_backdrops(p, frame)
        bg = {-1, g[0][0], g[0][n - 1], g[n - 1][0], g[n - 1][n - 1]}
        seen: Mask = set()
        stack = [(x, y) for x in range(n) for y in (0, n - 1)] + \
                [(x, y) for y in range(n) for x in (0, n - 1)]
        while stack:
            x, y = stack.pop()
            if not (0 <= x < n and 0 <= y < n) or (x, y) in seen or g[y][x] not in bg:
                continue
            seen.add((x, y))
            stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
        return seen if by == "outside" else everything - seen
    raise NibError(f"Unknown selection {by!r}: use all, rect, colour, layer, outside or inside.")


def _composite_without_backdrops(p: Project, frame: int) -> list[list[int]]:
    n = p.size
    out = [[-1] * n for _ in range(n)]
    for cel, info in zip(p.frame(frame)["cels"], p.layers):
        if not info.get("visible", True) or all(v >= 0 for row in cel for v in row):
            continue
        for y in range(n):
            for x in range(n):
                if cel[y][x] >= 0:
                    out[y][x] = cel[y][x]
    return out


def bounds(mask: Mask) -> tuple[int, int, int, int] | None:
    if not mask:
        return None
    xs = [c[0] for c in mask]
    ys = [c[1] for c in mask]
    return min(xs), min(ys), max(xs), max(ys)


# ---------------------------------------------------------------- edits

def paint(p: Project, colour, cells=None, fill_at=None, frame=0, layer=None) -> int:
    idx = p.colour(colour)
    g = p.cel(frame, layer)
    n = p.size
    changed = 0
    if cells:
        for x, y in cells:
            if not (0 <= x < n and 0 <= y < n):
                raise NibError(f"Cell ({x}, {y}) is off the {n}x{n} canvas.")
            if g[y][x] != idx:
                g[y][x] = idx
                changed += 1
    if fill_at:
        # Mirrors CanvasStore.fill: 4-connected flood of the clicked colour.
        x, y = fill_at
        if not (0 <= x < n and 0 <= y < n):
            raise NibError(f"Cell ({x}, {y}) is off the {n}x{n} canvas.")
        target = g[y][x]
        if target != idx:
            stack = [(x, y)]
            while stack:
                cx, cy = stack.pop()
                if not (0 <= cx < n and 0 <= cy < n) or g[cy][cx] != target:
                    continue
                g[cy][cx] = idx
                changed += 1
                stack += [(cx + 1, cy), (cx - 1, cy), (cx, cy + 1), (cx, cy - 1)]
    return changed


def transform(p: Project, op: str, mask: Mask | None = None, frame=0, layer=None,
              dx: int = 0, dy: int = 0, size: int | None = None) -> str:
    n = p.size
    if op == "canvas_size":
        if not size or size < 4:
            raise NibError("canvas_size needs size >= 4.")
        off = (size - n) // 2
        for fr in p.frames:
            fr["cels"] = [_reframe(cel, size, off, off) for cel in fr["cels"]]
        p.data.pop("source", None)  # its pickedGrid no longer fits
        return f"canvas {n} -> {size}, content centred"
    if op == "recentre":
        # Every layer moves together, so a sprite and its brush stay attached.
        box = bounds(mask or select(p, "inside", frame))
        if not box:
            return "nothing to centre"
        x0, y0, x1, y1 = box
        mx = (n - (x1 - x0 + 1)) // 2 - x0
        my = (n - (y1 - y0 + 1)) // 2 - y0
        for fr in p.frames:
            fr["cels"] = [cel if all(v >= 0 for r in cel for v in r) else _reframe(cel, n, mx, my)
                          for cel in fr["cels"]]
        return f"moved by ({mx}, {my})"
    if op == "roll":
        g = p.cel(frame, layer)
        rolled = [[g[(y - dy) % n][(x - dx) % n] for x in range(n)] for y in range(n)]
        _replace(p, frame, layer, rolled)
        return f"rolled by ({dx}, {dy}), wrapping"
    if op in ("flip_h", "flip_v", "rotate_cw", "rotate_ccw"):
        return _flip_rotate(p, op, mask, frame, layer)
    raise NibError(f"Unknown transform {op!r}.")


def _reframe(cel, size, ox, oy):
    n = len(cel)
    out = [[-1] * size for _ in range(size)]
    for y in range(n):
        for x in range(n):
            if 0 <= x + ox < size and 0 <= y + oy < size:
                out[y + oy][x + ox] = cel[y][x]
    return out


def _replace(p, frame, layer, grid):
    p.frame(frame)["cels"][p.layer_index(layer)] = grid


def _flip_rotate(p, op, mask, frame, layer) -> str:
    """Mirrors Grids.transformed in Shapes.swift: the selection's box turns about
    its centre; outside the old box only opaque cells are stamped."""
    n = p.size
    g = p.cel(frame, layer)
    box = bounds(mask) if mask else (0, 0, n - 1, n - 1)
    x0, y0, x1, y1 = box
    w, h = x1 - x0 + 1, y1 - y0 + 1
    OUT = None
    block = [[g[y][x] if (mask is None or (x, y) in mask) else OUT
              for x in range(x0, x1 + 1)] for y in range(y0, y1 + 1)]
    if op == "flip_h":
        out = [list(reversed(r)) for r in block]
    elif op == "flip_v":
        out = list(reversed(block))
    elif op == "rotate_cw":
        out = [[block[h - 1 - yy][xx] for yy in range(h)] for xx in range(w)]
    else:
        out = [[block[yy][w - 1 - xx] for yy in range(h)] for xx in range(w)]
    nh, nw = len(out), len(out[0])
    ox, oy = x0 + (w - nw) // 2, y0 + (h - nh) // 2
    new = [r[:] for r in g]
    for yy in range(h):
        for xx in range(w):
            if block[yy][xx] is not OUT:
                new[y0 + yy][x0 + xx] = -1
    for yy, row in enumerate(out):
        for xx, v in enumerate(row):
            x, y = ox + xx, oy + yy
            if v is not OUT and v >= 0 and 0 <= x < n and 0 <= y < n:
                new[y][x] = v
    _replace(p, frame, layer, new)
    return op.replace("_", " ")


BAYER2 = [[0, 2], [3, 1]]


def gradient(p: Project, stops: list[str], bands: int = 5, mode: str = "vertical",
             dither: bool = False, mask: Mask | None = None, frame=0, layer=None) -> str:
    """Banded gradient through any number of colour stops. Each band is one
    palette colour, appended if new. With `dither`, a 2x2 checker fills the far
    half of each band edge, as on the Nib icon."""
    if len(stops) < 2:
        raise NibError("A gradient needs at least two stops.")
    bands = max(2, min(16, bands))
    n = p.size
    cells = mask if mask is not None else {(x, y) for y in range(n) for x in range(n)}
    if not cells:
        return "empty selection, nothing filled"
    x0, y0, x1, y1 = bounds(cells)
    rgbs = [hex_rgb(s) for s in stops]

    def band_colour(i):
        t = i / (bands - 1) * (len(rgbs) - 1)
        j = min(int(t), len(rgbs) - 2)
        u = t - j
        return rgb_hex([rgbs[j][k] + (rgbs[j + 1][k] - rgbs[j][k]) * u for k in range(3)])

    idx = [p.colour(band_colour(i)) for i in range(bands)]

    def field(x, y):
        fx = (x - x0) / max(1, x1 - x0)
        fy = (y - y0) / max(1, y1 - y0)
        if mode == "horizontal":
            return fx
        if mode == "diagonal":
            return (fx + fy) / 2
        if mode == "radial":
            cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
            r = math.hypot(max(1, x1 - x0) / 2, max(1, y1 - y0) / 2)
            return min(1.0, math.hypot(x - cx, y - cy) / r)
        return fy

    g = p.cel(frame, layer)
    for x, y in cells:
        t = field(x, y) * (bands - 1)
        i = int(t)
        if dither and t - i > 0.5 and BAYER2[y % 2][x % 2] < 2 and i + 1 < bands:
            i += 1
        elif not dither:
            i = round(t)
        g[y][x] = idx[min(i, bands - 1)]
    return f"{bands} bands {mode}{', dithered' if dither else ''} over {len(cells)} cells"


def palette_op(p: Project, op: str, index: int | None = None, colour: str | None = None,
               to: int | None = None, darker: bool = True, steps: int = 1) -> str:
    pal = p.palette
    if op == "add":
        i = p.colour(colour)
        return f"{pal[i]} is index {i}"
    if index is None or not 0 <= index < len(pal):
        raise NibError(f"{op} needs a palette index 0..{len(pal) - 1}.")
    if op == "replace":
        was = pal[index]
        pal[index] = rgb_hex(hex_rgb(colour))
        p._palette_edited()
        return f"index {index}: {was} -> {pal[index]}, every cell using it changes colour"
    if op == "swap":
        if to is None or not 0 <= to < len(pal):
            raise NibError("swap needs `to`, another palette index.")
        moved = 0
        for fr in p.frames:
            for cel in fr["cels"]:
                for row in cel:
                    for x, v in enumerate(row):
                        if v == index:
                            row[x] = to
                            moved += 1
        return f"{moved} cells moved from {index} to {to}, everywhere"
    if op == "shade":
        made, h = [], pal[index]
        for _ in range(max(1, min(6, steps))):
            h = shade(h, darker)
            made.append(p.colour(h))
        return f"{'darker' if darker else 'lighter'} steps of {index}: indices {made}"
    if op == "remove":
        if len(pal) <= 2:
            raise NibError("A palette keeps at least two colours.")
        target = min((i for i in range(len(pal)) if i != index),
                     key=lambda i: sum((a - b) ** 2 for a, b in zip(hex_rgb(pal[i]), hex_rgb(pal[index]))))
        for fr in p.frames:
            for cel in fr["cels"]:
                for row in cel:
                    for x, v in enumerate(row):
                        if v == index:
                            row[x] = target
                        if row[x] > index:
                            row[x] -= 1
        del pal[index]
        p._palette_edited()
        return f"removed {index}; its cells went to the nearest colour"
    raise NibError(f"Unknown palette op {op!r}.")


def structure(p: Project, op: str, name: str | None = None, layer=None,
              position: str | int | None = None, frame: int = 0) -> str:
    n = p.size
    if op == "add_layer":
        info = {"id": str(uuid.uuid4()).upper(), "name": name or f"Layer {len(p.layers) + 1}",
                "visible": True}
        at = 0 if position in ("bottom", "below") else (
            len(p.layers) if position in (None, "top", "above") else int(position))
        p.layers.insert(at, info)
        for fr in p.frames:
            fr["cels"].insert(at, [[-1] * n for _ in range(n)])
        return f"added {info['name']!r} at position {at} (0 is the bottom)"
    i = p.layer_index(layer)
    if op in ("hide_layer", "show_layer"):
        p.layers[i]["visible"] = op == "show_layer"
        return f"{p.layers[i]['name']} {'shown' if op == 'show_layer' else 'hidden'}"
    if op == "delete_layer":
        if len(p.layers) == 1:
            raise NibError("The last layer cannot be deleted.")
        gone = p.layers.pop(i)
        for fr in p.frames:
            fr["cels"].pop(i)
        return f"deleted {gone['name']!r}"
    if op == "move_layer":
        to = 0 if position == "bottom" else len(p.layers) - 1 if position == "top" else int(position)
        info = p.layers.pop(i)
        p.layers.insert(to, info)
        for fr in p.frames:
            fr["cels"].insert(to, fr["cels"].pop(i))
        return f"{info['name']!r} now at position {to}"
    if op == "rename_layer":
        p.layers[i]["name"] = name
        return f"renamed to {name!r}"
    if op == "add_frame":
        p.frames.append(_blank_frame(n, len(p.layers)))
        return f"blank frame {len(p.frames) - 1}"
    if op == "duplicate_frame":
        dup = copy.deepcopy(p.frame(frame))
        dup["id"] = str(uuid.uuid4()).upper()
        p.frames.insert(frame + 1, dup)
        return f"frame {frame} duplicated as {frame + 1}"
    if op == "delete_frame":
        if len(p.frames) == 1:
            raise NibError("The last frame cannot be deleted.")
        p.frame(frame)
        p.frames.pop(frame)
        return f"deleted frame {frame}"
    raise NibError(f"Unknown structure op {op!r}.")


def lift(p: Project, mask: Mask, name: str, layer=None, fill: str = "none") -> str:
    """Move the masked cells off a layer onto a new layer just above it.

    Every frame, since a layer exists in every frame. `fill` decides what the
    holes become: "none" leaves them transparent; "surroundings" patches each
    from the cells two, four and six along in its own row, skipping the lifted
    ones. Even offsets, because those land on the same phase of a checkerboard
    dither, so a dithered gradient closes over the hole instead of showing a
    patch of the wrong half of the pattern.
    """
    if not mask:
        raise NibError("The selection is empty: nothing to lift.")
    if fill not in ("none", "surroundings"):
        raise NibError("fill is none or surroundings.")
    src = p.layer_index(layer)
    n = p.size
    info = {"id": str(uuid.uuid4()).upper(), "name": name, "visible": True}
    p.layers.insert(src + 1, info)
    moved = 0
    for fr in p.frames:
        old = fr["cels"][src]
        new = [[-1] * n for _ in range(n)]
        left = [row[:] for row in old]
        for (x, y) in mask:
            if old[y][x] >= 0:
                new[y][x] = old[y][x]
                left[y][x] = -1
                moved += 1
        if fill == "surroundings":
            for (x, y) in mask:
                near = [old[y][x + k] for k in (-2, 2, -4, 4, -6, 6)
                        if 0 <= x + k < n and (x + k, y) not in mask and old[y][x + k] >= 0]
                if not near:
                    near = [old[yy][xx] for xx, yy in ((x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1))
                            if 0 <= xx < n and 0 <= yy < n and (xx, yy) not in mask and old[yy][xx] >= 0]
                if near:
                    left[y][x] = max(set(near), key=near.count)
        fr["cels"][src] = left
        fr["cels"].insert(src + 1, new)
    return (f"lifted {moved // len(p.frames)} cells from {p.layers[src]['name']!r} onto a new "
            f"layer {name!r} just above it" + (", holes filled from their row" if fill != "none" else ""))


def roll_across(p: Project, layer, frames: int | None = None, dx: int = 0, dy: int = 0,
                start: int = 0) -> str:
    """Replace the animation with copies of one frame in which only `layer`
    moves, (dx, dy) cells further each frame, wrapping. The rest hold still.

    Mirrors CanvasStore.buildScroll ("Roll Across Frames"), keep-going mode.
    Without `frames`, exactly enough for one full turn, which loops seamlessly.
    """
    if dx == 0 and dy == 0:
        raise NibError("Give dx or dy: which way, and how many cells per frame.")
    n = p.size
    li = p.layer_index(layer)
    turn = math.lcm(n // math.gcd(n, abs(dx)), n // math.gcd(n, abs(dy)))
    count = frames or turn
    if not 2 <= count <= 256:
        raise NibError(f"{count} frames: use 2 to 256.")
    template = copy.deepcopy(p.frame(start))
    base = template["cels"][li]
    out = []
    for i in range(count):
        f = copy.deepcopy(template)
        f["id"], f["hold"] = str(uuid.uuid4()).upper(), 1
        ox, oy = dx * i, dy * i
        f["cels"][li] = [[base[(y - oy) % n][(x - ox) % n] for x in range(n)] for y in range(n)]
        out.append(f)
    p.data["frames"] = out
    note = "" if count % turn == 0 else (
        f" Not a whole turn, so the loop will jump; {turn} frames would close it.")
    return (f"{count} frames, {p.layers[li]['name']!r} moving ({dx}, {dy}) per frame from "
            f"frame {start}; the animation was replaced.{note}")


# ---------------------------------------------------------------- pictures

def grid_image(p: Project, grid, checker=True) -> Image.Image:
    n = len(grid)
    im = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    px = im.load()
    for y in range(n):
        for x in range(n):
            v = grid[y][x]
            if v >= 0:
                px[x, y] = hex_rgb(p.palette[v]) + (255,)
            elif checker:
                px[x, y] = (204, 204, 204, 255) if (x + y) % 2 else (236, 236, 236, 255)
    return im


def scaled(im: Image.Image, target: int) -> Image.Image:
    k = max(1, target // im.width)
    return im.resize((im.width * k, im.height * k), Image.NEAREST)


def png(im: Image.Image) -> bytes:
    b = io.BytesIO()
    im.save(b, "PNG")
    return b.getvalue()


def outline_mask(im: Image.Image, mask: Mask, n: int) -> Image.Image:
    k = im.width // n
    out = im.convert("RGB")
    d = ImageDraw.Draw(out)
    for x, y in mask:
        for neighbour, (a, b) in (((x, y - 1), ((x, y), (x + 1, y))),
                                  ((x, y + 1), ((x, y + 1), (x + 1, y + 1))),
                                  ((x - 1, y), ((x, y), (x, y + 1))),
                                  ((x + 1, y), ((x + 1, y), (x + 1, y + 1)))):
            if neighbour not in mask:
                d.line([(a[0] * k, a[1] * k), (b[0] * k, b[1] * k)], fill=(255, 0, 200), width=2)
    return out


def sheet(items: list[tuple[str, Image.Image]], sizes=(160,), columns: int = 4) -> Image.Image:
    """Labelled options side by side, each at every size in `sizes`. The thing
    every good decision in the icon round came from."""
    cell_w = sum(sizes) + 12 * len(sizes) + 12
    cell_h = max(sizes) + 30
    rows = (len(items) + columns - 1) // columns
    out = Image.new("RGB", (cell_w * min(columns, len(items)), cell_h * rows), (236, 236, 238))
    d = ImageDraw.Draw(out)
    for i, (label, im) in enumerate(items):
        X, Y = (i % columns) * cell_w, (i // columns) * cell_h
        x = X + 8
        for s in sizes:
            t = im.resize((s, s), Image.NEAREST if s >= im.width else Image.LANCZOS)
            if t.mode == "RGBA":
                out.paste(t, (x, Y + 22 + (max(sizes) - s) // 2), t)
            else:
                out.paste(t, (x, Y + 22 + (max(sizes) - s) // 2))
            x += s + 12
        d.text((X + 8, Y + 6), label, fill=(70, 70, 70))
    return out


def _squircle_mask(size=1024) -> Image.Image:
    big = size * 2
    m = Image.new("L", (big, big), 0)
    a = big / 2
    pts = []
    for i in range(1440):
        t = 2 * math.pi * i / 1440
        c, s = math.cos(t), math.sin(t)
        pts.append((a + a * math.copysign(abs(c) ** 0.4, c), a + a * math.copysign(abs(s) ** 0.4, s)))
    ImageDraw.Draw(m).polygon(pts, fill=255)
    return m.resize((size, size), Image.LANCZOS)


def as_icon(p: Project, frame=0) -> Image.Image:
    """The composite, full-bleed, masked the way macOS 26 masks a square icon."""
    art = grid_image(p, p.composite(frame), checker=False).convert("RGB")
    full = art.resize((1024, 1024), Image.NEAREST)
    out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    out.paste(full, (0, 0), _squircle_mask())
    return out


def icon_preview(icons: list[tuple[str, Image.Image]], sizes=(256, 128, 64, 32)) -> Image.Image:
    """Each icon at Dock sizes, on a light Dock and a dark one, side by side."""
    light = _icon_panel(icons, sizes, (236, 236, 238))
    dark = _icon_panel(icons, sizes, (38, 38, 42))
    out = Image.new("RGB", (light.width * 2 + 20, light.height), (255, 255, 255))
    out.paste(light, (0, 0))
    out.paste(dark, (light.width + 20, 0))
    return out


def _icon_panel(icons, sizes, bg) -> Image.Image:
    cell_w = sum(sizes) + 16 * len(sizes) + 16
    cell_h = max(sizes) + 34
    out = Image.new("RGB", (cell_w, cell_h * len(icons)), bg)
    d = ImageDraw.Draw(out)
    for r, (label, im) in enumerate(icons):
        x = 12
        for s in sizes:
            t = im.resize((s, s), Image.LANCZOS)
            out.paste(t, (x, r * cell_h + 26 + (max(sizes) - s) // 2), t)
            x += s + 16
        d.text((12, r * cell_h + 8), label, fill=(150, 150, 150))
    return out


def export(p: Project, kind: str, path: str, scale: int = 8, frame: int = 0) -> str:
    path = os.path.expanduser(path)
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    if kind == "png":
        grid_image(p, p.composite(frame), checker=False).resize(
            (p.size * scale, p.size * scale), Image.NEAREST).save(path)
        return path
    if kind == "gif":
        imgs = [quantise.gif_frame(p.composite(i), p.palette, scale) for i in range(len(p.frames))]
        durs = [int(1000 / p.data.get("fps", 8)) * fr.get("hold", 1) for fr in p.frames]
        imgs[0].save(path, save_all=True, append_images=imgs[1:], duration=durs, loop=0,
                     disposal=2, transparency=len(p.palette), optimize=False)
        return path
    if kind == "icns":
        if 1024 % p.size:
            raise NibError(f"An icon needs a canvas that divides 1024 (16, 32, 64, 128); "
                           f"this one is {p.size}, so cells would come out uneven widths.")
        art = grid_image(p, p.composite(frame), checker=False).convert("RGB")

        def at(px):
            if px >= p.size:
                return art.resize((px, px), Image.NEAREST).convert("RGBA")
            return art.resize((1024, 1024), Image.NEAREST).resize((px, px), Image.LANCZOS).convert("RGBA")
        # Pillow, not iconutil: iconutil corrupts the 1x 16 and 32px entries.
        at(1024).save(path, format="ICNS", append_images=[at(s) for s in (16, 32, 64, 128, 256, 512)])
        return path
    raise NibError(f"Unknown export kind {kind!r}: png, gif or icns.")
