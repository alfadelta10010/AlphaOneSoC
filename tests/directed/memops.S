# store/load mix across all widths -- catches a dropped store or a load that
# samples dmem_rdata before the handshake completes.
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    li  t0, 0x81000000
    li  t1, 0x12345678
    sw  t1, 0(t0)
    li  t2, 0x9abcdef0
    sw  t2, 4(t0)
    lw  a0, 0(t0)
    lw  a1, 4(t0)
    li  t3, 0x0badf00d
    sw  t3, 8(t0)
    lw  a3, 8(t0)
    li  a4, 0x000000ff
    sb  a4, 12(t0)
    lbu a5, 12(t0)
    li  t4, 1
    la  t5, tohost
    sw  t4, 0(t5)
1:  j 1b
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
