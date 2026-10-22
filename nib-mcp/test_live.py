"""The live link, against a real Nib window.

    uv run --directory nib-mcp python test_live.py <project.nibart>

Needs the app running with that project open, so it is not part of
`test_server.py`: that suite must pass on a machine with no window at all.
Every change here lands in the window and is left there; open a scratch copy,
not something you care about.
"""
from __future__ import annotations

import asyncio
import sys

from mcp import Client

import link
import server

FAILS: list[str] = []


def check(name: str, ok: bool, detail: str = ""):
    print(("PASS " if ok else "FAIL ") + name + (f"  ({detail})" if detail and not ok else ""))
    if not ok:
        FAILS.append(name)


def text(r) -> str:
    return "\n".join(c.text for c in r.content if getattr(c, "type", "") == "text")


def err(r) -> bool:
    return bool(getattr(r, "is_error", None) or getattr(r, "isError", None))


async def main(path: str):
    w = link.window()
    if w is None:
        print("No Nib window is listening. Open the project in Nib first.")
        return 1
    check("the window reports the project under test", link.same_file(w.get("path"), path),
          f"window has {w.get('path')}")

    async with Client(server.server) as c:
        r = await c.call_tool("open_project", {"path": path})
        check("opening a project the window has open goes live",
              "appear in that window" in text(r), text(r))
        check("the session knows it is live", server.S.live)
        check("live, a render of the canvas is for the agent only",
              "Do not send it" in text(r), text(r))

        before = link.window()["version"]
        r = await c.call_tool("structure", {"op": "add_layer", "name": "Test", "position": "bottom"})
        check("a change reports that it reached the window",
              "applied in the open Nib window" in text(r), text(r))
        after = link.window()
        check("the window gained the layer", after["layers"] == w["layers"] + 1,
              f"{w['layers']} -> {after['layers']}")
        check("the window's version moved", after["version"] > before)

        # Options are tried aside, not on the person's canvas.
        at_propose = link.window()["version"]
        r = await c.call_tool("propose", {"options": [
            {"label": "red", "steps": [{"tool": "gradient", "args": {"stops": ["#ff0000", "#550000"], "layer": 0}}]},
            {"label": "blue", "steps": [{"tool": "gradient", "args": {"stops": ["#0000ff", "#000055"], "layer": 0}}]},
        ], "sizes": [120]})
        check("propose returns a sheet", "2 options" in text(r), text(r))
        check("a sheet is still shared: it is not on their screen",
              "Share the file with the person" in text(r), text(r))
        check("propose leaves the window alone", link.window()["version"] == at_propose,
              f"{at_propose} -> {link.window()['version']}")
        check("quiet is cleared afterwards", server.S.quiet is False)

        r = await c.call_tool("apply", {"handle": "option-2"})
        check("applying a pick reaches the window",
              "applied in the open Nib window" in text(r), text(r))

        # The person draws while we are working: their stroke wins.
        stolen = link.call({"cmd": "hello"})
        link.call({"cmd": "apply", "label": "the person draws", "doc": stolen["doc"]})
        r = await c.call_tool("paint", {"colour": "#ffffff", "cells": [[0, 0]]})
        check("an edit built on a stale canvas is refused, not forced",
              err(r) and "changed the canvas" in text(r), text(r))
        check("the refusal leaves the session on the window's version",
              server.S.version == link.window()["version"],
              f"{server.S.version} vs {link.window()['version']}")
        r = await c.call_tool("paint", {"colour": "#ffffff", "cells": [[0, 0]]})
        check("and the next attempt goes through", not err(r), text(r))

        r = await c.call_tool("save", {})
        check("save routes to the window", "from the Nib window" in text(r), text(r))
        check("the window is no longer dirty", link.window()["dirty"] is False)

    print("\n" + ("ALL PASSED" if not FAILS else f"{len(FAILS)} FAILED: " + ", ".join(FAILS)))
    return 1 if FAILS else 0


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        raise SystemExit(2)
    raise SystemExit(asyncio.run(main(sys.argv[1])))
