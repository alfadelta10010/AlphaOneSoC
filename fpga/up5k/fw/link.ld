/* flash at 0x2000_0000 (code + rodata), bss in PSRAM A at 0x8000_0000, stack below 0x8001_0000 */
ENTRY(_start)
MEMORY {
    FLASH (rx)  : ORIGIN = 0x20000000, LENGTH = 1M
    PSRAM (rwx) : ORIGIN = 0x80000000, LENGTH = 32K
    RAMC  (rwx) : ORIGIN = 0x80020000, LENGTH = 16K   /* code that must run while flash is in a mode under test */
}
SECTIONS {
    .text : { *(.text.start) *(.text*) } > FLASH
    .rodata : { *(.rodata*) *(.srodata*) } > FLASH
    .pattern ALIGN(1024) : { KEEP(*(.pattern)) } > FLASH
    .ramcode : { _ramcode = .; *(.ramcode*) . = ALIGN(4); _eramcode = .; } > RAMC AT> FLASH
    _ramcode_lma = LOADADDR(.ramcode);
    .bss (NOLOAD) : { _bss = .; *(.bss*) *(.sbss*) *(COMMON) _ebss = .; } > PSRAM
    /DISCARD/ : { *(.comment) *(.riscv.attributes) *(.eh_frame*) }
}
ASSERT(SIZEOF(.data) == 0, "no initialised .data: keep globals zero-initialised")
_stack_top = 0x80010000;
