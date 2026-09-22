---
name: rtl-area-hotspots-fyracore
description: Where FyraCore's area actually goes and which structures are over-general — checked 2026-09-05, use as the starting point for any future area/PPA pass
metadata:
  type: project
---

Ranked area hotspots found in a 2026-09-05 read of `src/*.v` (sky130 / TinyTapeout context).

1. **`regFile.v:22-27`** resets all 32x32 bits, forcing ~1024 reset-flops (`dfrtp` ~26 µm² vs
   `dfxtp` ~20 µm²) plus a huge reset tree. The ISA does not require x1–x31 to reset. Entry 0 is
   also live in the read mux even though `r1`/`r2` mux it out (`:31-32`). Biggest single win,
   **but removing the reset is observable in Spike lockstep** if any test reads before writing.
2. **`alu.v:12,23,27`** infers **three** independent 32-bit barrel shifters (SLL / SRL / SRA).
   One shifter + input/output bit reversal + a fill-bit mux does all three. ~2/3 of the shift logic.
3. **`alu.v:15,22,30`** infers **three** adders (`sub33` for SLT/SLTU, `d1+d2`, `d1-d2`).
   One 33-bit add/sub (`d1 + (sub ? ~d2 : d2) + sub`) covers all three.
4. **`pmp.v`** is instantiated **twice** (`fyracore.v:627,643`); `napot_match` (`pmp.v:56-65`)
   computes `~(pa | (pa+1))` — a 30-bit incrementer **per entry per instance** = 8 incrementers for
   values that only change when `pmpaddr*` is written. Hoist the masks into `csr.v` and share.
   TOR compares (`:73,81,89,97`) are 32-bit where 30-bit (4-byte PMP granularity) suffices.
5. **`fyracore.v:662-699`** re-implements the entire CSR WARL masking that already exists in
   `csr.v` (pmpcfg lock+A-mask x4, mstatus MPP legalization, misa, mtvec, mepc) purely for EX-stage
   forwarding; `:707-713` masks mtvec/mepc a *third* time. The TB (`tb_rivercore.v`) has a fourth copy.
6. **`csr.v:152-204`** — 32-bit read mux over ~35 arms. The C0x counter aliases duplicate the B0x
   sources; collapsing them removes ~6 x 32 mux inputs.
7. **`fyracore.v:502-515`** `amo_computed` infers 4 separate 32-bit comparators (MIN/MAX/MINU/MAXU)
   plus an adder; one 33-bit subtract + sign fix serves all of them.
8. **`muldiv.v`** — multiply (`mul_m/mul_p/mul_n`) and divide (`div_dvd/div_dvs/div_rem/div_quot/
   div_a_orig`) use **disjoint** registers (8 x 32 = 256 FF) and two 33-bit adders (`:75`, `:101-102`);
   a shared A/Q/M datapath is the textbook 3 x 32 = 96 FF. `:194` is a dedicated **64-bit**
   incrementer used only for the signed-product negate.
9. **`fyracore.v:871`** `exwb_pc_next` and `ifex_pc_next` (64 FF) are fully recomputable from
   `exwb_trap_pc`/`ifex_pc` + the already-stored `compressed` flag.
10. **`fyracore.v:271-272`** a 32-bit 2:1 mux where only bit 0 differs (JALR clears bit 0).

Dead / risky code found at the same time: `fyracore.v:459-460` (`amo_write_data`/`amo_write_mask`
declared, never used — duplicated inline at `:470-471`); `src/regs.v` and `src/memController.v` are
never instantiated; `fyracore.v:683,685` use a **hierarchical reference** `csr_unit.mstatus` inside
synthesizable RTL.

**Why:** the design targets a TinyTapeout tile, so area is the binding constraint, but it is also
being driven to full arch-test compliance, so nothing here should change ISA-visible behavior.
**How to apply:** items 2, 3, 5, 6, 7, 9, 10 are architecturally transparent. Item 1 is not
(reset values are observable). Item 4 changes nothing functionally but touches the PMP interface.

Related: [[project-fyracore-overview]].
