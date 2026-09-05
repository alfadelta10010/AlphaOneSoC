---
name: finding-wb-stall-drops-memory-op
description: CRITICAL open finding — fyracore.v inserts an EX/WB bubble on every stall cycle, which withdraws an in-flight load/store request before dmem_ready, so any wait-stated memory corrupts data
metadata:
  type: project
---

**Status: OPEN (as of 2026-09-05 review).** `src/fyracore.v:855-866`.

```
end else if (stall && !irq_inject) begin
    exwb_valid <= 1'b0; exwb_regWR <= 1'b0; exwb_memRD <= 1'b0; exwb_memWR <= 1'b0; ...
```

`stall` includes `wb_mem_stall = exwb_valid && (exwb_memRD || exwb_memWR) && !dmem_ready`
(`fyracore.v:392,400,412`). So the first cycle a memory op is *not* ready, the EX/WB register is
cleared — the request is withdrawn, `wb_mem_stall` self-clears, and the transaction never completes.
`if_mem_stall = !imem_ready` (`:391`) does the same thing to whatever is in WB.

Additionally `wb_regWR` (`:526`) is still asserted during that stall cycle, so a load writes
whatever is on `dmem_rdata` into rd before the data is valid.

**Why it matters:** invisible in CI because `tb/memory_model.v:39-40` hardwires
`imem_ready = dmem_ready = 1`. The tapeout target is external QSPI flash + PSRAM, which always has
wait states, so this is a guaranteed silicon failure, not a corner case.

**How to apply:** the fix is to hold EX/WB (not bubble it) while `wb_mem_stall`/`if_mem_stall` is
asserted, and gate `wb_regWR` / `instret_inc` on completion. Any future stall-related review must
be run against a wait-state memory model.

Reproduced 2026-09-05 with a scratchpad testbench (`dmem_ready` high 1 cycle in 4, `imem_ready`=1):
`lw a0` / `lw a1` returned correct data by luck (combinational rdata), but `sw a2, 8(t0)` was
dropped and the following `lw a3, 8(t0)` returned 0 instead of 0x12345679.

Related: [[finding-mret-multicommit-on-stall]], [[project-fyracore-overview]].
