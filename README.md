# RV32IM Pipelined Processor

A five-stage pipelined RISC-V core in SystemVerilog, tested in simulation with
the official riscv-tests suites and checked with riscv-formal.

- **ISA:** RV32IM with Zicsr, machine mode only, precise traps
- **Pipeline:** fetch, decode, execute, memory, writeback, with full bypassing,
  a load-use stall and an 8-entry branch target buffer
- **Memory:** a ready/valid request/response interface, so the core runs
  against memories that answer late or refuse requests
- **Bus:** instruction and data memories (IMEM, DMEM), MMIO, and an SDRAM region
  behind 16 KiB instruction and data caches

## Quick start

```bash
git submodule update --init --recursive
# edit site-config.sh to point at your RISC-V toolchain and simulators
make            # build and run every riscv-tests suite under Icarus Verilog
```

You need a RISC-V GCC toolchain (`riscv64-unknown-elf-*`), Icarus Verilog,
Verilator and Python 3. Co-simulation also needs Spike, which `make spike` builds
from the `cosim/riscv-isa-sim` submodule (it needs `dtc`). The formal flow has its
own requirements, listed in [`formal/README.md`](formal/README.md).

## Configurations

Programs are built and run in one of two configurations, chosen with `CONFIG`:

| `CONFIG` | Program lives in | For |
|---|---|---|
| `core` (default) | IMEM and DMEM | Developing and benchmarking the core |
| `system` | A boot stub in IMEM, the program in SDRAM | Testing the bus and caches |

```bash
make rv32ui CONFIG=system      # rv32ui from SDRAM
make dhrystone CONFIG=core     # Dhrystone from IMEM/DMEM
make help                      # every target and option
```

Each configuration builds into its own folder, `build/core/` or `build/system/`.
`tools/elftohex-core.sh` and `tools/elftohex-system.sh` turn a program into the
memory images for each.

## Architecture

| Stage | Does |
|---|---|
| Fetch | Issues instruction fetches, predicts taken branches with the BTB, drops responses for redirected fetches |
| Decode | Decodes, reads the register file, and writes back the instruction retiring that cycle |
| Execute | Bypasses operands, runs the ALU, resolves branches, accesses CSRs, and takes traps |
| Memory | Issues loads and stores |
| Writeback | Formats load data and writes the register file |

Multiply is single-cycle. Divide and remainder use an iterative divider
(`rtl/core/divider.sv`) that takes about 35 cycles and stalls the pipeline
while it runs. Traps are taken in execute, which is the commit point, so a
faulting instruction never reaches writeback.

### CSRs and exceptions

| CSRs | |
|---|---|
| Read/write | `mstatus` (MIE, MPIE), `mtvec` (direct mode), `mscratch`, `mepc`, `mcause`, `mtval`, `mcycle[h]`, `minstret[h]` |
| Read-only | `misa`, `cycle[h]`, `instret[h]`, and the ID registers, which read zero |
| Always zero | `mie`, `mip`, `mstatush`, `tselect`, `tdata1`, `tdata2` (no interrupts, no debug triggers) |

Accessing any other CSR, or writing a read-only one, is an illegal instruction.

| Cause | Raised by |
|---|---|
| 0 | jump or taken branch to an address that isn't 4-byte aligned |
| 2 | illegal instruction |
| 3 | `ebreak` |
| 4 / 6 | misaligned load / store |
| 11 | `ecall` |

### Memory map

This is the simulation top, `sim/top.sv`.

| Address | What |
|---|---|
| `0x0001_0000` | Instruction memory, 64 KiB; the reset PC |
| `0x0002_0000` | Data memory, 64 KiB, minus the MMIO block |
| `0x0002_FFC0` | MMIO: `tohost` (`FFC0`), I-cache invalidate (`FFD0`), cycles (`FFF0`), instructions retired (`FFF4`), putchar (`FFF8`), halt (`FFFC`) |
| `0x8000_0000` | SDRAM model, behind 16 KiB instruction and data caches |

## Verification

| Command | What it checks |
|---|---|
| `make` / `make test` | rv32ui (40), rv32um (8) and rv32mi (15) from [riscv-tests](https://github.com/riscv-software-src/riscv-tests), in the suite's stock `p` environment, in the core configuration and then the system configuration |
| `make rv32ui`, `rv32um`, `rv32mi` | One suite, in `CONFIG` |
| `make cosim-test` | Every riscv-test in both configurations in lockstep with [Spike](https://github.com/riscv-software-src/riscv-isa-sim), comparing every retired instruction |
| `make cosim-test-rv32ui`, `-rv32um`, `-rv32mi` | One suite in lockstep with Spike, in `CONFIG` |
| `make cosim-random ITERS=100 SEED=1` | Random RV32IM programs from `tools/rvgen.py`, in lockstep with Spike, in `CONFIG` |
| `make latency-sweep` | Every suite again against memories that answer up to 16 cycles late, and with random stalls |
| `make cycle-check` | Cycle counts against the checked-in baselines for both configurations, to catch timing changes |
| `make divider` | The divider on its own: every spec corner case plus random operands |
| `make coverage` | Verilator coverage over every suite in both configurations, per file, with every line and branch never reached. Over `rtl/`: 91% of lines, 97% of branches, 60% of toggles |
| `make -C formal run-insn` | riscv-formal instruction checks (see [`formal/README.md`](formal/README.md)) |

`make test` and the single suites run on Icarus; the `cosim-*` targets run the
co-simulator (`cosim/cosim.cpp`), which steps Spike once for every instruction
the core retires and stops at the first difference, printing both sides and the
ten instructions before it. Every instruction it checks, with Spike's
disassembly and the RVFI fields, goes to `build/trace/<test>.log`, e.g.
`build/trace/rv32ui-system-lw.log`. Build output from Spike and the simulators
goes to `build/logs/`, and `make help` lists every target with its options.

Excluded riscv-tests: `fence_i` (instruction and data memories are separate, so
code can't be modified in place), `ma_data` (it expects misaligned accesses to
be emulated; this core traps instead, which the spec also allows) and
`pmpaddr` (no physical memory protection).

riscv-tests only need linker scripts from this repo: `tests/riscv-tests-env/link.ld`
maps them onto IMEM/DMEM, and `link-system.ld` with the `boot.S` stub runs
them from SDRAM.

## Known issues

- **The divider can start with a stale operand behind a slow load.** Random
  co-simulation in the system configuration found a `remu` whose divisor was
  loaded two instructions earlier through the data cache, and which computed as
  if dividing by 0. Reproduce with `make cosim-random CONFIG=system SEED=1039 ITERS=1`.

- **Liveness under external stall.** riscv-formal found a case where a
  one-cycle `stall` with a `jal` in fetch leaves the instruction latched and
  never retiring. The simulation's random stall injection drives the same input.
- **`fence.i` doesn't invalidate the instruction cache**, so self-modifying code
  needs the MMIO invalidate register, and the riscv-tests `fence_i` test is
  excluded.

## Software

| Command | What |
|---|---|
| `make dhrystone` | Dhrystone in `CONFIG`: 0.842 DMIPS/MHz in core, 0.768 in system |

## Layout

| Path | What |
|---|---|
| `rtl/core/` | The core: pipeline (`cpu.sv`), divider, ISA decode |
| `rtl/bus/` | Address decoder, MMIO, instruction and data caches, SDRAM arbiter |
| `rtl/mem/` | Memory interface |
| `sim/` | Simulation top, memory model with optional random latency, Icarus and Verilator harnesses |
| `cosim/` | Lockstep co-simulator against Spike, and Spike (submodule) |
| `tests/` | riscv-tests (submodule), its linker script, cycle baseline, divider testbench |
| `formal/` | riscv-formal harness |
| `bench/` | Dhrystone and the small C library it links against |
| `tools/` | Random program generator, ELF-to-hex scripts, cycle-count reporter |
