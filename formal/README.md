# Formal verification

[riscv-formal](https://github.com/YosysHQ/riscv-formal) checks the core through
an RVFI commit port. Unlike the test suites the solver reasons about every
operand value and every reachable pipeline state and not just the ones a test had happened
to pick.

## Toolchain

```bash
brew install yices2 z3            # SMT solvers; yosys already provides yosys-smtbmc
git clone https://github.com/YosysHQ/sby /tmp/sby
cd /tmp/sby && make install PREFIX=$HOME/.local
export PATH=$HOME/.local/bin:$PATH
```

```bash
cd formal && sby -f smoke.sby      # expect FAIL with a counterexample trace
```

## Checks

`checks.cfg` targets RV32IM, which generates 54 checks:

| Check | What it proves |
|---|---|
| `insn_*` (45) | each instruction matches the ISA model for every operand value and reachable pipeline state |
| `reg` | a register read returns what was last written to it |
| `pc_fwd` / `pc_bwd` | consecutive instructions' PCs chain correctly |
| `causal` | an instruction never depends on a value produced after it |
| `unique` | `rvfi_order` is strictly increasing; nothing retires twice |
| `liveness` | after a retirement the next one comes within 22 cycles; no divides |
| `ill` | an all-zero instruction traps and writes neither a register nor memory |
| `hang` | at least one instruction retires within 30 cycles of reset; no divides |
| `cover` | two retirements and one trap are reachable |

```bash
cd formal
make checks                        # generate the .sby files
make list                          # what was generated
make one CHECK=insn_addi_ch0       # a single check
make run-insn                      # the RV32I instruction checks
make run-consistency               # reg, pc_fwd, pc_bwd, causal, unique, liveness, ill, hang, cover
make run-m                         # the eight M checks (unknown runtime, hasn't been run)
```

## Status


| Checks | Result |
|---|---|
| `hang` | PASS|
| `liveness` | PASS|
| `insn_i*` | PASS |
| `causal`, `cover`, `ill`, `pc_bwd`, `unique` | PASS|
| `pc_fwd` | no result yet; stopped after 58 minutes |
| `reg` | no result yet; stopped after 60 minutes |
| `insn_m*` | not run on purpose |

The M checks are left out on purpose since SMT solvers can't finish them in a reasonable time
and multiply and divide results are already checked by `rv32um` and by random
programs in lockstep with Spike.

Every check here is bounded model checking meaning a PASS only covers what the core can
reach within the check's depth after reset. 
