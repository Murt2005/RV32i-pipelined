/* Link script for the *stock* riscv-tests `p` environment.
 *
 * Same memory split as link.ld, plus a placement for the .tohost section the
 * stock environment reports results through. tohost is `.align 6` inside that
 * section, so the section base must be 64-byte aligned -- which is why this
 * cannot simply be the existing halt register at 0x0002FFFC. The tops treat a
 * write to 0x0002FFC0 as a halt as well, and surface the value written.
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
