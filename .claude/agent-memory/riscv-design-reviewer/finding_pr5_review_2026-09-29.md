---
name: finding-pr5-review-2026-09-29
description: Adversarial PR #5 review (peripherals + verification claims) at 4b4ed8b -- no Critical/Major in uart/gpio; suites reproduce; CLINT-decode mutant escapes everything; mutation-claim overstated
metadata:
  type: project
---

Reviewed PR #5 (soc-fabric -> main) at RTL tip 4b4ed8b, 2026-09-29. Slice: uart.v, gpio.v, soc_bus/top IO
integration, pins doc, tb_uart/tb_gpio/tb_soc_periph + board models, and the PR body's test claims.

**Why:** gate before merging the SoC branch; builds on [[finding-periph-review-2026-09-27]].
**How to apply:** don't re-derive the verified list; re-check open items if gpio/uart/soc_bus/MANIFEST change.

Reproduced locally (scratch `git archive 4b4ed8b`, local Spike 1.1.1-dev == upstream refs):
- run.sh 106/106 (66 min loaded box), run.sh soc 66/66 (55 min), make test-all PASS (14.5 min),
  tb_uart 1,806,956 checks, tb_gpio 101,298, soc-periph 7/7 with the PR's cycle counts exactly.
- `./run.sh refs` regenerates all 68 committed .ref byte-for-byte.

Linux 8250 re-verified against mainline source (fetched 2026-09-29): 8250_of uses
uart_read_and_validate_port_properties -> platform_get_irq (NOT _optional) -> irq=0 poll, but logs
"IRQ index 0 not found" at error level; UPF_FIXED_TYPE -> no autoconfig; nbcon console_write/fifo_write,
wait_for_lsr timeout = 2 frame times (back-pressure makes timeout harmless); earlycon clock handling as doc says.

Findings (all Minor/Nit; no RTL bug found in uart/gpio this round):
- PROVEN verif gap: mutant `clint.we = dmem_req && dmem_we` (CLINT written by every store) passes all 7
  soc-periph programs AND 13 SoC directed tests incl. t_irq_slow/wfi_slow/irq_stress/mie_disable. Nothing
  asserts CLINT state is untouched by non-CLINT stores.
- PROVEN doc nit: keypad "discard one IN read" is insufficient at pipeline speed: after `sw OUT`, loads 1 and 2
  read stale rows, load 3 is first fresh (2-flop sync + registered out). Only hidden by ~57 clk/instr.
- Claims: "each commit names its mutants / every model check mutation-tested" false (7469370, 753a267,
  339e4a4, b99a228, dda3fd3, 71a8514, a6fb6dd, 8b2fb5b, eb4ad71 name none); "UART 23 / GPIO 12 mutants" vs
  16 (13 distinct) / 11 listed. t_ctl's #soc-skip reason says 40-clock period but t_ctl uses 100; LR/SC under
  interrupts has no SoC-speed test. 7 expect-mode .ref files are dead. pma_flash comment cites a removed stub.
- Mutants I ran: tb_uart caught all 5 (rts-ignores-busy, no break wait, IIR ungated, no glitch filter, FE
  frame kept) -- 3 only by TIMEOUT at 400 ms sim (~40 min wall each). tb_gpio caught 3-flop IN; soc-periph
  alone misses UART 1-flop sync and GPIO 3-flop IN (unit benches catch them). GPIO no-hold caught by SSD1331
  tAH/tCSH at SoC level. UART ready-without-sel caught only by irq_stall.
