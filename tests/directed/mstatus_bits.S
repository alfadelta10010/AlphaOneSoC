# mstatus writable-bit probe. misa advertises U, so the privileged spec
# requires MPRV (17) and TW (21) to be writable.
.section .text.init
.option norvc
.globl rvtest_entry_point
rvtest_entry_point:
    li   t0, -1
    csrw mstatus, t0
    csrr a0, mstatus           # expect 0x00221888 once MPRV+TW exist
    li   t0, 0x00020000        # MPRV alone
    csrw mstatus, t0
    csrr a1, mstatus
    li   t0, 0x00200000        # TW alone
    csrw mstatus, t0
    csrr a2, mstatus
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
