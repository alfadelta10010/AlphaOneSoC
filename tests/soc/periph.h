/* Shared definitions for the SoC peripheral tests (tb/tb_soc_periph.v).
 *
 * The programs boot from flash (link.ld) and talk to the testbench through
 * a mailbox in the reserved syscon window, which the SoC ignores: the
 * testbench watches the core's data port for stores there.
 *
 *   SYSCON + 0x0  FINISH  1 = pass; anything else = the failing check's code
 *   SYSCON + 0x4  EVENT   a test-specific cue to the testbench
 *   SYSCON + 0x8  VALUE   a value for the testbench to check
 *   SYSCON + 0xC  VALUE2  a second one (on a failure: the value seen)
 *
 * s11 holds SYSCON in every program.
 */
#define UART      0x10000000
#define GPIO      0x10010000
#define SYSCON    0x10020000
#define MTIMECMP  0x02004000
#define MTIME     0x0200BFF8

#define MB_FINISH 0x0
#define MB_EVENT  0x4
#define MB_VALUE  0x8
#define MB_VALUE2 0xC

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
.macro VALUE r
    sw   \r, MB_VALUE(s11)
.endm
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
/* test_pass / test_fail, once per program */
.macro EPILOGUE
test_fail:
    sw   a7, MB_VALUE2(s11)
    sw   a6, MB_FINISH(s11)
1:  j    1b
test_pass:
    li   t5, 1
    sw   t5, MB_FINISH(s11)
1:  j    1b
.endm
