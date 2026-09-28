# Backlog

## fence.i doesn't invalidate the instruction cache

`fence.i` decodes as a no-op, so code written through the data port and then run from SDRAM needs the MMIO invalidate register at `0x0002FFD0`. Making `fence.i` invalidate the I-cache and refetch would let riscv-tests' `fence_i` run from SDRAM, and cover the invalidate path, which nothing tests today.

## Rerun riscv-formal

The fetch and decode changes of 2026-09-27 fixed the `hang` and `liveness` failures, and both now pass. Every other check last passed before those changes, so rerun `make -C formal run-insn` and the rest of `run-consistency`; `pc_fwd` and `reg` also still need a run longer than an hour. The M checks are left out on purpose. `formal/README.md` has the details.

## A C runtime for programs in SDRAM

`sw/runtime` and `sw/examples/hello.c` were removed; they're in git history before this change. They linked newlib programs into SDRAM: a reset stub in IMEM that set the stack, cleared `.bss` and jumped to `main`, a linker script, and the syscalls newlib needs (`_write` to the putchar register, `_exit` to halt, `_sbrk` for a heap from `_end`). `hello.c` checked printf, malloc, string.h, M-extension C code and `mcycle`. Something like it is the only test of the cache/SDRAM path with compiler-generated code. If it comes back, drop the in-memory file layer (`_open`/`_read`/`_lseek`), which was only there for Doom's WAD. Remember `-mstrict-align` too: misaligned accesses trap, and `mtvec` is 0.
