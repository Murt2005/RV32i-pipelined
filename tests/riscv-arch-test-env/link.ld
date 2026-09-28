/* Places riscv-arch-test tests at the start of SDRAM, the one memory both fetch
 * and loads reach; the boot stub in IMEM jumps there. The framework needs
 * .text.init and .text.rvtest as separate sections, and .text.rvmodel after the
 * data: its code differs between the DUT and Sail builds, and mustn't move the
 * data the tests check. The size limit matches sdram_bytes in sim/top.sv and the
 * SDRAM region in sail.json
 */
OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)

SECTIONS
{
  . = 0x80000000;
  .text.init    : { *(.text.init) }
  .text.rvtest  : { *(.text.rvtest) *(.text.rvtest.*) }
  .rodata       : { *(.rodata) *(.rodata.*) *(.srodata) *(.srodata.*) }
  .data         : { *(.data) *(.data.*) *(.sdata) *(.sdata.*) }
  .tohost       : { *(.tohost) }
  .bss          : { *(.sbss) *(.sbss.*) *(.bss) *(.bss.*) *(COMMON) }
  .text.rvmodel : { *(.text.rvmodel) *(.text.rvmodel.*) *(.text) *(.text.*) }

  ASSERT(. <= 0x80100000, "test doesn't fit in the 1 MiB of SDRAM")
}
