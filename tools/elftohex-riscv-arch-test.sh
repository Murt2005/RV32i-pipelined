#!/bin/bash
#
# riscv-arch-test: turn an ELF linked at the start of SDRAM into the SDRAM hex images
# memory.sv reads, plus an IMEM boot stub that jumps there
#
#   elftohex-riscv-arch-test.sh <elf> <out-dir>

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/site-config.sh"
dumphex="$root/build/tools/dumphex"     # `make build/tools/dumphex`

elf="$1"
out="${2:?usage: elftohex-riscv-arch-test.sh <elf> <out-dir>}"
mkdir -p "$out"

printf '\xb7\x02\x00\x80\x67\x80\x02\x00' > "$elf.bin"     # lui t0, 0x80000; jr t0
"$dumphex" -i "$elf.bin" -o "$out/code" -base 0 -size 0x10000 -strip -byte
: > "$elf.bin"
"$dumphex" -i "$elf.bin" -o "$out/data" -base 0 -size 0x10000 -strip -byte
rm "$elf.bin"

# -size must match the sdram_bytes parameter in sim/top.sv
$RISCV_PREFIX-objcopy -O binary "$elf" "$elf.bin"
"$dumphex" -i "$elf.bin" -o "$out/sdram" -base 0 -size 0x100000 -strip -byte
rm "$elf.bin"
