#!/usr/bin/env python3
"""
Convert the harness's captured frames to PNG.

The harness writes binary PPM because it needs no library and cannot fail in an
interesting way. Nothing on macOS opens PPM, though, so this converts them --
also with no library, since PNG's required encoding is deflate and zlib is in
the standard library.

    python3 host/ppm_to_png.py build/doom/*.ppm
"""

import struct
import sys
import zlib


def read_ppm(path):
    with open(path, "rb") as f:
        if f.readline().strip() != b"P6":
            raise ValueError(f"{path}: not a binary PPM")
        # Skip comments, which the harness does not emit but other tools do.
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = map(int, line.split())
        f.readline()                      # maxval
        return w, h, f.read()


def write_png(path, w, h, rgb):
    # One filter byte per scanline; filter 0 (none) is fine for indexed art and
    # keeps this to a dozen lines.
    raw = b"".join(b"\x00" + rgb[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(tag, data):
        body = tag + data
        return (struct.pack(">I", len(data)) + body
                + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF))

    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n")
        f.write(chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0)))
        f.write(chunk(b"IDAT", zlib.compress(raw, 9)))
        f.write(chunk(b"IEND", b""))


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    for src in argv[1:]:
        w, h, rgb = read_ppm(src)
        dst = src.rsplit(".", 1)[0] + ".png"
        write_png(dst, w, h, rgb)
        print(f"{dst}  {w}x{h}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
