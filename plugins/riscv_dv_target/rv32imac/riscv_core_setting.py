"""
Copyright 2020 Google LLC
Copyright 2020 PerfectVIPs Inc.
Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at
http://www.apache.org/licenses/LICENSE-2.0
Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
"""

import math
from pygen_src.riscv_instr_pkg import (privileged_reg_t, satp_mode_t,
                                       riscv_instr_group_t, mtvec_mode_t,
                                       privileged_mode_t)


# -----------------------------------------------------------------------------
# Processor feature configuration
# -----------------------------------------------------------------------------

# XLEN
XLEN = 32

# set to BARE if address translation is not supported
SATP_MODE = satp_mode_t.BARE

# Supported Privileged mode
supported_privileged_mode = [privileged_mode_t.MACHINE_MODE,
                             privileged_mode_t.USER_MODE]

# Unsupported instructions
unsupported_instr = []

# ISA supported by the processor
supported_isa = [riscv_instr_group_t.RV32I, riscv_instr_group_t.RV32M,
                 riscv_instr_group_t.RV32A, riscv_instr_group_t.RV32C]

# Interrupt mode support
supported_interrupt_mode = [mtvec_mode_t.DIRECT]

# The number of interrupt vectors to be generated, only used if VECTORED
# interrupt mode is supported
max_interrupt_vector_num = 16

# Physical memory protection support.
# src/pmp.v implements four regions checked against pmpcfg0 and pmpaddr0-3,
# with TOR, NA4 and NAPOT matching, and src/csr.v implements the lock bits and
# the TOR address locking rule. With this set, riscv-dv emits a pmp_setup
# section that programs the CSRs before entering the test, and moves the trap
# handlers and test_done ahead of main so a PMP fault can still be handled.
support_pmp = 1

# Debug mode support
support_debug_mode = 0

# Support delegate trap to user mode
support_umode_trap = 0

# Support sfence.vma instruction
support_sfence = 0

# Support unaligned load/store.
# FyraCore raises load/store-address-misaligned (causes 4/6) instead of
# completing the access, and Spike is run without --misaligned so the
# reference traps identically.
support_unaligned_load_store = 0

# GPR Setting
NUM_FLOAT_GPR = 32
NUM_GPR = 32
NUM_VEC_GPR = 32

# -----------------------------------------------------------------------------
# Vector extension configuration
# -----------------------------------------------------------------------------

# Parameter for vector extension
VECTOR_EXTENSION_ENABLE = 0

VLEN = 512

# Maximum size of a single vector element
ELEN = 32

# Minimum size of a sub-element, which must be at most 8-bits.
SELEN = 8

# Maximum size of a single vector element (encoded in vsew format)
VELEN = int(math.log(ELEN) // math.log(2)) - 3

# Maxium LMUL supported by the core
MAX_LMUL = 8


# -----------------------------------------------------------------------------
# Multi-harts configuration
# -----------------------------------------------------------------------------

# Number of harts
NUM_HARTS = 1

# -----------------------------------------------------------------------------
# Previleged CSR implementation
# -----------------------------------------------------------------------------

# Implemented previlieged CSR list.
#
# Transcribed from the read decode in src/csr.v: a CSR belongs here if reading
# it sets addr_valid, i.e. if it does *not* raise an illegal instruction. That
# is the property riscv-dv actually uses -- implemented_csr is the exclusion
# list for illegal-CSR stimulus (riscv_instr.create_csr_filter), so anything
# missing here gets generated as an "illegal" access against a CSR the core
# implements, and the trap the stimulus expects never arrives.
implemented_csr = [
    # Machine information (read-only)
    privileged_reg_t.MVENDORID,      # 0xF11 Vendor ID
    privileged_reg_t.MARCHID,        # 0xF12 Architecture ID
    privileged_reg_t.MIMPID,         # 0xF13 Implementation ID
    privileged_reg_t.MHARTID,        # 0xF14 Hardware thread ID
    privileged_reg_t.MCONFIGPTR,     # 0xF15 Config data pointer (reads 0)
    # Machine trap setup
    privileged_reg_t.MSTATUS,        # 0x300 Machine status
    privileged_reg_t.MISA,           # 0x301 ISA and extensions (C bit is WARL)
    privileged_reg_t.MIE,            # 0x304 Machine interrupt-enable
    privileged_reg_t.MTVEC,          # 0x305 Trap-handler base (direct mode only)
    privileged_reg_t.MCOUNTEREN,     # 0x306 Counter enable for U-mode
    privileged_reg_t.MCOUNTINHIBIT,  # 0x320 Counter inhibit (CY, IR)
    # Machine trap handling
    privileged_reg_t.MSCRATCH,       # 0x340 Scratch register
    privileged_reg_t.MEPC,           # 0x341 Exception program counter
    privileged_reg_t.MCAUSE,         # 0x342 Trap cause
    privileged_reg_t.MTVAL,          # 0x343 Bad address or instruction
    privileged_reg_t.MIP,            # 0x344 Interrupt pending
    # Physical memory protection. The core implements four regions in pmpcfg0
    # and pmpaddr0-3; pmpcfg1-3 and pmpaddr4-15 decode as hardwired zero and
    # ignore writes rather than trapping, which is what the spec requires of
    # unimplemented PMP entries, so they are implemented for this purpose.
    privileged_reg_t.PMPCFG0,        # 0x3A0
    privileged_reg_t.PMPCFG1,        # 0x3A1 read-only zero
    privileged_reg_t.PMPCFG2,        # 0x3A2 read-only zero
    privileged_reg_t.PMPCFG3,        # 0x3A3 read-only zero
    privileged_reg_t.PMPADDR0,       # 0x3B0
    privileged_reg_t.PMPADDR1,       # 0x3B1
    privileged_reg_t.PMPADDR2,       # 0x3B2
    privileged_reg_t.PMPADDR3,       # 0x3B3
    privileged_reg_t.PMPADDR4,       # 0x3B4 read-only zero
    privileged_reg_t.PMPADDR5,       # 0x3B5 read-only zero
    privileged_reg_t.PMPADDR6,       # 0x3B6 read-only zero
    privileged_reg_t.PMPADDR7,       # 0x3B7 read-only zero
    privileged_reg_t.PMPADDR8,       # 0x3B8 read-only zero
    privileged_reg_t.PMPADDR9,       # 0x3B9 read-only zero
    privileged_reg_t.PMPADDR10,      # 0x3BA read-only zero
    privileged_reg_t.PMPADDR11,      # 0x3BB read-only zero
    privileged_reg_t.PMPADDR12,      # 0x3BC read-only zero
    privileged_reg_t.PMPADDR13,      # 0x3BD read-only zero
    privileged_reg_t.PMPADDR14,      # 0x3BE read-only zero
    privileged_reg_t.PMPADDR15,      # 0x3BF read-only zero
    # Machine counters (Zicntr). Writable halves of the 64-bit counters.
    privileged_reg_t.MCYCLE,         # 0xB00
    privileged_reg_t.MINSTRET,       # 0xB02
    privileged_reg_t.MCYCLEH,        # 0xB80
    privileged_reg_t.MINSTRETH,      # 0xB82
    # Unprivileged counter aliases (Zicntr). Readable from M-mode
    # unconditionally, and from U-mode only when the matching mcounteren bit
    # is set -- init_privileged_mode is MACHINE_MODE, so they never trap here.
    privileged_reg_t.CYCLE,          # 0xC00
    privileged_reg_t.TIME,           # 0xC01 driven from the CLINT mtime
    privileged_reg_t.INSTRET,        # 0xC02
    privileged_reg_t.CYCLEH,         # 0xC80
    privileged_reg_t.TIMEH,          # 0xC81
    privileged_reg_t.INSTRETH,       # 0xC82
]

# Implementation-specific custom CSRs
custom_csr = []
