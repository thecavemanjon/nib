"""Python client for nibd, and the CLI used to poke it by hand.

    python3 client.py ping
    python3 client.py quantise <image> [size]
"""

from __future__ import annotations

import json
import os
import socket
import sys

SOCK = os.path.expanduser("~/.nib/nibd.sock")

# The default palette lives here as well as in Swift; Swift owns the ones the UI
# offers, this copy exists so the CLI is usable on its own.
INK = ["#ffffff", "#c9ccd1", "#8b9199", "#4a5058", "#22262b", "#000000"]


def send(req: dict) -> dict:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCK)
    with s, s.makefile("rwb") as f:
        f.write((json.dumps(req) + "\n").encode())
        f.flush()
        return json.loads(f.readline().decode())


def main() -> None:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    cmd = sys.argv[1]

    if cmd == "ping":
        print(send({"cmd": "ping"}))
        return

    if cmd == "quantise":
        path = os.path.abspath(sys.argv[2])
        size = int(sys.argv[3]) if len(sys.argv) > 3 else 32
        r = send({"cmd": "quantise", "path": path, "size": size, "palette": INK})
        if not r.get("ok"):
            sys.exit(r.get("error", "failed"))
        ch = lambda v: "." if v < 0 else (str(v) if v < 10 else chr(65 + v - 10))
        for row in r["grid"]:
            print("".join(ch(v) for v in row))
        print("usage:", r["usage"])
        return

    sys.exit(f"unknown command: {cmd}")


if __name__ == "__main__":
    main()
