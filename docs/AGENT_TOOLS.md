# Nib for agents: the tool surface

A design for letting someone's own Claude session work in Nib, as an MCP server
(`nib-mcp/`) plus an instruction file, packaged as a Claude Code plugin.

**The pitch is a studio assistant, not an artist.** Every attempt to have a model
draw was measured and failed. What works is a person
drawing and the agent doing the mechanical work: backgrounds, palettes and
shading ramps, recolours, centring, icon sets, scrolling runs, batch exports,
always offered as a sheet of options to pick from.

## Principles

1. **Look after every change.** Every change tool returns a small render (about
   256px) alongside its text, so the agent always sees what it did.
2. **Offer options, don't decide.** `propose` runs one operation with several
   settings on scratch copies and returns a labelled sheet. Nothing is applied
   until `apply`. This is the importer's philosophy.
3. **Never write behind the person's back.** Edits live in an in-memory working
   copy. `save` refuses to overwrite a file that changed on disk since it was
   opened, unless told to.
4. **Everything can be undone.** Every change is a named step; `undo` walks back.
5. **Drawing stays low-level on purpose.** `set_cells` exists for small fixes. There
   is no "draw a penguin" tool.

## Tools

Status: **exists** is a `nibd` function already; **port** means the logic is in
Swift and needs a Python twin; **new** is new.

| # | Tool | What it does | Status |
|---|---|---|---|
| 1 | `open_project(path)` | Load a `.nibart`: size, layers, frames, palette with usage | new |
| 2 | `import_image(path, size, crop)` | The importer's options as a sheet, plus handles | exists (`variants`) |
| 3 | `save(path?, overwrite=false)` | Write the working copy; refuse if the file changed on disk | new |
| 4 | `render(frame?, layer?, scale, look?)` | PNG of a frame, one layer, or every frame as a strip | exists (`export`, `render_look`) |
| 5 | `inspect(region?)` | The grid as text indices, for exact positions | new |
| 6 | `preview_icon(sizes)` | Masked as macOS masks it, at Dock sizes, light and dark | new |
| 7 | `select(by)` | A named mask: rect, colour, layer content, outside, inside | new; flood fill is a port |
| 8 | `set_cells` / `fill` | Low-level fixes | port |
| 9 | `transform(op, mask?)` | Flip, rotate, recentre, pad to size | port + new |
| 10 | `gradient(mask?, stops, bands, mode, dither)` | Multi-stop gradient fill | exists (2 stops); multi-stop new |
| 11 | `palette(op)` | Add, replace, swap, remove, shade ramp, switch with remap | remap exists; rest port |
| 12 | `structure(op)` | Layers, frames, roll, scrolling run | port |
| 13 | `undo(steps)` | | new |
| 14 | `propose(tool, variants)` / `apply(handle)` | Try settings on scratch copies, return one sheet | new, the heart of it |
| 15 | `export(kind, path, scale, look?)` | PNG, GIF, or macOS `.icns` | png/gif exist; icon new |
| 16 | `lift(mask, name, fill)` | Move selected cells to a new layer above, optionally patching the holes at the same dither phase | built 2026-09-21 |
| 17 | `roll_across_frames(layer, dx, dy, frames?)` | One layer drifting across a new animation, the rest still; defaults to one seamless turn | built 2026-09-21 |

## A worked example

Making the 2026-09-19 icon would have been: `open_project` → `select(outside)` →
`transform(recentre, 32)` → `propose(gradient, 7 sunsets × 4 tip colours)` → pick →
`apply` → `export(icon)`.

## Stages

1. MCP server on saved files. **Built 2026-09-19**: 17 tools, tests pass on
   a generated project and on a copy of the real icon project, stdio launch
   verified, and a file it wrote opens in the app.
2. Package as a Claude Code plugin.
3. Live link. **Built 2026-09-20**: the app listens on `~/.nib/app.sock`, the
   session goes live when the window has that project open, and every change
   lands there as one labelled undo step. Verified against a real window by
   `test_live.py`, including a person drawing mid-edit.

## Open questions

- ~~**Duplicated logic.**~~ Settled by the live link, which sends whole
  documents rather than operations: the app runs none of the agent's edits, so
  there is nothing to keep in step. The ports in `nibcore.py` stay the only
  implementation on this path.
- **Image cost.** A render per change costs context. 256px default; full size on
  request.
