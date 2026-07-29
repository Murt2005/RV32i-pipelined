#!/usr/bin/env python3
"""
Drive the live Doom harness over a pty, for testing the input path.

The harness only enables live input when stdin is a terminal, which is correct
-- raw mode on a pipe is meaningless -- but it also means a plain shell pipeline
cannot test the thing. This allocates a real pty, so isatty() is true and the
keys go in exactly as if they had been typed.

    python3 tests/doom/drive_live.py build/doom/title.snap \\
        1.0:ESC 3.0:ENTER 3.0:ENTER 3.0:ENTER 6.0:www 6.0:q

Each argument is <delay-seconds>:<keys>, the delay being measured from the
previous one. Names ESC, ENTER and TAB stand for the bytes of the same name;
anything else is sent literally.
"""

import os
import pty
import select
import sys
import time

NAMED = {"ESC": b"\x1b", "ENTER": b"\r", "TAB": b"\t", "SPACE": b" "}

# Arrow keys, as a terminal actually sends them.
NAMED.update({"UP": b"\x1b[A", "DOWN": b"\x1b[B",
              "RIGHT": b"\x1b[C", "LEFT": b"\x1b[D"})

# SGR mouse, exactly as a terminal sends it: ESC [ < btn ; col ; row M/m.
# CLICK is the press and release pair a real click produces.
NAMED.update({"MDOWN": b"\x1b[<0;40;12M", "MUP": b"\x1b[<0;40;12m",
              "CLICK": b"\x1b[<0;40;12M\x1b[<0;40;12m",
              "RCLICK": b"\x1b[<2;40;12M\x1b[<2;40;12m"})


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2

    snap = argv[1]
    script = []
    for a in argv[2:]:
        delay, _, keys = a.partition(":")
        script.append((float(delay), NAMED.get(keys, keys.encode())))

    env = dict(os.environ)
    env["DOOM_LIVE"] = "1"
    env["DOOM_KEYS"] = ""
    env["DOOM_LOAD"] = snap

    # The build directory carries the renderer configuration in its name, so
    # the caller has to say which one; there is no single "the" Doom build.
    out = os.environ.get("DOOM_OUT_DIR", "build/tests/doom-d0b10rt0")
    cmd = ["./build/doom/Vtop",
           f"{out}/doom.sdram.bin",
           "tests/doom/doom1.wad",
           f"{out}/doom.boot.bin",
           "0"]

    pid, fd = pty.fork()
    if pid == 0:
        os.execvpe(cmd[0], cmd, env)
        os._exit(1)

    next_at = time.monotonic() + script[0][0]
    idx = 0
    out = []
    while True:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            out.append(data)
            sys.stdout.write(data.decode("utf-8", "replace"))
            sys.stdout.flush()

        now = time.monotonic()
        if idx < len(script) and now >= next_at:
            keys = script[idx][1]
            print(f"\n[drive] sending {keys!r}\n", flush=True)
            os.write(fd, keys)
            idx += 1
            if idx < len(script):
                next_at = now + script[idx][0]

        if idx >= len(script) and not r:
            # Everything sent and the child has gone quiet.
            try:
                if os.waitpid(pid, os.WNOHANG)[0] == pid:
                    break
            except ChildProcessError:
                break

    os.close(fd)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
