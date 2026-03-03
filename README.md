# RV32I Pipelined Processor

A 32-bit RISC-V (RV32I) pipelined processor in SystemVerilog, with separate instruction and data memories and a test framework using Icarus Verilog or Verilator.

## Architecture

- **Top** (`top.sv`): Instantiates the **core**, instruction memory (code), and data memory. Reset PC is `0x0001_0000`. MMIO: write to `0x0002_FFF8` for putchar, write to `0x0002_FFFC` for halt.
- **Core** (`cpu.sv`): Five-stage pipeline — **fetch** → **decode** (and writeback) → **execute** → **memory** → **writeback**, plus **control** for hazards and redirects.
- **Support**: `base.sv` (macros), `system.sv` (word/address sizes), `memory_io.sv` (req/rsp structs), `memory.sv` (byte-initialized RAM), `riscv.sv` / `riscv32_common.sv` (ISA types and decode).

Memory map (from `ld.script`): `.text` at `0x00010000`, `.rodata`/`.data`/`.bss` at `0x00020000`.

## Supported instructions

The core implements **RV32I** only (no M, A, F, or other extensions). Supported instructions:

| Instruction Type | Instructions |
|-------------------|--------------|
| **OP** | `add`, `sub`, `sll`, `slt`, `sltu`, `xor`, `srl`, `sra`, `or`, `and` |
| **OP-IMM** | `addi`, `slti`, `sltiu`, `xori`, `ori`, `andi`, `slli`, `srli`, `srai` |
| **Store** | `sb`, `sh`, `sw` |
| **Load** | `lb`, `lh`, `lw`, `lbu`, `lhu` |
| **Branch** | `beq`, `bne`, `blt`, `bge`, `bltu`, `bgeu` |
| **AUIPC** | `auipc` |
| **JAL** | `jal` |
| **JALR** | `jalr` |
| **LUI** | `lui` |

## Build System

- **Config**: `site-config.sh` sets `RISCV_PREFIX`, `RISCV_LIB`, `IVERILOG`, `VERILATOR`. Edit for your toolchain and simulators.
- **Tools**: RISC-V toolchain (gcc/as/ld), `dumphex` (built from `dumphex.c`), and either Icarus Verilog or Verilator.
- **Libraries**: `libmc/` provides a small C runtime (`libmc.a`); build with `make -C libmc`.

## Toolchain and build order

**Toolchain**: (1) **RISC-V** — `$(RISCV_PREFIX)-gcc`, `-as`, `-ld`, `-objcopy` (RV32I, no multiply); (2) **Host** — plain `gcc` to build `dumphex`; (3) **Sim** — Icarus Verilog (`iverilog`) or Verilator. Paths come from `site-config.sh`.

**What happens when you run `make`** (default target is `result-iverilog`):

1. **Build `dumphex`** — host `gcc` compiles `dumphex.c`; used later to turn binary into byte-wide `.hex` files for the memories.
2. **Build `libmc/libmc.a`** — RISC-V C runtime (e.g. `printf`, `putc`); `make -C libmc` (after a clean).
3. **Build the program** — RISC-V `as` assembles `start.s`, `gcc` compiles `test.c`; `ld` links them with `ld.script` and `libmc.a` into the `test` ELF.
4. **ELF → hex** — `elftohex.sh test .` runs:
   - `objcopy -j .text` → binary; `dumphex` writes `code0.hex`–`code3.hex` (instruction memory, 64 KiB).
   - `objcopy -R .text` → binary; `dumphex` writes `data0.hex`–`data3.hex` (data memory, 64 KiB).
5. **Build simulator** — `iverilog` compiles `itop.sv` (and included RTL) into the `result-iverilog` executable.
6. **Run** — `./result-iverilog` runs until the program writes to the halt address; then the Makefile removes the binary.

For **`make run-test-<name>-iverilog`**: build the test ELF from `tests/<name>.s` (with `test_macros.s` / `test_runtime.s`), run `elftohex.sh` on that ELF to refresh the root `*.hex`, then run `build/sim/result-iverilog` (which reads those hex files).

## Tests

Tests are RV32I assembly programs under `tests/isa/` (ISA correctness) and `tests/hazards/` (pipeline hazards and bypass). Each test includes `tests/common/test_macros.s` for `TEST_BEGIN`, `TEST_PASS`, `TEST_FAIL`, and `ASSERT_*` macros, and links with `tests/common/test_runtime.s` for stack init and print. Output goes to UART at `0x0002FFF8`; writing to `0x0002FFFC` halts the simulator.

- **`tests/isa/`** — add/sub, shifts, logic, compare, loads/stores (basic and sign-ext), LUI/AUIPC, branches (basic/signed/unsigned), jumps (JAL/JALR).
- **`tests/hazards/`** — load-use stalls, load chains, branch-after-load/ALU, EX–EX and MEM–EX data hazards, bypass stress.

Run one test: `make run-test-<name>-iverilog` (e.g. `run-test-isa-add_sub-iverilog`). Run all: `make run-tests-iverilog`.

## Make Targets

| Command | Description |
|--------|-------------|
| `make` or `make result-iverilog` | Build test program, build Icarus Verilog sim, run it (binary removed after run). |
| `make build/sim/result-iverilog` | Build Icarus Verilog simulator only → `build/sim/result-iverilog`. |
| `make result-verilator` | Build and run Verilator simulator (produces `result-verilator`). |
| `make test` | Build `test` ELF and generate `*.hex` (code/data) in project root. |
| `make run-test-<name>-iverilog` | Build ELF for `tests/<name>.s` (e.g. `isa/add_sub` → `run-test-isa-add_sub-iverilog`), run that test under Icarus. |
| `make run-tests-iverilog` | Run all tests under `tests/isa/` and `tests/hazards/`. |
| `make clean` | Remove build artifacts, `*.hex`, `test`, sim binaries, `test.vcd`, `obj_dir/`. |

**Note**: `result-iverilog` and `result-verilator` depend on `test`; ensure `test.c` and `start.s` are built and `elftohex.sh` has been run so `code*.hex` and `data*.hex` exist before simulating.

## File reference

| File | Description |
|------|-------------|
| **RTL (SystemVerilog)** | |
| `itop.sv` | Icarus Verilog testbench: clk/reset/halt, `$dumpvars`, includes `top.sv`. |
| `top.sv` | Top-level: instantiates core + code memory + data memory; MMIO putchar/halt. |
| `cpu.sv` | Pipeline core: modules `fetch`, `decode_and_writeback`, `execute`, `memory`, `writeback`, `control`. |
| `riscv.sv` | Package wrapper; includes `riscv32_common.sv` (or 64-bit). |
| `riscv32_common.sv` | RV32 types (tag, instr32, funct3/7, opcode), decode helpers, format enums. |
| `base.sv` | Macros: `true`/`false`, `one`/`zero`; `bool` for Verilator. |
| `system.sv` | Word/address sizes (`word_size`, `word_address_size`), `word` type. |
| `memory_io.sv` | Structs `memory_io_req` / `memory_io_rsp` and byte-enable helpers. |
| `memory.sv` | Parametric RAM: byte arrays, `$readmemh` from `code*.hex` / `data*.hex`. |
| **Build & config** | |
| `Makefile` | Builds dumphex, libmc, test ELF, hex files, iverilog/verilator sim; test targets. |
| `site-config.sh` | Paths: `RISCV_PREFIX`, `RISCV_LIB`, `IVERILOG`, `VERILATOR`. |
| `ld.script` | Linker script: `.text` at 0x10000, `.rodata`/`.data`/`.bss` at 0x20000. |
| `elftohex.sh` | Converts ELF to `code*.hex` (text) and `data*.hex` (data) via objcopy + dumphex. |
| `dumphex.c` | Host utility: reads binary, writes byte-wide hex files for memory init. |
| **Test program (default)** | |
| `start.s` | Assembly entry `_start`: sets stack, runs inline pipeline tests, then calls `main` and `halt`. |
| `test.c` | C entry used by default `make`; linked with `start.s` and libmc. |
| **Verilator** | |
| `verilator_top.cpp` | Verilator testbench: drives clk/reset, runs until `halt`. |
| **Tests (assembly)** | |
| `tests/common/test_macros.s` | Macros: `TEST_BEGIN`, `TEST_PASS`, `TEST_FAIL`, `ASSERT_*`; UART/HALT/stack constants. |
| `tests/common/test_runtime.s` | `init_stack`, `print_str`; linked into per-test ELFs. |
| `tests/isa/*.s` | ISA tests: add_sub, shift, logic, compare, load/store, lui_auipc, branch_*, jump_jal_jalr. |
| `tests/hazards/*.s` | Hazard tests: load_use, load_chain, branch_after_*, data_*_ex, bypass_stress. |
| **libmc (C runtime)** | |
| `libmc/Makefile` | Builds `libmc.a` from C sources and `mmio.s`. |
| `libmc/libmc.h` | Declarations: printf, putc, puts, mmio_*, string/atoi helpers, halt. |
| `libmc/base.h` | Types (e.g. `native_t`) and base defines. |
| `libmc/mmio.s` | RV32I assembly: `mmio_read32`/`mmio_write32`, `mmio_read8`/`mmio_write8`. |
| `libmc/*.c` | printf, putc, puts, halt, atoi, strlen, strcmp, strchr, strtok, memset, itoa/htoa/btoa, etc. |
