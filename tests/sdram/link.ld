/*
 * Link a program to run out of SDRAM.
 *
 * The core resets to 0x00010000, which is on-chip instruction memory and only
 * 64 KiB -- smaller than anything with a C library in it. So the reset address
 * holds a stub whose whole job is to jump to SDRAM, and everything else lives
 * there.
 *
 * .data and .bss are in SDRAM too, not in the on-chip data memory. Doom's zone
 * heap alone is larger than that memory, and splitting the program across two
 * regions to save a few cycles on globals would buy nothing.
 *
 * The MMIO block is still at 0x0002FFC0 and the stack still starts below it,
 * because print and halt go through those registers and the existing runtime
 * expects them there. The heap grows up from _end in SDRAM instead.
 */

/* --gc-sections needs a root to trace from, and the boot stub must survive
 * whether or not anything references it. Without both of these the linker
 * discards the entire program and produces a valid, empty ELF. */
ENTRY(_start)

MEMORY
{
    boot  (rx)  : ORIGIN = 0x00010000, LENGTH = 64K
    sdram (rwx) : ORIGIN = 0x80000000, LENGTH = 64M
}

SECTIONS
{
    /* The stub, at the reset address. */
    .boot : { KEEP(*(.boot)) } > boot

    .text : {
        *(.text.init)
        *(.text)
        *(.text.*)
    } > sdram

    .rodata : {
        *(.rodata)
        *(.rodata.*)
        *(.srodata*)
    } > sdram

    .data : {
        *(.data)
        *(.data.*)
        *(.sdata*)
    } > sdram

    .bss : {
        __bss_start = .;
        *(.bss)
        *(.bss.*)
        *(.sbss*)
        *(COMMON)
        __bss_end = .;
    } > sdram

    . = ALIGN(16);
    _end = .;                 /* start of the heap, for sbrk */

    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.tohost) }
}
