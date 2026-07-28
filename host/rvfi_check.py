#!/usr/bin/env python3
"""
Cross-check the core's RVFI commit record against the reference model.

riscv-formal reasons entirely about what the RVFI port reports, so a wrong RVFI
record produces confident nonsense in both directions: real bugs hidden, and
proofs that mean nothing. This validates the record itself before any of that,
by replaying every retired instruction through host/rv32_model.py and comparing
the fields the formal checks depend on.

    make build/sim/result-rvfi
    python3 host/rvfi_check.py build/tests/isa/add_sub.elf
    python3 host/rvfi_check.py --all
"""

import argparse
import glob
import os
import subprocess
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from rv32_model import Rv32Model                      # noqa: E402
from rv32_host import elf_to_images                   # noqa: E402

SIM = "build/sim/result-rvfi"

# The reference model implements the ISA, not this board's peripherals or CSRs.
# Where an instruction's result legitimately comes from something the model
# knows nothing about, take the core's value and keep stepping rather than
# reporting a mismatch that is really a model gap.
MMIO_LO, MMIO_HI = 0x0002FFF0, 0x0002FFFF
FIELDS = ("order pc_rdata pc_wdata insn rs1_addr rs1_rdata rs2_addr rs2_rdata "
          "rd_addr rd_wdata mem_addr mem_rmask mem_wmask mem_rdata mem_wdata "
          "trap").split()


def write_hex(image, prefix, out_dir):
    """Write a memory image as the four byte-lane hex files memory.sv reads.

    dumphex normally does this from an ELF via objcopy. Writing it directly lets
    a caller simulate a program it generated in memory, with no ELF and no
    assembler in the loop.
    """
    for lane in range(4):
        with open(os.path.join(out_dir, f"{prefix}{lane}.hex"), "w") as f:
            for i in range(lane, len(image), 4):
                f.write(f"{image[i]:02x}\n")


def run_sim_images(text, data, repo_root, timeout_cycles=200000, sim_args=()):
    """Run the RVFI simulator over raw images and return the commit records.

    Runs in a scratch directory rather than the repo root. memory.sv reads
    code0.hex..data3.hex from the working directory, so every build target and
    test runner in the tree writes those same eight files -- which means two runs
    in parallel silently read each other's program. That has already produced one
    phantom mismatch. Nothing here needs to be in the repo, so it is not.
    """
    with tempfile.TemporaryDirectory(prefix="rv32sim-") as work:
        write_hex(text, "code", work)
        write_hex(data if data else b"\x00" * 4, "data", work)
        sim = os.path.abspath(os.path.join(repo_root, SIM))
        return _run_sim_binary(work, timeout_cycles, sim_args, sim=sim)


def run_sim(elf, repo_root, timeout_cycles=200000, sim_args=()):
    subprocess.run(["/bin/bash", "./elftohex.sh", elf, "."],
                   cwd=repo_root, capture_output=True)
    return _run_sim_binary(repo_root, timeout_cycles, sim_args)


def _run_sim_binary(work_dir, timeout_cycles, sim_args=(), sim=None):
    r = subprocess.run([sim or f"./{SIM}", f"+timeout={timeout_cycles}", *sim_args],
                       cwd=work_dir, capture_output=True, text=True, timeout=600)
    recs = []
    for line in r.stdout.splitlines():
        # Not anchored: the program's putchar uses $write with no newline, so a
        # record emitted on the same cycle is prefixed by that character.
        idx = line.find("RVFI ")
        if idx < 0:
            continue
        parts = line[idx:].split()[1:]
        if len(parts) != len(FIELDS):
            continue
        rec = {}
        for name, val in zip(FIELDS, parts):
            rec[name] = int(val, 16) if name not in ("order", "rs1_addr", "rs2_addr",
                                                     "rd_addr", "trap") else int(val)
        recs.append(rec)
    return recs


def check(elf, repo_root, limit=None, verbose=False, sim_args=(),
          timeout_cycles=200000):
    recs = run_sim(elf, repo_root, timeout_cycles=timeout_cycles, sim_args=sim_args)
    if not recs:
        return [f"{os.path.basename(elf)}: no RVFI records"]
    text, data = elf_to_images(elf)
    return compare(recs, text, data, limit=limit, verbose=verbose)


def compare(recs, text, data, limit=None, verbose=False):
    """Replay the commit records through the model and report disagreements.

    Separated from check() so a caller with its own program -- a randomly
    generated one, say -- can reuse the comparison without producing an ELF.
    """
    model = Rv32Model(text, data)
    errors = []

    for n, r in enumerate(recs):
        if limit and n >= limit:
            break
        if r["trap"]:
            # The model has no trap support, so stop rather than report noise.
            break

        if model.pc != r["pc_rdata"]:
            errors.append(f"  #{n} pc: core {r['pc_rdata']:08x}, model {model.pc:08x}")
            break

        # Through the model's region map, not its low-memory array: code can run
        # from SDRAM now, and indexing `mem` directly reports zero for it.
        insn = int.from_bytes(model.read(model.pc, 4), "little")
        if insn != r["insn"]:
            errors.append(f"  #{n} @{model.pc:08x} insn: core {r['insn']:08x}, "
                          f"memory {insn:08x}")
            break

        for which in ("rs1", "rs2"):
            addr = r[f"{which}_addr"]
            if addr and model.x[addr] != r[f"{which}_rdata"]:
                errors.append(f"  #{n} @{model.pc:08x} {which}=x{addr}: core "
                              f"{r[f'{which}_rdata']:08x}, model {model.x[addr]:08x}")

        try:
            model.step()
        except Exception as exc:
            errors.append(f"  #{n} @{r['pc_rdata']:08x} model: {exc}")
            break

        if model.pc != r["pc_wdata"]:
            errors.append(f"  #{n} @{r['pc_rdata']:08x} next pc: core "
                          f"{r['pc_wdata']:08x}, model {model.pc:08x}")
            break

        rd = r["rd_addr"]
        opcode = r["insn"] & 0x7F
        model_blind = (opcode == 0x73) or (           # any CSR read
            opcode == 0x03 and MMIO_LO <= r["mem_addr"] <= MMIO_HI)
        if rd:
            if model_blind:
                model.x[rd] = r["rd_wdata"]           # resync, keep going
            elif model.x[rd] != r["rd_wdata"]:
                errors.append(f"  #{n} @{r['pc_rdata']:08x} x{rd}: core "
                              f"{r['rd_wdata']:08x}, model {model.x[rd]:08x}")

        if errors:
            break

    if verbose and not errors:
        print(f"  {len(recs)} instructions checked")
    return errors


def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("elf", nargs="?")
    ap.add_argument("--all", action="store_true",
                    help="every directed test plus the rv32ui suite")
    ap.add_argument("-v", "--verbose", action="store_true")
    # The commit record has to be right when the memory is slow, not only when it
    # answers in one cycle. An RVFI shadow that was overwritten while its
    # instruction waited in EX/MEM went unnoticed for two phases precisely
    # because this only ever ran at zero.
    ap.add_argument("--mem-latency", type=int, default=0,
                    help="extra memory latency, 0..N cycles drawn per access")
    ap.add_argument("--stall-rate", type=int, default=0,
                    help="external stall injection, out of 256")
    args = ap.parse_args()

    if not os.path.exists(os.path.join(repo_root, SIM)):
        sys.exit(f"{SIM} not built -- run `make {SIM}`")

    elfs = []
    if args.all:
        elfs += sorted(glob.glob(os.path.join(repo_root, "build/tests/isa/*.elf")))
        elfs += sorted(glob.glob(os.path.join(repo_root, "build/tests/hazards/*.elf")))
        elfs += sorted(glob.glob(os.path.join(repo_root, "build/riscv-tests/*.elf")))
    elif args.elf:
        elfs = [os.path.abspath(args.elf)]
    else:
        ap.error("give an ELF or --all")

    bad = 0
    for elf in elfs:
        name = os.path.basename(elf)[:-4]
        errs = check(elf, repo_root, verbose=args.verbose,
                     sim_args=[f"+memlatency={args.mem_latency}",
                               f"+stallrate={args.stall_rate}"],
                     # A slow memory stretches every program out; the default
                     # watchdog would report a timeout as "no RVFI records".
                     timeout_cycles=200000 * (args.mem_latency + 1))
        if errs:
            bad += 1
            print(f"MISMATCH {name}")
            for e in errs[:4]:
                print(e)
        else:
            print(f"ok       {name}")

    print(f"\n{len(elfs) - bad} matched, {bad} mismatched, {len(elfs)} total")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
