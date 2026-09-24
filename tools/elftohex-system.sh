#!/bin/bash
#
# System configuration: split an ELF linked to run from SDRAM into the IMEM boot
# stub and the SDRAM hex images memory.sv reads
#
#   elftohex-system.sh <elf> <out-dir>

root="$(cd "$(dirname "$0")/.." && pwd)"
source "$root/site-config.sh"
dumphex="$root/build/tools/dumphex"     # `make build/tools/dumphex`

elf="$1"
out="${2:?usage: elftohex-system.sh <elf> <out-dir>}"
mkdir -p "$out"

$RISCV_PREFIX-objcopy -O binary -j .boot -g "$elf" "$elf.bin"
"$dumphex" -i "$elf.bin" -o "$out/code" -base 0 -size 0x10000 -strip -byte
rm "$elf.bin"

# -size must match the sdram_bytes parameter in rtl/top.sv
$RISCV_PREFIX-objcopy -O binary -j .text -j .rodata -j .data -g "$elf" "$elf.bin"
"$dumphex" -i "$elf.bin" -o "$out/sdram" -base 0 -size 0x100000 -strip -byte
rm "$elf.bin"
