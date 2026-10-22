"""Nib's MCP server: lets a person's own Claude session work on Nib projects.

    uv run --directory nib-mcp server.py        # stdio, for Claude Code / Desktop

Design and reasoning: docs/AGENT_TOOLS.md. Every operation lives in nibcore.py;
this file only turns them into tools, keeps the session (one open project, its
named selections, pending proposals), and returns a small render with every
change so the agent always sees what it just did.
"""
from __future__ import annotations

import copy
import functools
import os
import sys
import time
from pathlib import Path

from mcp.server.mcpserver import Image, MCPServer
from mcp.server.mcpserver.exceptions import ToolError

import link
import nibcore as core
from nibcore import NibError, Project

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "nibd"))
import nibd  # noqa: E402  (the importer's option spread lives there)

INSTRUCTIONS = """\
You are working in Nib, a pixel-art editor, on the person's own drawings.

How to work:
- You are a studio assistant, not the artist. Do mechanical work (backgrounds,
  palettes, shading ramps, recolours, centring, icons, animation frames) and
  leave drawing decisions to the person. Never try to draw a subject from
  scratch cell by cell; it has been measured and it does not work.
- Look after every change: each change tool returns a render. Check it.
- Tools that make something to look at (render, preview_icon, propose,
  import_image, open_project, apply) return the image to you *and* save it.
  Share that file in the conversation every time, rendered as an image (a
  file-sending tool's render/display option, never an attachment). You can
  already see it, so never read it back. Never describe a sheet the person has
  not been shown.
- Keep replies short. The person is looking at the picture, not at your prose:
  a line on what changed, and the question if there is one.
- Working live, they can see their own canvas, so send only what the window
  cannot show them: sheets from `propose` and `import_image`. Each tool says
  which of its images to send.
- When there is more than one reasonable choice (a background, a colour, a
  tip), use `propose` to show a labelled sheet and let the person pick, then
  `apply` their choice. Do not decide taste on their behalf.
- Nothing is written to disk until `save`. It refuses to overwrite a file that
  changed since it was opened (the person may have saved from the app); never
  pass overwrite=true for that case unless they say so.
- If the project is open in Nib, your changes appear in that window as you make
  them, each one a labelled undo step the person can reverse. `open_window`
  works on whatever they have on screen; `open_project` does the same by itself
  when they have that file open. They can draw at the same time: if they do, an
  edit of yours may be refused, their work is loaded here, and you redo it.
  Their canvas is not a scratchpad, so make the change they asked for and use
  `propose` for anything else, which tries options aside rather than on screen.
- Canvases are square; cells are palette indices, -1 is transparent. Layers are
  listed bottom to top; tools act on the top layer unless you name one.
"""

server = MCPServer("nib", instructions=INSTRUCTIONS)


def tool(fn):
    """Register a tool, turning NibError into ToolError. The SDK shows a
    ToolError's message to the model and replaces anything else with a generic
    "Error executing tool", so without this the agent would be told a call
    failed but never why ("no layer called X; the layers are...")."""
    @functools.wraps(fn)
    def wrapped(*args, **kwargs):
        try:
            return fn(*args, **kwargs)
        except NibError as e:
            raise ToolError(str(e)) from e
    return server.tool()(wrapped)


class Session:
    project: Project | None = None
    masks: dict[str, core.Mask] = {}
    pending: dict[str, Project] = {}
    #: Changes go straight to the open Nib window, not just this copy.
    live: bool = False
    #: The window's document version as of our last exchange with it.
    version: int | None = None
    #: Set while `propose` is running tools on scratch copies, which must not
    #: reach the window: the person asked to see options, not to be shown each
    #: one being built on their canvas.
    quiet: bool = False


S = Session()


def push(label: str) -> str:
    """Send the working copy to the open window as one labelled undo step.

    Returns a note to append to the tool's reply, so the agent can see where
    its edit went. Silent and harmless when the session is not live.
    """
    if not S.live or S.quiet or S.project is None:
        return ""
    try:
        reply = link.call({"cmd": "apply", "label": label,
                           "doc": S.project.data, "version": S.version})
    except link.LinkError as e:
        S.live = False
        return (f"\n(The window is gone: {e}. Still editing a copy here; "
                "`save` writes it to the file.)")
    if reply.get("stale"):
        # The person drew in the window while we were working. Their strokes
        # win: re-read, and let the agent redo the one step that was refused.
        S.project.data = link.call({"cmd": "hello"})["doc"]
        S.version = reply.get("version")
        raise NibError(
            "The person changed the canvas in Nib while this edit was being built, so it "
            "was not applied. Their work is now loaded here. Look at it, then redo the "
            "change if it still makes sense.")
    if not reply.get("ok"):
        raise NibError(f"Nib would not apply that: {reply.get('error', 'no reason given')}")
    S.version = reply.get("version")
    return "\n(applied in the open Nib window, undoable there as one step)"


def go_live(hello: dict) -> None:
    S.project = Project(hello["doc"], hello.get("path"))
    S.masks, S.pending = {}, {}
    S.live, S.version = True, hello["version"]


def go_offline() -> None:
    S.live, S.version = False, None


def need() -> Project:
    if S.project is None:
        raise NibError("No project open. Use open_project, new_project or import_image first.")
    return S.project


def mask_of(name: str | None) -> core.Mask | None:
    if name is None:
        return None
    if name not in S.masks:
        raise NibError(f"No selection called {name!r}. Make one with `select`. Have: {list(S.masks)}")
    return S.masks[name]


def look(p: Project, frame: int = 0, size: int = 256, mask: core.Mask | None = None) -> Image:
    im = core.scaled(core.grid_image(p, p.composite(frame)), size)
    if mask:
        im = core.outline_mask(im, mask, p.size)
    return Image(data=core.png(im), format="png")


PREVIEWS = Path.home() / ".nib" / "previews"


def for_person(im, name: str, share: bool = True) -> list:
    """An image for the person: inline for the agent, and as a file to share.

    Both, for different readers. Inline, the agent can see it immediately, but
    for the person it is buried in a tool call the app collapses, so an agent
    that could see a sheet used to discuss it with someone who could not. As a
    file it can be shared into the conversation where they will actually look
    at it.

    The agent having it inline is what keeps the transcript short: it never
    needs to read the file back, so each preview costs one line and one image
    rather than a send, a read and a render. Keeps the newest 40."""
    PREVIEWS.mkdir(parents=True, exist_ok=True)
    path = PREVIEWS / f"{time.strftime('%Y%m%d-%H%M%S')}-{name}.png"
    im.save(path)
    for old in sorted(PREVIEWS.glob("*.png"))[:-40]:
        old.unlink()
    note = (f"That image is above, and saved at {path}\n"
            "Share the file with the person now, rendered as an image in the "
            "conversation (in the Claude desktop app: a file-sending tool with display "
            "'render'), never as a downloadable attachment. Do not read the file back: "
            "you can already see it. Do not rebuild it."
            if share else
            f"That image is above, for you, and saved at {path} if it is ever needed. "
            "Do not send it: this is the canvas the person is watching in Nib, and a "
            "picture of what is already on their screen is clutter.")
    return [Image(data=core.png(im), format="png"), note]


def person_look(p: Project, name: str, frame: int = 0, size: int = 384) -> list:
    # Live, the person is watching the window, so a render of it belongs to the
    # agent alone. Sheets of options are different: those are not on screen.
    return for_person(core.scaled(core.grid_image(p, p.composite(frame)), size), name,
                      share=not S.live)


def changed(label: str, text: str, frame: int = 0) -> list:
    """Every change tool ends here, which is also where the open window hears
    about it. One chokepoint, so no tool can quietly skip the link."""
    return [f"{label}: {text}{push(label)}", look(need(), frame)]


# ---------------------------------------------------------------- session

@tool
def open_project(path: str) -> list:
    """Open a Nib project (.nibart). Returns its layers, palette with cell
    counts per colour, and a render. If the person has that same project open
    in Nib, this works on their window instead of the file, and every change
    appears there as it is made."""
    w = link.window()
    if w and link.same_file(w.get("path"), path):
        go_live(w)
        return [S.project.summary(),
                "This project is open in Nib, so changes will appear in that window as "
                "labelled undo steps. Nothing is written to the file until `save`."
                ] + person_look(S.project, "open")
    go_offline()
    S.project, S.masks, S.pending = Project.open(path), {}, {}
    return [S.project.summary()] + person_look(S.project, "open")


@tool
def open_window() -> list:
    """Work on whatever the person has open in Nib right now, changes appearing
    in their window as they are made. Use this when they say "what I'm looking
    at" or when no file path was given."""
    w = link.window()
    if w is None:
        raise NibError("Nib is not running, or its window is not answering. "
                       "Ask the person to open the project in Nib, or give a file path "
                       "for `open_project`.")
    go_live(w)
    where = w.get("path") or "never saved, so `save` will need a path"
    return [f"{S.project.summary()}\nOpen in Nib: {where}"] + person_look(S.project, "window")


@tool
def new_project(size: int = 32) -> list:
    """Start a blank square canvas, white and black palette. 32 suits icons."""
    go_offline()
    S.project, S.masks, S.pending = Project.blank(size), {}, {}
    return [S.project.summary()]


@tool
def import_image(path: str, size: int = 32, crop: bool = True) -> list:
    """Reduce an image to pixel art with Nib's quantiser. Returns a sheet of
    every option (Fine, Bold, 3 tone...) and a handle per option; `apply` the
    one the person picks to start a project from it. Without `crop` the largest
    centred square of the image is used."""
    go_offline()
    S.pending = {}
    items = []
    for r in nibd.handle_stream({"cmd": "variants", "path": str(Path(path).expanduser()),
                                 "size": size, "trim": crop}):
        if not r.get("ok", True):
            raise NibError(r.get("error", "import failed"))
        e = r.get("event", {})
        if e.get("kind") != "variant":
            continue
        p = Project.blank(size, list(e["palette"]))
        p.data["paletteName"] = e["label"]
        p.frames[0]["cels"][0] = e["grid"]
        handle = f"import-{len(S.pending) + 1}"
        S.pending[handle] = p
        items.append((f"{handle}: {e['label']}", core.grid_image(p, e["grid"])))
    return [f"{len(items)} options. Show the person and `apply` their pick.",
            *for_person(core.sheet(items, sizes=(160,), columns=4), "import-options")]


@tool
def save(path: str | None = None, overwrite: bool = False) -> str:
    """Write the project. With no path, saves over the file it was opened from,
    but refuses if that file changed on disk since opening."""
    p = need()
    # Live, saving in place: the window saves its own document. Writing the file
    # from here would leave the window believing it still had unsaved work.
    if S.live and path is None:
        reply = link.call({"cmd": "save"})
        if not reply.get("ok"):
            raise NibError(reply.get("error", "Nib could not save"))
        return f"saved {reply.get('path')} (from the Nib window)"
    return f"saved {p.save(path, overwrite)}"


# ---------------------------------------------------------------- looking

@tool
def render(frame: int = 0, size: int = 512, all_frames: bool = False) -> list:
    """Render the project, transparency as a checkerboard. `all_frames` shows
    every frame side by side."""
    p = need()
    if not all_frames:
        return person_look(p, "render", frame, size)
    items = [(f"frame {i}", core.grid_image(p, p.composite(i))) for i in range(len(p.frames))]
    return for_person(core.sheet(items, sizes=(min(size, 192),), columns=6), "frames")


@tool
def inspect(x0: int = 0, y0: int = 0, x1: int | None = None, y1: int | None = None,
            frame: int = 0, layer: str | int | None = None) -> str:
    """Cells as text (palette indices, '.' for transparent), for exact
    positions. Rows are y, columns x. Omit `layer` for the composite."""
    p = need()
    n = p.size
    x1 = n - 1 if x1 is None else x1
    y1 = n - 1 if y1 is None else y1
    g = p.cel(frame, layer) if layer is not None else p.composite(frame)
    w = max(2, len(str(len(p.palette) - 1)) + 1)
    head = "    " + "".join(str(x).rjust(w) for x in range(x0, x1 + 1))
    rows = [str(y).rjust(3) + " " + "".join(("." if g[y][x] < 0 else str(g[y][x])).rjust(w)
                                          for x in range(x0, x1 + 1)) for y in range(y0, y1 + 1)]
    return head + "\n" + "\n".join(rows)


@tool
def preview_icon(frame: int = 0) -> list:
    """The project as a macOS app icon: masked the way macOS 26 masks a square
    icon, at 256/128/64/32px on a light and a dark Dock. Judge at 32."""
    p = need()
    return for_person(core.icon_preview([("current", core.as_icon(p, frame))]), "icon")


# ---------------------------------------------------------------- selecting

@tool
def select(by: str, name: str = "selection", rect: list[int] | None = None,
           colour: str | int | list | None = None, layer: str | int | None = None,
           frame: int = 0) -> list:
    """Make a named selection that other tools take as `mask`.
    by: all | rect (rect=[x0,y0,x1,y1] inclusive) | colour (one, or a list) | layer (its
    non-transparent cells) | outside (background reachable from the edges,
    ignoring full backdrop layers) | inside (everything else: the subject)."""
    p = need()
    m = core.select(p, by, frame, layer, rect, colour)
    S.masks[name] = m
    return [f"{name}: {len(m)} cells, bounds {core.bounds(m)}", look(p, frame, mask=m)]


# ---------------------------------------------------------------- changing

@tool
def paint(colour: str | int, cells: list[list[int]] | None = None,
          fill_at: list[int] | None = None, frame: int = 0,
          layer: str | int | None = None) -> list:
    """Low-level fixes: set cells [[x,y],...] to a colour, and/or flood-fill
    from fill_at=[x,y]. colour: palette index, hex, or 'transparent'. For small
    corrections only, not for drawing a subject."""
    p = need()
    p.checkpoint("paint")
    return changed("paint", f"{core.paint(p, colour, cells, fill_at, frame, layer)} cells", frame)


@tool
def transform(op: str, mask: str | None = None, frame: int = 0, layer: str | int | None = None,
              dx: int = 0, dy: int = 0, size: int | None = None) -> list:
    """op: flip_h | flip_v | rotate_cw | rotate_ccw (the mask, or the whole
    layer) | roll (dx, dy, wrapping; one layer) | recentre (all layers move
    together so the subject is centred) | canvas_size (size=N, centred)."""
    p = need()
    p.checkpoint(op)
    return changed(op, core.transform(p, op, mask_of(mask), frame, layer, dx, dy, size), frame)


@tool
def gradient(stops: list[str], bands: int = 5, mode: str = "vertical", dither: bool = False,
             mask: str | None = None, frame: int = 0, layer: str | int | None = None) -> list:
    """Banded gradient through any number of hex stops, top to bottom by
    default. mode: vertical | horizontal | diagonal | radial. dither adds a
    2x2 checker at band edges. Fills the mask, or the whole layer. For a
    background, add a layer at the bottom first with `structure`."""
    p = need()
    p.checkpoint("gradient")
    return changed("gradient", core.gradient(p, stops, bands, mode, dither, mask_of(mask), frame, layer), frame)


@tool
def palette(op: str, index: int | None = None, colour: str | None = None,
            to: int | None = None, darker: bool = True, steps: int = 1) -> list:
    """op: add (colour) | replace (index, colour: every cell of that index
    changes colour) | swap (index, to: moves cells to another index) | remove
    (index; cells go to the nearest colour) | shade (index, darker, steps:
    appends a hand-shading ramp, hue-shifted, greys stay neutral)."""
    p = need()
    p.checkpoint(f"palette {op}")
    return changed(f"palette {op}", core.palette_op(p, op, index, colour, to, darker, steps))


@tool
def structure(op: str, name: str | None = None, layer: str | int | None = None,
              position: str | int | None = None, frame: int = 0) -> list:
    """op: add_layer (name, position: top|bottom|index) | delete_layer |
    move_layer (position) | hide_layer | show_layer | rename_layer (name) |
    add_frame | duplicate_frame (frame) | delete_frame (frame)."""
    p = need()
    p.checkpoint(op)
    return changed(op, core.structure(p, op, name, layer, position, frame)) + [p.summary()]


@tool
def lift(mask: str, name: str = "Lifted", layer: str | int | None = None,
         fill: str = "none") -> list:
    """Move the selected cells off a layer onto a new layer just above it, in
    every frame. How to separate stars from a sky, or a sprite from a background
    it was drawn onto. fill: none (the holes go transparent) | surroundings (each
    hole is patched from its own row at the same dither phase, so a gradient
    closes over it). Select first, e.g. select(by="colour", colour=..., layer=...)."""
    p = need()
    p.checkpoint("lift")
    return changed("lift", core.lift(p, mask_of(mask), name, layer, fill)) + [p.summary()]


@tool
def roll_across_frames(layer: str | int, dx: int = 0, dy: int = 0,
                       frames: int | None = None, frame: int = 0) -> list:
    """Replace the animation with copies of `frame` in which only `layer` moves,
    dx/dy cells further each frame (positive is right/down), wrapping. Every
    other layer holds still: stars drifting behind a character, a road under a
    car. Leave out `frames` for exactly one full turn, which loops without a
    seam. The same as Frame > Roll Across Frames in the app."""
    p = need()
    p.checkpoint("roll across frames")
    return changed("roll across frames", core.roll_across(p, layer, frames, dx, dy, frame)) \
        + [p.summary()]


@tool
def undo(steps: int = 1) -> list:
    """Undo the last change(s) made in this session. Live, this arrives in the
    window as another step rather than winding its undo stack back, so the
    person can still Cmd+Z past it."""
    p = need()
    done = p.undo(steps)
    label = f"undo {', '.join(done)}" if done else "undo"
    return [f"undid: {', '.join(done) or 'nothing'}{push(label)}", look(p)]


# ---------------------------------------------------------------- choosing

CHANGE_TOOLS = {"paint": paint, "transform": transform, "gradient": gradient,
                "palette": palette, "structure": structure, "lift": lift,
                "roll_across_frames": roll_across_frames}


@tool
def propose(options: list[dict], sizes: list[int] | None = None, as_icon: bool = False) -> list:
    """Try several versions on scratch copies and show them side by side;
    nothing changes until `apply`. Each option: {"label": str, "steps":
    [{"tool": "gradient"|"palette"|"transform"|"paint"|"structure", "args": {...}}]}.
    sizes: pixel sizes to show each at, e.g. [160, 32]. as_icon: show each
    masked as a macOS icon at Dock sizes, light and dark."""
    base = need()
    S.pending = {}
    items = []
    # Trials run through the same change tools, which push to the window. The
    # person asked to see options, not to watch each one land on their canvas.
    S.quiet = True
    try:
        for i, opt in enumerate(options, 1):
            trial = copy.deepcopy(base)
            trial.history = []
            saved, S.project = S.project, trial
            try:
                for step in opt.get("steps", []):
                    tool = CHANGE_TOOLS.get(step.get("tool"))
                    if tool is None:
                        raise NibError(f"propose can run {list(CHANGE_TOOLS)}, not {step.get('tool')!r}.")
                    tool(**step.get("args", {}))
            finally:
                S.project = saved
            handle = f"option-{i}"
            S.pending[handle] = trial
            label = f"{handle}: {opt.get('label', '')}"
            items.append((label, core.as_icon(trial) if as_icon else core.grid_image(trial, trial.composite(0))))
    finally:
        S.quiet = False
    img = (core.icon_preview(items, sizes=tuple(sizes or (256, 128, 64, 32))) if as_icon
           else core.sheet(items, sizes=tuple(sizes or (160,)), columns=4))
    return [f"{len(items)} options. Show the person and `apply` their pick.",
            *for_person(img, "options")]


@tool
def apply(handle: str) -> list:
    """Commit an option from `propose` or `import_image` (e.g. "option-3")."""
    if handle not in S.pending:
        raise NibError(f"No pending option {handle!r}. Have: {list(S.pending)}")
    chosen = S.pending.pop(handle)
    label = f"apply {handle}"
    if S.project is not None and handle.startswith("option-"):
        S.project.checkpoint(label)
        S.project.data = chosen.data
    else:
        # An import starts a different document, so it is not the window's.
        go_offline()
        S.project, S.masks = chosen, {}
    S.pending = {}
    return [f"applied {handle}{push(label)}"] + person_look(S.project, "applied")


# ---------------------------------------------------------------- export

@tool
def export(kind: str, path: str, scale: int = 8, frame: int = 0) -> str:
    """kind: png (one frame, scaled by whole numbers) | gif (every frame, holds
    and fps honoured) | icns (macOS icon; canvas must divide 1024)."""
    return f"wrote {core.export(need(), kind, path, scale, frame)}"


if __name__ == "__main__":
    server.run()
