#ifndef _COMPLIANCE_MODEL_H
#define _COMPLIANCE_MODEL_H
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

//RV_COMPLIANCE_HALT
#define RVMODEL_HALT                                              \
  fence;                                                                   \
  li x1, 1;                                                                   \
  write_tohost:                                                               \
    sw x1, tohost, t2;                                                        \
    fence;                                                                    \
    me: beqz x0, me;

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
    li t0, 0x2007ffff; \
    csrw pmpaddr0, t0; \
    fence.i; \
2:  la t0, 3f; \
    csrw mtvec, t0; \
    fence; \
3:  nop;    \
    csrw mtvec, t1;

//RV_COMPLIANCE_DATA_BEGIN
#define RVMODEL_DATA_BEGIN                                              \
  RVMODEL_DATA_SECTION                                                        \
  /* Begin signature section explicitly placed in RAM */                       \
  .section .begin_signature,"aw",@progbits;                                \
  .align 4; .global begin_signature; begin_signature:                        \


//RV_COMPLIANCE_DATA_END
#define RVMODEL_DATA_END                                                      \
  /* End signature section explicitly placed in RAM */                         \
  .section .end_signature,"aw",@progbits;                                  \
  .align 4; .global end_signature; end_signature:  

//RVTEST_IO_INIT
#define RVMODEL_IO_INIT
//RVTEST_IO_WRITE_STR
#define RVMODEL_IO_WRITE_STR(_R, _STR)
//RVTEST_IO_CHECK
#define RVMODEL_IO_CHECK()
//RVTEST_IO_ASSERT_GPR_EQ
#define RVMODEL_IO_ASSERT_GPR_EQ(_S, _R, _I)
//RVTEST_IO_ASSERT_SFPR_EQ
#define RVMODEL_IO_ASSERT_SFPR_EQ(_F, _R, _I)
//RVTEST_IO_ASSERT_DFPR_EQ
#define RVMODEL_IO_ASSERT_DFPR_EQ(_D, _R, _I)

#define RVMODEL_SET_MSW_INT

#define RVMODEL_CLEAR_MSW_INT

#define RVMODEL_CLEAR_MTIMER_INT

#define RVMODEL_CLEAR_MEXT_INT


#endif // _COMPLIANCE_MODEL_H
