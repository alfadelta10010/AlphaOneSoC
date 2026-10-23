# Every access shape the core can make, aimed at the peripherals: byte,
# halfword and word loads and stores, AMOs, the 64 KB window aliases,
# misaligned accesses (which trap before reaching the bus), and a syscon word no
# hardware implements (the mailbox's spare word). The core drives dmem_be on loads too, so a load's width decides
# which registers it touches: only a load covering offset 0 pops RBR, only
# one covering offset 5 clears OE.
#
# Cues: 0x10 = the RP2350 sends VALUE's low byte (CTS on); 0x20 = the
# testbench checks gpio_out == VALUE; 0x21 = it drives IN with 0xA4 (bits
# 7-4 and 2-1: in[3] is the UART's RX line, idle high, and in[0] the
# rd_late strap, 0); 0x30 = the next SPI bytes are captured from here.
#include "periph.h"

.macro RP_SEND byte
    li   t0, \byte
    VALUE t0
    EVENT 0x10
    WAIT_LSR s0, LSR_DR
.endm
.macro PINS v
    li   t0, \v
    VALUE t0
    EVENT 0x20
.endm

    .section .text.init
    .globl _start
_start:
    li   s11, SYSCON
    li   s0, UART
    li   s1, GPIO
    la   t0, trap
    csrw mtvec, t0

    # ---- UART loads, every width ----
    lw   t0, 4(s0)
    CHECK t0, 0x00B06000, 0x101  # SCR MSR LSR MCR
    lhu  t0, 4(s0)
    CHECK t0, 0x6000, 0x102      # LSR MCR
    lh   t0, 6(s0)
    CHECK t0, 0x00B0, 0x103      # SCR MSR
    lb   t0, 6(s0)
    CHECK t0, 0xFFFFFFB0, 0x104  # MSR, sign-extended
    lbu  t0, 6(s0)
    CHECK t0, 0xB0, 0x105
    lb   t0, 5(s0)
    CHECK t0, 0x60, 0x106
    lbu  t0, 2(s0)
    CHECK t0, 0x01, 0x107        # IIR
    lhu  t0, 2(s0)
    CHECK t0, 0x0001, 0x108      # LCR IIR
    lw   t0, 0(s0)               # LCR IIR IER RBR; RBR is undefined while DR = 0
    srli t0, t0, 8
    CHECK t0, 0x000100, 0x109
    # aliases: only address bits 2 and 1:0 reach the UART
    li   t2, 0x1000FFFE
    lbu  t0, 0(t2)
    CHECK t0, 0xB0, 0x10A        # offset 6
    li   t2, 0x10001235
    lbu  t0, 0(t2)
    CHECK t0, 0x60, 0x10B        # offset 5
    li   t2, 0x1000ABC4
    lw   t0, 0(t2)
    CHECK t0, 0x00B06000, 0x10C

    # ---- UART stores, every width ----
    li   t0, 0x0241
    sh   t0, 0(s0)               # THR 'A' and IER = THRI together
    lbu  t0, IER(s0)
    CHECK t0, 0x02, 0x110
    lbu  t0, IIR(s0)
    CHECK t0, 0x01, 0x111        # 'A' still going: THRE clear
    WAIT_LSR s0, LSR_TEMT
    lbu  t0, IIR(s0)
    CHECK t0, 0x02, 0x112
    li   t0, 0x80000042
    sw   t0, 0(s0)               # THR 'B' (DLAB still 0), IER 0, FCR 0, then LCR = DLAB
    lbu  t0, LCR(s0)
    CHECK t0, 0x80, 0x113
    lhu  t0, 0(s0)
    CHECK t0, 0x0004, 0x114      # DLM DLL = UART_DIV_RESET
    lbu  t0, IIR(s0)
    CHECK t0, 0x01, 0x115        # IER was cleared by the word store
    li   t0, 0x0004
    sh   t0, 0(s0)               # DLL/DLM rewritten, no THR write (DLAB)
    sb   zero, LCR(s0)
    lbu  t0, IER(s0)
    CHECK t0, 0x00, 0x116
    li   t0, 0x55
    sb   t0, SCR(s0)
    lbu  t0, SCR(s0)
    CHECK t0, 0x00, 0x117        # SCR reads 0
    sw   t0, 4(s0)               # a word store to offsets 4-7: all ignored
    lw   t0, 4(s0)
    li   t1, 0x00B00000          # (THRE and TEMT may be clear: 'B' may still go)
    srli t0, t0, 16
    slli t0, t0, 16
    CHECKR t0, t1, 0x118
    WAIT_LSR s0, LSR_TEMT

    # ---- UART AMOs ----
    addi t2, s0, 4
    amoor.w t0, zero, (t2)       # reads SCR MSR LSR MCR, writes them back: ignored
    CHECK t0, 0x00B06000, 0x120
    RP_SEND 'q'
    amoor.w t0, zero, (s0)       # read pops RBR; write puts the same word back:
    andi t0, t0, 0xFF            # THR = 'q', IER 0, FCR 0, LCR 0
    CHECK t0, 'q', 0x121
    lbu  t0, LSR(s0)
    andi t0, t0, LSR_DR
    CHECK t0, 0, 0x122
    WAIT_LSR s0, LSR_TEMT

    # ---- misaligned: trap, no bus access ----
    RP_SEND 'm'
    li   s4, 0                   # traps taken
    .option push
    .option norvc
    lh   t0, 1(s0)               # would cover offsets 1-2
    lw   t0, 2(s0)               # would cover offsets 2-5
    sh   t0, 3(s0)
    sw   t0, 1(s0)
    .option pop
    CHECK s4, 4, 0x130
    li   t1, 0x80000200          # the mtvals the handler logged
    lw   t0, 0(t1)
    CHECK t0, 0x10000001, 0x133
    lw   t0, 4(t1)
    CHECK t0, 0x10000002, 0x134
    lw   t0, 8(t1)
    CHECK t0, 0x10000003, 0x135
    lw   t0, 12(t1)
    CHECK t0, 0x10000001, 0x136
    lbu  t0, LSR(s0)
    CHECK t0, 0x61, 0x131        # DR still set: nothing popped
    lbu  t0, IER(s0)             # loads that miss offset 0 do not pop either
    lhu  t0, IIR(s0)
    lh   t0, 2(s0)
    lbu  t0, LCR(s0)
    lbu  t0, MCR(s0)
    lw   t0, 4(s0)
    lbu  t0, LSR(s0)
    CHECK t0, 0x61, 0x137
    lbu  t0, RBR(s0)
    CHECK t0, 'm', 0x132

    # ---- a syscon word no hardware implements reads 0, ignores writes ----
    li   t0, 0x5A5A5A5A
    sw   t0, MB_SPARE(s11)
    lw   t0, MB_SPARE(s11)
    CHECK t0, 0, 0x138

    # ---- GPIO ----
    lw   t0, G_OUT(s1)
    CHECK t0, 0x09, 0x140
    PINS 0x09
    li   t0, 0xFF
    sw   t0, G_OUT(s1)
    lw   t1, G_OUT(s1)
    CHECK t1, 0xCF, 0x141
    PINS 0xCF
    li   t0, 0x42
    sb   t0, G_OUT(s1)
    li   t0, 0x7E
    sb   t0, G_OUT+1(s1)         # lane 1: ignored
    lbu  t1, G_OUT(s1)
    CHECK t1, 0x42, 0x142
    li   t0, 0x0081
    sh   t0, G_OUT(s1)
    li   t0, 0x00FF
    sh   t0, G_OUT+2(s1)         # lanes 2-3: ignored
    lw   t1, G_OUT(s1)
    CHECK t1, 0x81, 0x143
    PINS 0x81
    EVENT 0x21                   # IN = 0xA4 on bits 7-4, 2-1
    lw   t0, G_IN(s1)
    CHECK t0, 0xAC, 0x144        # + RX idle (bit 3), strap 0 (bit 0)
    lb   t0, G_IN(s1)
    CHECK t0, 0xFFFFFFAC, 0x145
    lbu  t0, G_IN(s1)
    CHECK t0, 0xAC, 0x146
    lh   t0, G_IN(s1)
    CHECK t0, 0xAC, 0x147
    lhu  t0, G_IN+2(s1)
    CHECK t0, 0, 0x148
    li   t2, 0x1001FFF4          # IN, aliased
    lbu  t0, 0(t2)
    CHECK t0, 0xAC, 0x149
    lw   t0, G_DATA(s1)
    CHECK t0, 0, 0x14A           # DATA reads 0
    # AMOs on OUT
    li   t0, 0x40
    amoor.w t1, t0, (s1)
    CHECK t1, 0x81, 0x150
    PINS 0xC1
    li   t0, ~0x80
    amoand.w t1, t0, (s1)
    CHECK t1, 0xC1, 0x151
    PINS 0x41
    li   t0, 0x0F
    amoxor.w t1, t0, (s1)
    CHECK t1, 0x41, 0x152
    PINS 0x4E
    li   t0, 0x49
    amoswap.w t1, t0, (s1)       # CS# high, RES# high, SCK idle high
    CHECK t1, 0x4E, 0x153
    PINS 0x49
    # AMOs on CTRL
    addi t2, s1, G_CTRL
    li   t0, 0x2
    amoadd.w t1, t0, (t2)        # DIV 0 -> 1
    CHECK t1, 0x0, 0x160
    amoadd.w t1, t0, (t2)        # DIV 1 -> 2
    CHECK t1, 0x2, 0x161
    li   t0, 0x7
    amoor.w t1, t0, (t2)         # EN, DIV 3
    CHECK t1, 0x4, 0x162
    li   t0, 0x48
    sw   t0, G_OUT(s1)           # CS# low: the OLED model captures from here
    EVENT 0x30
    li   t0, 0x81
    sw   t0, G_DATA(s1)
    addi t2, s1, G_DATA
    li   t0, 0x7E
    amoswap.w t1, t0, (t2)       # read DATA (0) at once; the write waits for 0x81
    CHECK t1, 0, 0x163
    li   t0, 0x5A
    sh   t0, G_DATA(s1)          # a halfword store sends lane 0
    li   t0, 0x33
    sb   t0, G_DATA+1(s1)        # a byte store to lane 1 sends nothing
    addi t2, s1, G_CTRL
    li   t3, ~0x1
    li   t0, 0xC3
    sb   t0, G_DATA(s1)          # waits for 0x5A; the AMO is fetched meanwhile
    amoand.w t1, t3, (t2)        # reads CTRL while 0xC3 shifts; EN off waits for it
    CHECK t1, 0x107, 0x164       # EN, DIV 3, BUSY
    lw   t0, G_CTRL(s1)
    CHECK t0, 0x6, 0x165
    li   t0, 0x49
    sw   t0, G_OUT(s1)
    PINS 0x49
    WAIT_LSR s0, LSR_TEMT
    j    test_pass

    .align 2
trap:
    csrr a3, mcause
    csrr a4, mtval
    slli a5, s4, 2               # log mtval at 0x8000_0200 + 4 x trap number
    li   a2, 0x80000200
    add  a5, a5, a2
    sw   a4, 0(a5)
    csrr a5, mepc
    addi a5, a5, 4
    csrw mepc, a5
    addi s4, s4, 1
    # causes 4 (load misaligned) and 6 (store misaligned), in order: 4 4 6 6
    li   a5, 4
    li   a4, 3
    blt  s4, a4, 1f
    li   a5, 6
1:  bne  a3, a5, 2f
    mret
2:  mv   a7, a3
    li   a6, 0x3FE
    j    test_fail
    EPILOGUE
