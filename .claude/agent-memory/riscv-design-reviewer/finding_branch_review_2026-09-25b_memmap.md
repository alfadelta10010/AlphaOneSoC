---
name: finding-branch-review-2026-09-25b-memmap
description: Adversarial review at 0b6eabb (RTL = 832e068 + c641e76/d83bff7/6aadc0f/bceaa5f/d05e277) plus the Linux memory-map proposal — no new ISA CRITICAL; SoC/PMA gaps are the tapeout blockers (single exec window, flash writable, no bus error, halfword-aligned fetch, mtvec reset 0)
metadata:
  type: project
---

Reviewed 2026-09-25 (second pass) at HEAD 0b6eabb on riscv-compliance_alfadelta10010.
Environment had no tools: installed iverilog/verilator/yosys via apt, built Spike from git master
(needs `--without-boost --without-boost-asio --without-boost-regex`, boost yield macro clash), and
used clang/lld via shims in scratchpad/bin (gcc->clang, objcopy->python ELF->verilog hex).
**Gotchas:** (1) Spike master no longer logs the 5 boot-ROM lines -> run.sh `sed '1,5d'` eats 5 real
lines; (2) clang encodes some `li` differently from GNU as -> committed .ref files mismatch; always
regenerate refs with the same toolchain. (3) mtvec direct mode: align trap handlers (`.align 2`) in
probes or the handler lands 2 bytes early.

## Verified at HEAD (do not re-raise)
- 6aadc0f pmpcfg W&=R (csr.v pmpcfg_legal), bceaa5f csr_new=wdata (verilator -Wall: only UNSIGNED
  warnings, no UNOPTFLAT), c641e76 load byte lanes (dmem_be=access_be for loads), d05e277 fencei gate,
  d83bff7 imem_req only inside PMA_MEM (if_fetched forced 0 outside).
- CSR existence probe vs Spike master: all match except tselect/tdata1/tcontrol (Spike has Sdtrig) and
  pmpcfg4-15/pmpaddr16-63 (Spike implements 64 entries; DUT's 16-CSR set is legal). Both legal.
- Interrupt vs ECALL on same insn: DUT takes the ECALL first (irq masked by !ex_trap), Spike takes the
  interrupt first. Ibex does the same as DUT (ibex_controller.sv DECODE: irq only if !special_req). Legal.

## Findings (this pass)
- MAJOR (SoC/PMA): one executable window (PMA_MEM) that is also writable -> moving flash away from RAM
  needs a 2nd exec window; stores/AMO/SC to flash go to the bus; no dmem_err/imem_err input so the PMA
  is the ONLY source of access faults (Ibex has data_err_i/instr_err_i).
- MAJOR (SoC contract): imem_addr = pc (halfword-aligned), memory must return 4 bytes from any halfword
  incl. across chip boundaries (PSRAM A/B at +8MB). Ibex/PicoRV32 fetch word-aligned only.
- MINOR: mtvec resets to 0 (csr.v:338); fine when RESET_PC=0, a trap-loop at an unmapped vector once
  flash moves. Ibex resets mtvec from boot_addr.
- NOTE: imem_req still high on every stall incl. WFI -> refetch storm on shared QSPI unless controller
  holds last word (documented in fyracore.v:65-73).
- Linux facts checked in master: RISC-V XIP_KERNEL depended on MMU and is removed in 7.1 -> NOMMU kernel
  must be copied to PSRAM; NOMMU selects RELOCATABLE unless PHYS_RAM_BASE_FIXED (default 0x80000000);
  kernel at 4 MB (PMD) boundary on rv32; M-mode head.S reads mhartid itself, writes pmpaddr0=-1 +
  pmpcfg0=0x1F (clobbers entries 1-3); time via CLINT MMIO (timex.h), clint min delta 100 ticks,
  writeq lo-then-hi on RV32.

## Proposed map (recommendation given to user)
Flash 0x2000_0000 16MB RX (reset vector), PSRAM 0x8000_0000 16MB contiguous (CS = addr[23]), CLINT
0x0200_0000 64KB, PLIC reserved 0x0C00_0000, UART 0x1000_0000 (ns16550a, reg-shift 0 now possible),
GPIO/PWM 0x1001_0000, syscon 0x1002_0000. Spike accepts `-m0x20000000:0x1000000,0x80000000:0x1000000`
(verified). TT QSPI Pmod: CS0 flash, CS1 RAM A, CS2 RAM B share one quad bus.

Related: [[finding-branch-review-2026-09-25]], [[reference-kianv-memory-map]], [[reference-spike-probed-behaviours]].
