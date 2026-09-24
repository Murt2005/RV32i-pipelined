#!/usr/bin/env python3
"""
Split an ELF into the byte-lane hex images the simulator's memories read.

elftohex.sh already does this for the two on-chip memories, using objcopy and
dumphex and assuming the old two-region map. A program linked to run from SDRAM
has a boot stub at 0x00010000 and everything else at 0x80000000, which needs
three images rather than two and needs each one based at its own region.

    python3 tools/elf_to_sdram_hex.py build/sw/examples/hello.elf .

writes code0..3.hex (the boot stub), data0..3.hex (empty, but the simulator
reads them anyway) and sdram0..3.hex.
"""

import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from elf_images import find_objcopy, section_image, SDRAM_SECTIONS  # noqa: E402

REGIONS = [
    # name,     base,        sections to keep
    ("code",  0x00010000, [".boot"]),
    ("data",  0x00020000, []),
    ("sdram", 0x80000000, SDRAM_SECTIONS),
]


def write_lanes(image, prefix, out_dir):
    """One hex file per byte lane, one byte per line -- what memory.sv reads."""
    for lane in range(4):
        path = os.path.join(out_dir, f"{prefix}{lane}.hex")
        with open(path, "w") as f:
            for i in range(lane, len(image), 4):
                f.write(f"{image[i]:02x}\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf")
    ap.add_argument("out_dir", nargs="?", default=".")
    args = ap.parse_args()

    objcopy = find_objcopy()
    os.makedirs(args.out_dir, exist_ok=True)
    for name, base, sections in REGIONS:
        img = section_image(args.elf, sections, objcopy) if sections else b""
        write_lanes(img, name, args.out_dir)
        print(f"{name}: {len(img)} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
