OUTPUT_ARCH("riscv")
ENTRY(rvtest_entry_point)
SECTIONS { . = 0x80000000;
  .text.init : { *(.text.init) } . = ALIGN(0x1000);
  .tohost : { *(.tohost) } . = ALIGN(0x1000);
  .text : { *(.text) *(.text.*) }
  .fpage 0x800033FC : { *(.fpage) }
  .gpage 0x807FFFFC : { *(.gpage) }
  _end = .; }
