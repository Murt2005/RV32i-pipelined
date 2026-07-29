#!/usr/bin/env python3
"""
Turn the harness's PC samples into a per-function profile.

    DOOM_PROFILE=build/doom/prof.txt make doom-watch ...
    python3 host/profile_report.py build/doom/prof.txt build/tests/doom-d1b8rt0/doom.elf

The harness samples the fetch PC every 64 cycles and counts where it lands.
This maps those addresses onto the ELF's symbol table and aggregates, which
turns "the frame costs 2.36 million cycles" into "R_DrawColumn is 31% of it".

Samples are taken on a wall-clock-uniform schedule, so a function's share of
samples is its share of *cycles*, stalls included -- a routine that spends its
time waiting on memory shows up exactly as expensively as one that spends it
computing. That is the number worth optimising against.
"""

import bisect
import subprocess
import sys


def load_symbols(elf):
    """Sorted (addr, name) for every function symbol in the ELF."""
    for nm in ("riscv64-unknown-elf-nm", "riscv32-unknown-elf-nm",
               "riscv-none-elf-nm", "nm"):
        try:
            out = subprocess.run([nm, "-n", elf], capture_output=True,
                                 text=True, check=True).stdout
            break
        except (FileNotFoundError, subprocess.CalledProcessError):
            continue
    else:
        raise SystemExit(f"no usable nm found for {elf}")

    syms = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) != 3:
            continue
        addr, kind, name = parts
        if kind in "tTwW":                      # text symbols only
            syms.append((int(addr, 16), name))
    syms.sort()
    return syms


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    prof, elf = argv[1], argv[2]
    top_n = int(argv[3]) if len(argv) > 3 else 25

    syms = load_symbols(elf)
    addrs = [a for a, _ in syms]
    if not syms:
        raise SystemExit("no text symbols; is this the right ELF?")

    counts = {}
    total = outside = 0
    for line in open(prof):
        if line.startswith("#"):
            for tok in line.split():
                if tok.startswith("total="):   total = int(tok[6:])
                if tok.startswith("outside="): outside = int(tok[8:])
            continue
        a, c = line.split()
        a, c = int(a, 16), int(c)
        i = bisect.bisect_right(addrs, a) - 1
        name = syms[i][1] if i >= 0 else "?"
        counts[name] = counts.get(name, 0) + c

    in_range = sum(counts.values())
    if not in_range:
        raise SystemExit("no samples landed in any known function")

    print(f"{total:,} samples, {outside:,} outside the text range "
          f"({100*outside/max(total,1):.1f}%)\n")
    print(f"{'share':>7}  {'samples':>10}  function")
    print(f"{'-'*7}  {'-'*10}  {'-'*40}")
    cum = 0.0
    for name, c in sorted(counts.items(), key=lambda kv: -kv[1])[:top_n]:
        pct = 100 * c / in_range
        cum += pct
        print(f"{pct:6.2f}%  {c:>10,}  {name}")
    print(f"\ntop {top_n} account for {cum:.1f}% of in-range samples")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
