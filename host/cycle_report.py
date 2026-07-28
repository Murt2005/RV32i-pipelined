#!/usr/bin/env python3
"""Extract per-test cycle counts from a simulation suite log, and diff two runs.

The point of this is a single gate: some changes to the pipeline are supposed to
be *invisible* when the memory answers in one cycle. Decoupling the memory
stage's request generation from its advance signal is the obvious example -- with
a single-cycle memory none of the new stall conditions can ever assert, so every
test must take exactly the same number of cycles as before. A cycle-count delta
is then the cheapest possible signal that the fast path was perturbed, and it
shows up long before any test starts failing.

Cycles come from the simulator's own `$finish` timestamp rather than from the
core's mcycle CSR, because that works for every test including the ones that
never read a counter, and it costs nothing to collect.

    # record a baseline
    make run-tests-iverilog | python3 host/cycle_report.py --save build/cycles-base.json

    # after a change, compare
    make run-tests-iverilog | python3 host/cycle_report.py --compare build/cycles-base.json
"""

import argparse
import json
import re
import sys

# itop.sv: `timescale 1ns/1ps with `always #5 clk`, so one cycle is 10 ns and
# $finish reports picoseconds.
PS_PER_CYCLE = 10_000

# Two log shapes. The directed suite prints a banner and lets the simulator's own
# output through, so the name precedes the $finish:
#     === tests/isa/add_sub ===
#     itop.sv:65: $finish called at 15640000 (1ps)
# The riscv-tests runners swallow the simulator output and print one line per
# test, so the runner re-emits the timestamp itself:
#     PASS rv32ui-add  finish=15640000
NAME_RE = re.compile(r"^===\s*(\S+)\s*===")
FINISH_RE = re.compile(r"\$finish called at (\d+)")
TIMEOUT_RE = re.compile(r"^TIMEOUT after (\d+) cycles")
SUMMARY_RE = re.compile(r"^(?:PASS|FAIL)\s+(\S+)\s+finish=(\d+)")


def parse(lines):
    """Map test name -> cycles. A test's name always precedes its $finish."""
    cycles = {}
    pending = None
    for line in lines:
        m = SUMMARY_RE.match(line)
        if m:
            cycles[m.group(1)] = int(m.group(2)) // PS_PER_CYCLE
            pending = None
            continue
        m = NAME_RE.match(line)
        if m:
            pending = m.group(1)
            continue
        m = FINISH_RE.search(line)
        if m and pending is not None:
            cycles[pending] = int(m.group(1)) // PS_PER_CYCLE
            pending = None
            continue
        m = TIMEOUT_RE.match(line)
        if m and pending is not None:
            # Record it rather than dropping it -- a test that started timing out
            # is exactly what this tool exists to make visible.
            cycles[pending] = -int(m.group(1))
            pending = None
    return cycles


def compare(base, now):
    """Return (regressions, added, removed). Any delta at all is a finding."""
    deltas = []
    for name in sorted(set(base) & set(now)):
        if base[name] != now[name]:
            deltas.append((name, base[name], now[name]))
    return deltas, sorted(set(now) - set(base)), sorted(set(base) - set(now))


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--save", metavar="FILE", help="write the parsed counts as JSON")
    ap.add_argument("--compare", metavar="FILE",
                    help="diff against a saved baseline; exit 1 on any difference")
    ap.add_argument("log", nargs="?", help="suite log file (default: stdin)")
    args = ap.parse_args()

    if args.log:
        with open(args.log) as f:
            cycles = parse(f)
    else:
        cycles = parse(sys.stdin)
    if not cycles:
        print("no test results found in the log", file=sys.stderr)
        return 2

    total = sum(c for c in cycles.values() if c > 0)
    print(f"{len(cycles)} tests, {total} cycles total")

    if args.save:
        with open(args.save, "w") as f:
            json.dump(cycles, f, indent=2, sort_keys=True)
        print(f"saved to {args.save}")

    if args.compare:
        with open(args.compare) as f:
            base = json.load(f)
        deltas, added, removed = compare(base, cycles)
        for name in added:
            print(f"  new      {name}: {cycles[name]}")
        for name in removed:
            print(f"  gone     {name}: was {base[name]}")
        for name, was, now in deltas:
            print(f"  CHANGED  {name}: {was} -> {now}  ({now - was:+d})")
        if deltas:
            print(f"{len(deltas)} test(s) changed cycle count", file=sys.stderr)
            return 1
        print("cycle counts identical")

    return 0


if __name__ == "__main__":
    sys.exit(main())
