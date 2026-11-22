	/* First-stage stub: the loader jumps here with a0 = a1 = 0. */
	.section .text
	.globl _start
_start:
	li	a0, 0			/* hartid */
	li	a1, DTB_ADDR
	li	t0, KERNEL_ADDR
	jr	t0
