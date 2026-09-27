# Backlog

## Liveness counterexample with the external stall

riscv-formal's `liveness_ch0` found that one stalled cycle with a `jal` in fetch leaves the instruction latched and never retiring: the core is busy rather than hung, so no watchdog catches it. The simulation's random stall injection and the formal wrapper both drive `stall`. Not fixed yet. The original note is in `cf35b72:fpga/de1soc/rv32_de1soc.sv`.

## fence.i doesn't invalidate the instruction cache

`fence.i` decodes as a no-op, so code written through the data port and then run from SDRAM needs the MMIO invalidate register at `0x0002FFD0`. Making `fence.i` invalidate the I-cache and refetch would let riscv-tests' `fence_i` run from SDRAM, and cover the invalidate path, which nothing tests today.

## Rerun riscv-formal

The 37 RV32I instruction checks, `causal` and `cover` passed on 2026-09-26, after the machine-mode CSR and trap changes. Still to rerun: `hang`, `ill`, `liveness`, `pc_bwd`, `pc_fwd`, `reg` and `unique` (the rest of `make -C formal run-consistency`), and the eight M checks (`make -C formal run-m`, which takes hours). `formal/README.md` has the full status.

## A C runtime for programs in SDRAM

`sw/runtime` and `sw/examples/hello.c` were removed; they're in git history before this change. They linked newlib programs into SDRAM: a reset stub in IMEM that set the stack, cleared `.bss` and jumped to `main`, a linker script, and the syscalls newlib needs (`_write` to the putchar register, `_exit` to halt, `_sbrk` for a heap from `_end`). `hello.c` checked printf, malloc, string.h, M-extension C code and `mcycle`. Something like it is the only test of the cache/SDRAM path with compiler-generated code. If it comes back, drop the in-memory file layer (`_open`/`_read`/`_lseek`), which was only there for Doom's WAD. Remember `-mstrict-align` too: misaligned accesses trap, and `mtvec` is 0.
