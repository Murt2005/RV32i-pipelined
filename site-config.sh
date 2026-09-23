#!/bin/bash
#
RISCV_PREFIX=/opt/homebrew/bin/riscv64-unknown-elf
RISCV_LIB=/opt/homebrew/Cellar/riscv-gnu-toolchain/main/lib/gcc/riscv64-unknown-elf/15.1.0/rv32im/ilp32
VERILATOR=/usr/local/bin/verilator
IVERILOG=/opt/homebrew/bin/iverilog

MARCH=rv32im_zicsr
MABI=ilp32

LDEMUL=elf32lriscv
