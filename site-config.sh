#!/bin/bash
#
# This file is both a bash file and a Makefile include, so every line has to be
# a plain VAR=value assignment -- no $(...) , which means one thing to make and
# another to sh.
#
#
# riscv-gnu-toolchain from Homebrew (GCC 15.1). Replaced the xPack
# riscv-none-embed-gcc 8.2.0 build, which had only an rv32i/ilp32 multilib and
# no usable newlib for it. This one ships rv32i/ilp32 *and* rv32im/ilp32 for
# both libgcc and newlib, which is what the M extension and a real malloc/printf
# need.
#
# Two things to know about the newer compiler:
#   * CSR instructions now need the extension named explicitly, so the march
#     strings are rv32im_zicsr rather than rv32im. Older GCC accepted csrr under
#     plain rv32i.
#   * RISCV_LIB has the compiler version in its path. Regenerate it with
#       riscv64-unknown-elf-gcc -march=rv32im_zicsr -mabi=ilp32 \
#           -print-libgcc-file-name
#     and drop the trailing /libgcc.a.
RISCV_PREFIX=/opt/homebrew/bin/riscv64-unknown-elf
RISCV_LIB=/opt/homebrew/Cellar/riscv-gnu-toolchain/main/lib/gcc/riscv64-unknown-elf/15.1.0/rv32im/ilp32
VERILATOR=/usr/local/bin/verilator
IVERILOG=/opt/homebrew/bin/iverilog

# The target ISA, in one place because both Makefile and libmc/Makefile build
# objects that get linked together -- they have to agree, and RISCV_LIB above
# has to point at the matching multilib.
#
# The core implements M, so C code multiplies and divides natively instead of
# calling libgcc's __mulsi3/__divsi3 -- which is most of what the Dhrystone
# number used to be paying for. RISCV_LIB must point at the matching multilib or
# the link fails on mismatched ISA attributes.
MARCH=rv32im_zicsr
MABI=ilp32

# ld's default emulation follows the toolchain's target, and this one is
# riscv64-*, so without this every link fails with "target emulation
# elf32-littleriscv does not match elf64-littleriscv". The old riscv-none-embed
# toolchain was 32-bit only and needed no such flag.
LDEMUL=elf32lriscv
