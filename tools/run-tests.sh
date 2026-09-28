#!/bin/bash
#
# Run test ELFs on a simulator and report each one's tohost result
#
#   run-tests.sh <simulator> [+plusarg...] <elf>...
#
# Run from the repo root, with JOBS=<n> tests at a time. ELFs live under
# build/<config>/, which picks the hex converter (tools/elftohex-<config>.sh);
# each one's images go in build/hex/<same path>, where the simulator runs.
# With TRACE=<dir> the co-simulator writes <dir>/<name>.log

sim="$1"; shift
[[ $sim = /* ]] || sim="$PWD/$sim"

args=()
while [[ $1 = +* ]]; do args+=("$1"); shift; done

# The simulator runs from another folder, so output folders need absolute paths
absdir() { mkdir -p "$1" && (cd "$1" && pwd); }
[ -n "$TRACE" ] && TRACE="$(absdir "$TRACE")"

# Runs one ELF and writes its report to <hex>/result, so parallel runs don't interleave
run_one() {
    elf="$1"
    rel="${elf#build/}"; rel="${rel%.elf}"         # core/riscv-tests/rv32ui/add
    config="${rel%%/*}"
    if [ "$config" = riscv-arch-test ]; then
        name="$config-$(basename "$rel")"          # riscv-arch-test-I-add-00
    else
        name="$(basename "$(dirname "$rel")")-$config-$(basename "$rel")"   # rv32ui-core-add
    fi
    hex="build/hex/$rel"
    mkdir -p "$hex"
    exec > "$hex/result"

    if ! tools/elftohex-$config.sh "$elf" "$hex" >/dev/null 2>&1; then
        echo "FAIL $name  (hex conversion)"; return
    fi

    extra=()
    [ -n "$TRACE" ] && extra+=("+trace=$TRACE/$name.log")
    abs="$PWD/$elf"
    out="$(cd "$hex" && "$sim" "$abs" "${args[@]}" "${extra[@]}" 2>/dev/null)"

    tohost="$(sed -n 's/^TOHOST=\([0-9]*\).*/\1/p' <<< "$out" | head -1)"
    finish="$(sed -n 's/.*finish called at \([0-9]*\).*/\1/p' <<< "$out" | head -1)"
    insns="$(sed -n 's/^\([0-9]*\) instructions match/\1/p' <<< "$out")"
    if [ "$tohost" = 1 ]; then
        echo "PASS $name${finish:+  finish=$finish}${insns:+  $insns instructions}"
        return
    fi
    if grep -q "^RVCP: " <<< "$out"; then
        echo "FAIL $name"                           # riscv-arch-test prints what went wrong
        grep "^RVCP: " <<< "$out" | grep -v "DEBUG INFORMATION"
    elif [ -n "$tohost" ]; then
        echo "FAIL $name  (test $((tohost >> 1)))"
    else
        echo "FAIL $name  (no tohost write)"
        grep "^  " <<< "$out"
        grep -E "^(MISMATCH|TIMEOUT)" <<< "$out" | head -1
    fi
    [ -n "$TRACE" ] && echo "full trace: ${TRACE#$PWD/}/$name.log"
}
export -f run_one
export sim TRACE ARGS="${args[*]}"

printf '%s\n' "$@" | xargs -P "${JOBS:-1}" -I{} bash -c 'args=($ARGS); run_one "$1"' _ {}

results="$(for elf in "$@"; do rel="${elf#build/}"; cat "build/hex/${rel%.elf}/result"; done)"
echo "$results"

pass=$(grep -c '^PASS ' <<< "$results")
fail=$(grep -c '^FAIL ' <<< "$results")
echo ""
echo "$pass passed, $fail failed, $((pass + fail)) total"
[ $fail -eq 0 ]
