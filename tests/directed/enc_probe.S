# Each probe: a0 <- 0xdead; <insn>; the handler puts mcause|0x100 into a0 and skips.
# The trace shows either the CSR value read or the trap cause.
  .option norvc
  .section .text.init
  .globl rvtest_entry_point
rvtest_entry_point:
  li   a1, 0                  # the amoadd probe's address (x-regs are not reset)
  la   t0, handler
  csrw mtvec, t0
#define P(...) li a0, 0xdead; __VA_ARGS__; mv s1, a0
  P(.word 0x10200073)        /* sret */
  P(.word 0x10000073)        /* funct7=0001000 rs2=0 (reserved) */
  P(.word 0x10400073)        /* funct7=0001000 rs2=4 (reserved) */
  P(.word 0x12000073)        /* sfence.vma x0,x0 */
  P(.word 0x7b200073)        /* dret */
  P(.word 0x70200073)        /* mnret */
  li s0, 0x80800000
  P(.word 0x1014252f)        /* lr.w a0,(s0) with rs2=1 (reserved) */
  P(.word 0x0000100f)        /* fence.i */
  P(.word 0x8330000f)        /* fence.tso */
  P(.word 0x0100000f)        /* pause */
  P(.word 0x30500073)        /* mret enc rs2=5 */
  /* (no WFI probe: Spike sleeps on a WFI with nothing pending and stops logging) */
  P(.word 0x10502073)        /* wfi-like funct3=010 -> csrrs x0,0x105 */
  P(.word 0x0000000f)        /* fence 0 */
  P(.word 0x0ff0400f)        /* fence with funct3=100 (reserved) */
  P(.word 0x00000073)        /* ecall */
  P(.word 0x00100073)        /* ebreak */
  P(.word 0x00200073)        /* uret (removed) */
  P(.word 0x0000500b)        /* custom-0 */
  P(.word 0x00001073)        /* csrrw x0, 0x000 (ustatus, absent) */
  P(.word 0xc0001073)        /* csrrw x0, cycle, x0 (RO write) */
  P(.word 0x34002573)        /* csrr a0, mscratch: legal (a cycle read would differ by design) */
  P(.word 0x00a5a52f)        /* amoadd.w a0,a0,(a1)? reserved check */
  li t0, 1
  la t1, tohost
  sw t0, 0(t1)
1: j 1b
  .align 2
handler:
  csrr a0, mcause
  ori  a0, a0, 0x100
  csrr t6, mepc
  addi t6, t6, 4
  csrw mepc, t6
  mret
  .section .tohost,"aw",@progbits
  .align 6
  .globl tohost
tohost: .dword 0
  .align 6
  .globl fromhost
fromhost: .dword 0
