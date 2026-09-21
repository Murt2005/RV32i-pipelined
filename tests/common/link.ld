SECTIONS
{
  . = 0x00010000;
  .text         : { *(.text)   }
  . = 0x00020000;
  .rodata       : { *(.rodata) }
  .data         : { *(.data)   }
  .bss          : { *(.bss)    }
}
