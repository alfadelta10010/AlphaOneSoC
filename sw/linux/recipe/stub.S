	/* First-stage stub: the loader jumps here with a0 = a1 = 0. */
	.section .text
	.globl _start
_start:
	csrwi	mcounteren, 7		/* boot contract rule 9: U-mode rdcycle/rdtime/rdinstret (resets to 0; the DT says zicntr) */
	li	a0, 0			/* hartid */
	li	a1, DTB_ADDR
	li	t0, KERNEL_ADDR
	jr	t0
