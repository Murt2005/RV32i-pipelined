#!/bin/bash
#
# Run test ELFs on a simulator and report each one's tohost result
#
#   run-tests.sh <simulator> [+plusarg...] <elf>...
#
# Run from the repo root. ELFs live under build/<config>/, which picks the hex
# converter; each one's images go in build/hex/<same path>, where the simulator
# runs. With COVERAGE=<dir> set, each run also writes <dir>/<name>.dat, and
# with TRACE=<dir> the co-simulator writes <dir>/<name>.log

sim="$1"; shift
[[ $sim = /* ]] || sim="$PWD/$sim"

args=()
while [[ $1 = +* ]]; do args+=("$1"); shift; done

# The simulator runs from another folder, so output folders need absolute paths
absdir() { mkdir -p "$1" && (cd "$1" && pwd); }
[ -n "$COVERAGE" ] && COVERAGE="$(absdir "$COVERAGE")"
[ -n "$TRACE" ] && TRACE="$(absdir "$TRACE")"

pass=0; fail=0
for elf in "$@"; do
    rel="${elf#build/}"; rel="${rel%.elf}"         # core/riscv-tests/rv32ui/add
    config="${rel%%/*}"
    name="$(basename "$(dirname "$rel")")-$config-$(basename "$rel")"   # rv32ui-core-add
    hex="build/hex/$rel"

    if ! tools/elftohex-$config.sh "$elf" "$hex" >/dev/null 2>&1; then
        fail=$((fail+1)); echo "FAIL $name  (hex conversion)"; continue
    fi

    extra=()
    [ -n "$COVERAGE" ] && extra+=("+coverage=$COVERAGE/$name.dat")
    [ -n "$TRACE" ] && extra+=("+trace=$TRACE/$name.log")
    abs="$PWD/$elf"
    out="$(cd "$hex" && "$sim" "$abs" "${args[@]}" "${extra[@]}" 2>/dev/null)"

    tohost="$(sed -n 's/^TOHOST=\([0-9]*\).*/\1/p' <<< "$out" | head -1)"
    finish="$(sed -n 's/.*finish called at \([0-9]*\).*/\1/p' <<< "$out" | head -1)"
    insns="$(sed -n 's/^\([0-9]*\) instructions match/\1/p' <<< "$out")"
    if [ "$tohost" = 1 ]; then
        pass=$((pass+1)); echo "PASS $name${finish:+  finish=$finish}${insns:+  $insns instructions}"
        continue
    fi
    fail=$((fail+1))
    if [ -n "$tohost" ]; then
        echo "FAIL $name  (test $((tohost >> 1)))"
    else
        echo "FAIL $name  (no tohost write)"
        grep "^  " <<< "$out"
        grep -E "^(MISMATCH|TIMEOUT)" <<< "$out" | head -1
    fi
    [ -n "$TRACE" ] && echo "full trace: ${TRACE#$PWD/}/$name.log"
done

echo ""
echo "$pass passed, $fail failed, $((pass + fail)) total"
[ $fail -eq 0 ]
