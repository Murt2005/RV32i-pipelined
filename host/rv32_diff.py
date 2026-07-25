#!/usr/bin/env python3
"""
Differential test: random RV32I programs, hardware vs reference model.

For each iteration it generates a random straight-line-plus-forward-branches
program, runs it on the FPGA and on rv32_model.py, then compares the full
architectural state -- all 30 general registers plus the scratch memory the
program was allowed to touch -- read back over the loader's 'R' command.

Why this finds things the directed tests cannot: the hand-written tests and
even riscv-tests exercise instructions in patterns a human chose. The bugs left
in a pipelined core live in *interactions* -- a particular bypass source
landing on a particular stall cycle next to a particular branch. Random
sequences hit those combinations without anyone having to imagine them.

    python3 host/rv32_diff.py                    # 50 programs
    python3 host/rv32_diff.py --iters 500 --seed 7
    python3 host/rv32_diff.py --length 400       # longer programs
"""

import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rv32_model import Rv32Model                                # noqa: E402
from rv32_host import (open_board, Rv32Error, TEXT_BASE,        # noqa: E402
                       DATA_BASE)

# x31 is reserved as the scratch-memory base pointer and is never written by
# generated code, so every load and store is guaranteed to land in bounds.
BASE_REG = 31

SCRATCH_BASE = 0x00021000
SCRATCH_SIZE = 256
DUMP_OFFSET = 1024                  # from SCRATCH_BASE; fits a 12-bit imm
DUMP_BASE = SCRATCH_BASE + DUMP_OFFSET
DUMP_REGS = list(range(1, 31))      # x1..x30
HALT_ADDR = 0x0002FFFC


# ---------------------------------------------------------------------------
# instruction encoders
# ---------------------------------------------------------------------------
def r_type(f7, rs2, rs1, f3, rd, op):
    return (f7 << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def i_type(imm, rs1, f3, rd, op):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (f3 << 12) | (rd << 7) | op


def s_type(imm, rs2, rs1, f3, op):
    imm &= 0xFFF
    return ((imm >> 5) << 25) | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
        | ((imm & 0x1F) << 7) | op


def b_type(imm, rs2, rs1, f3, op):
    imm &= 0x1FFF
    return (((imm >> 12) & 1) << 31) | (((imm >> 5) & 0x3F) << 25) \
        | (rs2 << 20) | (rs1 << 15) | (f3 << 12) \
        | (((imm >> 1) & 0xF) << 8) | (((imm >> 11) & 1) << 7) | op


def u_type(imm, rd, op):
    return (imm & 0xFFFFF000) | (rd << 7) | op


def j_type(imm, rd, op):
    imm &= 0x1FFFFF
    return (((imm >> 20) & 1) << 31) | (((imm >> 1) & 0x3FF) << 21) \
        | (((imm >> 11) & 1) << 20) | (((imm >> 12) & 0xFF) << 12) \
        | (rd << 7) | op


def li(rd, value):
    """lui/addi pair loading an arbitrary 32-bit constant."""
    value &= 0xFFFFFFFF
    lower = value & 0xFFF
    upper = value - (lower - 0x1000 if lower & 0x800 else lower)
    out = []
    if upper & 0xFFFFF000:
        out.append(u_type(upper & 0xFFFFF000, rd, 0x37))
        out.append(i_type(lower, rd, 0, rd, 0x13))
    else:
        out.append(i_type(lower, 0, 0, rd, 0x13))
    return out


OP_F3F7 = [("add", 0, 0x00), ("sub", 0, 0x20), ("sll", 1, 0x00),
           ("slt", 2, 0x00), ("sltu", 3, 0x00), ("xor", 4, 0x00),
           ("srl", 5, 0x00), ("sra", 5, 0x20), ("or", 6, 0x00),
           ("and", 7, 0x00)]

OPIMM_F3 = [("addi", 0), ("slti", 2), ("sltiu", 3),
            ("xori", 4), ("ori", 6), ("andi", 7)]

BRANCH_F3 = [("beq", 0), ("bne", 1), ("blt", 4),
             ("bge", 5), ("bltu", 6), ("bgeu", 7)]

LOAD_F3 = [("lb", 0, 1), ("lh", 1, 2), ("lw", 2, 4), ("lbu", 4, 1), ("lhu", 5, 2)]
STORE_F3 = [("sb", 0, 1), ("sh", 1, 2), ("sw", 2, 4)]


def gen_program(rng, body_len):
    """Returns (list of instruction words, initial register values)."""
    # Registers a generated instruction may write: anything but the scratch
    # base. x0 is included on purpose -- writes to it must be discarded.
    wr_regs = [r for r in range(0, 31)]
    rd_regs = list(range(0, 31))

    init = {r: rng.getrandbits(32) for r in range(1, 31)}

    prologue = []
    for r in range(1, 31):
        prologue += li(r, init[r])
    prologue += li(BASE_REG, SCRATCH_BASE)

    body = []
    for idx in range(body_len):
        kind = rng.choices(
            ["op", "opimm", "shift", "lui", "auipc", "load", "store", "branch", "jal"],
            weights=[26, 18, 10, 5, 5, 12, 12, 10, 2])[0]
        rd = rng.choice(wr_regs)
        rs1 = rng.choice(rd_regs)
        rs2 = rng.choice(rd_regs)

        if kind == "op":
            _, f3, f7 = rng.choice(OP_F3F7)
            body.append(r_type(f7, rs2, rs1, f3, rd, 0x33))
        elif kind == "opimm":
            _, f3 = rng.choice(OPIMM_F3)
            body.append(i_type(rng.randrange(-2048, 2048), rs1, f3, rd, 0x13))
        elif kind == "shift":
            shamt = rng.randrange(0, 32)
            f3, f7 = rng.choice([(1, 0x00), (5, 0x00), (5, 0x20)])
            body.append(i_type((f7 << 5) | shamt, rs1, f3, rd, 0x13))
        elif kind == "lui":
            body.append(u_type(rng.getrandbits(20) << 12, rd, 0x37))
        elif kind == "auipc":
            body.append(u_type(rng.getrandbits(20) << 12, rd, 0x17))
        elif kind == "load":
            _, f3, width = rng.choice(LOAD_F3)
            off = rng.randrange(0, SCRATCH_SIZE // width) * width
            body.append(i_type(off, BASE_REG, f3, rd, 0x03))
        elif kind == "store":
            _, f3, width = rng.choice(STORE_F3)
            off = rng.randrange(0, SCRATCH_SIZE // width) * width
            body.append(s_type(off, rs2, BASE_REG, f3, 0x23))
        elif kind == "branch":
            # Forward only, so the program always terminates.
            _, f3 = rng.choice(BRANCH_F3)
            skip = rng.randrange(1, 9)
            target = min(idx + 1 + skip, body_len)
            body.append(b_type((target - idx) * 4, rs2, rs1, f3, 0x63))
        else:  # jal, forward only
            skip = rng.randrange(1, 5)
            target = min(idx + 1 + skip, body_len)
            body.append(j_type((target - idx) * 4, rd, 0x6F))

    # Dump x1..x30 before anything can clobber them, then stop.
    epilogue = []
    for i, r in enumerate(DUMP_REGS):
        epilogue.append(s_type(DUMP_OFFSET + i * 4, r, BASE_REG, 2, 0x23))
    # x1 has already been dumped, so it is safe to reuse for the halt address.
    epilogue += li(1, HALT_ADDR)
    epilogue.append(s_type(0, 0, 1, 2, 0x23))       # sw x0, 0(x1)
    epilogue.append(j_type(0, 0, 0x6F))             # j . (halt is edge-latched)

    return prologue + body + epilogue, init


def to_bytes(words):
    out = bytearray()
    for w in words:
        out += (w & 0xFFFFFFFF).to_bytes(4, "little")
    return bytes(out)


def run_one(board, rng, body_len, verbose=False):
    words, _ = gen_program(rng, body_len)
    text = to_bytes(words)

    # reference
    model = Rv32Model(text, b"")
    if not model.run():
        return "model did not halt", None

    # hardware
    board.halt()
    board.zero_mem()
    board.write_mem(TEXT_BASE, text)
    out, halted = board.go(run_timeout=10.0)
    if not halted:
        return "hardware did not halt", text
    if out:
        return f"hardware produced unexpected output {out!r}", text

    hw_dump = board.read_mem(DUMP_BASE, len(DUMP_REGS) * 4)
    hw_scratch = board.read_mem(SCRATCH_BASE, SCRATCH_SIZE)
    md_dump = model.read(DUMP_BASE, len(DUMP_REGS) * 4)
    md_scratch = model.read(SCRATCH_BASE, SCRATCH_SIZE)

    if hw_dump != md_dump:
        for i, r in enumerate(DUMP_REGS):
            h = int.from_bytes(hw_dump[i * 4:i * 4 + 4], "little")
            m = int.from_bytes(md_dump[i * 4:i * 4 + 4], "little")
            if h != m:
                return f"x{r}: hardware 0x{h:08x}, model 0x{m:08x}", text
    if hw_scratch != md_scratch:
        for i in range(0, SCRATCH_SIZE, 4):
            h = hw_scratch[i:i + 4]
            m = md_scratch[i:i + 4]
            if h != m:
                return (f"mem[0x{SCRATCH_BASE + i:08x}]: hardware {h.hex()}, "
                        f"model {m.hex()}"), text
    return None, text


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port")
    ap.add_argument("--iters", type=int, default=50)
    ap.add_argument("--length", type=int, default=120,
                    help="instructions in the random body")
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--save-failure", default="build/diff-failure.bin")
    args = ap.parse_args()

    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    print(f"seed {seed}, {args.iters} programs of {args.length} instructions")

    try:
        board = open_board(args.port)
    except Rv32Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    failures = 0
    try:
        for i in range(args.iters):
            # Per-iteration seed, so any single failure is reproducible on its
            # own without replaying everything before it.
            rng = random.Random(seed + i)
            why, text = run_one(board, rng, args.length)
            if why:
                failures += 1
                print(f"FAIL  iter {i} (seed {seed + i}): {why}")
                if text:
                    os.makedirs(os.path.dirname(args.save_failure), exist_ok=True)
                    with open(args.save_failure, "wb") as f:
                        f.write(text)
                    print(f"      program written to {args.save_failure}")
                break
            if (i + 1) % 10 == 0:
                print(f"  {i + 1}/{args.iters} ok")
    except Rv32Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        board.close()

    print(f"\n{args.iters - failures} matched, {failures} mismatched")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
