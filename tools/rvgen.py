#!/usr/bin/env python3
"""
Random RV32IM program generator for co-simulation against Spike.

    python3 tools/rvgen.py <seed> [length] > prog.S

Writes an assembly program that always terminates and never touches memory
outside its own scratch array: branches only go forward, loops count down a
register nothing else writes, and loads, stores and jalr use base registers
nothing else writes. It ends by writing 1 to tohost, like the riscv-tests.
"""

import random
import sys

BASE = "x31"        # scratch array base, for loads and stores
LOOP = "x30"        # loop counter
CODE = "x29"        # address of the body, for jalr
FREE = [f"x{i}" for i in range(29)]     # x0 included: writes to it must be dropped
ANY = [f"x{i}" for i in range(32)]
SCRATCH = 256       # bytes

OP = ["add", "sub", "sll", "slt", "sltu", "xor", "srl", "sra", "or", "and",
      "mul", "mulh", "mulhsu", "mulhu", "div", "divu", "rem", "remu"]
OPIMM = ["addi", "slti", "sltiu", "xori", "ori", "andi"]
SHIFT = ["slli", "srli", "srai"]
BRANCH = ["beq", "bne", "blt", "bge", "bltu", "bgeu"]
LOAD = [("lb", 1), ("lh", 2), ("lw", 4), ("lbu", 1), ("lhu", 2)]
STORE = [("sb", 1), ("sh", 2), ("sw", 4)]


def simple(rng):
    """One instruction with no control flow"""
    rd, rs1, rs2 = rng.choice(FREE), rng.choice(ANY), rng.choice(ANY)
    kind = rng.choices(["op", "opimm", "shift", "lui", "auipc", "load", "store", "csr"],
                       weights=[38, 17, 10, 5, 5, 12, 12, 3])[0]
    if kind == "op":
        return f"{rng.choice(OP)} {rd}, {rs1}, {rs2}"
    if kind == "opimm":
        return f"{rng.choice(OPIMM)} {rd}, {rs1}, {rng.randrange(-2048, 2048)}"
    if kind == "shift":
        return f"{rng.choice(SHIFT)} {rd}, {rs1}, {rng.randrange(32)}"
    if kind in ("lui", "auipc"):
        return f"{kind} {rd}, {rng.getrandbits(20)}"
    if kind == "load":
        op, width = rng.choice(LOAD)
        return f"{op} {rd}, {rng.randrange(SCRATCH // width) * width}({BASE})"
    if kind == "store":
        op, width = rng.choice(STORE)
        return f"{op} {rs2}, {rng.randrange(SCRATCH // width) * width}({BASE})"
    return rng.choice([f"csrw mscratch, {rs1}", f"csrr {rd}, mscratch", f"csrr {rd}, mcycle"])


def body(rng, length):
    """The random part, one instruction per line, labelled L0, L1, ..."""
    lines = []

    def label(i):
        return f"L{min(i, length)}"

    while len(lines) < length:
        i = len(lines)
        rd, rs1, rs2 = rng.choice(FREE), rng.choice(ANY), rng.choice(ANY)
        kind = rng.choices(["simple", "branch", "jal", "jalr", "loop"],
                           weights=[62, 14, 4, 8, 12])[0]
        if kind == "simple":
            lines.append(simple(rng))
        elif kind == "branch":
            lines.append(f"{rng.choice(BRANCH)} {rs1}, {rs2}, {label(i + 1 + rng.randrange(1, 9))}")
        elif kind == "jal":
            lines.append(f"jal {rd}, {label(i + 1 + rng.randrange(1, 5))}")
        elif kind == "jalr":
            # Forward, within a 12-bit offset of CODE. Every body line is one
            # instruction, so line n is at CODE + 4n. An odd offset checks that
            # jalr clears bit 0 of the target
            target = min(i + 1 + rng.randrange(1, 6), length, 500)
            lines.append(f"jalr {rd}, {4 * target + (rng.random() < 0.25)}({CODE})")
        else:
            # The counter is masked to 0..7 every pass, so even a branch that
            # lands inside the loop, past its initialisation, can't spin for long
            top = f"T{i}"
            lines.append(f"li {LOOP}, {rng.randrange(2, 6)}")
            lines.append(f"{top}: {simple(rng)}")
            for _ in range(rng.randrange(0, 4)):
                lines.append(simple(rng))
            lines.append(f"addi {LOOP}, {LOOP}, -1")
            lines.append(f"andi {LOOP}, {LOOP}, 7")
            lines.append(f"bnez {LOOP}, {top}")
    return lines[:length]


def program(seed, length):
    rng = random.Random(seed)
    out = [f"# rvgen seed {seed}", ".option norelax", ".option norvc",
           ".section .text.init", ".globl _start", "_start:"]
    for r in range(1, 29):
        out.append(f"    li x{r}, {rng.getrandbits(32)}")
    out += [f"    li {LOOP}, 0", f"    la {BASE}, scratch", f"    la {CODE}, L0"]

    lines = body(rng, length)
    for i, line in enumerate(lines):
        # A loop's own label sits inside the line, so body labels go on their own line
        out.append(f"L{i}:")
        out.append(f"    {line}")
    out += [f"L{len(lines)}:", "    li t0, 0x0002FFC0", "    li t1, 1",
            "    sw t1, 0(t0)", "1:  j 1b",
            ".data", ".align 4", "scratch:"]
    out += [f"    .word {rng.getrandbits(32)}" for _ in range(SCRATCH // 4)]
    return "\n".join(out) + "\n"


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("usage: rvgen.py <seed> [length]")
    sys.stdout.write(program(int(sys.argv[1]), int(sys.argv[2]) if len(sys.argv) > 2 else 200))
