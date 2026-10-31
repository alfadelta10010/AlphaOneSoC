# Five boots through four reboots, each decided from BOOT_MODE (which a reboot
# keeps), none from memory. The first thing every boot does is report mtime:
# the CLINT restarts with the SoC, so the bench sees the same count each time
# (VALUE, five reports).
#
#   boot 1  bm 0     cause 0x1: dirty the SoC (GPIO OUT, mtimecmp, msip, the
#                    UART divisor and LCR), set BOOT_MODE 0x5A, reboot with sw
#   boot 2  bm 0x5A  cause 0x3: everything dirty is back at its reset value;
#                    W1C SOFT; BOOT_MODE 0xC3; reboot with sh 0x7777
#   boot 3  bm 0xC3  cause 0x3: BOOT_MODE 0x96; reboot with sw 0x12347777
#   boot 4  bm 0x96  cause 0x3: BOOT_MODE 0x01 by syscon-reboot-mode's
#                    read-modify-write; reboot as Linux's syscon-reboot does
#                    (read FINISH, or in the value, write it)
#   boot 5  bm 0x01  cause 0x3: pass
#
# Cue: 0x51 = about to reboot out of boot 1 (once).
# Failure codes: 0x1nn boot 1, 0x2nn boot 2, 0x3nn boot 3, 0x4nn boot 4,
# 0x5nn boot 5.
#include "periph.h"

#define CLINT 0x02000000

# The reboot store as a whole word at a word boundary, with the next
# instruction in the next word: the core is already fetching it when the store
# completes, so the reboot cuts a flash fetch in flight. (After a store
# followed by a compressed instruction in the same word the engine is idle.)
.macro REBOOT_ON_FETCH r
    .option push
    .option norvc
    .balign 4
    sw   \r, 0(s11)
    nop
    .option pop
.endm

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    MB_INIT
    li   t6, MTIME
    lw   t0, 0(t6)
    VALUE t0                         # mtime at the start of the boot
    lw   s0, 4(s11)                  # RESET_CAUSE
    lw   s1, 8(s11)                  # BOOT_MODE
    beqz s1, boot1
    li   t0, 0x5A
    beq  s1, t0, boot2
    li   t0, 0xC3
    beq  s1, t0, boot3
    li   t0, 0x96
    beq  s1, t0, boot4
    li   t0, 0x01
    beq  s1, t0, boot5
    li   a6, 0x100                   # a BOOT_MODE nobody wrote
    mv   a7, s1
    j    test_fail

boot1:
    CHECK s0, 0x1, 0x101
    # dirty everything a reboot has to clean
    li   t0, GPIO
    li   t1, 0xC0
    sw   t1, G_OUT(t0)
    li   t0, MTIMECMP
    sw   zero, 4(t0)                 # mtimecmp = 0, high half first (mie stays 0)
    sw   zero, 0(t0)
    li   t0, CLINT
    li   t1, 1
    sw   t1, 0(t0)                   # msip
    li   t0, UART
    li   t1, 0x80
    sb   t1, LCR(t0)                 # DLAB
    li   t1, 5
    sb   t1, DLL(t0)
    li   t1, 0x03
    sb   t1, LCR(t0)                 # 8 bits, DLAB off
    li   t1, 0x5A
    sw   t1, 8(s11)                  # BOOT_MODE
    EVENT 0x51
    li   t1, 0x7777
    REBOOT_ON_FETCH t1               # reboot, cutting a fetch
1:  j    1b

boot2:
    CHECK s0, 0x3, 0x201
    lw   t0, 0x10(s11)
    CHECK t0, 0, 0x202               # STRAPS
    li   t0, MTIMECMP
    lw   t1, 0(t0)
    CHECK t1, 0xFFFFFFFF, 0x203      # mtimecmp back to all ones
    lw   t1, 4(t0)
    CHECK t1, 0xFFFFFFFF, 0x204
    li   t0, CLINT
    lw   t1, 0(t0)
    CHECK t1, 0, 0x205               # msip
    csrr t1, mip
    CHECK t1, 0, 0x206               # no timer or software interrupt pending
    li   t0, GPIO
    lw   t1, G_OUT(t0)
    CHECK t1, 0x89, 0x207
    li   t0, UART
    lbu  t1, LCR(t0)
    CHECK t1, 0, 0x208
    li   t2, 0x80
    sb   t2, LCR(t0)
    lbu  t1, DLL(t0)
    CHECK t1, UART_DIV_RESET, 0x209   # the bench's UART_DIV_RESET
    sb   zero, LCR(t0)
    lbu  t1, LSR(t0)
    CHECK t1, 0x60, 0x20A
    li   t1, 2
    sw   t1, 4(s11)                  # W1C SOFT
    lw   t1, 4(s11)
    CHECK t1, 0x1, 0x20B
    li   t1, 0xC3
    sw   t1, 8(s11)
    li   t1, 0x7777
    sh   t1, 0(s11)                  # reboot, halfword form
1:  j    1b

boot3:
    CHECK s0, 0x3, 0x301
    li   t1, 0x96
    sw   t1, 8(s11)
    li   t1, 0x12347777
    REBOOT_ON_FETCH t1               # reboot: the upper half is ignored
1:  j    1b

boot4:
    CHECK s0, 0x3, 0x401
    lw   t0, 8(s11)                  # syscon-reboot-mode: read, mask 0xff, magic, write
    andi t0, t0, -256
    ori  t0, t0, 0x01
    sw   t0, 8(s11)
    lw   t1, 8(s11)
    CHECK t1, 0x01, 0x402
    lw   t0, 0(s11)                  # syscon-reboot: read the register (reads 0) ...
    CHECK t0, 0, 0x403
    li   t2, 0x7777
    or   t0, t0, t2                  # ... or in the value, write it
    sw   t0, 0(s11)
1:  j    1b

boot5:
    CHECK s0, 0x3, 0x501
    j    test_pass

    EPILOGUE
