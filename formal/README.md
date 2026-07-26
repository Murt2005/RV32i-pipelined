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

## riscv-formal

```bash
brew install yices2                # solver
git clone https://github.com/YosysHQ/sby /tmp/sby
cd /tmp/sby && make install PREFIX=$HOME/.local
export PATH=$HOME/.local/bin:$PATH

cd formal
make checks                        # generate the .sby files
make list                          # what was generated
make one CHECK=insn_addi_ch0       # a single check
make run-insn                      # all 37 instruction checks
make run                           # everything, including the slow ones
```

Each `insn_*` check is a bounded proof that one instruction is implemented
correctly for **every** operand value and **every** reachable pipeline state,
rather than the handful a directed test happens to pick. That is the thing
neither riscv-tests nor the random differential tester can give you.

### How it is wired

`yosys` cannot read this project's SystemVerilog, so `formal/Makefile` runs
`sv2v` over `wrapper.sv` + `cpu.sv` first and points riscv-formal at the
flattened result. `genchecks.py` derives its base directory from the working
directory and expects a `<basedir>/cores/<core>/` layout, so the Makefile
builds that layout in `formal/rf/` out of symlinks into the vendored
riscv-formal rather than copying it.

The RVFI port itself lives in `cpu.sv` behind `` `ifdef RVFI ``, so the
synthesised build carries none of it. It is validated independently by
`host/rvfi_check.py`, which replays every retired instruction through the
reference model — worth doing first, because riscv-formal reasons entirely
about what RVFI reports, and a wrong record yields confident nonsense in both
directions.

### The memory model

`wrapper.sv` leaves the memory *data* free — that is the point, the solver
picks whatever instruction stream exposes a violation. The *protocol* is
constrained to match the real memories: a request presented in one cycle is
answered the next, with the response echoing the address it was issued for.
Without that the core would be judged against a memory no implementation has,
and the pc-chain checks would fail on the environment rather than the design.

## Appendix: what RVFI needed

The instrumentation that had to be added. riscv-formal drives its checks off
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
