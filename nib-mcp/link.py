"""The live link: the socket a running Nib window listens on.

Transport only, kept out of `nibcore` so the document model stays a pure thing
that knows nothing about how it travels. The protocol is three commands, JSON
lines over `~/.nib/app.sock`:

    hello -> {ok, version, path, doc, size, frames, layers, dirty}
    apply {doc, label, version} -> {ok, version} or {ok: false, stale, version}
    save -> {ok, path}

`version` is the window's document version. Quote it when applying and an edit
built on a canvas the person has since drawn on is refused instead of burying
their work. See `AppLink.swift`.
"""
from __future__ import annotations

import json
import os
import socket

SOCKET = os.path.expanduser("~/.nib/app.sock")


class LinkError(Exception):
    """The window is not reachable. Never fatal: the file path still works."""


def call(request: dict, timeout: float = 5.0) -> dict:
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(SOCKET)
    except OSError as e:
        raise LinkError(f"Nib is not listening on {SOCKET} ({e.strerror or e})") from e
    try:
        s.sendall((json.dumps(request) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(1 << 16)
            if not chunk:
                break
            buf += chunk
    except OSError as e:
        raise LinkError(f"the window stopped answering ({e})") from e
    finally:
        s.close()
    if not buf:
        raise LinkError("the window closed the connection without answering")
    try:
        return json.loads(buf)
    except json.JSONDecodeError as e:
        raise LinkError(f"unreadable reply from the window: {e}") from e


def window() -> dict | None:
    """What the app has open, or None if it is not running or not listening."""
    try:
        reply = call({"cmd": "hello"})
    except LinkError:
        return None
    return reply if reply.get("ok") else None


def same_file(a: str | None, b: str | None) -> bool:
    if not a or not b:
        return False
    return os.path.realpath(os.path.expanduser(a)) == os.path.realpath(os.path.expanduser(b))
