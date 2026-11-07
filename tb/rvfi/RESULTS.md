# riscv-formal on FyraCore: results (WO-38, 2026-11-07)

Verdict wording: riscv-formal is BMC. Every PASS below is **BOUNDED (BMC depth N from reset)**,
never PROVED. A TIMEOUT never counts as a PASS.

## Run

* Tree: commit `38a9133` (frozen with `git archive`; src/ identical to main a2f7285 plus the
  ifdef'd RVFI port of WO-36), at `~/regr/vc/WO-38/acc-38a9133` on the sandbox.
* riscv-formal pin: `c992aa61fdfe0846c5ed90324c596202a1c69b76`. Tools: OSS CAD Suite 2026-11-01.
* Defines: `RISCV_FORMAL_ALIGNED_MEM`, `RISCV_FORMAL_ALTOPS`, `FYRA_MAX_WAIT 2`, and
  `FYRA_WRAPPER_COVERS` for the cover check (checks.cfg `[defines]`).
* Command (sandbox, after `source ~/tools/oss-cad-suite/environment`), one invocation per solver
  family, sequential (run.sh regenerates the shared rf/ tree per SOLVER):
  `bash tb/rvfi/run.sh OUT=<dir> JOBS=4 TIMEOUT=7200 SOLVER=<s> ONLY="<checks>"`;
  driver: `localFiles/verif-close-2026-11-07/WO-38/driver.sh <acc-dir>` (resumable, thermal watchdog
  peak 70 C, no trip). Faults: `bash tb/rvfi/mutants.sh <ID> <check>...`.
* Result: `rvfi: 82 checks, 82 PASS/REACHED (BOUNDED, BMC from reset), 0 FAIL, 0 TIMEOUT, 0 ERROR`.

| Family | Solver | Checks | Depth | Wall (JOBS=4) | Verdict |
|---|---|---|---|---|---|
| plain insn (RV32I/C loads, stores, ALU, branches, jumps) and ill | yices | 54 | 20 | 12 m 20 s | BOUNDED (BMC depth 20 from reset) |
| reg, pc_fwd, pc_bwd, causal, unique, liveness | bmc3 | 6 | 30 (liveness 62) | 6 m 10 s | BOUNDED (BMC depth 30 / 62 from reset) |
| shifts (9) and M (8) | boolector | 17 | 41 shifts, 42 mul*, 44 div/rem | 22 m 38 s | BOUNDED (BMC depth 41/42/44 from reset) |
| cover | yices | 1 | 20 | 1 m 12 s | all covers reached, BOUNDED depth 20 |
| fyra_imem, lat_mul, lat_div, lat_sll31 | bmc3 | 4 | 22; probes 50 | 4 m 22 s | fyra_imem BOUNDED (BMC depth 22 from reset); probes REACHED |

Batch total about 47 min wall, matrix about 19 min (4 mutants in parallel, JOBS=1 each).
Solver per family follows the WO-37 calibration (fastest PASS on the family representative; bmc3 has no
cover mode, so cover is on yices). Measured first-retire cycles (lat_* probes): SLLI by 31 k=38,
MUL* k=39, DIV/REM k=41; depths are k+3.

### Per-check table

| Check | Solver | Depth | Seconds | Verdict |
|---|---|---|---|---|
| causal_ch0 | bmc3 | 30 | 7 | BOUNDED (BMC depth 30 from reset) |
| cover | yices | 20 | 72 | all covers REACHED by depth 20 |
| fyra_imem | bmc3 | 22 | 262 | BOUNDED (BMC depth 22 from reset) |
| ill_ch0 | yices | 20 | 4 | BOUNDED (BMC depth 20 from reset) |
| insn_add_ch0 | yices | 20 | 33 | BOUNDED (BMC depth 20 from reset) |
| insn_addi_ch0 | yices | 20 | 22 | BOUNDED (BMC depth 20 from reset) |
| insn_and_ch0 | yices | 20 | 18 | BOUNDED (BMC depth 20 from reset) |
| insn_andi_ch0 | yices | 20 | 14 | BOUNDED (BMC depth 20 from reset) |
| insn_auipc_ch0 | yices | 20 | 16 | BOUNDED (BMC depth 20 from reset) |
| insn_beq_ch0 | yices | 20 | 35 | BOUNDED (BMC depth 20 from reset) |
| insn_bge_ch0 | yices | 20 | 33 | BOUNDED (BMC depth 20 from reset) |
| insn_bgeu_ch0 | yices | 20 | 29 | BOUNDED (BMC depth 20 from reset) |
| insn_blt_ch0 | yices | 20 | 27 | BOUNDED (BMC depth 20 from reset) |
| insn_bltu_ch0 | yices | 20 | 21 | BOUNDED (BMC depth 20 from reset) |
| insn_bne_ch0 | yices | 20 | 22 | BOUNDED (BMC depth 20 from reset) |
| insn_c_add_ch0 | yices | 20 | 24 | BOUNDED (BMC depth 20 from reset) |
| insn_c_addi16sp_ch0 | yices | 20 | 25 | BOUNDED (BMC depth 20 from reset) |
| insn_c_addi4spn_ch0 | yices | 20 | 35 | BOUNDED (BMC depth 20 from reset) |
| insn_c_addi_ch0 | yices | 20 | 30 | BOUNDED (BMC depth 20 from reset) |
| insn_c_and_ch0 | yices | 20 | 18 | BOUNDED (BMC depth 20 from reset) |
| insn_c_andi_ch0 | yices | 20 | 19 | BOUNDED (BMC depth 20 from reset) |
| insn_c_beqz_ch0 | yices | 20 | 25 | BOUNDED (BMC depth 20 from reset) |
| insn_c_bnez_ch0 | yices | 20 | 27 | BOUNDED (BMC depth 20 from reset) |
| insn_c_jal_ch0 | yices | 20 | 28 | BOUNDED (BMC depth 20 from reset) |
| insn_c_jalr_ch0 | yices | 20 | 20 | BOUNDED (BMC depth 20 from reset) |
| insn_c_j_ch0 | yices | 20 | 11 | BOUNDED (BMC depth 20 from reset) |
| insn_c_jr_ch0 | yices | 20 | 8 | BOUNDED (BMC depth 20 from reset) |
| insn_c_li_ch0 | yices | 20 | 12 | BOUNDED (BMC depth 20 from reset) |
| insn_c_lui_ch0 | yices | 20 | 18 | BOUNDED (BMC depth 20 from reset) |
| insn_c_lw_ch0 | yices | 20 | 95 | BOUNDED (BMC depth 20 from reset) |
| insn_c_lwsp_ch0 | yices | 20 | 86 | BOUNDED (BMC depth 20 from reset) |
| insn_c_mv_ch0 | yices | 20 | 13 | BOUNDED (BMC depth 20 from reset) |
| insn_c_or_ch0 | yices | 20 | 21 | BOUNDED (BMC depth 20 from reset) |
| insn_c_slli_ch0 | boolector | 41 | 519 | BOUNDED (BMC depth 41 from reset) |
| insn_c_srai_ch0 | boolector | 41 | 592 | BOUNDED (BMC depth 41 from reset) |
| insn_c_srli_ch0 | boolector | 41 | 581 | BOUNDED (BMC depth 41 from reset) |
| insn_c_sub_ch0 | yices | 20 | 32 | BOUNDED (BMC depth 20 from reset) |
| insn_c_sw_ch0 | yices | 20 | 110 | BOUNDED (BMC depth 20 from reset) |
| insn_c_swsp_ch0 | yices | 20 | 127 | BOUNDED (BMC depth 20 from reset) |
| insn_c_xor_ch0 | yices | 20 | 31 | BOUNDED (BMC depth 20 from reset) |
| insn_div_ch0 | boolector | 44 | 105 | BOUNDED (BMC depth 44 from reset) |
| insn_divu_ch0 | boolector | 44 | 103 | BOUNDED (BMC depth 44 from reset) |
| insn_jal_ch0 | yices | 20 | 21 | BOUNDED (BMC depth 20 from reset) |
| insn_jalr_ch0 | yices | 20 | 18 | BOUNDED (BMC depth 20 from reset) |
| insn_lb_ch0 | yices | 20 | 103 | BOUNDED (BMC depth 20 from reset) |
| insn_lbu_ch0 | yices | 20 | 185 | BOUNDED (BMC depth 20 from reset) |
| insn_lh_ch0 | yices | 20 | 151 | BOUNDED (BMC depth 20 from reset) |
| insn_lhu_ch0 | yices | 20 | 254 | BOUNDED (BMC depth 20 from reset) |
| insn_lui_ch0 | yices | 20 | 14 | BOUNDED (BMC depth 20 from reset) |
| insn_lw_ch0 | yices | 20 | 232 | BOUNDED (BMC depth 20 from reset) |
| insn_mul_ch0 | boolector | 42 | 105 | BOUNDED (BMC depth 42 from reset) |
| insn_mulh_ch0 | boolector | 42 | 103 | BOUNDED (BMC depth 42 from reset) |
| insn_mulhsu_ch0 | boolector | 42 | 63 | BOUNDED (BMC depth 42 from reset) |
| insn_mulhu_ch0 | boolector | 42 | 98 | BOUNDED (BMC depth 42 from reset) |
| insn_or_ch0 | yices | 20 | 22 | BOUNDED (BMC depth 20 from reset) |
| insn_ori_ch0 | yices | 20 | 16 | BOUNDED (BMC depth 20 from reset) |
| insn_rem_ch0 | boolector | 44 | 64 | BOUNDED (BMC depth 44 from reset) |
| insn_remu_ch0 | boolector | 44 | 96 | BOUNDED (BMC depth 44 from reset) |
| insn_sb_ch0 | yices | 20 | 195 | BOUNDED (BMC depth 20 from reset) |
| insn_sh_ch0 | yices | 20 | 198 | BOUNDED (BMC depth 20 from reset) |
| insn_sll_ch0 | boolector | 41 | 237 | BOUNDED (BMC depth 41 from reset) |
| insn_slli_ch0 | boolector | 41 | 485 | BOUNDED (BMC depth 41 from reset) |
| insn_slt_ch0 | yices | 20 | 24 | BOUNDED (BMC depth 20 from reset) |
| insn_slti_ch0 | yices | 20 | 16 | BOUNDED (BMC depth 20 from reset) |
| insn_sltiu_ch0 | yices | 20 | 20 | BOUNDED (BMC depth 20 from reset) |
| insn_sltu_ch0 | yices | 20 | 20 | BOUNDED (BMC depth 20 from reset) |
| insn_sra_ch0 | boolector | 41 | 511 | BOUNDED (BMC depth 41 from reset) |
| insn_srai_ch0 | boolector | 41 | 475 | BOUNDED (BMC depth 41 from reset) |
| insn_srl_ch0 | boolector | 41 | 489 | BOUNDED (BMC depth 41 from reset) |
| insn_srli_ch0 | boolector | 41 | 290 | BOUNDED (BMC depth 41 from reset) |
| insn_sub_ch0 | yices | 20 | 35 | BOUNDED (BMC depth 20 from reset) |
| insn_sw_ch0 | yices | 20 | 107 | BOUNDED (BMC depth 20 from reset) |
| insn_xor_ch0 | yices | 20 | 27 | BOUNDED (BMC depth 20 from reset) |
| insn_xori_ch0 | yices | 20 | 22 | BOUNDED (BMC depth 20 from reset) |
| lat_div | bmc3 | 41 | 64 | REACHED (probe) |
| lat_mul | bmc3 | 39 | 63 | REACHED (probe) |
| lat_sll31 | bmc3 | 38 | 49 | REACHED (probe) |
| liveness_ch0 | bmc3 | 62 | 27 | BOUNDED (BMC depth 62 from reset) |
| pc_bwd_ch0 | bmc3 | 30 | 7 | BOUNDED (BMC depth 30 from reset) |
| pc_fwd_ch0 | bmc3 | 30 | 107 | BOUNDED (BMC depth 30 from reset) |
| reg_ch0 | bmc3 | 30 | 363 | BOUNDED (BMC depth 30 from reset) |
| unique_ch0 | bmc3 | 30 | 7 | BOUNDED (BMC depth 30 from reset) |

## Triage

No FAIL, TIMEOUT or ERROR in the batch, so there is no DUT bug, PORT or ENV row. Two matrix rows
did not behave as expected; both are explained below and neither is a DUT defect.

**(a) BC-PC1 on pc_bwd_ch0 PASS (pc_fwd_ch0 FAIL).** By the check's definition, not a hole in the port.
In riscv-formal's `rvfi_pc_bwd_check` the check cycle is the retire of order N. The expected pc is
latched from the retire of order N+1 (`rvfi_order == insn_order+1`) on an earlier cycle and compared
with N's `pc_wdata`. An in-order core with strictly increasing `rvfi_order` retires N+1 after N, so
the expectation is never valid at the check cycle: pc_bwd is vacuous for FyraCore and the pc_fwd check
(N-1 retired before N, compare its `pc_wdata` with N's `pc_rdata`) is the one that carries the
pc-continuity property. Non-vacuity of the pc_bwd *check* was shown with the probe BC-ORD-DOWN
(order reported as the complement, so N+1 retires first): pc_bwd_ch0 FAIL (bmc3, depth 30).
Action: pc_bwd is kept in the batch for completeness; the matrix row for BC-PC1 is pc_fwd (FAIL).

**(b) RG05 on reg_ch0 PASS.** The matrix set RG05 against `reg_ch0` only (bmc3, depth 30). In WO-37's
mutant test RG05 was killed by `insn_add_ch0`. Re-run in this matrix's setup (mutants.sh, yices,
depth 20): `RG05 insn_add_ch0 FAIL`, so the matrix keeps its kill, and `RG05 reg_ch0` PASS was
reproduced on a second run. The kill comes from the insn check. With the bypass removed the add consumes the macro's one-cycle
collision value, but the port samples rs1/rs2_rdata when the instruction leaves EX
(fyracore.v:1636-1640). By then the RF has re-read the correct value, so the reported operand is
the architectural one and rd_wdata disagrees with it. The reg check compares reported operands with
reported writes (rvfi_reg_check.sv:32-44, free register and order), so it cannot see this fault at
any depth. This is not a depth gap. A review probe at `reg 1 20` was a TIMEOUT (inconclusive);
FC56 FAILs at the same config. Residual: a transient operand error is caught only by the insn check
of the consuming instruction. Consumers with no insn check (CSR write source, A) have no
riscv-formal operand check.

**Expected survivors (PASS, as documented).**
* FC51 (data wait ignored) on insn_lw: the port does not implement the RVFI_BUS interface and checks.cfg
  enables no bus_* check (the wrapper frees memory data every cycle and ready is free), so a core that ignores dmem wait is still a legal trace;
  core_hold bench and directed tests kill it (W-RVFI-3).
* MD01 (MULHSU multiplicand unsigned), MD10 (MULHSU returns the low word), MD03 (negative / 0): the M
  arithmetic is replaced by riscv-formal's ALTOPS formulas (A-v3), so these faults live in logic that
  is not on the checked path. tb_muldiv and directed tests kill them (VPLAN 4.2).
  The M *control* path is covered: BC-ALTMUL and BC-ALTDIV (a mask bit flipped in the ALTOPS hook)
  FAIL insn_mul and insn_div at the real latency (depth 42 / 44), showing the checks reach a real M
  retire; CT16 (divides not routed to muldiv) FAILs insn_div and insn_divu.

## Mutant matrix

Each row: fault applied to a copy of src/ (or the wrapper for BC-COV), the check run on the same
solver as in the batch. FAIL = fault detected.

| Fault | Check | Result | Expected | Match |
|---|---|---|---|---|
| BR02 | insn_bge_ch0 | FAIL | FAIL | as expected  |
| BR05 | insn_bltu_ch0 | FAIL | FAIL | as expected  |
| SE01 | insn_jal_ch0 | FAIL | FAIL | as expected  |
| ALU06 | insn_slt_ch0 | FAIL | FAIL | as expected  |
| ALU06 | insn_slti_ch0 | FAIL | FAIL | as expected  |
| CT01 | insn_lbu_ch0 | FAIL | FAIL | as expected  |
| ALU01 | insn_add_ch0 | FAIL | FAIL | as expected  |
| ALU01 | insn_addi_ch0 | FAIL | FAIL | as expected  |
| ALU01 | insn_c_add_ch0 | FAIL | FAIL | as expected  |
| FC43 | insn_jalr_ch0 | FAIL | FAIL | as expected  |
| FC24 | insn_sb_ch0 | FAIL | FAIL | as expected  |
| FC22 | insn_lb_ch0 | FAIL | FAIL | as expected  |
| FC22 | insn_sb_ch0 | FAIL | FAIL | as expected  |
| SE03 | insn_sb_ch0 | FAIL | FAIL | as expected  |
| SE03 | insn_sw_ch0 | FAIL | FAIL | as expected  |
| CD01 | insn_c_addi4spn_ch0 | FAIL | FAIL | as expected  |
| CD16 | insn_c_jalr_ch0 | FAIL | FAIL | as expected  |
| FC72 | insn_c_jal_ch0 | FAIL | FAIL | as expected  |
| FC72 | insn_c_jalr_ch0 | FAIL | FAIL | as expected  |
| RFF02 | insn_c_beqz_ch0 | FAIL | FAIL | as expected  |
| RF02 | insn_c_lw_ch0 | FAIL | FAIL | as expected  |
| BC-ILL | ill_ch0 | FAIL | FAIL | as expected  |
| BC-COV | cover | FAIL | FAIL | as expected  |
| FR06 | fyra_imem | FAIL | FAIL | as expected  |
| FR01 | fyra_imem | FAIL | FAIL | as expected  |
| FC51 | insn_lw_ch0 | PASS | PASS (survivor) | as expected  |
| FC52 | fyra_imem | FAIL | FAIL | as expected  |
| FR05 | fyra_imem | FAIL | FAIL | as expected  |
| FR02 | fyra_imem | FAIL | FAIL | as expected  |
| CD07 | insn_c_srai_ch0 | FAIL | FAIL | as expected  |
| BC-ALTMUL | insn_mul_ch0 | FAIL | FAIL | as expected  |
| MD06 | insn_sll_ch0 | FAIL | FAIL | as expected  |
| BC-ALTDIV | insn_div_ch0 | FAIL | FAIL | as expected  |
| MD01 | insn_mulhsu_ch0 | PASS | PASS (survivor) | as expected  |
| MD03 | insn_div_ch0 | PASS | PASS (survivor) | as expected  |
| CT16 | insn_div_ch0 | FAIL | FAIL | as expected  |
| CT16 | insn_divu_ch0 | FAIL | FAIL | as expected  |
| MD10 | insn_mulhsu_ch0 | PASS | PASS (survivor) | as expected  |
| FC56 | reg_ch0 | FAIL | FAIL | as expected  |
| BC-PC1 | pc_fwd_ch0 | FAIL | FAIL | as expected  |
| BC-PC1 | pc_bwd_ch0 | PASS | FAIL | DEVIATION (see triage (a)) |
| BC-ORD-DOWN | causal_ch0 | FAIL | FAIL | as expected  |
| BC-ORD-TRAP | unique_ch0 | FAIL | FAIL | as expected  |
| MD08 | liveness_ch0 | FAIL | FAIL | as expected  |
| FC44 | liveness_ch0 | FAIL | FAIL | as expected  |
| MD05 | insn_srl_ch0 | FAIL | FAIL | as expected  |
| MD05 | insn_srli_ch0 | FAIL | FAIL | as expected  |
| FC01 | reg_ch0 | FAIL | FAIL | as expected  |
| RG05 | reg_ch0 | PASS | FAIL | DEVIATION (see triage (b)) |
| RG05 | insn_add_ch0 | FAIL | FAIL | as expected (probe in the matrix setup, 11-07) |
| BC-ORD-DOWN | pc_bwd_ch0 | FAIL | FAIL | as expected (probe: pc_bwd is not vacuous) |

Coverage of the "must FAIL" list: every row FAILs except the two noted (BC-PC1/pc_bwd, RG05/reg), and
each of those has a killing sibling (BC-PC1/pc_fwd, RG05/insn_add). Every check family (insn, shifts,
M routing, reg, pc, causal, unique, liveness, ill, cover, fyra_imem) fails on at least one fault.

## Not covered (and where it is covered instead)

* **Environment (A-v1):** the wrapper forces M-mode, no PMP lock, no MPRV-to-U and misa.C = 1, so
  U-mode, MPRV and C toggling are not exercised (W-RVFI-2). Covered by tb_pmp, csr formal, directed.
* **M arithmetic (A-v3):** replaced by ALTOPS; covered by tb_muldiv and directed. Only M dispatch (isMulDiv),
  latency and writeback are checked.
* **CSRs:** no csr checks (trap causes, mtval, mepc, interrupt causes included); covered by the
  CSR/trap benches and river_core.
* **A extension:** reported but no A insn checks exist for rv32imc; covered by directed and river_core.
* **Data-memory consistency (W-RVFI-3):** none; covered by directed memory_model. PMA (W-RVFI-1)
  uses a full-RAM parameterisation.
* **Interrupted WFI in EX** never occurs in the trace (liveness fairness assumption).
* **Bounded history:** BMC from reset at depth 20-62, not a proof for all histories; PROVED is
  reserved for induction or a pdr PASS from a defined reset state.
* **pc_bwd** is vacuous on an in-order core. pc_fwd checks the same pc pairs, and liveness and
  unique rule out order gaps and repeats (triage (a)). **reg_ch0** checks the operand the port
  samples at EX exit, not the one consumed (triage (b)).
* **Memory waits** are bounded at FYRA_MAX_WAIT = 2 cycles. Longer stalls are not explored.
* **Illegal encodings:** the ill check covers only the all-zero parcel.
* **Trap and mret targets** have no spec check (no csr/mret checks). pc_fwd checks continuity only.
* **Not run:** hang, causal_mem, causal_io, bus_* (no RVFI_BUS port), fault, csrw/csr_ill.
* The kv-held-across-an-M-stall fetch case (~45 cycles) is beyond fyra_imem depth 22 (core_fetch induction).

## VPLAN text (the riscv-formal rows of tb/VPLAN.md 4.5)

> **VC-5 riscv-formal (RVFI port, tb/rvfi, results tb/rvfi/RESULTS.md).** 82 checks, all BOUNDED
> (BMC depth 20 for the RV32I/C insn checks and ill; 41/42/44 for shifts, MUL*, DIV/REM; reg, pc_fwd,
> pc_bwd, causal, unique 30; liveness 62; cover 20; fetch consistency fyra_imem 22), 0 FAIL, solvers
> yices / bmc3 / boolector per family, pin c992aa61, about 47 min on 4 cores. Closes the insn
> semantics of RV32I/M(routing)/C for retire-order histories from reset, reg/pc/order/liveness
> consistency, and fetch-reuse consistency. Non-vacuity: 49 fault runs plus 2 probes (51 matrix rows, 45 FAIL and 6 PASS); 43 of the 49 fault runs FAIL; the 4 expected
> survivors are FC51 (no bus model) and MD01/MD03/MD10 (ALTOPS replaces M arithmetic); pc_bwd is
> vacuous in-order (killed only by a reversed-order probe) and reg_ch0 misses RG05 (insn_add kills it).
> Not covered: U-mode/PMP/MPRV/misa.C, CSRs and trap causes, A semantics, M arithmetic, data-memory
> consistency, unbounded histories. Reproduce: bash tb/rvfi/run.sh (see RESULTS.md).

> Suggested ROADMAP 2.2 item 2 status line: "riscv-formal through RVFI: 82/82 BOUNDED (BMC from reset),
> 49-row fault matrix, residuals in tb/rvfi/RESULTS.md."
