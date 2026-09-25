# Backlog

## Divider starts with a stale operand behind a slow load

Found by the random co-simulation: `make cosim-random CONFIG=system SEED=1039 ITERS=1`.

```
80000308  lhu  s7, 184(t6)     # loads 0xd119 from SDRAM, through the D-cache
8000030c  sltiu t0, ra, 70
80000310  remu s5, t2, s7      # core writes 0x8000016c (= t2), Spike 0x1da6
```

RVFI shows the `remu` read the right divisor (0xd119), but the result is the dividend unchanged, which is what dividing by 0 gives. The divider seems to start before the load two instructions ahead has returned: its start condition only checks `is_load_use_hazard`, a load immediately before. It only shows up with a multi-cycle load, so the system configuration, and passes in the core configuration.

## Liveness counterexample with the external stall

riscv-formal's `liveness_ch0` found that one stalled cycle with a `jal` in fetch leaves the instruction latched and never retiring: the core is busy rather than hung, so no watchdog catches it. The simulation's random stall injection and the formal wrapper both drive `stall`. Not fixed yet. The original note is in `cf35b72:fpga/de1soc/rv32_de1soc.sv`.

## fence.i doesn't invalidate the instruction cache

`fence.i` decodes as a no-op, so code written through the data port and then run from SDRAM needs the MMIO invalidate register at `0x0002FFD0`. Making `fence.i` invalidate the I-cache and refetch would let riscv-tests' `fence_i` run from SDRAM, and cover the invalidate path, which nothing tests today.

## Rerun riscv-formal

The formal checks haven't been rerun since the machine-mode CSR and trap changes. `make -C formal run-insn` and `run-consistency` take hours.

## A C runtime for programs in SDRAM

`sw/runtime` and `sw/examples/hello.c` were removed; they're in git history before this change. They linked newlib programs into SDRAM: a reset stub in IMEM that set the stack, cleared `.bss` and jumped to `main`, a linker script, and the syscalls newlib needs (`_write` to the putchar register, `_exit` to halt, `_sbrk` for a heap from `_end`). `hello.c` checked printf, malloc, string.h, M-extension C code and `mcycle`. Something like it is the only test of the cache/SDRAM path with compiler-generated code. If it comes back, drop the in-memory file layer (`_open`/`_read`/`_lseek`), which was only there for Doom's WAD. Remember `-mstrict-align` too: misaligned accesses trap, and `mtvec` is 0.

## Verible lint findings

`make lint` reports 47 findings with the rules in `.rules.verible_lint`:

- 14 lines over 120 columns, mostly in `cpu.sv`
- tabs in `sim/top.sv` (12) and trailing spaces in `riscv32-common.sv` (4)
- `case` without a `default` at `riscv32-common.sv:497`, `512` and `533`
- `always @*` at `cpu.sv:181`, which should be `always_comb`
- `$random` in `tests/tb-divider.sv:137-138`, which Verible wants as `$urandom`
- `$test$plusargs` in `sim/itop.sv:28`
- 7 enums in `riscv32-common.sv` and 2 structs in `memory-io.sv` not ending in `_t`: rename them, or add `-enum-name-style` and `-struct-union-name-style` to the rules

The formatter isn't applied yet either: `make format` reindents nearly every file, since Verible always indents module bodies. Do it as its own commit and list that commit in `.git-blame-ignore-revs`.
