/* Shared definitions for the SoC peripheral tests (tb/tb_soc_periph.v).
 *
 * The programs boot from flash (link.ld) and talk to the testbench through
 * word stores to the syscon window, which the testbench watches on the
 * core's data port. s11 holds SYSCON in every program.
 *
 *   SYSCON + 0x000  FINISH  QEMU sifive_test codes: 0x5555 pass,
 *                           (code << 16) | 0x3333 fail with code 1..0xFFFF,
 *                           0x7777 reboot (never written here)
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
    slli a6, a6, 16
    li   t5, FINISH_FAIL
    or   a6, a6, t5
    j    87f
test_pass:
    li   a6, FINISH_PASS
87:
    sw   a6, MB_FINISH(s11)
1:  j    1b
.endm
