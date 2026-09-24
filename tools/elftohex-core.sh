#!/bin/bash
#
# Core configuration: split an ELF into the IMEM and DMEM hex images memory.sv reads
#
#   elftohex-core.sh <elf> <out-dir>

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/site-config.sh"
dumphex="$root/build/tools/dumphex"     # `make build/tools/dumphex`

elf="$1"
out="${2:?usage: elftohex-core.sh <elf> <out-dir>}"
mkdir -p "$out"

$RISCV_PREFIX-objcopy -O binary -j .text -g "$elf" "$elf.bin"
"$dumphex" -i "$elf.bin" -o "$out/code" -base 0 -size 0x10000 -strip -byte
rm "$elf.bin"

$RISCV_PREFIX-objcopy -O binary -R .text -R .bss -g "$elf" "$elf.bin"
"$dumphex" -i "$elf.bin" -o "$out/data" -base 0 -size 0x10000 -strip -byte
rm "$elf.bin"
