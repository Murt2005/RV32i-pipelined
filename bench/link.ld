/* Link script for C benchmarks. It collects .text.* too, since GCC puts code in
 * .text.startup and .text.unlikely at -O2
 */
SECTIONS
{
  . = 0x00010000;
  .text   : { *(.text.init) *(.text) *(.text.*) }

  . = 0x00020000;
  .rodata : { *(.rodata) *(.rodata.*) }
  .data   : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) }
  .bss    : { *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON) }

  /DISCARD/ : { *(.comment) *(.riscv.attributes) }
}
