---
name: reference-spike-probed-behaviours
description: Spike 1.1.1-dev behaviours measured by direct probe (2026-09-12) that matter for FyraCore lockstep — --instructions truncation, device map, CSR WARL choices, mtval
metadata:
  type: reference
---

Local Spike: `/tools/rv32-isa-sim/bin/spike` (1.1.1-dev), same as sandbox build.
Flags used by the flow: `--priv=mu -m0x80000000:0x2000000 --isa=rv32imac_zicntr --pmpregions=4 --pmpgranularity=4`.

- `--instructions=N` is NOT an instruction bound. `sim_t::idle()` does
  `instruction_limit -= INTERLEAVE` per 5000-step chunk; `processor_t::step` returns early at
  any trap, so each trap burns a whole chunk. N<5000 => exits at the first trap.
  N=200005 => exits after ~40 traps. **Never pass --instructions when reproducing trap tests.**
- Device map (`--dump-dts`): mem 0x80000000+0x2000000, CLINT 0x02000000+0xC0000,
  PLIC 0x0C000000+0x1000000, ns16550 0x10000000+0x100, boot ROM at 0x1000 (readable, executable).
  Unused CLINT offsets read 0. Fetch from CLINT executes it (msip=0 -> 0x0000 -> cause 2, tval 0).
- misa: M, A, C writable (A/M can be cleared); U read-only. Clearing C at PC[1]=1 is suppressed
  and NOT logged.
- mstatus write mask (M+U): MIE, MPIE, MPRV, MPP, TW -> `csrw mstatus,-1` reads 0x00221888.
  MPP=01/10 legalized to 00 (U).
- mcountinhibit: writable mask 0x5. The toggling instruction's own retire is counted with the
  NEW inhibit value (bump happens after execute).
- minstret low write: high half still receives the carry from the writing instruction's increment.
- Illegal instruction: mtval = raw instruction bits (16-bit parcel for RVC), never forced 0.
- marchid = 5 (Spike's registered open-source ID), mimpid = 0.
- minstret includes the 5 boot-ROM instructions, so absolute counter reads never match a DUT
  that starts at 0.

Related: [[finding-branch-review-2026-09-12]], [[verification-flow-river-core-riscof]].

## Added 2026-09-24 (probed at 7cd1eb6 flags, -m0x80000000:0x2000000)

- CSR existence (M-mode csrr): mstatush, mhpmcounter3(h), mhpmevent3, menvcfg(h), tselect,
  pmpcfg4, pmpaddr16 all read **0**; hpmcounter3 and mseccfg are illegal (no Zihpm/Smepmp).
- mip after `csrw mip,-1` reads 0x80 (only live MTIP; nothing writable without S-mode).
- SRET, funct7=0001000 rs2!=5, MRET-with-rs2!=2, LR.W rs2!=0, sfence.vma, dret, mnret: all cause 2.
- mtimecmp resets to 0 (MTIP asserted), mtime ticks per 100 instructions: any test reading
  mtime diverges at the first read — interrupt tests are DUT-only.
- **Trap clears the reservation in effect**: processor_t::step sets `n = instret` on trap_t
  (execute.cc); sim_t::step still adds the full requested chunk to current_step, hits
  INTERLEAVE, calls `yield_load_reservation()` before the handler runs (sim.cc). Interrupts
  go through the same trap path. So `lr; ecall; sc` fails on Spike (measured 2026-09-22).
