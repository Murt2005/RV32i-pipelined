# Backlog

## Liveness counterexample with the external stall

riscv-formal's `liveness_ch0` found that one stalled cycle with a `jal` in fetch leaves the instruction latched and never retiring: the core is busy rather than hung, so no watchdog catches it. The simulation's random stall injection and the formal wrapper both drive `stall`. Not fixed yet. The original note is in `cf35b72:fpga/de1soc/rv32_de1soc.sv`.

The 2026-09-27 rerun points at the fetch stage: a response arriving two cycles after its request lands in the cycle `instruction_miss_q` freezes the front end, so it's dropped and refetched, even with no stall. Check it in simulation with an instruction memory that always takes two cycles. The formal wrapper also needs one bound on blocked cycles covering both `stall` and memory refusals, since the solver currently lines them up to block fetch indefinitely.

## fence.i doesn't invalidate the instruction cache

`fence.i` decodes as a no-op, so code written through the data port and then run from SDRAM needs the MMIO invalidate register at `0x0002FFD0`. Making `fence.i` invalidate the I-cache and refetch would let riscv-tests' `fence_i` run from SDRAM, and cover the invalidate path, which nothing tests today.

## Rerun riscv-formal

Rerun on 2026-09-26 and 27: the 37 RV32I instruction checks, `causal`, `cover`, `ill`, `pc_bwd` and `unique` pass, and `hang` and `liveness` fail. `pc_fwd` and `reg` were stopped after an hour with no result and still need a longer run. The M checks are left out on purpose. `formal/README.md` has the details.

## A C runtime for programs in SDRAM

`sw/runtime` and `sw/examples/hello.c` were removed; they're in git history before this change. They linked newlib programs into SDRAM: a reset stub in IMEM that set the stack, cleared `.bss` and jumped to `main`, a linker script, and the syscalls newlib needs (`_write` to the putchar register, `_exit` to halt, `_sbrk` for a heap from `_end`). `hello.c` checked printf, malloc, string.h, M-extension C code and `mcycle`. Something like it is the only test of the cache/SDRAM path with compiler-generated code. If it comes back, drop the in-memory file layer (`_open`/`_read`/`_lseek`), which was only there for Doom's WAD. Remember `-mstrict-align` too: misaligned accesses trap, and `mtvec` is 0.
