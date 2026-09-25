#!/usr/bin/env python3
"""Summarise a merged Verilator coverage file: line, branch and toggle coverage per
file, a total over the design in rtl/, and every line and branch never reached.

    python3 tools/coverage-report.py build/cov/merged.dat
"""

import collections
import re
import sys

KINDS = ("line", "branch", "toggle")
RECORD_RE = re.compile(r"^C '(.*)' (\d+)$")


def fields(key):
    """Verilator packs each point's attributes as \\x01name\\x02value pairs."""
    return dict(part.split("\x02", 1) for part in key.split("\x01") if "\x02" in part)


def main():
    total = collections.Counter()
    hit = collections.Counter()
    missed = []
    with open(sys.argv[1]) as f:
        for record in f:
            m = RECORD_RE.match(record.strip())
            if not m:
                continue
            attrs, count = fields(m.group(1)), int(m.group(2))
            kind = attrs["page"].split("/")[0].removeprefix("v_")
            key = (attrs["f"], kind)
            total[key] += 1
            hit[key] += count > 0
            if count == 0 and kind in ("line", "branch"):
                missed.append((attrs["f"], int(attrs["l"]), kind, attrs.get("o", "")))

    def cell(h, t):
        return f"{h:5}/{t:<5} {100 * h / t:5.1f}%" if t else f"{'-':>18}"

    files = sorted({f for f, _ in total}, key=lambda f: (not f.startswith("rtl/"), f))
    print(f"\n{'file':24}" + "".join(f"{k:>19}" for k in KINDS))
    design = collections.Counter(), collections.Counter()
    for f in files:
        print(f"{f:24}" + "".join(f" {cell(hit[f, k], total[f, k])}" for k in KINDS))
        if f.startswith("rtl/"):
            for k in KINDS:
                design[0][k] += hit[f, k]
                design[1][k] += total[f, k]
    print(f"{'design (rtl/)':24}" + "".join(f" {cell(design[0][k], design[1][k])}" for k in KINDS))

    print("\nnever reached (sources annotated in build/cov/annotated/):")
    if not missed:
        print("  none")
    sources = {}
    for f, line, kind, what in sorted(set(missed)):
        if f not in sources:
            try:
                sources[f] = open(f).read().splitlines()
            except OSError:
                sources[f] = []
        text = sources[f][line - 1].strip() if line <= len(sources[f]) else ""
        print(f"  {f + ':' + str(line):26} {kind:6} {what:6} {text[:60]}")


if __name__ == "__main__":
    main()
