# RTL fix branch — progress

**Branch:** `riscv-compliance_alfadelta10010`, 19 commits on top of `main` (`fc24364`).
Now checked out directly in `/home/alfadelta10010/projects/AlphaOneSoC` — the
separate worktree at `projects/worktrees/riscv-compliance` is gone, commits are fine.

**Status:** 21/21 directed tests green at HEAD (`7cd1eb6`) — 20 compared against
Spike, plus `lrsc_policy`, which is checked against the intended DUT policy rather
than Spike because two of its cases are a deliberate, spec-legal divergence (see
`027a17d`). Three silicon-fatal bugs fixed. Not tapeout-ready — see *Open* below.

---

## Commits

| | |
|---|---|
| `68d85b6` | **tb: wait states.** `IMEM_WAIT`/`DMEM_WAIT`, `*_RANDOM`, `MEM_SEED`, all plusargs. `0` = old always-ready. Writes commit only on the ready cycle; rdata is X while not ready. **This is what exposed everything below.** |
| `2167485` | **CRIT.** Hold EX/WB across a data-memory stall instead of bubbling. Gates `wb_regWR`, `instret_inc`, `dbg_retired`, reservation, AMO capture. |
| `760a524` | **CRIT.** MRET commits once, not once per stall cycle. |
| `fc4c84d` | Illegal LOAD/STORE/JALR stop asserting `memRD`/`memWR`/`doJump`. |
| `11384f8` | Exception priority: illegal instruction above the address exceptions (Table 3.7). |
| `6c564b3` | Illegal-instruction `mtval` = the faulting encoding, not 0. |
| `fce59af` | **CRIT.** No interrupt injection while stalled (`stall_other`, not `stall` — `stall` closes a comb loop via `flush`→`muldiv_start`). |
| `f2e42b5` | MRET not applied from a fetch-faulting word. |
| `b7c5805` | pmpcfg WARL: reserved bits read 0, NA4 legal. Fixed in all three copies. |
| `7babc48` | `csr_fwd_data` missing WARL masks (`mie`, `mcounteren`, `mcountinhibit`, `mip`, `mepc` IALIGN). |
| `a005334` | Drop three unread counter ports. |
| `21fbe65` | `marchid` parameterised, default 0 (5 is Spike's registered ID); tb overrides to 5. |
| `36995e0` | Three comments that stated the opposite of the truth. |
| `4437a41` | LR/SC to an IO window faults (cause 5/7); AMO there still succeeds. |
| `2e6718b` | **CRIT.** muldiv sticky-done + `!muldiv_want` on `irq_inject`. |
| `15a23df` | **CRIT.** CSR write commits before the MRET transform; `mstatus_mpp` exported post-write. |
| `027a17d` | AMO invalidates the reservation like a store (drop `&& !exwb_isAmo`). |
| `8485cf0` | `mstatus.TW`. U-mode WFI no longer unconditionally illegal. |
| `7cd1eb6` | `mstatus.MPRV`. Data PMP uses MPP; MRET clears below M; EX-stage forward. |

### The three that would have killed silicon

**muldiv livelock (`2e6718b`).** `muldiv_done` is a one-cycle pulse and the result
is only latched by the EX/WB `else` arm, which needs `!stall`. On the done cycle
`muldiv_stall` has already dropped, so one coincident `if_mem_stall` binned the
result and restarted the operation. Fixed latency + free-running wait counter =
**phase lock**, not a race. Retires, 3 = wedged:

```
IMEM_WAIT        0      1      2      3      5      8     15
before      100011  74996      3      3      3      3      3
after       100011  74996  49999  37500  25002  16670   9378
```

After = exactly `100000/(W+1)`, i.e. fetch-bandwidth-limited. QSPI XIP is
*deterministic* multi-wait-state — precisely the case that hung.

**`csrw <CSR>; mret` write loss (`15a23df`).** Two bugs. `csr.v`'s write block was
`trap > mret > we` and `mret` is an EX signal, so a `csrw` in WB was skipped for
**every** CSR. Fixing that exposed the second: `mstatus_mpp` was exported from the
raw register, so the MRET privilege restore still read the pre-write MPP and dropped
to U-mode. **Inverted timing signature — `IMEM_WAIT >= 1` *masks* it.** It only
appears when fetch is fast, so it would survive slow-flash bring-up and bite when a
prefetch buffer or I-cache is added.

**EX/WB stall bubble (`2167485`).** `stall` contains `wb_mem_stall`, which is derived
from `exwb_memRD`/`memWR`. Bubbling dropped those bits, withdrawing the request
before `dmem_ready`; the stall self-cleared and nothing retried. Stores vanished.

---

## How to verify

```
cd tests/directed
./run.sh build     # rebuild sim from ../../src, ../../tb
./run.sh           # full regression vs Spike
./run.sh refs      # regenerate Spike references
./run.sh one memops +DMEM_WAIT=3
```

Tests and `.ref` files are in `tests/directed/`, artifacts in `tests/directed/out/`
(gitignored). **All untracked** — decide whether they get committed.

`lrsc_policy` uses `chk_exact` rather than `chk`: it asserts the intended policy,
not Spike agreement. Any other test that diverges from Spike on purpose should go
the same way, so a real regression stays distinguishable from a known difference.

Toolchain: `riscv64-unknown-elf-*`, `spike`, `iverilog` on PATH. Control machine has
them; each run is ~30 s, dominated by the testbench's 33M-entry memory zero-fill.

---

## Environment

**Sandbox is down.** `mempool.lan` went from "no route to host" to not resolving at
all. It died mid-sweep during the session. Everything since has been local.
Bring-up procedure is in the `sandbox-regression-server` memory.

---

## Open

### Repairs — no decision needed, just not done

1. **`imem_valid`/`dmem_valid` bus strobes.** The reviewer rates this as blocking SoC
   integration. There is no request strobe on either port, so a controller cannot
   tell when a transaction is wanted, stale addresses get presented as reads every
   cycle (fatal for a UART RX FIFO), and **a failing `sc.w` issues no transaction but
   still waits for `dmem_ready` — which hangs forever on a real request/ack bus.**
2. **Aligned-word instruction fetch** (~17 flops + a 2-state FSM). Fixes the
   straddling-fetch hole for PMA *and* PMP without a second PMP checker, and matches
   what QSPI/PSRAM can actually do — neither can read 4 bytes at a 2-byte-aligned
   address without splitting the burst. Today a 32-bit instruction at the top of the
   window **executes with a garbage upper half** and commits a junk register write.
3. **CSR conformance gaps.** `mstatush` and `mhpmcounter3-31`/`mhpmevent3-31` trap
   instead of reading zero. `mip`'s writable mask is inverted — it is `~0x888`,
   allowing writes to everything except the three real bits; correct value is 0.

### Decisions — yours

4. **`mtime` prescaler.** Today it is a 64-bit incrementer clocked every cycle with a
   combinational 64-bit compare feeding `irq_inject → flush → next_pc` — a likely
   sky130 critical path and a lot of toggling. KianV runs 10 kHz off ~70 MHz for
   exactly this reason. Make the divisor a writable register, not a constant, or the
   DTB's `timebase-frequency` goes wrong if the clock is retuned post-silicon.
5. **Memory map.** Proposal: PSRAM `0x8000_0000` (Spike's own base — deletes all tb
   remapping), flash `0x2000_0000`, CLINT stays `0x0200_0000`, UART `0x1000_0000` so
   `earlycon` works unmodified, syscon for poweroff/reboot. **Note the PMA parameters
   have only one executable window and flash needs to be executable too for XIP.**
6. **Drop the PLIC.** KianV boots NOMMU Linux on one hart without one. 1–2k gates for
   no functional gain; a 1-bit claim register in syscon covers MEIP if ever needed.
7. **LR/SC trap clear — still unresolved.** `docs/LR-SC_decision.md`'s formula has no
   trap term; its single-hart form is literally `reservation_clear = executing_SC`,
   which would delete ours. The reviewer says keep it. **I changed nothing.** Neither
   source says a Linux boot depends on it — `ret_from_exception` clears the
   reservation in software with a dummy SC — so this is purely about bare-metal and
   bootloader robustness, and it costs one OR term.
8. **Where the directed tests live.** Currently untracked in `tests/directed/`.

---

## Gotchas worth keeping

- **Deterministic and randomised wait states catch *different* bugs.** Randomised
  mode *hides* the muldiv livelock (always escapes the phase lock); wait states
  *hide* the `csrw; mret` loss (it needs fast fetch). Run both, and sweep
  `IMEM_WAIT` and `DMEM_WAIT` independently.
- **Livelocks here are congruence effects, not thresholds.** Wait states do not widen
  the interrupt-vulnerable window — `irq_inject`'s `!stall_other` gate pins it at 2
  cycles — they change the loop length and so *re-roll which periods are unsafe*.
  A sweep at one wait setting says nothing about another. Always run a non-atomic
  control loop alongside an atomic one.
- **Spike pads single-digit register names to width 3** (`x8  0x…`). A grep for
  `\bx8 0x` silently returns nothing for x0–x9 while matching x10–x31 fine. This
  nearly produced a false divergence report. Use `' +'`.
- **`iverilog … | head -5 && echo OK` reports `head`'s exit status.** It printed
  BUILD_OK over a real elaboration error. Test `$?` directly.
- **MPRV is only observable through PMP**, so an MPRV test is really a PMP test and
  inherits the PMP-reset divergence (we reset to 0 per spec, Spike resets permissive
  `0x1f`/`~0`). Configure an explicit unlocked entry with no permissions instead.
- **The EX-consumes/WB-commits staleness family has now bitten three times**: `misa.C`
  (still open), `mstatus_mpp` (fixed in `15a23df`), MPRV (created and fixed inside
  `7cd1eb6`). Whenever a new mstatus field is read outside `csr.v`, check whether the
  consumer sits in EX and needs the forward. A test only catches it if the write and
  the dependent access are **adjacent**.
- **WARL is implemented four times** (`csr.v`, `csr_fwd_data`, tb `csr_committed`,
  plus the mtvec/mepc masks). That duplication has produced two separate defects.

---

## Untracked artifacts

| path | what |
|---|---|
| `tests/directed/` | 35 `.S` tests, `link.ld`, `run.sh`, `.ref` files |
| `docs/riscv-dv-generator-handoff.md` | Generator work for another agent → `localFiles/riscv-dv-svf`, branch `sv-faithful`. Four items: unconstrained LR/SC sequences, U-mode tests missing the `head.S` PMP prologue, `misa` M/A writes, no `mtimecmp` init before `mip` is read. Has an explicit "NOT generator work" list. |
| `docs/LR-SC_decision.md` | Your second-opinion doc. Cites the spec backwards in one place: it lists another hart's store/AMO as *breaking* forward progress, where the spec lists it among the events that **satisfy** the guarantee. |
| `.claude/agent-memory/riscv-design-reviewer/finding_branch_review_2026-09-22.md` | Full audit |
| `.claude/agent-memory/riscv-design-reviewer/finding_lrsc_policy_2026-09-22.md` | LR/SC verdict + policy matrix |
| `.claude/agent-memory/riscv-design-reviewer/reference_kianv_memory_map.md` | KianV DTS benchmark |

---

## Biggest caveat

**Verified against 20 directed tests, not against arch-test or riscv-dv.** Those have
not run since before commit 1. They are what would catch a regression nobody thought
to write a test for — and the branch touches the trap chain, the CSR file, the stall
logic and the reservation. Run them before trusting this.
