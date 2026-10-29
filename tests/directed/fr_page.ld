OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)
SECTIONS { . = 0x80000000;
  .text.init : { *(.text.init) }
  .page1 0x800003F0 : { *(.page1) }
  .page2 0x800007F2 : { *(.page2) }
  . = ALIGN(0x1000);
  .tohost : { *(.tohost) } . = ALIGN(0x1000);
  .text : { *(.text) *(.text.*) } . = ALIGN(0x1000);
  .data : { *(.data) *(.data.*) } .bss : { *(.bss) }
  .page3 0x807FFFC0 : { *(.page3) }
  .page4 0x807FFFEA : { *(.page4) }
  _end = .; }
