/* Link script for C benchmarks in the system configuration: a boot stub in IMEM
 * jumps to the program in SDRAM. The stack stays in DMEM, where crt0.s puts it
 */
SECTIONS
{
  .boot   0x00010000 : { *(.boot) }

  .text   0x80000000 : { *(.text.init) *(.text) *(.text.*) }
  .rodata            : { *(.rodata) *(.rodata.*) }
  .data              : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) }
  .bss               : { *(.bss) *(.bss.*) *(.sbss) *(.sbss.*) *(COMMON) }

  /DISCARD/          : { *(.comment) *(.riscv.attributes) }
}
