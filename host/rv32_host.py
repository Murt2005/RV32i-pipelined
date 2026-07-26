#!/usr/bin/env python3
"""
Host driver for the RV32I pipelined processor running on a pico2-ice.

Loads a program image over the USB-CDC <-> UART bridge, releases the core, and
streams back whatever the program writes to the putchar MMIO register.

Typical use:

    # probe the link and report what answered
    python3 host/rv32_host.py --probe

    # run one test built by the repo's normal flow
    python3 host/rv32_host.py --elf build/tests/isa/add_sub.elf

    # run the whole regression against silicon and diff against simulation
    python3 host/rv32_host.py --regress

Port selection: both CDC ports report the same product string on macOS, so
there is no reliable way to tell the bridged one from the log one. With no
--port, this tries every candidate and keeps the first that answers a ping.
"""

import argparse
import glob
import os
import subprocess
import sys
import time

try:
    import serial
    from serial.tools import list_ports
except ImportError:
    sys.exit("pyserial is required:  pip install pyserial")

# ---- wire protocol (mirrors the localparams in fpga/ice40/rv32_top.sv) ----
CMD_NOP    = 0x00
CMD_PING   = 0x50   # 'P' -> 0x70, VERSION
CMD_ZERO   = 0x5A   # 'Z' -> 0x7A
CMD_WRITE  = 0x57   # 'W' -> addr[4] len[2] data...,  then 0x77
CMD_READ   = 0x52   # 'R' -> addr[4] len[2],  then 0x72 and len bytes
CMD_GO     = 0x47   # 'G' -> 0x67, then program output until EOT
CMD_HALT   = 0x48   # 'H' -> 0x68
CMD_STATUS = 0x53   # 'S' -> 0x73, status byte
CMD_TRATE  = 0x54   # 'T' -> rate[1],  then 0x74
CMD_BUILD  = 0x42   # 'B' -> 0x62 and 4 bytes LE

RSP_PING   = 0x70
RSP_ZERO   = 0x7A
RSP_WRITE  = 0x77
RSP_READ   = 0x72
RSP_GO     = 0x67
RSP_HALT   = 0x68
RSP_STATUS = 0x73
RSP_TRATE  = 0x74
RSP_BUILD  = 0x62
EOT        = 0x04

PROTO_VERSION = 0x05

BAUD = 1000000         # must equal BAUD_RATE in fpga/ice40/Makefile
CLK_HZ = 12_000_000    # must equal CLK_FREQ in fpga/ice40/Makefile

TEXT_BASE = 0x00010000
DATA_BASE = 0x00020000

# The FPGA writes one byte per memory transaction and the UART paces it, but
# keep frames modest so a stuck link fails fast rather than after 64 KiB.
CHUNK = 1024


class Rv32Error(RuntimeError):
    pass


class Rv32Board:
    def __init__(self, port, baud=BAUD, timeout=2.0, verbose=False):
        self.verbose = verbose
        self.port_name = port
        self.ser = serial.Serial(port, baud, timeout=timeout)
        # Drop anything a previous session left in flight, so a desynced
        # state machine cannot be mistaken for a protocol error here.
        time.sleep(0.05)
        self.ser.reset_input_buffer()
        self.ser.reset_output_buffer()

    def close(self):
        self.ser.close()

    # ---- primitives ----
    def _expect(self, want, what):
        got = self.ser.read(1)
        if not got:
            raise Rv32Error(f"{what}: timed out waiting for 0x{want:02x}")
        if got[0] != want:
            raise Rv32Error(f"{what}: expected 0x{want:02x}, got 0x{got[0]:02x}")

    def ping(self):
        """Returns the protocol version reported by the gateware."""
        self.ser.write(bytes([CMD_PING]))
        self.ser.flush()
        self._expect(RSP_PING, "ping")
        ver = self.ser.read(1)
        if not ver:
            raise Rv32Error("ping: no version byte")
        return ver[0]

    def status(self):
        self.ser.write(bytes([CMD_STATUS]))
        self.ser.flush()
        self._expect(RSP_STATUS, "status")
        st = self.ser.read(1)
        if not st:
            raise Rv32Error("status: no status byte")
        return st[0]

    def halt(self):
        self.ser.write(bytes([CMD_HALT]))
        self.ser.flush()
        self._expect(RSP_HALT, "halt")

    def build_id(self):
        """Hash of the RTL the flashed bitstream was built from."""
        self.ser.write(bytes([CMD_BUILD]))
        self.ser.flush()
        self._expect(RSP_BUILD, "build id")
        raw = self.ser.read(4)
        if len(raw) != 4:
            raise Rv32Error("build id: short reply")
        return int.from_bytes(raw, "little")

    def set_stall_rate(self, rate):
        """
        Drive the core's stall input from an LFSR `rate`/256 of the time.

        Normally `stall` only ever comes from transmit-queue backpressure,
        which is tied to how often the program prints and so barely exercises
        the stall/redirect interaction in the pipeline. 0 restores that.
        """
        if not 0 <= rate <= 255:
            raise Rv32Error(f"stall rate {rate} out of range 0..255")
        self.ser.write(bytes([CMD_TRATE, rate]))
        self.ser.flush()
        self._expect(RSP_TRATE, "stall rate")

    def resync(self):
        """
        Put the gateware's command FSM back in its idle state.

        A previous run interrupted mid-'W' leaves the FSM expecting address or
        payload bytes, where it would happily eat the next session's commands.
        0x00 is a NOP in the idle state, and the longest frame header is 6
        bytes, so a run of NOPs longer than any partial frame guarantees the
        FSM is idle -- and a following ping proves it.
        """
        self.ser.write(bytes([CMD_NOP] * 16))
        self.ser.flush()
        time.sleep(0.05)
        self.ser.reset_input_buffer()

    def zero_mem(self):
        """
        Clear both memories.

        The simulator's memory.sv zeroes its arrays in an `initial` block, so
        every simulated run starts from all-zero memory. SPRAM keeps its
        contents across runs, so without this the hardware starts from the
        previous program's leftovers -- which silently breaks any test that
        asserts a location its own program never writes.
        """
        # Widen the timeout *before* sending. pyserial's timeout setter
        # reconfigures the port with tcsetattr, which discards buffered input --
        # and the clear only takes ~3 ms, so the reply has already arrived by
        # the time a post-write setter would run, and would be thrown away.
        old = self.ser.timeout
        if old is None or old < 2.0:
            self.ser.timeout = 2.0
        try:
            self.ser.write(bytes([CMD_ZERO]))
            self.ser.flush()
            self._expect(RSP_ZERO, "zero")
        finally:
            if self.ser.timeout != old:
                self.ser.timeout = old

    def write_mem(self, addr, payload):
        for off in range(0, len(payload), CHUNK):
            chunk = payload[off:off + CHUNK]
            base = addr + off
            hdr = bytes([CMD_WRITE,
                         base & 0xFF, (base >> 8) & 0xFF,
                         (base >> 16) & 0xFF, (base >> 24) & 0xFF,
                         len(chunk) & 0xFF, (len(chunk) >> 8) & 0xFF])
            self.ser.write(hdr + chunk)
            self.ser.flush()
            self._expect(RSP_WRITE, f"write ack @0x{base:08x}")

    def read_mem(self, addr, nbytes):
        """Read memory back. Used to compare state against a reference model."""
        out = bytearray()
        for off in range(0, nbytes, CHUNK):
            n = min(CHUNK, nbytes - off)
            base = addr + off
            self.ser.write(bytes([CMD_READ,
                                  base & 0xFF, (base >> 8) & 0xFF,
                                  (base >> 16) & 0xFF, (base >> 24) & 0xFF,
                                  n & 0xFF, (n >> 8) & 0xFF]))
            self.ser.flush()
            self._expect(RSP_READ, f"read ack @0x{base:08x}")
            chunk = self.ser.read(n)
            if len(chunk) != n:
                raise Rv32Error(f"read @0x{base:08x}: got {len(chunk)} of {n} bytes")
            out += chunk
        return bytes(out)

    def go(self, run_timeout=15.0):
        """Release the core and collect its output up to the halt sentinel."""
        self.ser.write(bytes([CMD_GO]))
        self.ser.flush()
        self._expect(RSP_GO, "go")

        out = bytearray()
        deadline = time.time() + run_timeout
        while time.time() < deadline:
            b = self.ser.read(1)
            if not b:
                continue
            if b[0] == EOT:
                return bytes(out), True
            out.append(b[0])
        return bytes(out), False


# ---------------------------------------------------------------------------
# ELF -> memory images, reusing the repo's own objcopy conventions
# ---------------------------------------------------------------------------
def elf_to_images(elf_path, objcopy=None):
    """Returns (text_bytes, data_bytes) exactly as elftohex.sh splits them."""
    if objcopy is None:
        objcopy = _find_objcopy()

    def run(args, out):
        subprocess.run([objcopy] + args + [elf_path, out],
                       check=True, capture_output=True)
        with open(out, "rb") as f:
            return f.read()

    tmp = f"/tmp/rv32_host_{os.getpid()}"
    try:
        text = run(["-j", ".text", "-O", "binary"], tmp + ".text")
        # .bss is excluded deliberately: it is zero by definition and the Z
        # command has already cleared memory, so including it would pad the
        # image to the top of .bss -- 60 KB for a benchmark with a 10 KB array.
        data = run(["-R", ".text", "-R", ".bss", "-O", "binary"], tmp + ".data")
    finally:
        for suffix in (".text", ".data"):
            try:
                os.unlink(tmp + suffix)
            except OSError:
                pass
    return text, data


def _find_objcopy():
    # site-config.sh holds the toolchain prefix the rest of the build uses.
    cfg = os.path.join(os.path.dirname(__file__), "..", "site-config.sh")
    if os.path.exists(cfg):
        for line in open(cfg):
            if line.startswith("RISCV_PREFIX="):
                cand = line.split("=", 1)[1].strip() + "-objcopy"
                if os.path.exists(cand):
                    return cand
    for cand in ("riscv64-unknown-elf-objcopy", "riscv-none-embed-objcopy",
                 "riscv64-elf-objcopy"):
        try:
            subprocess.run([cand, "--version"], check=True, capture_output=True)
            return cand
        except (OSError, subprocess.CalledProcessError):
            continue
    raise Rv32Error("no RISC-V objcopy found; set RISCV_PREFIX in site-config.sh")


# ---------------------------------------------------------------------------
# Port discovery
# ---------------------------------------------------------------------------
def local_build_id(repo_root):
    """
    Hash the RTL sources the same way fpga/ice40/Makefile does.

    The protocol version only tracks the wire protocol, so a bitstream built
    from older core RTL answers a ping perfectly happily. Comparing this
    against what the board reports turns "mysterious hardware bug" back into
    "you forgot to reflash".
    """
    import hashlib
    ice = os.path.join(repo_root, "fpga", "ice40")
    listing = os.path.join(ice, "rtl-sources.txt")
    if not os.path.exists(listing):
        return None
    blob = b""
    with open(listing) as f:
        for name in f.read().split():
            path = os.path.join(ice, name)
            if not os.path.exists(path):
                return None
            with open(path, "rb") as src:
                blob += src.read()
    return int(hashlib.sha256(blob).hexdigest()[:8], 16)


def check_build_id(board, repo_root):
    """Warn if the flashed bitstream predates the RTL in the working tree."""
    try:
        on_board = board.build_id()
    except Rv32Error:
        return
    local = local_build_id(repo_root)
    if local is None or on_board == local:
        return
    print(f"warning: bitstream was built from different RTL "
          f"(board 0x{on_board:08x}, sources 0x{local:08x}).\n"
          f"         run `make -C fpga/ice40 prog` to reflash.",
          file=sys.stderr)


def candidate_ports():
    seen = []
    for p in list_ports.comports():
        seen.append(p.device)
    seen += [p for p in glob.glob("/dev/cu.usbmodem*") if p not in seen]
    # The bridged CDC is usually the higher-numbered one, so try those first.
    return sorted(set(seen), reverse=True)


def open_board(port=None, verbose=False):
    if port:
        b = Rv32Board(port, verbose=verbose)
        b.resync()
        ver = b.ping()
        if ver != PROTO_VERSION:
            raise Rv32Error(f"protocol version {ver}, expected {PROTO_VERSION} "
                            "-- host and bitstream are out of step")
        return b

    errors = []
    mismatch = None
    for cand in candidate_ports():
        try:
            b = Rv32Board(cand, timeout=0.6, verbose=verbose)
        except Exception as exc:
            errors.append(f"  {cand}: {exc}")
            continue
        try:
            b.resync()
            ver = b.ping()
            if ver != PROTO_VERSION:
                # Answered, so this *is* the right port -- the bitstream is
                # just older than this host. Say so plainly instead of
                # reporting it as "nothing responded".
                mismatch = (cand, ver)
                raise Rv32Error(f"protocol version {ver}, expected {PROTO_VERSION}")
            b.ser.timeout = 2.0
            if verbose:
                print(f"[found gateware on {cand}]", file=sys.stderr)
            return b
        except Exception as exc:
            errors.append(f"  {cand}: {exc}")
            b.close()

    if mismatch:
        cand, ver = mismatch
        raise Rv32Error(
            f"{cand} answered with protocol v{ver}, but this host speaks "
            f"v{PROTO_VERSION}.\nThe flashed bitstream is older than the "
            f"working tree -- run `make -C fpga/ice40 prog` to reflash.")

    raise Rv32Error("no port answered a ping. Tried:\n" + "\n".join(errors) +
                    "\n\nCheck: firmware flashed, gateware flashed, and the "
                    "board replugged since the last gateware flash.")


# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------
def do_probe(board):
    print(f"port     : {board.port_name}")
    print(f"protocol : v{PROTO_VERSION} (gateware answered)")
    st = board.status()
    print(f"status   : running={st & 1} halted={(st >> 1) & 1} "
          f"uart_errors={(st >> 2) & 1}")


def run_elf(board, elf, timeout=15.0, quiet=False):
    text, data = elf_to_images(elf)
    board.halt()
    board.zero_mem()
    board.write_mem(TEXT_BASE, text)
    board.write_mem(DATA_BASE, data)
    out, halted = board.go(run_timeout=timeout)
    if not quiet:
        sys.stdout.write(out.decode("utf-8", errors="replace"))
        sys.stdout.flush()
        if not halted:
            print(f"\n[timeout after {timeout}s -- no halt sentinel]",
                  file=sys.stderr)
    return out, halted


def sim_output(stem, repo_root):
    """Run the same test under iverilog and return its stdout for comparison."""
    r = subprocess.run(["make", f"run-test-{stem.replace('/', '-')}-iverilog"],
                       cwd=repo_root, capture_output=True, text=True)
    lines = []
    keep = False
    for line in r.stdout.splitlines():
        if line.startswith("==="):
            keep = True
        if keep and not line.startswith(("make", "cp ", "mkdir", "/bin/bash",
                                         "./build", "WARNING", "VCD", "rm ")):
            if "$finish called" in line:
                break
            lines.append(line)
    return "\n".join(lines).strip()


def do_riscv_tests(board, repo_root, timeout):
    """Run the official rv32ui suite on hardware. Each test prints one line."""
    elfs = sorted(glob.glob(os.path.join(repo_root, "build", "riscv-tests", "*.elf")))
    if not elfs:
        print("no ELFs in build/riscv-tests -- run `make riscv-tests` first",
              file=sys.stderr)
        return 2

    npass = nfail = 0
    for elf in elfs:
        name = os.path.basename(elf)[:-4]
        out, halted = run_elf(board, elf, timeout=timeout, quiet=True)
        text = out.decode("utf-8", errors="replace").strip()
        if halted and text == "PASS":
            npass += 1
            print(f"PASS rv32ui-{name}")
        else:
            nfail += 1
            detail = text if halted else f"no halt, got {text!r}"
            print(f"FAIL rv32ui-{name}  ({detail})")

    print(f"\n{npass} passed, {nfail} failed, {len(elfs)} total")
    return 0 if nfail == 0 else 1


BENCH_RESULT_ADDR = 0x00021800


def do_bench(board, elf, timeout):
    """Run a workload that samples the performance counters and report IPC."""
    _, halted = run_elf(board, elf, timeout=timeout, quiet=True)
    if not halted:
        print("benchmark did not halt", file=sys.stderr)
        return 1
    raw = board.read_mem(BENCH_RESULT_ADDR, 8)
    cycles = int.from_bytes(raw[0:4], "little")
    retired = int.from_bytes(raw[4:8], "little")
    if cycles == 0:
        print("counters read back zero -- is the bitstream current?", file=sys.stderr)
        return 1
    print(f"cycles   : {cycles}")
    print(f"retired  : {retired}")
    print(f"IPC      : {retired / cycles:.3f}")
    print(f"at {CLK_HZ/1e6:.0f} MHz: {cycles / CLK_HZ * 1e3:.2f} ms, "
          f"{retired / (cycles / CLK_HZ) / 1e6:.2f} MIPS")
    return 0


DHRYSTONE_ELF = "build/tests/bench/dhrystone/dhrystone.elf"
# 1 DMIPS is 1757 Dhrystones/second, the VAX 11/780 reference.
VAX_DHRYSTONES = 1757.0


def do_dhrystone(board, repo_root, timeout):
    elf = os.path.join(repo_root, DHRYSTONE_ELF)
    if not os.path.exists(elf):
        print("run `make dhrystone` first", file=sys.stderr)
        return 2

    out, halted = run_elf(board, elf, timeout=max(timeout, 60), quiet=True)
    text = out.decode("utf-8", errors="replace")
    if not halted:
        print("dhrystone did not halt", file=sys.stderr)
        return 1

    fields = {}
    for line in text.splitlines():
        for key in ("CYCLES", "RUNS"):
            if line.startswith(key + "="):
                fields[key] = int(line.split("=", 1)[1])
    if "CYCLES" not in fields or "RUNS" not in fields:
        print(text, file=sys.stderr)
        print("could not find CYCLES/RUNS in the output", file=sys.stderr)
        return 1

    cycles, runs = fields["CYCLES"], fields["RUNS"]
    cycles_per_run = cycles / runs
    # Dhrystone's own report normalises to 1 MHz, so this is per-MHz directly.
    dhry_per_sec_per_mhz = 1e6 / cycles_per_run
    dmips_per_mhz = dhry_per_sec_per_mhz / VAX_DHRYSTONES
    mhz = CLK_HZ / 1e6

    print(f"runs             : {runs}")
    print(f"cycles           : {cycles}  ({cycles_per_run:.0f} per run)")
    print(f"Dhrystones/s     : {dhry_per_sec_per_mhz * mhz:.0f}  at {mhz:.0f} MHz")
    print(f"DMIPS            : {dmips_per_mhz * mhz:.2f}")
    print(f"DMIPS/MHz        : {dmips_per_mhz:.3f}")
    return 0


def do_regress(board, repo_root, timeout):
    stems = []
    for sub in ("isa", "hazards"):
        d = os.path.join(repo_root, "tests", sub)
        for f in sorted(glob.glob(os.path.join(d, "*.s"))):
            stems.append(f"{sub}/{os.path.splitext(os.path.basename(f))[0]}")

    npass = nfail = 0
    failures = []
    for stem in stems:
        elf = os.path.join(repo_root, "build", "tests", stem + ".elf")
        if not os.path.exists(elf):
            subprocess.run(["make", f"build/tests/{stem}.elf"],
                           cwd=repo_root, capture_output=True)
        if not os.path.exists(elf):
            print(f"SKIP {stem} (no ELF)")
            continue

        hw_out, halted = run_elf(board, elf, timeout=timeout, quiet=True)
        hw = hw_out.decode("utf-8", errors="replace").strip()
        sim = sim_output(stem, repo_root)

        ok = halted and hw == sim and "FAIL" not in hw
        if ok:
            npass += 1
            print(f"PASS {stem}")
        else:
            nfail += 1
            reason = ("no halt" if not halted
                      else "FAIL in output" if "FAIL" in hw
                      else "differs from simulation")
            print(f"FAIL {stem}  ({reason})")
            failures.append((stem, sim, hw))

    print(f"\n{npass} passed, {nfail} failed, {len(stems)} total")
    for stem, sim, hw in failures:
        print(f"\n--- {stem} ---\n[sim]\n{sim}\n[hw]\n{hw}")
    return 0 if nfail == 0 else 1


def main():
    repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))

    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--port", help="serial port; autodetected if omitted")
    ap.add_argument("--elf", help="ELF to load and run")
    ap.add_argument("--probe", action="store_true", help="ping and report status")
    ap.add_argument("--regress", action="store_true",
                    help="run every test in tests/ and diff against simulation")
    ap.add_argument("--riscv-tests", action="store_true",
                    help="run the official rv32ui suite from build/riscv-tests")
    ap.add_argument("--bench", metavar="ELF",
                    help="run a counter-sampling workload and report IPC")
    ap.add_argument("--dhrystone", action="store_true",
                    help="run Dhrystone and report DMIPS/MHz")
    ap.add_argument("--timeout", type=float, default=15.0,
                    help="seconds to wait for the halt sentinel")
    ap.add_argument("-v", "--verbose", action="store_true")
    args = ap.parse_args()

    if not (args.elf or args.probe or args.regress or args.riscv_tests
            or args.bench or args.dhrystone):
        ap.error("give one of --elf, --probe, --regress, --riscv-tests, "
                 "--bench or --dhrystone")

    try:
        board = open_board(args.port, verbose=args.verbose)
    except Rv32Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    try:
        check_build_id(board, repo_root)
        if args.probe:
            do_probe(board)
        if args.elf:
            _, halted = run_elf(board, args.elf, timeout=args.timeout)
            return 0 if halted else 1
        if args.dhrystone:
            return do_dhrystone(board, repo_root, args.timeout)
        if args.bench:
            return do_bench(board, args.bench, args.timeout)
        if args.riscv_tests:
            return do_riscv_tests(board, repo_root, args.timeout)
        if args.regress:
            return do_regress(board, repo_root, args.timeout)
    except Rv32Error as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    finally:
        board.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
