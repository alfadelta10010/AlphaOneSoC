# riscv-dv generator work — handoff

**Written 2026-09-22.** Source: the 2026-09-22 adversarial RTL review of
`riscv-compliance_alfadelta10010`, plus the directed reproductions behind it.

Everything in this file is a **generator** defect, not an RTL defect. Each item
is a case where riscv-dv drives the DUT and Spike into territory the RISC-V
spec leaves undefined, or where the generated program omits setup that real
software always does. In every one of them **both models are conformant** and
the lockstep diff is still red. Fixing the RTL to match Spike would make the
core *less* correct.

## Where to work

- Repo: `localFiles/riscv-dv-svf`, branch **`sv-faithful`**
  (remote `git@github.com:alfadelta10010/riscv-dv-patched.git`).
- `sv-faithful` is the branch that tracks the SystemVerilog original's
  behaviour, which is the right home for all four items below: in each case the
  SV generator either already does the right thing or the constraint was lost
  in the Python port. **Check the SV source first** — `riscv_instr_gen_config.sv`,
  `riscv_asm_program_gen.sv`, `riscv_load_store_instr_lib.sv` — before writing
  anything new.
- Commit style: smallest functional change per commit, same as the RTL branch.
- The sibling branch `pyflow-fixes` is the max-bugs-fixed branch; do not
  cross-port to it without checking `localFiles/rdv-survey/RESULTS.md`.

## How to know you fixed something

Run on the **sandbox**, not the control machine (`ssh sandbox`; toolchains at
`/home/mempool/tools/{rv64-gcc-elf,rv32-isa-sim}/bin`). The control box runs
out of resources.

A fix is proven when the generated program's dut/ref dumps stop diverging *and*
the program still executes its body — check the dump line count, not just the
verdict. See `verification-false-passes` for the ways a test that never ran
reports green.

---

## 1. LR/SC — the generator emits unconstrained sequences

**Priority: highest.** This is the only item that is currently producing
failures in the regression.

### Symptom

```
lr.w  s6, (a0)
sw    s6, 0(a0)        # <-- plain store to the reserved address, same hart
sc.w  s7, s2, (a0)

DUT  s7 = 1  (SC failed)
Spike s7 = 0  (SC succeeded, store performed)
```

Measured identical at every memory wait-state setting, so it is not a timing
artefact. Seen in `rrag_config_out16_007453_..._00045` and
`rrag_config_out3_005650_..._00014` in the 2026-09-09 run, and it is the whole
of the residual rrag failure set (17 of 1000 in run 3).

### Why neither model is wrong

The unprivileged A chapter defines a **constrained** LR/SC sequence: between
the LR and the SC there may be only a bounded number of instructions, and no
loads, stores, AMOs or taken branches. The sequence above contains a store, so
it is **unconstrained**, and for unconstrained sequences the spec guarantees
nothing about whether the SC succeeds. An implementation may fail it for any
reason, and may also succeed.

So Spike succeeding and FyraCore failing are both conformant. There is nothing
to fix in the core, and a lockstep comparison of this sequence is meaningless.

There is a separate, real RTL inconsistency in this area (a plain store clears
the reservation but an AMO to the same address does not) which is being handled
on the RTL branch and is **not** your problem — it does not change the fact
that these sequences should never have been generated.

### What to change

Constrain the generator so that the instructions it places between a paired
`lr.w` and `sc.w` stay inside the constrained set: no loads, stores, AMOs or
taken branches, and a bounded count.

Start by diffing against the SV original — `riscv_amo_instr_lib.sv` builds
LR/SC sequences with exactly this constraint in upstream, and the likeliest
story is that the Python port dropped it (this is the same family of defect as
the enum-vs-string and append-vs-extend bugs already catalogued in
`pyflow-pyvsc-traps`).

If the constraint genuinely does not exist upstream either, add it, and say so
in the commit message so it can be sent upstream.

### Acceptance

A generated program containing LR/SC pairs where every pair is constrained, and
the rrag failure count drops from 17/1000 to 0 with no new failures.

---

## 2. U-mode tests never configure PMP

### Symptom

Generated U-mode tests compare a DUT that **denies every access** against a
Spike that **allows every access**. Every such test diverges on the first
U-mode memory access, for a reason that has nothing to do with the core.

### Why

PMP reset values differ, and here **the DUT is right and Spike is not**:

| | FyraCore | Spike |
|---|---|---|
| `pmpcfg0` at reset | `0x00000000` | `0x0000001f` |
| `pmpaddr0` at reset | `0x00000000` | `0xffffffff` |

The privileged spec requires writable PMP registers' A and L fields to reset to
0. Spike's permissive reset is a legacy convenience. With no PMP entry matching,
an M-mode access is allowed but a **U-mode access is denied** — which is the
correct architectural behaviour and exactly what Linux relies on.

Real software always sets PMP up before dropping to U-mode. `head.S` in the
kernel, under `CONFIG_RISCV_M_MODE`, does:

```asm
li   a0, -1
csrw pmpaddr0, a0
li   a0, 0x1f
csrw pmpcfg0, a0
```

That is NAPOT covering all of memory with R/W/X. The generator's U-mode tests
skip it.

### What to change

Add that four-instruction prologue to the setup of every generated test that
enters U-mode, before the `mret` that drops privilege. This is program setup,
not a constraint change, so it belongs wherever the generator emits its
privileged-mode init (`riscv_asm_program_gen.sv` / its Python equivalent,
`gen_privileged_mode_init` and friends).

### Acceptance

A U-mode generated test whose dut/ref dumps agree through the first U-mode
load, store and `ecall`. The RTL side of this is already proven: running that
exact `head.S` sequence followed by `mret` into U-mode produces a
**byte-identical trace to Spike** on the current RTL, including U-mode fetch,
load, store and `ecall` (cause 8).

---

## 3. Generated programs write `misa` extension bits

### Symptom

Spike permits `misa.M` and `misa.A` to be cleared; FyraCore holds them
read-only. A generated `csrw misa` that touches those bits diverges.

### Why neither model is wrong

`misa` is WARL and the spec explicitly allows an implementation to make
extension bits read-only. We do; Spike does not. Both conformant.

Note that `misa.C` **is** writable on FyraCore and is handled correctly,
including the rule that a write clearing C is refused when the next PC would
become misaligned. Do not constrain C away — that path is worth exercising.

### What to change

Constrain the generator not to write `misa` bits other than C, or exclude
`misa` from the randomly-written CSR set entirely. The second is simpler and
loses almost no coverage, since the only architecturally interesting `misa`
write on this core is the C toggle.

---

## 4. No `mtimecmp` init before `mip` is read

### Symptom

At reset, `mip` reads `0x00000000` on FyraCore and `0x00000080` on Spike —
Spike has MTIP asserted out of reset. Any generated program that reads `mip`
before programming the timer diverges on the first read.

### Why the DUT is right

`mtimecmp`'s reset value is architecturally **unspecified**. Spike resets it to
0, so `mtime >= mtimecmp` is true immediately and a timer interrupt is pending
before any software has installed a handler. `src/clint.v` resets it to
all-ones, which is the safe silicon choice — a core that comes out of reset
with a pending timer interrupt is a bring-up hazard.

Linux survives either way (`head.S` does `csrw CSR_IE, zero` early, and the
CLINT timer driver programs `mtimecmp` before enabling MTIE). It is generated
code with no such discipline that gets hurt.

### What to change

Emit `mtimecmp = -1` in the generated program's prologue, before anything reads
`mip` or enables interrupts. Same location as item 2's PMP prologue.

---

## Explicitly NOT generator work

Listed so nobody picks them up here by mistake.

- **`minstret` absolute values differ by 5.** Spike's boot ROM at `0x1000`
  retires 5 instructions before ours starts, and it cannot be disabled. Fix is
  in the comparison (compare deltas, or seed the DUT's counter) —
  **testbench**, not generator.
- **`mtime` tick rate.** FyraCore ticks per clock, Spike per ~100 retired
  instructions with no CLI knob. Fix is a `tick` input on `clint.v` driven by a
  retire counter in the testbench — **RTL + testbench**, not generator.
- **`mcountinhibit.IR` timing.** The writing instruction's own retire is
  counted under the *old* inhibit value on FyraCore and the new one on Spike.
  The spec says a CSR write takes effect after the writing instruction has
  otherwise completed, so **FyraCore is right and Spike is loose**. Filter in
  the comparison.
- **`mstatus` MPP reset** (`0x1800` here, `0` on Spike) and **MPP=01
  legalization**. Both legal; being handled on the RTL branch.
- **The testbench's `csr_committed` dump model** disagrees with the DUT's own
  registers for `mepc` (missing the IALIGN mask) and for locked PMP entries.
  That produces spurious lockstep failures and is a **testbench** fix.
