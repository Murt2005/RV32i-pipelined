.text
.globl mmio_read32
.globl mmio_write32
.globl mmio_read8
.globl mmio_write8

mmio_read32:
    lw  a0, 0(a0)
    ret

mmio_write32:
    sw  a1, 0(a0)
    ret

mmio_read8:
    lb  a0, 0(a0)
    ret

mmio_write8:
    sb  a1, 0(a0)
    ret


