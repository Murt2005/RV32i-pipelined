# RV32I on the pico2-ice

The five-stage RV32I core from this repo, running on the pico2-ice's
iCE40UP5K. Programs are loaded over USB at run time; one bitstream runs any
program the normal build flow produces.

Status: on hardware, all 19 tests under `tests/` pass with output byte-identical
to the Icarus simulation, all 40 official `rv32ui` riscv-tests pass, and 600
random programs match a reference model instruction for instruction.

```
Host PC ──USB──► RP2350 ──► iCE40UP5K
                   │  exports the FPGA clock (GPOUT0, GPIO21 → iCE40 pin 35)
                   │  pushes the bitstream (USB-DFU → SPI config bus)
                   └  bridges USB-CDC bytes to the FPGA's UART (GPIO28/29)
```

## Quick start

```bash
# one-time
git submodule update --init --recursive
brew install yosys nextpnr-ice40 icestorm dfu-util sv2v picotool
pip install pyserial

# 1. firmware  (only needed when the RP2350 side changes)
cd firmware && mkdir -p build && cd build
cmake -DPICO_BOARD=pico2_ice -DPICO_PLATFORM=rp2350-riscv \
      -DPICO_GCC_TRIPLE=riscv64-unknown-elf -G Ninja .. && ninja
picotool load -x pico2_ice_rv32.uf2      # board must be in BOOTSEL

# 2. gateware
cd fpga/ice40 && make prog

# 3. run something
python3 host/rv32_host.py --probe
python3 host/rv32_host.py --elf build/tests/isa/add_sub.elf
python3 host/rv32_host.py --regress       # all tests, diffed against simulation
python3 host/rv32_host.py --riscv-tests   # official rv32ui suite (make riscv-tests first)
python3 host/rv32_diff.py --iters 200     # random programs vs the reference model
python3 host/rv32_diff.py --stall-rate 200   # ... with the pipeline stalled most cycles
```

After the first firmware flash you never need BOOTSEL again: opening the CDC
port at 1200 baud reboots the board into the UF2 bootloader.

`dfu-util` prints *"Device's firmware is corrupt"* on **every** successful
gateware flash. Ignore it — the SDK's DFU manifest callback reports the result
of `ice_fpga_start()`, which returns 0 unconditionally without polling CDONE.

## Layout

| Path | What |
|---|---|
| `fpga/ice40/rv32_top.sv` | Board top: power-on reset, UART PHY, MMIO, host loader |
| `fpga/ice40/memory_spram.sv` | 64 KiB memory on two `SB_SPRAM256KA`, same `memory_io` interface as `memory.sv` |
| `fpga/ice40/uart.sv` | 8N1 transmitter and receiver |
| `fpga/ice40/rv32_top.pcf` | Pin constraints (iCE40 package pins) |
| `fpga/ice40/sim/` | Board-level testbench: same RTL, behavioural SPRAM, UART host model |
| `firmware/main.c` | RP2350 bridge |
| `host/rv32_host.py` | Loader / runner / regression driver |
| `host/rv32_model.py` | Reference RV32I interpreter (no pipeline, shares no structure with the RTL) |
| `host/rv32_diff.py` | Random program generator + differential test driver |

The core (`cpu.sv`) stays board-neutral. The only thing the board added to it
is a generic `stall` input; everything else talks over the existing
`memory_io` request/response pair.

## Design notes

**Memory is SPRAM, not block RAM.** The UP5K has only 30 × 4 Kbit BRAM =
15 KiB, which cannot hold the 64 KiB instruction + 64 KiB data image the memory
map assumes. It has 4 × 256 Kbit SPRAM = 128 KiB, exactly enough for both, so
the board build keeps the simulator's memory map bit for bit. SPRAM cannot be
initialised at configuration time — hence the host loader — which in turn
leaves all 30 BRAMs free.

**The register file lives in block RAM.** Left in logic it costs ~1024 FFs plus
two 32:1 × 32-bit read muxes and the design does not fit (110% LC). Getting
yosys to infer BRAM needed the read port to be a *plain* synchronous read, so
the write-back-during-decode mux was removed from it; that case is already
covered one stage later by `execute`'s level-2 bypass, which is registered from
the same write-back event. 4389 → 2575 LUT4.

**Clock is 6 MHz.** Post-place-and-route fMax is 8.4 MHz, limited by the
combinational loop writeback → bypass → execute ALU → control. 6 MHz is an
exact /2 of the 12 MHz crystal, so `ice_fpga_init()` sources it straight from
XOSC with a clean 50% duty cycle, and 500000 baud is an exact /12 of it. Both
UART ends therefore derive from the same crystal and cannot drift.

`CLK_FREQ` in `fpga/ice40/Makefile` **must** equal `FPGA_CLK_HZ` in
`firmware/main.c`. The baud divisor is a synthesis-time constant, so a mismatch
garbles bytes rather than producing silence.

**Utilisation** (`nextpnr --up5k --package sg48`): 3321/5280 LC (62%),
5/30 BRAM, 4/4 SPRAM, 8.46 MHz vs a 6 MHz constraint.

## Wire protocol

Host-initiated, one outstanding request, little endian. `0x00` is a NOP in the
idle state so idle filler is harmless.

| Cmd | | Response |
|---|---|---|
| `P` 0x50 | ping | `p` 0x70, version |
| `Z` 0x5A | zero both memories | `z` 0x7A |
| `W` 0x57 | write: `addr[4] len[2] data[len]` | `w` 0x77 |
| `R` 0x52 | read: `addr[4] len[2]` | `r` 0x72, then `len` bytes |
| `G` 0x47 | go | `g` 0x67, then program output until `0x04` (EOT) |
| `H` 0x48 | halt | `h` 0x68 |
| `S` 0x53 | status | `s` 0x73, `{5'b0, uart_err, halted, running}` |
| `T` 0x54 | stall injection rate: `rate[1]` | `t` 0x74 |
| `B` 0x42 | build id | `b` 0x62, then 4 bytes LE |

Program output is raw bytes between the `g` and the EOT sentinel; the test
programs emit ASCII only, so `0x04` is unambiguous.

The version byte is checked by the host, so a stale bitstream paired with a
newer host fails immediately and explicitly instead of misbehaving.

The version only tracks the *wire protocol*, though, so a bitstream built from
older **core** RTL still answers a ping perfectly happily — which cost one
debugging session chasing a hardware bug that was really a missing reflash. The
`B` command reports a hash of the RTL the bitstream was built from
(`fpga/ice40/rtl-sources.txt` lists the files, and both the Makefile and
`rv32_host.py` hash exactly that list), and the host warns when it differs from
the working tree.

## LEDs

The FPGA drives the RGB LED (pins 39/40/41, active low). The firmware
deliberately leaves those GPIOs alone — both chips reach these nets, and
driving from both would be contention.

- **Blue**, ~0.7 Hz blink — the external clock is alive and the fabric is
  running sequential logic. This is the single most useful bring-up signal.
- **Green** — core released and running.
- **Red** — program wrote the halt address.

With the FPGA unconfigured all three are dark, so "dark" is itself a usable
not-configured indication.

## Simulating the board build

`fpga/ice40/sim` runs the *same* RTL that gets synthesized against a
behavioural `SB_SPRAM256KA` and a UART host model, driving the real wire
protocol.

```bash
cd fpga/ice40/sim
make run                        # tests/isa/add_sub
make run TEST=hazards/load_use
make run-all                    # all 19
./tb_rv32_top +dbg              # per-character trace
```

Crucially it holds `reset_n` **high for all time**, which is what the board
does. Every testbench in the repo root pulses reset at t=0, which makes a
missing power-on reset structurally invisible to them.

## Things that bit during bring-up

**yosys cannot parse this RTL.** Its Verilog frontend has no `return`
statement, no `$bits(type_name)`, and does not resolve package typedefs used as
declaration types — and the ISA package is written entirely in that style. The
build runs `sv2v` first rather than rewriting the RTL. Separately, `bool` was
only typedef'd under `verilator`; Icarus has it as a built-in keyword, which is
why nothing had noticed. It is now declared for every tool except Icarus.

**The SDK's UART example is wrong for this board.** It hardcodes GPIO0/GPIO1,
which on pico2-ice are the onboard LEDs — the result is total silence on both
CDC ports. `pico2_ice.h` leaves `ICE_UART_TX`/`ICE_UART_RX` as 255, so the
correct pins come from the schematic: GPIO28 → iCE40 pin 9, GPIO29 → iCE40 pin
11. (`ICE_GPOUT_CLOCK_PIN 22` in that header is likewise stale; the SDK
actually uses `pico2_fpga.pin_clock = 21`.)

**Two SDK bridge bugs are patched in `firmware/main.c`.** `ice_usb_cdc_to_uart0()`
drops bytes once the 32-deep UART TX FIFO fills, which would corrupt every
program load; it is replaced with a blocking write so TinyUSB's CDC flow
control NAKs the host instead. `ice_usb_uart0_to_cdc()` calls TinyUSB device
APIs from the UART RX interrupt, racing `tud_task()` with no locking under
`CFG_TUSB_OS=OPT_OS_NONE`; it is demoted to a ring-buffer producer drained from
the main loop, so there is exactly one TinyUSB caller.

**MMIO putchar needed real backpressure.** `$write` is instantaneous in
simulation; a UART is not, and `memory_io` has no way to say "not ready". The
core gained a `stall` input that freezes fetch/decode/execute while the
transmit queue is full — the same shape as the existing load-use stall, so the
store already in EX/MEM issues exactly once and the instruction in ID/EX is
re-decoded from the fetch latch. Gating the *memory* stage with it instead put
the queue's flag on a combinational loop out through the memory request and
back, which capped the design at 8.9 MHz.

**A latent fetch bug surfaced.** On a stall, fetch realigns `fetch_pc` to
`latched_instruction_pc + 4`. If a branch redirect was applied the cycle
before, that overwrites the freshly set branch target and execution silently
resumes at the wrong address. It is unreachable with only the load-use stall
(ID/EX is flushed after a redirect, so the load-use condition cannot fire), but
an externally timed stall hits it. `fetch` now picks the realign target based
on what is actually in flight.

**Differential testing found a real bug that riscv-tests could not.** The
branch ALU zero-extends both operands into a 33-bit subtract; `blt` then read
bit 31, which is the sign of the *truncated* difference and is wrong whenever
the signed subtraction overflows. Bit 32 is the unsigned borrow, so signed
less-than is that xor'd with both operand sign bits. `blt.S` in riscv-tests
only uses operands in -2..1, where the subtraction can never overflow, so the
official suite passes with the bug present. `tests/isa/branch_signed.s` now
covers it directly.

**Stall injection.** `stall` is otherwise only ever driven by transmit-queue
backpressure, which is tied to how often the program prints and so barely
exercises the stall/redirect interaction — precisely where the fetch bug above
was hiding. The `T` command drives it from an LFSR instead, reseeded on every
`G` so a failing case replays identically. Extra stall cycles are always safe:
the queue-backpressure term is what guarantees no byte is dropped, and stalling
more never breaks it.

**Hardware and simulation must start from the same memory.** `memory.sv` zeroes
its arrays in an `initial` block, so every simulated run begins with all-zero
memory. SPRAM keeps its contents across runs. `hazards/branch_after_load`
asserts that a location its own program never writes is still zero — it passed
in simulation and failed on hardware purely because of the previous test's
leftovers. Hence the `Z` command, which clears both memories in 16384 cycles
(~2.7 ms).
