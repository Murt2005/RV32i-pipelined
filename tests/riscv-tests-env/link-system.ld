/* Runs the riscv-tests from SDRAM, so every fetch goes through the instruction
 * cache and every load and store through the data cache. A stub at the reset
 * PC jumps there, and tohost stays where the testbench watches for it.
 */
SECTIONS
{
  .boot   0x00010000 : { *(.boot) }
  .tohost 0x0002FFC0 : { *(.tohost) }

  .text   0x80000000 : { *(.text.init) *(.text) *(.text.*) }
  .rodata            : { *(.rodata) *(.rodata.*) }
  .data              : { *(.data) *(.data.*) }
  .bss               : { *(.bss) *(.bss.*) *(COMMON) }

  /DISCARD/          : { *(.comment) *(.riscv.attributes) }
}
