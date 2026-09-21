#!/bin/bash
#
# Split an ELF into the byte-lane hex images memory.sv reads.
#
#   elftohex.sh <elf> <out-dir>
#
# memory.sv opens code0.hex..data3.hex from the simulator's working directory,
# so the simulator has to be run from <out-dir>. Every run gets its own
# directory under build/: sharing one means two runs in parallel silently read
# each other's program.

here="$(cd "$(dirname "$0")" && pwd)"
source "$here/site-config.sh"

elf="$1"
out="${2:?usage: elftohex.sh <elf> <out-dir>}"
mkdir -p "$out"

$RISCV_PREFIX-objcopy -O binary -j .text -g "$elf" "$elf.bin"
"$here/dumphex" -i "$elf.bin" -o "$out/code" -base 0 -size 0x10000 -strip -byte
rm "$elf.bin"

$RISCV_PREFIX-objcopy -O binary -R .text -g "$elf" "$elf.bin"
"$here/dumphex" -i "$elf.bin" -o "$out/data" -base 0 -size 0x10000 -strip -byte
rm "$elf.bin"
