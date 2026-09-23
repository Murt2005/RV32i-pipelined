# Formal verification

[riscv-formal](https://github.com/YosysHQ/riscv-formal) checks the core through
an RVFI commit port. Unlike the test suites, the solver reasons about *every*
operand value and every reachable pipeline state, not the ones a test happened
to pick.

## Toolchain

```bash
brew install yices2 z3            # SMT solvers; yosys already provides yosys-smtbmc
git clone https://github.com/YosysHQ/sby /tmp/sby
cd /tmp/sby && make install PREFIX=$HOME/.local
export PATH=$HOME/.local/bin:$PATH
```

`formal/smoke.sby` is a two-minute check that the chain works. It is *expected*
to report FAIL: the counter is unconstrained at step 0, so the property really
is violable, and seeing the counterexample confirms yosys → smtbmc → yices are
all wired up.

```bash
cd formal && sby -f smoke.sby      # expect FAIL with a counterexample trace
```

## Checks

`checks.cfg` targets RV32IM, which generates 51 checks:

| Check | What it proves |
|---|---|
| `insn_*` (45) | each instruction matches the ISA model for every operand value and reachable pipeline state |
| `reg` | a register read returns what was last written to it, so the bypass network never lies |
| `pc_fwd` / `pc_bwd` | consecutive instructions' PCs chain correctly: none skipped, none run twice |
| `causal` | an instruction never depends on a value produced after it |
| `unique` | `rvfi_order` is strictly increasing, so nothing retires twice |
| `liveness` | the core always eventually retires an instruction |

```bash
cd formal
make checks                        # generate the .sby files
make list                          # what was generated
make one CHECK=insn_addi_ch0       # a single check
make run-insn                      # the RV32I instruction checks
make run-consistency               # reg, pc_fwd, pc_bwd, causal, unique, liveness
make run-m                         # the eight M checks, which take hours
```

The M checks are kept out of `run-insn`. Multiply is an equivalence check
between two multiplier structures, which SMT solvers handle badly, and divide
needs depth 56 before an iterative divide can retire.

**Status.** The checks haven't been rerun since the machine-mode CSR and trap
changes. `liveness` has an open counterexample: with the external `stall`
input asserted for one cycle while a `jal` is in fetch, the instruction stays
latched and never retires. The pico2-ice drives `stall` for UART backpressure,
so this matters on hardware.

## How it is wired

`yosys` cannot read this project's SystemVerilog, so `formal/Makefile` runs
`sv2v` over `wrapper.sv` + `cpu.sv` first and points riscv-formal at the
flattened result. `genchecks.py` expects a `<basedir>/cores/<core>/` layout, so
the Makefile builds one in `formal/rf/` out of symlinks into the riscv-formal
submodule.

The RVFI port lives in `cpu.sv` behind `` `ifdef RVFI ``, so the synthesised
build carries none of it. `make rvfi-check` validates it independently by
replaying every retired instruction through `tools/rv32_model.py`. That's worth
running first: riscv-formal reasons entirely about what RVFI reports, so a
wrong record gives wrong answers in both directions.

## The environment

`wrapper.sv` leaves memory *data* free, so the solver picks whatever
instruction stream exposes a violation. Memory *timing* is also up to the
solver: a request can be refused, and a response can arrive one or two cycles
later, so the core's stall paths are checked too. The external `stall` input is
driven by the solver as well.

All of this is bounded: at most two refusals or stalled cycles in a row. A
memory that never answers really would deadlock the core, and `liveness` would
then fail on the environment rather than the design.
