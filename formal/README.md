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

`checks.cfg` targets RV32IM, which generates 54 checks:

| Check | What it proves |
|---|---|
| `insn_*` (45) | each instruction matches the ISA model for every operand value and reachable pipeline state |
| `reg` | a register read returns what was last written to it, so the bypass network never lies |
| `pc_fwd` / `pc_bwd` | consecutive instructions' PCs chain correctly: none skipped, none run twice |
| `causal` | an instruction never depends on a value produced after it |
| `unique` | `rvfi_order` is strictly increasing, so nothing retires twice |
| `liveness` | after a retirement, the next one comes within 22 cycles, with no divides |
| `ill` | an all-zero instruction traps and writes neither a register nor memory |
| `hang` | at least one instruction retires within 30 cycles of reset, with no divides |
| `cover` | two retirements and one trap are reachable, so the other checks aren't passing vacuously |

```bash
cd formal
make checks                        # generate the .sby files
make list                          # what was generated
make one CHECK=insn_addi_ch0       # a single check
make run-insn                      # the RV32I instruction checks
make run-consistency               # reg, pc_fwd, pc_bwd, causal, unique, liveness, ill, hang, cover
make run-m                         # the eight M checks, which take hours
```

The M checks are kept out of `run-insn`. Multiply is an equivalence check
between two multiplier structures, which SMT solvers handle badly, and divide
needs depth 56 before an iterative divide can retire.

## Status

`hang` and `liveness` were rerun on 2026-09-27 after the fetch and decode
changes below. Everything else was last run on 2026-09-26 and 27, before them,
and needs rerunning:

| Checks | Result |
|---|---|
| `hang` | PASS in 20 minutes |
| `liveness` | PASS in 17 minutes |
| `insn_*` for RV32I (37) | all PASS before the changes, about 5 minutes each |
| `causal`, `cover`, `ill`, `pc_bwd`, `unique` | PASS before the changes |
| `pc_fwd` | no result before the changes, stopped after 58 minutes |
| `reg` | no result before the changes, stopped after 60 minutes |
| `insn_*` for M (8) | not run on purpose |

The M checks are left out: SMT solvers can't finish them in reasonable time,
and multiply and divide results are already checked by `rv32um` and by random
programs in lockstep with Spike.

`hang` and `liveness` used to fail, and fixing them took three changes:

- The wrapper bounded memory refusals and the external `stall` separately, so
  the solver could line them up and keep every fetch out. They now share one
  budget.
- Fetch dropped a response that arrived while the front end was frozen and
  fetched it again, so an instruction memory that always takes two or more
  cycles livelocked the core. Such a response is now held until the freeze
  lifts.
- Decode turned its instruction into a bubble on every freeze and fetch
  re-presented it afterwards, so an instruction needed two unfrozen cycles in
  a row to reach execute, and stalls on alternate cycles starved the core.
  Decode now holds its instruction through a freeze, rereading its operands
  each cycle.

Both checks run on a build that never fetches DIV or REM, since an iterative
divide takes longer than their depth of 30 cycles. The divider always finishes
after 32 iterations, and `make divider` tests it on its own.

Every check here is bounded model checking, so a PASS covers what the core can
reach within the check's depth after reset (24 cycles for the RV32I
instructions), not every state.

## How it is wired

`yosys` cannot read this project's SystemVerilog, so `formal/Makefile` runs
`sv2v` over `wrapper.sv` + `cpu.sv` first and points riscv-formal at the
flattened result. `genchecks.py` expects a `<basedir>/cores/<core>/` layout, so
the Makefile builds one in `formal/rf/` out of symlinks into the riscv-formal
submodule. A second flattened build, `rvfi_top_nodiv.v`, adds the wrapper's
no-divide assumption (`WRAPPER_NO_DIVIDE`, kept through sv2v with
`--exclude=Assert`), and the Makefile points `hang` and `liveness` at it.

The RVFI port lives in `cpu.sv` behind `` `ifdef RVFI ``, so the synthesised
build carries none of it. `make cosim-test` validates it independently by
checking every retired instruction against Spike. That's worth running first:
riscv-formal reasons entirely about what RVFI reports, so a wrong record gives
wrong answers in both directions.

## The environment

`wrapper.sv` leaves memory *data* free, so the solver picks whatever
instruction stream exposes a violation. Memory *timing* is also up to the
solver: a request can be refused, and a response can arrive one or two cycles
later, so the core's stall paths are checked too. The external `stall` input is
driven by the solver as well.

All of this is bounded by one budget: after two hostile cycles in a row (a
stall, or a memory that isn't busy refusing a request), the next cycle has no
stall and both memories ready. Bounding stalls and refusals separately isn't
enough, because the solver lines them up so the memory is only ready while the
core is stalled. A memory that never answers really would deadlock the core,
and `liveness` would then fail on the environment rather than the design.
