# Formal verification

## Toolchain (verified working)

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

## Status: riscv-formal is not wired up yet

The blocker is instrumentation, not tooling. riscv-formal drives its checks off
an [RVFI](https://github.com/YosysHQ/riscv-formal/blob/main/docs/rvfi.md) port
that reports, **at the commit point**, everything about the instruction that
just retired. This core does not carry most of that to writeback yet.

What already exists and what has to be plumbed:

| RVFI signal | Status |
|---|---|
| `rvfi_valid` | `memory_instruction_out.is_instruction_valid` at writeback |
| `rvfi_order` | new — a retire counter |
| `rvfi_insn` | **missing past decode** — `decoded_instruction_t.instruction` stops at execute |
| `rvfi_pc_rdata` | **missing** — `memory_instruction_t.pc` exists but is never assigned |
| `rvfi_pc_wdata` | **missing** — `next_pc_comb` is not carried past execute |
| `rvfi_rs1_addr` / `rs2_addr` | in `executed_instruction_t`, stops at memory |
| `rvfi_rs1_rdata` / `rs2_rdata` | `executed_instruction_t.rd1/rd2` hold the *bypassed* values, which is what RVFI wants |
| `rvfi_rd_addr` / `rd_wdata` | `writeback_instruction_t.wbs/wbd` |
| `rvfi_trap` | `trap.taken` in execute, not carried |
| `rvfi_mem_*` | address/masks exist in the memory stage; read data at writeback; none carried |
| `rvfi_mode` / `rvfi_ixl` | constants (3, 1) — this core is M-mode RV32 only |

So the work is: widen `memory_instruction_t` to carry pc, next-pc, insn, rs1/rs2
and the memory access, assign the fields that are currently declared-but-unused,
and expose a commit-point RVFI port from `core`. Roughly 150-250 lines of
mechanical plumbing, then a `checks.cfg` against riscv-formal's `rv32i` model.

Worth doing: it is the only technique here that reasons about *all* inputs
rather than the ones a test happened to pick, and every bug found in this core
so far has lived in an interaction (bypass against stall against redirect) that
is exactly what bounded model checking is good at.
