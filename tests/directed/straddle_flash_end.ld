OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)
SECTIONS { . = 0x20000000;
  .text.init : { *(.text.init) }
  .text : { *(.text) *(.text.*) }
  .rodata : { *(.rodata) *(.rodata.*) }
  . = 0x20FFFFFE;
  .straddle : { *(.straddle) }
  . = 0x80001000;
  .tohost (NOLOAD) : { *(.tohost) }
  _end = .; }
