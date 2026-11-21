# The instruction cache through its register (WO-62 / WO-66 SF4): CACHE_CTL at 0x1002_0024, written and read through the
# bus, no bench force. The register reads {30'b0, 1, en}.
#   1  the register: write 0 reads 2, write 1 reads 3, a byte store to lane 0 only (bit 0 is the only flop), then a
#      word write of 0xFFFFFFFE (EN = 0 again; the upper bits are read-only).
#   2  hits: the same 4-instruction loop from flash, 100 iterations, timed with mcycle with the cache off and then on.
#      On the cache a loop that fits the 128 bytes runs from hits, so it takes less than half the time. A bench run
#      with +CACHE_EN forces EN on (a write cannot clear it): that shows as the read-back of the 0 write being 3 and
#      the speed check is skipped.
#   3  self-modifying code with EN = 1: copy a 3-word routine to PSRAM (0x8000_1000), run it (it fills a line), rewrite
#      word 0 (li a0, 2), FENCE.I, run it: the new code, not the cached one (2). Rewrite word 1 (addi a0, a0, 10), FENCE.I,
#      run: 12. A store snoops the line, FENCE.I flushes everything; the program needs only the second.
#   4  EN = 0 again: the same routine rewritten (li a0, 7) and run gives 17, the timed loop still runs.
# Failure codes: 0x01-0x05 the register, 0x10 speed, 0x2n self-modifying code, 0x3n after EN = 0.
#include "periph4.h"
#define CACHE_CTL 0x10020024
#define CODE      0x80001000
#define I_LI1     0x00100513          /* addi a0, zero, 1 */
#define I_LI2     0x00200513          /* addi a0, zero, 2 */
#define I_LI7     0x00700513          /* addi a0, zero, 7 */
#define I_ADD10   0x00a50513          /* addi a0, a0, 10 */
#define I_NOP     0x00000013          /* addi zero, zero, 0 */
#define I_RET     0x00008067          /* jalr zero, 0(ra) */

# cycles of 100 loop iterations into \dst (clobbers t1-t4)
.macro TIMED dst
    li   t1, 100
    li   t2, 0
    .balign 16
    csrr t3, mcycle
1:  addi t1, t1, -1
    add  t2, t2, t1
    xor  t4, t2, t1
    bnez t1, 1b
    csrr t4, mcycle
    sub  \dst, t4, t3
.endm
# write the routine's word \n (0 or 1) and make it visible
.macro PATCH n, insn
    li   t1, CODE + 4 * \n
    li   t2, \insn
    sw   t2, 0(t1)
    fence.i
.endm
# call the routine, result in a0
.macro CALLR
    li   t0, CODE
    jalr ra, 0(t0)
.endm

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   s1, CACHE_CTL

    # 1: the register
    sw   zero, 0(s1)
    lw   t0, 0(s1)
    andi s2, t0, 1                # s2 = 1: the bench forces EN on
    bnez s2, 1f
    CHECK t0, 2, 0x01
1:  li   t0, 1
    sw   t0, 0(s1)
    lw   t0, 0(s1)
    CHECK t0, 3, 0x02
    sw   zero, 0(s1)
    lw   t0, 0(s1)
    andi t0, t0, 2
    CHECK t0, 2, 0x03
    li   t0, 0xFFFFFFFE           # EN = 0, the upper bits ignored
    sw   t0, 0(s1)
    lw   t0, 0(s1)
    bnez s2, 2f
    CHECK t0, 2, 0x04
2:

    # 2: hits (cache off first, the cold cache then on)
    TIMED s3
    li   t0, 1
    sb   t0, 0(s1)
    lw   t0, 0(s1)
    CHECK t0, 3, 0x05
    TIMED s4
    bnez s2, 3f
    slli t0, s4, 1
    bltu t0, s3, 3f               # on < off / 2
    mv   a7, s3
    li   a6, 0x10
    li   t0, 0
    sw   s4, MB_VALUE2(s11)
    j    test_fail
3:

    # 3: self-modifying code with EN = 1
    li   t1, CODE
    li   t2, I_LI1
    sw   t2, 0(t1)
    li   t2, I_NOP
    sw   t2, 4(t1)
    li   t2, I_RET
    sw   t2, 8(t1)
    fence.i
    CALLR
    CHECK a0, 1, 0x20
    CALLR                         # again, from the cache
    CHECK a0, 1, 0x21
    PATCH 0, I_LI2
    CALLR
    CHECK a0, 2, 0x22
    CALLR
    CHECK a0, 2, 0x23
    PATCH 1, I_ADD10
    CALLR
    CHECK a0, 12, 0x24

    # 4: EN = 0 again
    sw   zero, 0(s1)
    lw   t0, 0(s1)
    andi t0, t0, 2
    CHECK t0, 2, 0x30
    PATCH 0, I_LI7
    CALLR
    CHECK a0, 17, 0x31
    TIMED s5
    li   t0, 1
    sw   t0, 0(s1)                # leave it on: the finish runs from hits
    j    test_pass
    EPILOGUE
