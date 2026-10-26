/* RISCOF model header for the SoC (plugins/riscof_plugins/fyracore/env/model_test.h
 * with the halt changed): the signature sits in .data, which is PSRAM, so the
 * bench reads it from the Pmod model. RVMODEL_HALT stores 1 to tohost first,
 * which ends the run on Spike before any MMIO access (one ELF serves both),
 * then on the chip sends 'S' (and with -DSOC_SIG_UART the signature, raw),
 * drains and powers off. */
#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H
#include "soc_report.h"
#if XLEN == 64
  #define ALIGNMENT 3
#else
  #define ALIGNMENT 2
#endif

#define RVMODEL_DATA_SECTION \
        .pushsection .tohost,"aw",@progbits;                            \
        .align 8; .global tohost; tohost: .dword 0;                     \
        .align 8; .global fromhost; fromhost: .dword 0;                 \
        .popsection;                                                    \
        .align 8; .global begin_regstate; begin_regstate:               \
        .word 128;                                                      \
        .align 8; .global end_regstate; end_regstate:                   \
        .word 4;

#ifdef SOC_SIG_UART
#define SOC_DUMP SOC_SIG_DUMP;
#else
#define SOC_DUMP
#endif

#define RVMODEL_HALT                                                    \
  fence;                                                                \
  li x1, 1;                                                             \
  write_tohost:                                                         \
    sw x1, tohost, t2;                                                  \
    fence;                                                              \
    SOC_UART_INIT;                                                      \
    li a0, 'S';                                                         \
    SOC_PUTC a0;                                                        \
    SOC_DUMP                                                            \
    SOC_DRAIN;                                                          \
    li a4, 0x5555;                                                      \
    SOC_FINISH a4;

#define RVMODEL_BOOT                                                    \
    csrr t1, mtvec; \
    la t0, 1f; \
    csrw mtvec, t0; \
    csrwi 0x744, 0x8; \
1:  la t0, 2f; \
    csrw mtvec, t0; \
    /* setup PMP to permit all accesses */ \
    li t0, 0x1f; \
    csrw pmpcfg0, t0; \
    li t0, 0x3fffffff; \
    csrw pmpaddr0, t0; \
    fence.i; \
2:  la t0, 3f; \
    csrw mtvec, t0; \
    fence; \
3:  nop;    \
    csrw mtvec, t1;

#define RVMODEL_DATA_BEGIN                                              \
  RVMODEL_DATA_SECTION                                                  \
  .section .data;                                                       \
  .align 4; .global begin_signature; begin_signature:

#define RVMODEL_DATA_END                                                \
  .section .data;                                                       \
  .align 4; .global end_signature; end_signature:

#define RVMODEL_IO_INIT
#define RVMODEL_IO_WRITE_STR(_R, _STR)
#define RVMODEL_IO_CHECK()
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)
#define RVMODEL_SET_MSW_INT
#define RVMODEL_CLEAR_MSW_INT
#define RVMODEL_CLEAR_MTIMER_INT
#define RVMODEL_CLEAR_MEXT_INT

#endif // _COMPLIANCE_MODEL_H
