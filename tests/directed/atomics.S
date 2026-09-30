# AMO + LR/SC on main memory. The AMO read phase samples dmem_rdata, so this
# is the test that catches an ungated amo_old_val capture.
.section .text.init
.globl rvtest_entry_point
rvtest_entry_point:
    li  t0, 0x80800000
    li  t1, 0x00000100
    sw  t1, 0(t0)
    li  t2, 0x00000011
    amoadd.w a0, t2, (t0)
    lw  a1, 0(t0)
    li  t3, 0x000000f0
    amoor.w  a2, t3, (t0)
    lw  a3, 0(t0)
    lr.w     a4, (t0)
    li  t4, 0x0000beef
    sc.w     a5, t4, (t0)
    lw  a6, 0(t0)
    li  t5, 1
    la  t6, tohost
    sw  t5, 0(t6)
1:  j 1b
.section .tohost, "aw", @progbits
.align 6
.globl tohost
tohost: .dword 0
.align 6
.globl fromhost
fromhost: .dword 0
