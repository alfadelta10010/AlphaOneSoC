/* Two position-independent leaf functions of identical size for the cache snoop test (T4).
   fn_a(x) = x + 0x111, fn_b(x) = x + 0x222; both are 4 words of 32-bit instructions:
   word 0 and 3 are the same in both, so a patch of word 1 or one byte of it changes the result. */
    .option push
    .option norvc
    .section .text
    .balign 16
    .globl fn_a
fn_a:
    addi a0, a0, 0x111     /* word 0 */
    nop                    /* word 1 */
    nop                    /* word 2 */
    jalr x0, 0(ra)         /* word 3 */
    .globl fn_a_end
fn_a_end:
    .balign 16
    .globl fn_b
fn_b:
    addi a0, a0, 0x222
    nop
    nop
    jalr x0, 0(ra)
    .globl fn_b_end
fn_b_end:
    .option pop
