/* Shared definitions for the SoC peripheral tests (tb/tb_soc_periph.v).
 *
 * The programs boot from flash (link.ld) and talk to the testbench through
 * word stores to the syscon window, which the testbench watches on the
 * core's data port. s11 holds SYSCON in every program.
 *
 *   SYSCON + 0x000  FINISH  QEMU sifive_test codes: 0x5555 pass,
 *                           (code << 16) | 0x3333 fail with code 1..0xFFFF,
 *                           0x7777 reboot (never written here). It is the
 *                           syscon's FINISH register: 0x5555 and 0x3333 power
 *                           the SoC off, so EPILOGUE drains the UART and the
 *                           SPI shifter before writing it.
 *   SYSCON + 0x7F0  EVENT   a test-specific cue to the testbench
 *   SYSCON + 0x7F4  VALUE   a value for the testbench to check
 *   SYSCON + 0x7F8  VALUE2  a second one (on a failure: the value seen)
 *   SYSCON + 0x7FC  spare   ignored by the testbench
 *
 * The syscon decodes its offsets in full: 0x7F0-0x7FC read 0, ignore writes
 * and alias no register (WO-12 R-MB-1). The words sit below 0x800 so a
 * 12-bit store offset reaches them from SYSCON.
 */
#define UART      0x10000000
#define GPIO      0x10010000
#define SYSCON    0x10020000
#define MTIMECMP  0x02004000
#define MTIME     0x0200BFF8

#define MB_FINISH 0x000
#define MB_EVENT  0x7F0
#define MB_VALUE  0x7F4
#define MB_VALUE2 0x7F8
#define MB_SPARE  0x7FC
#define FINISH_PASS  0x5555
#define FINISH_FAIL  0x3333       /* (code << 16) | FINISH_FAIL */
#define FINISH_RESET 0x7777

/* UART offsets and bits (16550) */
#define RBR 0
#define THR 0
#define DLL 0
#define IER 1
#define DLM 1
#define IIR 2
#define FCR 2
#define LCR 3
#define MCR 4
#define LSR 5
#define MSR 6
#define SCR 7
#define LSR_DR   0x01
#define LSR_OE   0x02
#define LSR_THRE 0x20
#define LSR_TEMT 0x40

/* The UART divisor after reset. The internal benches (tb_soc_periph,
 * tb_syscon_soc) build the SoC with UART_DIV_RESET(4); the chip's is 27
 * (docs/pins-and-peripherals.md), which the pins bench builds pass with
 * -DUART_DIV_RESET=27. A program that means "the reset divisor" writes this. */
#ifndef UART_DIV_RESET
#define UART_DIV_RESET 4
#endif

/* GPIO registers */
#define G_OUT  0x0
#define G_IN   0x4
#define G_DATA 0x8
#define G_CTRL 0xC

/* r == v, or fail with `code` (clobbers t5, a6, a7) */
.macro CHECK r, v, code
    li   t5, \v
    beq  \r, t5, 88f
    mv   a7, \r
    li   a6, \code
    j    test_fail
88:
.endm
/* r1 == r2, or fail with `code` */
.macro CHECKR r1, r2, code
    beq  \r1, \r2, 88f
    mv   a7, \r1
    li   a6, \code
    j    test_fail
88:
.endm
.macro EVENT code
    li   t5, \code
    sw   t5, MB_EVENT(s11)
.endm
#ifdef MB_UART
/* -DMB_UART: the mailbox also goes out over the UART, so a bench that sees
 * only the chip's pins (tb/tb_tt_um.v +TEST=soc) can take the reports and the
 * cues. The syscon stores stay, so the same build runs on the internal
 * benches. A frame is a tag byte 0x10-0x13 and, but for the cue, 4 bytes LE:
 *   0x10 code    EVENT_P         a cue the pins bench acts on
 *   0x11 word    VALUE
 *   0x12 word    VALUE2, in EPILOGUE's fail path
 *   0x13 word    FINISH, in EPILOGUE, after DRAIN and before the store
 * Every other byte the chip sends is the program's own traffic. A frame waits
 * for LSR.TEMT first (the program's own characters finish) and again at the
 * end. These macros clobber only t4, t5 and t6, the set DELAY already uses. */
#ifndef MB_CUE_WAIT
#define MB_CUE_WAIT 3000          /* clocks EVENT_P waits for the bench's action */
#endif
#define MB_LOG_BASE 0x80FFF000    /* irq_stall's log in the board's PSRAM B */
.macro MB_TEMT
    li   t6, UART
89: lbu  t5, LSR(t6)
    andi t5, t5, LSR_TEMT
    beqz t5, 89b
.endm
.macro MB_PUT r                   /* t6 = UART; sends the low byte of r */
89: lbu  t5, LSR(t6)
    andi t5, t5, LSR_THRE
    beqz t5, 89b
    sb   \r, THR(t6)
.endm
.macro MB_FRAME tag, r
    MB_TEMT
    li   t4, \tag
    MB_PUT t4
    MB_PUT \r
    srli t4, \r, 8
    MB_PUT t4
    srli t4, \r, 16
    MB_PUT t4
    srli t4, \r, 24
    MB_PUT t4
    MB_TEMT
.endm
/* A cue the pins bench acts on: the syscon store, then the frame, then
 * MB_CUE_WAIT clocks for the action to land. */
.macro EVENT_NW code             /* the cue frame alone, no wait */
    EVENT \code
    MB_TEMT
    li   t4, 0x10
    MB_PUT t4
    li   t4, (\code) & 0xFF
    MB_PUT t4
    MB_TEMT
.endm
.macro EVENT_P code
    EVENT_NW \code
    DELAY MB_CUE_WAIT
.endm
.macro VALUE r
    sw   \r, MB_VALUE(s11)
    MB_FRAME 0x11, \r
.endm
/* At each program's entry (every boot): MB_DIV sets the divisor. */
#ifdef MB_DIV
.macro MB_INIT
    li   t0, UART
    li   t1, 0x80
    sb   t1, LCR(t0)
    li   t1, MB_DIV
    sb   t1, DLL(t0)
    sb   zero, DLM(t0)
    sb   zero, LCR(t0)
.endm
#else
.macro MB_INIT
.endm
#endif
#else
.macro EVENT_P code
    EVENT \code
.endm
.macro VALUE r
    sw   \r, MB_VALUE(s11)
.endm
.macro MB_INIT
.endm
#endif
/* Spin until mtime has advanced by n clocks (clobbers t4, t5, t6). */
.macro DELAY n
    li   t6, MTIME
    lw   t5, 0(t6)
    li   t4, \n
    add  t4, t4, t5
89: lw   t5, 0(t6)
    blt  t5, t4, 89b
.endm
/* Wait until LSR has all of `bits` (base register b; clobbers t4, t5). */
.macro WAIT_LSR b, bits
89: lbu  t5, LSR(\b)
    andi t5, t5, \bits
    li   t4, \bits
    bne  t5, t4, 89b
.endm
/* Wait until the UART has sent its last stop bit (LSR.TEMT) and the SPI
 * shifter is idle: a GPIO write waits for it, and OUT is written back with
 * its own value. Clobbers t4, t5, t6. */
.macro DRAIN
    li   t6, UART
    WAIT_LSR t6, LSR_TEMT
    li   t6, GPIO
    lw   t5, G_OUT(t6)
    sw   t5, G_OUT(t6)
.endm
/* test_pass / test_fail, once per program */
.macro EPILOGUE
test_fail:
    sw   a7, MB_VALUE2(s11)
#ifdef MB_UART
    MB_FRAME 0x12, a7
#endif
    slli a6, a6, 16
    li   t5, FINISH_FAIL
    or   a6, a6, t5
    j    87f
test_pass:
    li   a6, FINISH_PASS
87:
    DRAIN
#ifdef MB_UART
    MB_FRAME 0x13, a6
#endif
    sw   a6, MB_FINISH(s11)
1:  j    1b
.endm
