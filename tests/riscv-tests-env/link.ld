/* Link script for the riscv-tests rv32ui suite.
 *
 * Same split as ld.script -- .text into the instruction memory at 0x00010000,
 * everything else into the data memory at 0x00020000 -- but it also collects
 * the .text.* / .rodata.* / .data.* variants the suite emits, and drops the
 * .tohost section its macros reference but this environment does not use.
 */
SECTIONS
{
  . = 0x00010000;
  .text         : { *(.text.init) *(.text) *(.text.*) }

  . = 0x00020000;
  .rodata       : { *(.rodata) *(.rodata.*) }
  .data         : { *(.data) *(.data.*) }
  .bss          : { *(.bss) *(.bss.*) *(COMMON) }

  /DISCARD/     : { *(.tohost) *(.comment) *(.riscv.attributes) }
}
