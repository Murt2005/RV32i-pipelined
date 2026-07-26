/* Link script for C benchmarks.
 *
 * ld.script collects only *(.text), which is fine for the hand-written
 * assembly tests but silently drops the .text.startup / .text.unlikely
 * sections GCC emits at -O2 -- the code links, and then jumps into nothing.
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
