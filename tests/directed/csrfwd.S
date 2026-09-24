# Back-to-back csrw/csrr so the read is served by the EX forwarding path
# rather than the register, exercising fyracore's copy of csr.v's WARL masks.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    csrci misa, 4              # IALIGN=32 for the mepc probe
    nop
    nop
    li   t0, -1
    csrw mcountinhibit, t0
    csrr a0, mcountinhibit     # expect 0x00000005
    li   t0, 0x80000102
    csrw mepc, t0
    csrr a1, mepc              # expect 0x80000100
    li   t0, -1
    csrw mcounteren, t0
    csrr a2, mcounteren        # expect 0x00000007
    li   t0, -1
    csrw mie, t0
    csrr a3, mie               # expect 0x00000888
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
