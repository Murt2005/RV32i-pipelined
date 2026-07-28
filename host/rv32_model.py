#!/usr/bin/env python3
"""
Reference RV32I interpreter.

Deliberately written as a plain instruction-at-a-time interpreter with no
pipeline, no bypassing and no hazard logic, so that it shares no structure with
the RTL it is used to check. Everything the pipelined core has to get right --
forwarding, load-use stalls, branch flushes -- is invisible here, which is
exactly what makes the comparison meaningful.

Only the RV32I base integer set is modelled. Misaligned accesses raise, since
the core neither implements nor traps them and any test that produces one is a
bug in the generator rather than in the core.
"""

MASK32 = 0xFFFFFFFF


def _sx(value, bits):
    """Sign-extend `bits`-wide `value` to a Python int."""
    sign = 1 << (bits - 1)
    return (value & (sign - 1)) - (value & sign)


def _u32(v):
    return v & MASK32


def _trunc_div(a, b):
    """Signed division truncating towards zero, as RISC-V defines it.

    Python's // floors towards negative infinity, so -7 // 2 is -4 where the ISA
    wants -3. Done on magnitudes with the sign reapplied rather than via float
    division, which would be exact for 32-bit operands today and silently wrong
    the moment anyone reuses this for 64.
    """
    q = abs(a) // abs(b)
    return -q if (a < 0) != (b < 0) else q


class MisalignedAccess(Exception):
    pass


class Trap(Exception):
    pass


class Rv32Model:
    """
    Executes a program image. `text` is placed at text_base, `data` at
    data_base, in a flat sparse byte dict; the core's separate instruction and
    data memories never overlap in the address map so one dict is faithful.
    """

    HALT_ADDR = 0x0002FFFC
    PUTCHAR_ADDR = 0x0002FFF8

    def __init__(self, text, data, text_base=0x00010000, data_base=0x00020000):
        self.mem = bytearray(1 << 18)          # 256 KiB covers both regions
        self.text_base = text_base
        self.data_base = data_base
        self.mem[text_base:text_base + len(text)] = text
        self.mem[data_base:data_base + len(data)] = data
        self.x = [0] * 32
        self.pc = text_base
        self.output = bytearray()
        self.halted = False

    # ---- memory ----
    def _ld(self, addr, n, signed):
        if addr % n:
            raise MisalignedAccess(f"load of {n} bytes at 0x{addr:08x}")
        v = int.from_bytes(self.mem[addr:addr + n], "little")
        return _sx(v, n * 8) & MASK32 if signed else v

    def _st(self, addr, n, value):
        if addr % n:
            raise MisalignedAccess(f"store of {n} bytes at 0x{addr:08x}")
        if addr == self.PUTCHAR_ADDR:
            self.output.append(value & 0xFF)
            return
        if addr == self.HALT_ADDR:
            self.halted = True
            return
        self.mem[addr:addr + n] = (value & ((1 << (n * 8)) - 1)).to_bytes(n, "little")

    # ---- execution ----
    def step(self):
        instr = int.from_bytes(self.mem[self.pc:self.pc + 4], "little")
        opcode = instr & 0x7F
        rd = (instr >> 7) & 0x1F
        f3 = (instr >> 12) & 0x07
        rs1 = (instr >> 15) & 0x1F
        rs2 = (instr >> 20) & 0x1F
        f7 = (instr >> 25) & 0x7F
        a = self.x[rs1]
        b = self.x[rs2]
        next_pc = _u32(self.pc + 4)
        val = None

        if opcode == 0x37:                                   # LUI
            val = _u32(instr & 0xFFFFF000)
        elif opcode == 0x17:                                 # AUIPC
            val = _u32(self.pc + (instr & 0xFFFFF000))
        elif opcode == 0x6F:                                 # JAL
            imm = _sx(((instr >> 31) & 1) << 20 | ((instr >> 12) & 0xFF) << 12
                      | ((instr >> 20) & 1) << 11 | ((instr >> 21) & 0x3FF) << 1, 21)
            val = next_pc
            next_pc = _u32(self.pc + imm)
        elif opcode == 0x67:                                 # JALR
            imm = _sx(instr >> 20, 12)
            val = next_pc
            next_pc = _u32(a + imm) & ~1
        elif opcode == 0x63:                                 # BRANCH
            imm = _sx(((instr >> 31) & 1) << 12 | ((instr >> 7) & 1) << 11
                      | ((instr >> 25) & 0x3F) << 5 | ((instr >> 8) & 0xF) << 1, 13)
            sa, sb = _sx(a, 32), _sx(b, 32)
            taken = {0: a == b, 1: a != b, 4: sa < sb,
                     5: sa >= sb, 6: a < b, 7: a >= b}.get(f3)
            if taken is None:
                raise Trap(f"bad branch funct3 {f3} at 0x{self.pc:08x}")
            if taken:
                next_pc = _u32(self.pc + imm)
        elif opcode == 0x03:                                 # LOAD
            addr = _u32(a + _sx(instr >> 20, 12))
            val = {0: lambda: self._ld(addr, 1, True),
                   1: lambda: self._ld(addr, 2, True),
                   2: lambda: self._ld(addr, 4, False),
                   4: lambda: self._ld(addr, 1, False),
                   5: lambda: self._ld(addr, 2, False)}[f3]()
        elif opcode == 0x23:                                 # STORE
            imm = _sx(((instr >> 25) << 5) | ((instr >> 7) & 0x1F), 12)
            addr = _u32(a + imm)
            self._st(addr, {0: 1, 1: 2, 2: 4}[f3], b)
        elif opcode == 0x33 and f7 == 0x01:                  # OP, M extension
            # The corner cases are the whole point of writing these out rather
            # than leaning on Python's operators, which disagree with the spec on
            # every one of them:
            #   * division by zero is defined, not a trap -- quotient is all ones
            #     and remainder is the dividend.
            #   * signed overflow, INT_MIN / -1, wraps to INT_MIN with a zero
            #     remainder rather than raising.
            #   * Python's // and % floor towards negative infinity; RISC-V
            #     truncates towards zero, so -7/2 is -3 here and -4 in Python.
            sa, sb = _sx(a, 32), _sx(b, 32)
            if f3 == 0:                                      # MUL
                val = _u32(sa * sb)
            elif f3 == 1:                                    # MULH
                val = _u32((sa * sb) >> 32)
            elif f3 == 2:                                    # MULHSU
                val = _u32((sa * b) >> 32)
            elif f3 == 3:                                    # MULHU
                val = _u32((a * b) >> 32)
            elif f3 == 4:                                    # DIV
                if sb == 0:
                    val = 0xFFFFFFFF
                elif sa == -0x80000000 and sb == -1:
                    val = 0x80000000
                else:
                    val = _u32(_trunc_div(sa, sb))
            elif f3 == 5:                                    # DIVU
                val = 0xFFFFFFFF if b == 0 else _u32(a // b)
            elif f3 == 6:                                    # REM
                if sb == 0:
                    val = _u32(sa)
                elif sa == -0x80000000 and sb == -1:
                    val = 0
                else:
                    val = _u32(sa - sb * _trunc_div(sa, sb))
            else:                                            # REMU
                val = _u32(a) if b == 0 else _u32(a % b)
        elif opcode in (0x13, 0x33):                         # OP-IMM / OP
            if opcode == 0x13:
                operand = _u32(_sx(instr >> 20, 12))
                alt = (f7 == 0x20) and f3 == 5                # SRAI
                shamt = (instr >> 20) & 0x1F
            else:
                operand = b
                alt = f7 == 0x20                              # SUB / SRA
                shamt = b & 0x1F
            if f3 == 0:
                val = _u32(a - operand) if (alt and opcode == 0x33) else _u32(a + operand)
            elif f3 == 1:
                val = _u32(a << shamt)
            elif f3 == 2:
                val = int(_sx(a, 32) < _sx(operand, 32))
            elif f3 == 3:
                val = int(a < operand)
            elif f3 == 4:
                val = a ^ operand
            elif f3 == 5:
                val = _u32(_sx(a, 32) >> shamt) if alt else (a >> shamt)
            elif f3 == 6:
                val = a | operand
            else:
                val = a & operand
        elif opcode in (0x0F, 0x73):
            # FENCE / SYSTEM. The core decodes these to q_unknown and executes
            # them as NOPs; match that so a generator emitting one does not
            # produce a spurious mismatch.
            pass
        else:
            raise Trap(f"unimplemented opcode 0x{opcode:02x} at 0x{self.pc:08x}")

        if val is not None and rd != 0:
            self.x[rd] = _u32(val)
        self.x[0] = 0
        self.pc = next_pc

    def run(self, max_steps=2_000_000):
        for _ in range(max_steps):
            if self.halted:
                return True
            self.step()
        return False

    def read(self, addr, n):
        return bytes(self.mem[addr:addr + n])


if __name__ == "__main__":
    import sys
    sys.exit("this is a library; see rv32_diff.py")
