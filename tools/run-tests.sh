#!/bin/bash
#
# Run test ELFs on a simulator and report each one's tohost result
#
#   run-tests.sh <simulator> [+plusarg...] <elf>...
#
# Run from the repo root. ELFs live under build/<config>/, which picks the hex
# converter; each one's images go in build/hex/<same path>, where the simulator
# runs. With COVERAGE=<dir> set, each run also writes <dir>/<name>.dat

sim="$1"; shift
[[ $sim = /* ]] || sim="$PWD/$sim"

args=()
while [[ $1 = +* ]]; do args+=("$1"); shift; done

if [ -n "$COVERAGE" ]; then
    [[ $COVERAGE = /* ]] || COVERAGE="$PWD/$COVERAGE"
    mkdir -p "$COVERAGE"
fi

pass=0; fail=0
for elf in "$@"; do
    rel="${elf#build/}"; rel="${rel%.elf}"         # core/riscv-tests/rv32ui/add
    config="${rel%%/*}"
    name="$(basename "$(dirname "$rel")")-$(basename "$rel")"
    [ "$config" = system ] && name="${name/-/-sdram-}"  # the key tests/cycles/system.json uses
    hex="build/hex/$rel"

    if ! tools/elftohex-$config.sh "$elf" "$hex" >/dev/null 2>&1; then
        fail=$((fail+1)); echo "FAIL $name  (hex conversion)"; continue
    fi

    cov=()
    [ -n "$COVERAGE" ] && cov=("+coverage=$COVERAGE/$name.dat")
    abs="$PWD/$elf"
    out="$(cd "$hex" && "$sim" "$abs" "${args[@]}" "${cov[@]}" 2>/dev/null)"

    tohost="$(sed -n 's/^TOHOST=\([0-9]*\).*/\1/p' <<< "$out" | head -1)"
    finish="$(sed -n 's/.*finish called at \([0-9]*\).*/\1/p' <<< "$out" | head -1)"
    if [ "$tohost" = 1 ]; then
        pass=$((pass+1)); echo "PASS $name${finish:+  finish=$finish}"
    elif [ -n "$tohost" ]; then
        fail=$((fail+1)); echo "FAIL $name  (test $((tohost >> 1)))"
    else
        fail=$((fail+1)); echo "FAIL $name  (no tohost write)"
        grep -E "^(MISMATCH|TIMEOUT)" <<< "$out" | head -1
    fi
done

echo ""
echo "$pass passed, $fail failed, $((pass + fail)) total"
[ $fail -eq 0 ]
