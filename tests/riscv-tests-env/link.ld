/* Places the riscv-tests on this core's memory: code goes in instruction
 * memory, data in data memory. The tests report their result by writing to
 * tohost at 0x0002FFC0, and the testbench stops when it sees the write there.
 */
SECTIONS
{
  . = 0x00010000;
  .text         : { *(.text.init) *(.text) *(.text.*) }

  . = 0x00020000;
  .rodata       : { *(.rodata) *(.rodata.*) }
  .data         : { *(.data) *(.data.*) }
  .bss          : { *(.bss) *(.bss.*) *(COMMON) }

  . = 0x0002FFC0;
  .tohost       : { *(.tohost) }

  /DISCARD/     : { *(.comment) *(.riscv.attributes) }
}
