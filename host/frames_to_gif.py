#!/usr/bin/env python3
"""
Pack the harness's captured frames into an animated GIF.

Two hundred frames of Doom is a film, not a flipbook, and opening them one at a
time tells you very little about whether the thing is actually running. This
turns a capture into something you can watch.

GIF rather than a video format for one reason: Doom's output is already 8-bit
paletted, which is exactly what GIF stores, so the frames go in without being
resampled or re-quantised. What you watch is what the hardware drew, pixel for
pixel. It also means no encoder to install -- GIF's compression is LZW, which is
about sixty lines, where every video codec worth using is a dependency.

    python3 host/frames_to_gif.py build/doom/doom.gif build/doom/frame*.ppm

Options:
    --delay N    hundredths of a second per frame (default 3, about 33 fps)
    --scale N    integer pixel doubling (default 2, since 320x200 is small)
"""

import struct
import sys


def read_ppm(path):
    with open(path, "rb") as f:
        if f.readline().strip() != b"P6":
            raise ValueError(f"{path}: not a binary PPM")
        line = f.readline()
        while line.startswith(b"#"):
            line = f.readline()
        w, h = map(int, line.split())
        f.readline()                      # maxval
        return w, h, f.read()


def quantise(rgb, w, h):
    """RGB bytes -> (indices, 256-entry palette).

    The source really is 8-bit paletted -- the harness expanded it on the way
    out -- so this cannot overflow 256 entries unless something upstream is
    wrong, and if it does the error says so rather than silently picking
    colours.
    """
    table = {}
    palette = bytearray()
    indices = bytearray(w * h)
    for i in range(w * h):
        c = rgb[i * 3:i * 3 + 3]
        idx = table.get(c)
        if idx is None:
            if len(table) == 256:
                raise ValueError("more than 256 colours in a frame")
            idx = len(table)
            table[c] = idx
            palette += c
        indices[i] = idx
    palette += bytes(768 - len(palette))
    return bytes(indices), bytes(palette)


def scale_up(indices, w, h, n):
    if n == 1:
        return indices, w, h
    out = bytearray(w * n * h * n)
    for y in range(h):
        row = indices[y * w:(y + 1) * w]
        wide = bytearray(w * n)
        for x in range(w):
            wide[x * n:(x + 1) * n] = bytes([row[x]]) * n
        base = y * n * w * n
        for k in range(n):
            out[base + k * w * n: base + (k + 1) * w * n] = wide
    return bytes(out), w * n, h * n


def lzw_encode(indices, min_code_size):
    """GIF's variable-width LZW.

    The width grows when the next code to be assigned no longer fits, and the
    decoder grows its own table in lockstep -- so the two must agree on exactly
    when that happens. Off by one here produces a file that some viewers open
    and others reject, which is why round_trip() below exists.
    """
    clear_code = 1 << min_code_size
    end_code = clear_code + 1

    out = bytearray()
    acc = 0
    nbits = 0

    def emit(code, size):
        nonlocal acc, nbits
        acc |= code << nbits
        nbits += size
        while nbits >= 8:
            out.append(acc & 0xFF)
            acc >>= 8
            nbits -= 8

    def fresh():
        return ({(i,): i for i in range(clear_code)},
                end_code + 1,
                min_code_size + 1)

    table, next_code, code_size = fresh()
    emit(clear_code, code_size)

    prefix = ()
    for k in indices:
        cand = prefix + (k,)
        if cand in table:
            prefix = cand
            continue
        emit(table[prefix], code_size)
        if next_code < 4096:
            table[cand] = next_code
            next_code += 1
            # Strictly greater, not equal. next_code is the code that will be
            # assigned *next*, so when it reaches 1<<code_size the widest code
            # actually in use is still (1<<code_size)-1 and fits. Widening on
            # equality emits one code at ten bits that every real decoder is
            # still reading as nine, which desynchronises the stream from that
            # point on -- the file's own palette renders, the image does not.
            if next_code > (1 << code_size) and code_size < 12:
                code_size += 1
        else:
            emit(clear_code, code_size)
            table, next_code, code_size = fresh()
        prefix = (k,)

    if prefix:
        emit(table[prefix], code_size)
    emit(end_code, code_size)
    if nbits:
        out.append(acc & 0xFF)
    return bytes(out)


def lzw_decode(data, min_code_size):
    """Independent decoder, used only to check the encoder against itself."""
    clear_code = 1 << min_code_size
    end_code = clear_code + 1
    code_size = min_code_size + 1
    table = [(i,) for i in range(clear_code)] + [None, None]
    out = []
    prev = None
    acc = 0
    nbits = 0
    pos = 0
    while True:
        while nbits < code_size:
            if pos >= len(data):
                return bytes(out)
            acc |= data[pos] << nbits
            nbits += 8
            pos += 1
        code = acc & ((1 << code_size) - 1)
        acc >>= code_size
        nbits -= code_size

        if code == clear_code:
            table = [(i,) for i in range(clear_code)] + [None, None]
            code_size = min_code_size + 1
            prev = None
            continue
        if code == end_code:
            return bytes(out)

        if code < len(table):
            entry = table[code]
        elif prev is not None:
            entry = prev + (prev[0],)
        else:
            raise ValueError("corrupt LZW stream")

        out.extend(entry)
        if prev is not None and len(table) < 4096:
            table.append(prev + (entry[0],))
            # One earlier than the encoder's test, and deliberately so. The
            # encoder adds an entry for every code it writes; the decoder cannot
            # add one for the first code after a clear, because it needs the
            # code *after* it to know the last symbol. So its table trails the
            # encoder's next_code by exactly one for the rest of the stream,
            # and the two tests differ by exactly that one.
            if len(table) == (1 << code_size) and code_size < 12:
                code_size += 1
        prev = entry


def blocks(data):
    """GIF data is carried in sub-blocks of at most 255 bytes."""
    out = bytearray()
    for i in range(0, len(data), 255):
        chunk = data[i:i + 255]
        out.append(len(chunk))
        out += chunk
    out.append(0)
    return bytes(out)


def write_gif(path, frames, w, h, delay):
    with open(path, "wb") as f:
        f.write(b"GIF89a")
        # Every frame carries its own colour table, because Doom changes the
        # palette for damage flashes and the menu fade. A global table is
        # therefore redundant -- but it is written anyway, holding the first
        # frame's colours.
        #
        # The reason is compatibility, not correctness. A GIF with no global
        # table is legal and this file's pixel data decodes byte-exactly
        # without one, but macOS's ImageIO renders it as a black rectangle:
        # it composites onto the background colour before consulting any local
        # table. Supplying a global table costs 768 bytes once and makes the
        # file open everywhere.
        f.write(struct.pack("<HHBBB", w, h, 0xF7, 0, 0))
        f.write(frames[0][1])
        # Loop forever.
        f.write(b"\x21\xFF\x0BNETSCAPE2.0\x03\x01\x00\x00\x00")

        for indices, palette in frames:
            f.write(b"\x21\xF9\x04\x00" + struct.pack("<H", delay) + b"\x00\x00")
            f.write(b"\x2C" + struct.pack("<HHHH", 0, 0, w, h) + bytes([0x87]))
            f.write(palette)
            f.write(bytes([8]))
            f.write(blocks(lzw_encode(indices, 8)))

        f.write(b"\x3B")


def round_trip(indices):
    got = lzw_decode(lzw_encode(indices, 8), 8)
    if got != indices:
        raise SystemExit("LZW round-trip failed -- the GIF would be corrupt")


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    opts = [a for a in argv[1:] if a.startswith("--")]
    if len(args) < 2:
        print(__doc__)
        return 2

    delay, scale = 3, 2
    for o in opts:
        k, _, v = o[2:].partition("=")
        if k == "delay":
            delay = int(v)
        elif k == "scale":
            scale = int(v)

    dst, srcs = args[0], args[1:]
    frames = []
    ow = oh = None
    for n, src in enumerate(srcs):
        w, h, rgb = read_ppm(src)
        indices, palette = quantise(rgb, w, h)
        indices, w, h = scale_up(indices, w, h, scale)
        if ow is None:
            ow, oh = w, h
            round_trip(indices)     # once; it is the encoder being checked
        elif (w, h) != (ow, oh):
            raise SystemExit(f"{src}: {w}x{h} does not match {ow}x{oh}")
        frames.append((indices, palette))
        if (n + 1) % 25 == 0:
            print(f"  {n + 1}/{len(srcs)} frames", flush=True)

    write_gif(dst, frames, ow, oh, delay)
    import os
    print(f"{dst}  {ow}x{oh}  {len(frames)} frames  "
          f"{os.path.getsize(dst) / 1e6:.1f} MB  {100 / delay:.0f} fps")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
