"""The Nib daemon: one long-lived process holding the quantiser.

Same shape as chess-coach's `coachd`: a Unix socket speaking JSON lines, started
on demand by the Swift app and never launched by hand. It exists so the pipeline
has exactly one implementation, and because Pillow does the image work better
than anything Swift offers without pulling in a framework.

Protocol: one JSON object per line in, one JSON object per line out.
Every reply carries "ok": true/false. A false reply always carries "error".
"""

from __future__ import annotations

import base64
import json
import os
import socket
import sys
import urllib.error
import traceback
from pathlib import Path

from PIL import Image

import effects as effects_mod
import looks as looks_mod
import quantise

STATE = Path(os.path.expanduser("~/.nib"))
SOCK = STATE / "nibd.sock"
OUT = STATE / "output"


def handle(req: dict) -> dict:
    cmd = req.get("cmd")

    if cmd == "ping":
        return {"ok": True, "pong": True}

    if cmd == "quantise":
        path = req["path"]
        if not os.path.exists(path):
            return {"ok": False, "error": f"no such file: {path}"}
        size = int(req.get("size", 48))
        palette = req["palette"]
        source = Image.open(path)
        if req.get("trim", True):
            source = quantise.trim(source)
        # A two-colour palette means a two-tone subject, so take the line-art
        # path: threshold first, reduce the mask. `ink_bias` becomes the
        # coverage threshold, inverted so the slider still reads "more ink".
        if req.get("line_art") and len(palette) == 2:
            grid = quantise.line_art(
                source,
                size=size,
                coverage=max(0.05, 0.55 - float(req.get("ink_bias", 0.4)) * 0.5),
            )
            counts = quantise.usage(grid)
            return {"ok": True, "grid": grid, "size": size,
                    "usage": {str(k): v for k, v in sorted(counts.items())}}
        grid = quantise.quantise(
            source,
            size=size,
            palette=palette,
            metric=req.get("metric", "lab"),
            dither=bool(req.get("dither", False)),
            ink_bias=float(req.get("ink_bias", 0.0)),
            adaptive=bool(req.get("adaptive", False)),
        )
        if req.get("drop_background") is not None:
            grid = quantise.drop_background(grid, int(req["drop_background"]))
        counts = quantise.usage(grid)
        return {
            "ok": True,
            "grid": grid,
            "size": size,
            "usage": {str(k): v for k, v in sorted(counts.items())},
        }

    if cmd == "export":
        grid = req["grid"]
        palette = req["palette"]
        scale = int(req.get("scale", 1))
        name = req.get("name") or "nib"
        look = req.get("look", "clean")
        OUT.mkdir(parents=True, exist_ok=True)
        img = looks_mod.render(grid, palette, scale, look)
        suffix = "" if scale == 1 else f"@{scale}x"
        # The look is in the filename, so a decorated export can never be
        # mistaken for the clean one sitting next to it in the same folder.
        if look != "clean":
            suffix += f"_{look}"
        dest = Path(req["path"]) if req.get("path") else OUT / f"{name}_{len(grid)}x{len(grid)}{suffix}.png"
        dest.parent.mkdir(parents=True, exist_ok=True)
        img.save(dest, "PNG")
        return {"ok": True, "path": str(dest)}

    if cmd == "render_look":
        # The preview panel. Returns the image itself rather than writing a file:
        # a preview is not an export, and littering ~/.nib/output with every
        # keystroke would make finding a real export impossible.
        img = looks_mod.render(req["grid"], req["palette"],
                               int(req.get("scale", 12)), req.get("look", "screen"))
        return {"ok": True, "png": base64.b64encode(quantise.png_bytes(img)).decode(),
                "width": img.width, "height": img.height}

    if cmd == "duotone":
        look = looks_mod.find(req.get("look", "terminal"))
        if not look or not look["duotone"]:
            return {"ok": False, "error": "that look has no duotone"}
        return {"ok": True, "colors": looks_mod.duotone(req["palette"], *look["duotone"],
                                                        invert=look.get("invert", True))}

    if cmd == "gradient":
        n = len(req["grid"])
        rect = req.get("rect") or [0, 0, n - 1, n - 1]
        grid, colors, full = effects_mod.gradient(
            req["grid"], req["palette"], rect,
            req["from"], req["to"],
            bands=req.get("bands", 5), mode=req.get("mode", "vertical"),
            dither=bool(req.get("dither", False)))
        return {"ok": True, "grid": grid, "palette": colors, "full": full}

    if cmd == "effects":
        return {"ok": True, "effects": effects_mod.EFFECTS}

    if cmd == "effect":
        grid, colors, full = effects_mod.apply(req["grid"], req["palette"], req["effect"])
        return {"ok": True, "grid": grid, "palette": colors, "full": full}

    if cmd == "looks":
        return {"ok": True, **looks_mod.available(),
                "looks": [{"id": l["id"], "name": l["name"],
                           "filtered": l["screen"] is not None} for l in looks_mod.LOOKS]}

    if cmd == "analyse":
        path = req["path"]
        if not os.path.exists(path):
            return {"ok": False, "error": f"no such file: {path}"}
        return {"ok": True, **quantise.analyse(Image.open(path))}

    if cmd == "extract_palette":
        path = req["path"]
        if not os.path.exists(path):
            return {"ok": False, "error": f"no such file: {path}"}
        colors = quantise.extract_palette(Image.open(path), int(req.get("colors", 16)))
        return {"ok": True, "colors": colors}

    if cmd == "remap":
        # Nearest colour for every index of one palette in another, in Lab.
        # The app applies the map to every frame itself; this exists so that
        # colour distance has one implementation, and it is not the hue-blind one.
        old = [quantise.hex_to_rgb(c) for c in req["from"]]
        new = [quantise.hex_to_rgb(c) for c in req["to"]]
        if not old or not new:
            return {"ok": False, "error": "remap needs two non-empty palettes"}
        lab_new = [quantise.rgb_to_lab(c) for c in new]
        mapping = []
        for c in old:
            lab = quantise.rgb_to_lab(c)
            best, best_d = 0, None
            for i, t in enumerate(lab_new):
                d = sum((a - b) ** 2 for a, b in zip(lab, t))
                if best_d is None or d < best_d:
                    best, best_d = i, d
            mapping.append(best)
        return {"ok": True, "map": mapping}

    if cmd == "export_gif":
        frames = req["frames"]
        palette = req["palette"]
        if len(frames) < 2:
            return {"ok": False, "error": "a GIF needs more than one frame"}
        if len(palette) > 255:
            return {"ok": False, "error": "GIF holds 255 colours plus transparency"}
        fps = max(1.0, float(req.get("fps", 8)))
        scale = int(req.get("scale", 1))
        name = req.get("name") or "nib"
        OUT.mkdir(parents=True, exist_ok=True)
        look = req.get("look", "clean")
        imgs, durations = [], []
        for f in frames:
            durations.append(int(round(max(1, int(f.get("hold", 1))) / fps * 1000)))
        if look == "clean":
            imgs = [quantise.gif_frame(f["grid"], palette, scale=scale) for f in frames]
        else:
            # A filtered frame is full colour -- bloom alone invents thousands of
            # shades -- so it has to be re-quantised. Every frame is quantised
            # against the *first* frame's palette rather than its own, or the
            # colours crawl from frame to frame as each one picks a new 255.
            rgb = [looks_mod.render(f["grid"], palette, scale, look) for f in frames]
            master = rgb[0].quantize(colors=255, method=Image.MEDIANCUT)
            imgs = [master] + [im.quantize(palette=master, dither=Image.Dither.NONE)
                               for im in rgb[1:]]
        suffix = "" if scale == 1 else f"@{scale}x"
        if look != "clean":
            suffix += f"_{look}"
        dest = Path(req["path"]) if req.get("path") else OUT / f"{name}_{len(frames)}f{suffix}.gif"
        dest.parent.mkdir(parents=True, exist_ok=True)
        # disposal=2 clears each frame back to the background before the next is
        # drawn. Without it a transparent cell shows whatever the previous frame
        # left there, and an animation with holes in it smears.
        save_args = {"save_all": True, "append_images": imgs[1:], "duration": durations,
                     "loop": 0, "disposal": 2, "optimize": False}
        if look == "clean":
            save_args["transparency"] = len(palette)   # a screen has no transparency
        imgs[0].save(dest, **save_args)
        return {"ok": True, "path": str(dest), "frames": len(frames)}

    return {"ok": False, "error": f"unknown cmd: {cmd!r}"}


def variant_specs(kind: str, palette: list[str]) -> list[dict]:
    """The spread offered for a given kind of image.

    Deliberately a spread rather than a single guess. Every parameter we measured
    is right for some drawings and wrong for others -- 0.5 suits a bold pen, 0.8
    rescues a light one -- so showing a handful and letting the user point beats
    any heuristic.
    """
    if kind == "line_art":
        # Three stroke weights by four tone counts. The weights are coverage
        # cuts: "how much of a cell must be ink for it to reach this tone". The weights
        # are coverage cuts: "how much of a cell must be ink for it to be ink".
        # Every threshold option bridges gaps (quantise._bridge), without which
        # a thin stroke arrives dotted at 32.
        return [
            {"label": "Fine, 2 tone",   "cuts": [0.35],                    "palette": MONO},
            {"label": "Medium, 2 tone", "cuts": [0.25],                    "palette": MONO},
            {"label": "Bold, 2 tone",   "cuts": [0.15],                    "palette": MONO},
            {"label": "Fine, 3 tone",   "cuts": [0.35, 0.15],              "palette": GREY3},
            {"label": "Medium, 3 tone", "cuts": [0.25, 0.10],              "palette": GREY3},
            {"label": "Bold, 3 tone",   "cuts": [0.15, 0.05],              "palette": GREY3},
            {"label": "Fine, 4 tone",   "cuts": [0.35, 0.20, 0.08],        "palette": GREY4T},
            {"label": "Medium, 4 tone", "cuts": [0.28, 0.16, 0.06],        "palette": GREY4T},
            {"label": "Bold, 4 tone",   "cuts": [0.20, 0.10, 0.04],        "palette": GREY4T},
            {"label": "Fine, 5 tone",   "cuts": [0.38, 0.26, 0.15, 0.06],  "palette": GREY5},
            {"label": "Medium, 5 tone", "cuts": [0.30, 0.20, 0.11, 0.045], "palette": GREY5},
            {"label": "Bold, 5 tone",   "cuts": [0.22, 0.14, 0.08, 0.03],  "palette": GREY5},
        ]
    return [{"label": f"{c} colours from image", "colors": c} for c in (6, 8, 12, 16, 24, 32)]


MONO  = ["#ffffff", "#000000"]
GREY3 = ["#ffffff", "#8b9199", "#000000"]
GREY4T = ["#ffffff", "#c9ccd1", "#6b7178", "#000000"]
GREY5 = ["#ffffff", "#d3d6da", "#9aa0a7", "#5b6168", "#000000"]
GREY4 = ["#ffffff", "#9fa5ad", "#4a5058", "#000000"]


def handle_stream(req: dict):
    """Commands that report progress. Yields many replies for one request; the
    last one carries "done": true so the client knows to stop reading."""
    if req.get("cmd") == "variants":
        path = req["path"]
        if not os.path.exists(path):
            yield {"ok": False, "error": f"no such file: {path}", "done": True}
            return
        size = int(req.get("size", 48))
        full = Image.open(path)
        # Always square before reducing: resizing a non-square image straight
        # to size x size stretched it, which is what "crop off" used to do.
        # The crop comes from the person's frame in the picker; failing that,
        # the default for this kind of image.
        if req.get("crop"):
            box = quantise.clamp_crop(full, req["crop"])
        else:
            box = quantise.default_crop(full)
        source = quantise.crop(full, box)
        info = quantise.analyse(source)
        # The whole image and the frame on it, for the picker's crop tool.
        thumb = full.convert("RGB")
        thumb.thumbnail((512, 512), Image.Resampling.LANCZOS)
        yield {"ok": True, "event": {"kind": "analysed", "of": info["kind"],
                                     "saturation": info["saturation"],
                                     "preview": base64.b64encode(quantise.png_bytes(thumb)).decode(),
                                     "crop": list(box), "image_size": [full.width, full.height]}}

        for i, spec in enumerate(variant_specs(info["kind"], None)):
            if "colors" in spec:
                pal = quantise.extract_palette(source, spec["colors"])
                grid = quantise.quantise(source, size=size, palette=pal, metric="lab")
            else:
                pal = spec["palette"]
                grid = quantise.line_art(source, size=size, cuts=spec["cuts"])
            # Sent one at a time so the picker fills in as they land rather than
            # sitting blank until every variant is done.
            yield {"ok": True, "event": {"kind": "variant", "index": i,
                                         "label": spec["label"], "grid": grid,
                                         "palette": pal}}
        yield {"ok": True, "done": True, "count": len(variant_specs(info["kind"], None))}
        return

    yield handle(req)
    return


def serve() -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    if SOCK.exists():
        SOCK.unlink()
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(str(SOCK))
    srv.listen(8)
    sys.stderr.write(f"nibd listening on {SOCK}\n")
    sys.stderr.flush()

    while True:
        conn, _ = srv.accept()
        try:
            with conn, conn.makefile("rwb") as f:
                for raw in f:
                    line = raw.decode().strip()
                    if not line:
                        continue
                    try:
                        req = json.loads(line)
                        if req.get("cmd") == "variants":
                            for reply in handle_stream(req):
                                f.write((json.dumps(reply) + "\n").encode())
                                f.flush()
                            continue
                        reply = handle(req)
                    except Exception as e:  # never die on one bad request
                        traceback.print_exc()
                        reply = {"ok": False, "error": f"{type(e).__name__}: {e}", "done": True}
                    f.write((json.dumps(reply) + "\n").encode())
                    f.flush()
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == "__main__":
    serve()
