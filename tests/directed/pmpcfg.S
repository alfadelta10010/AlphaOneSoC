# pmpcfg0 WARL read-back. 0x75 = L0 res11 A10(NA4) X1 W0 R1 -> expect 0x15.
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    li   t0, 0x75757575
    csrw pmpcfg0, t0
    csrr a0, pmpcfg0           # expect 0x15151515
    li   t0, 0x6f6f6f6f        # A01(TOR) -> expect 0x0f0f0f0f
    csrw pmpcfg0, t0
    csrr a1, pmpcfg0
    li   t4, 1
    la   t5, tohost
    sw   t4, 0(t5)
1:  j 1b
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
