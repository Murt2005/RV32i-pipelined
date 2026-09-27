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
| `liveness` | the core always eventually retires an instruction |
| `ill` | an all-zero instruction traps and writes neither a register nor memory |
| `hang` | at least one instruction retires within 30 cycles of reset |
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

Last run on 2026-09-26 and 27, after the machine-mode CSR and trap changes:

| Checks | Result |
|---|---|
| `insn_*` for RV32I (37) | all PASS, about 5 minutes each, 2h56m in total |
| `causal` | PASS in 12 minutes |
| `cover` | PASS in 11 minutes: both cover statements reached at step 30 |
| `ill` | PASS in 4 minutes |
| `pc_bwd` | PASS in 13 minutes |
| `unique` | PASS in 16 minutes |
| `hang` | FAIL in 9 minutes |
| `liveness` | FAIL in 18 minutes |
| `pc_fwd` | no result, stopped after 58 minutes |
| `reg` | no result, stopped after 60 minutes |
| `insn_*` for M (8) | not run on purpose |

The M checks are left out: SMT solvers can't finish them in reasonable time,
and multiply and divide results are already checked by `rv32um` and by random
programs in lockstep with Spike.

`hang` and `liveness` fail for two reasons, which aren't separated yet:

- The wrapper bounds memory refusals and the external `stall` separately, and
  the solver lines them up: it raises `ready` only in cycles where `stall` is
  also high, so no fetch is accepted, and each of those resets the refusal
  count. The core can then be kept from fetching indefinitely. The environment
  needs one bound on blocked cycles covering both.
- In the fetch stage, a response that arrives two cycles after its request
  lands in the cycle `instruction_miss_q` freezes the front end, so it isn't
  latched and the address is fetched again. The `liveness` counterexample
  drops responses this way with no stall and `ready` high. If that holds, an
  instruction memory with a fixed latency of two or more cycles would stop the
  core making progress. It hasn't been confirmed in simulation yet.

`pc_fwd` and `reg` need longer runs, ideally after the wrapper fix.

Every check here is bounded model checking, so a PASS covers what the core can
reach within the check's depth after reset (24 cycles for the RV32I
instructions), not every state.

## How it is wired

`yosys` cannot read this project's SystemVerilog, so `formal/Makefile` runs
`sv2v` over `wrapper.sv` + `cpu.sv` first and points riscv-formal at the
flattened result. `genchecks.py` expects a `<basedir>/cores/<core>/` layout, so
the Makefile builds one in `formal/rf/` out of symlinks into the riscv-formal
submodule.

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

All of this is bounded: at most two refusals or stalled cycles in a row. A
memory that never answers really would deadlock the core, and `liveness` would
then fail on the environment rather than the design.
