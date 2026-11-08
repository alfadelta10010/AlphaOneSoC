# FyraCore RV32IMCA+Zicsr+Zifencei — Build & Test Makefile
# Usage:
#   make test-all        — Run all component + CPU tests
#   make test-alu        — Run ALU testbench
#   make test-cpu        — Compile and run CPU with default program
#   make asm FILE=x.S    — Assemble and run any .S file
#   make benchmarks      — Run all benchmark programs
#   make clean           — Remove build artifacts

IVERILOG   := iverilog
VVP        := vvp
TOOLCHAIN  := riscv64-unknown-elf-
MARCH      := rv32imac
MABI       := ilp32

SRC_DIR    := src
TB_DIR     := tb
BUILD_DIR  := build
TESTS_DIR  := tests
SCRIPTS_DIR:= scripts

# All source files for full CPU build
SRC_FILES  := $(SRC_DIR)/alu.v \
              $(SRC_DIR)/branchCtrl.v \
              $(SRC_DIR)/clint.v \
              $(SRC_DIR)/compressed_decoder.v \
              $(SRC_DIR)/controller.v \
              $(SRC_DIR)/csr.v \
              $(SRC_DIR)/decoder.v \
              $(SRC_DIR)/fyracore.v \
              $(SRC_DIR)/muldiv.v \
              $(SRC_DIR)/pmp.v \
              $(SRC_DIR)/regFile.v \
              $(SRC_DIR)/rf_top.v \
              $(SRC_DIR)/regs.v \
              $(SRC_DIR)/signExt.v

# Phony targets
.PHONY: all test-all test-components test-cpu benchmarks clean help \
        test-alu test-branchctrl test-decoder test-signext test-controller \
        test-regfile test-csr test-compressed test-muldiv test-pmp test-clint test-syscon test-seeds \
        test-qspi test-qspi-ddr-sweep test-pmod-dtr test-uart test-gpio test-spi test-soc-periph test-syscon-soc test-soc-spi \
        test-wrapper test-wrapper-soc test-gl asm bounds-qspi \
        rivercore-build rivercore-test

all: test-all

help:
	@echo "FyraCore Build System"
	@echo "====================="
	@echo ""
	@echo "Component tests:"
	@echo "  make test-alu          Run ALU testbench"
	@echo "  make test-branchctrl   Run branch controller testbench"
	@echo "  make test-decoder      Run decoder testbench"
	@echo "  make test-signext      Run sign-extension testbench"
	@echo "  make test-controller   Run controller testbench"
	@echo "  make test-regfile      Run register file testbench"
	@echo "  make test-csr          Run CSR testbench"
	@echo "  make test-syscon       Run syscon + watchdog testbench"
	@echo "  make test-compressed   Run compressed decoder testbench"
	@echo "  make test-qspi         Run memory controller + QSPI engine testbench"
	@echo "  make test-uart         Run UART testbench"
	@echo "  make test-gpio         Run the GPIO + SPI register and pin testbench"
	@echo "  make test-spi          Run the SPI controller bench (timing model, MISO probe, round-trip sweep)"
	@echo "  make test-soc-periph   Run the peripheral programs through the whole SoC"
	@echo "  make test-soc-spi      Run the SD card and shared-bus programs through the SoC at 62.5 MHz"
	@echo "  make test-syscon-soc   Run syscon (reboot, strap, fail, watchdog) through the whole SoC"
	@echo "  make test-wrapper      Run the TinyTapeout top level, pins only"
	@echo "  make test-gl NETLIST=.. PDK_ROOT=..  One tt_pins run on a gate-level netlist (smoke)"
	@echo "  make test-components   Run all component tests"
	@echo ""
	@echo "CPU tests:"
	@echo "  make test-cpu          Compile full CPU (syntax check)"
	@echo "  make asm FILE=test.S   Assemble and run any .S file"
	@echo "  make benchmarks        Run all test programs"
	@echo ""
	@echo ""
	@echo "River Core integration:"
	@echo "  make rivercore-build          Build river_core testbench"
	@echo "  make rivercore-test HEX=f.hex Run test with river_core dump"
	@echo ""
	@echo "  make test-all          Run everything"
	@echo "  make clean             Remove build artifacts"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# Run a unit testbench: $(1) the simulator, $(2) its plusargs, $(3) a suffix
# for the log. The target fails unless the run exits 0 (a $fatal exits 1,
# which a pipe through tee used to hide), prints a PASS line, and prints no
# FAIL, TIMEOUT, ERROR or FATAL line. The testbenches print FAIL/TIMEOUT
# lines and then $finish, which exits 0, and one that ends early or checks
# nothing prints no PASS, so the exit status alone is not enough either.
run_tb = cd $(BUILD_DIR) && { $(VVP) -n $(1) $(2) > $(1)$(3).log 2>&1; rc=$$?; cat $(1)$(3).log; \
         [ $$rc -eq 0 ] && grep -q '^PASS' $(1)$(3).log && ! grep -qE '^(FAIL|TIMEOUT|ERROR|FATAL)' $(1)$(3).log; }

# ============================================================
#  Component Testbenches
# ============================================================

test-alu: $(BUILD_DIR)
	@echo "=== Testing ALU ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_alu $(SRC_DIR)/alu.v $(SRC_DIR)/branchCtrl.v $(TB_DIR)/tb_alu.v
	@$(call run_tb,tb_alu)

test-branchctrl: $(BUILD_DIR)
	@echo "=== Testing Branch Controller ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_branchCtrl $(SRC_DIR)/branchCtrl.v $(TB_DIR)/tb_branchCtrl.v
	@$(call run_tb,tb_branchCtrl)

test-decoder: $(BUILD_DIR)
	@echo "=== Testing Decoder ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_decoder $(SRC_DIR)/decoder.v $(TB_DIR)/tb_decoder.v
	@$(call run_tb,tb_decoder)
	@$(IVERILOG) -o $(BUILD_DIR)/tb_rf_fields $(SRC_DIR)/decoder.v $(SRC_DIR)/compressed_decoder.v \
		$(TB_DIR)/tb_rf_fields.v
	@$(call run_tb,tb_rf_fields)

test-signext: $(BUILD_DIR)
	@echo "=== Testing Sign Extension ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_signExt $(SRC_DIR)/signExt.v $(TB_DIR)/tb_signExt.v
	@$(call run_tb,tb_signExt)

test-controller: $(BUILD_DIR)
	@echo "=== Testing Controller ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_controller $(SRC_DIR)/controller.v $(TB_DIR)/tb_controller.v
	@$(call run_tb,tb_controller)

test-regfile: $(BUILD_DIR)
	@echo "=== Testing Register File ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_regFile $(SRC_DIR)/regFile.v $(SRC_DIR)/rf_top.v $(TB_DIR)/tb_regFile.v
	@$(call run_tb,tb_regFile)
	@$(call run_tb,tb_regFile,+RF_X,_x)
	@$(call run_tb,tb_regFile,+RF_X +RF_COLLIDE_X,_cx)

test-csr: $(BUILD_DIR)
	@echo "=== Testing CSR ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_csr $(SRC_DIR)/csr.v $(TB_DIR)/tb_csr.v
	@$(call run_tb,tb_csr)
	@$(IVERILOG) -o $(BUILD_DIR)/tb_inc64 -s tb_inc64 $(SRC_DIR)/csr.v $(TB_DIR)/tb_inc64.v
	@$(call run_tb,tb_inc64)

test-compressed: $(BUILD_DIR)
	@echo "=== Testing Compressed Decoder ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_cdec $(SRC_DIR)/compressed_decoder.v $(TB_DIR)/tb_compressed_decoder.v
	@$(call run_tb,tb_cdec)

test-muldiv: $(BUILD_DIR)
	@echo "=== Testing MulDiv Unit ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_muldiv $(SRC_DIR)/muldiv.v $(TB_DIR)/tb_muldiv.v
	@$(call run_tb,tb_muldiv)

test-pmp: $(BUILD_DIR)
	@echo "=== Testing PMP checker ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_pmp $(SRC_DIR)/pmp.v $(TB_DIR)/tb_pmp.v
	@$(call run_tb,tb_pmp)

test-clint: $(BUILD_DIR)
	@echo "=== Testing CLINT ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_clint $(SRC_DIR)/clint.v $(SRC_DIR)/csr.v $(TB_DIR)/tb_clint.v
	@$(call run_tb,tb_clint)

test-syscon: $(BUILD_DIR)
	@echo "=== Testing syscon + watchdog ==="
	@$(IVERILOG) -I $(TB_DIR) -o $(BUILD_DIR)/tb_syscon $(SRC_DIR)/syscon.v $(TB_DIR)/tb_syscon.v
	@$(call run_tb,tb_syscon)

# The seeded random unit benches, once per seed: make test-seeds SEEDS="1 2 3".
# Each bench prints its seed; rerun one failure with its +SEED=.
SEEDS ?= 1 2 3 4 5 6 7 8
SEEDED := tb_alu tb_branchCtrl tb_signExt tb_decoder tb_csr tb_muldiv tb_pmp tb_clint tb_syscon tb_uart tb_gpio tb_spi
test-seeds: test-alu test-branchctrl test-signext test-decoder test-csr test-muldiv test-pmp test-clint test-syscon test-uart test-gpio test-spi
	@for s in $(SEEDS); do for t in $(SEEDED); do \
		( $(call run_tb,$${t},+SEED=$$s,_seed$$s) ) > /dev/null || { echo "FAIL $$t +SEED=$$s"; exit 1; }; \
		grep -h '^PASS' $(BUILD_DIR)/$${t}_seed$$s.log; \
	done; done

# The memory path (mem_ctrl + qspi_ctrl) against the QSPI Pmod model:
#   default           2 ns device delay, 1 ns hold
#   QSPI_DELAY=19     just under one SCK period, which rd_late = 0 must take
#   RD_LATE, 25 ns    past one SCK period, which needs the rd_late strap and
#                     a round trip of more than one clock (hold 12 ns)
#   PSRAM_WRAP        a PSRAM that wraps at 1 KB pages (no row crossing)
#   PSRAM_QPI + FLASH_CRM, FLASH_QPI, FLASH_QPI + FLASH_CRM, FLASH_DCRM,
#   PSRAM_A_QPI + FLASH_DCRM, PSRAM_B_QPI + FLASH_QPI
#                     devices handed over in states the start-up sequence
#                     has to undo
# then tb_qspi_stress, with core-shaped request streams: plain, late and
# wrapping, and twice more with resets dropped into the traffic.
# Every run is made three times: streaming flash reads on (stream_en 1),
# +NOSTREAM (0) and +STREAM_TOGGLE (flipped at random clocks).
QSPI_LATE := +RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12
QSPI_RUNS := "" "+QSPI_DELAY=19" "$(QSPI_LATE)" "+PSRAM_WRAP" \
             "+PSRAM_QPI +FLASH_CRM" "+FLASH_QPI" "+FLASH_QPI +FLASH_CRM" "+FLASH_DCRM" \
             "+PSRAM_A_QPI +FLASH_DCRM" "+PSRAM_B_QPI +FLASH_QPI"
# DDR flash reads (EDh), the 10 ns clock: capture points 0 and 1 suit the default 2 ns delay,
# point 2 needs the slower device; +MODESW adds the mode switches with a stream open.
QSPI_DDR_RUNS := "+DDR +DDR_CAP=0" "+DDR +DDR_CAP=1" "+DDR +DDR_CAP=2 +QSPI_DELAY=12 +QSPI_HOLD=6" \
                 "+DDR +DDR_CAP=1 +PSRAM_WRAP" "+DDR +DDR_CAP=1 +PSRAM_QPI +FLASH_CRM" "+MODESW"
QSPI_STRESS_RUNS := "+DDR +DDR_CAP=1" "+DDR +DDR_CAP=0 +RESETS" "" "$(QSPI_LATE) +PSRAM_WRAP" "+RESETS +QSPI_DELAY=19" "+RESETS $(QSPI_LATE) +PSRAM_WRAP +SEED=2"
test-qspi: $(BUILD_DIR)
	@echo "=== Testing QSPI memory path ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_qspi $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/req_hold_check.v $(TB_DIR)/tb_qspi.v
	@cd $(BUILD_DIR) && for sv in "" +NOSTREAM +STREAM_TOGGLE; do for args in $(QSPI_RUNS) $(QSPI_DDR_RUNS); do \
		$(VVP) tb_qspi $$args $$sv > tb_qspi.log 2>&1; grep -E 'PASS|FAIL|ERROR|TIMEOUT' tb_qspi.log | head -3; \
		grep -q '^PASS' tb_qspi.log || exit 1; \
	done; done
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_qspi_stress $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/req_hold_check.v $(TB_DIR)/tb_qspi_stress.v
	@cd $(BUILD_DIR) && for sv in "" +NOSTREAM +STREAM_TOGGLE; do for args in $(QSPI_STRESS_RUNS); do \
		$(VVP) tb_qspi_stress $$args $$sv > tb_qspi_stress.log 2>&1; grep -E '^PASS|FAIL|ERROR|TIMEOUT' tb_qspi_stress.log | head -3; \
		grep -q '^PASS' tb_qspi_stress.log || exit 1; \
	done; done

# DDR capture-point sweep (DDR-CONTRACT 3.3): the 60 MHz clock, a device whose flash output is
# valid from R + 7 ns after the SCK edge to R + 16.67 + 1 ns (tCLQV 6, a 2 ns spread around it),
# for round trips R, every DDR_CAP. The passing set is printed per R (c = DDR_CAP + 1). The
# same with +DTR_LAUNCH=1 (a device that launches the first nibble half an SCK late) must pass
# no capture point at all: a streamed run detects it.
SWEEP_R := 8 11 14 17 20 23 26 29 32
test-qspi-ddr-sweep: $(BUILD_DIR)
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_qspi_sweep $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/req_hold_check.v $(TB_DIR)/tb_qspi.v
	@cd $(BUILD_DIR) && for la in 0 1; do echo "DTR_LAUNCH=$$la"; for r in $(SWEEP_R); do \
		pass=""; for cap in 0 1 2 3 4 5 6 7; do \
			$(VVP) tb_qspi_sweep +SWEEP +DDR +DDR_CAP=$$cap +CLK_HALF_PS=8333 +QSPI_DELAY=$$((r+7)) \
				+QSPI_HOLD=$$((r+1)) +DTR_LAUNCH=$$la > sweep.log 2>&1; \
			grep -q '^SWEEP PASS' sweep.log && pass="$$pass c=$$((cap+1))"; \
		done; echo "  R=$$r ns: passing c:$${pass:- none}"; done; done

# The Pmod model's DTR (EDh) unit bench: pass, expected-fail and limit-raise cases.
test-pmod-dtr:
	@echo "=== Testing the QSPI Pmod model's DTR read ==="
	@BUILD_DIR=$(BUILD_DIR)/pmod_dtr bash $(TB_DIR)/pmod_dtr_run.sh

# The UART against spec-derived models: register/lane scoreboard, a
# reference receiver on TX, an asynchronous reference transmitter on RX
# (baud error, glitches, framing errors, overruns), RTS# and back-pressure
# checks, and a constrained-random run (+SEED=, +NRAND= for more).
test-uart: $(BUILD_DIR)
	@echo "=== Testing UART ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_uart $(SRC_DIR)/uart.v $(TB_DIR)/tb_uart.v
	@$(call run_tb,tb_uart)

# GPIO OUT/IN and the SPI controller's registers: register and pin model, a
# mode-3 SPI checker at several BAUD values, back-pressure, and a random run.
# The SPI engine's timing, modes and receive path are in test-spi.
test-gpio: $(BUILD_DIR)
	@echo "=== Testing GPIO + SPI registers ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_gpio $(SRC_DIR)/gpio.v $(SRC_DIR)/spi.v $(TB_DIR)/tb_gpio.v
	@$(call run_tb,tb_gpio)

# The SPI controller (gpio + spi) against a timing model written from the
# spec (tb/tb_spi.v, WO-29): directed sections T01-T14, a random phase with
# coverage floors, the MISO probe and the round-trip sweep. +SEED=, +CYCLES=.
test-spi: $(BUILD_DIR)
	@echo "=== Testing the SPI controller ==="
	@$(IVERILOG) -g2012 -I $(TB_DIR) -o $(BUILD_DIR)/tb_spi $(SRC_DIR)/gpio.v $(SRC_DIR)/spi.v $(TB_DIR)/tb_spi.v
	@$(call run_tb,tb_spi)

# The peripherals through the whole SoC: each tests/soc/*.S program boots
# from the QSPI Pmod model's flash with the demo board's devices on the pins
# (RP2350 UART with CTS, SSD1331, keypad) -- tb/tb_soc_periph.v. A run fails
# on a FAIL, ERROR or TIMEOUT line or a missing PASS; all runs go first.
# `make test-soc-periph MB_UART=1` (and test-syscon-soc) build the programs with
# -DMB_UART, as the pins bench does (tests/soc/periph.h): they send their cues and
# values over the UART as well, the benches strip those frames from the stream
# and follow the program's divisor (+MB_DIV), and every floor and check stays.
# MB_DIV per program as in scripts/gl/build_isa.sh; the programs that run at the
# reset divisor need none (4 here).
define MB_FLAGS
case $$t in uart_echo|irq_stall) d=4;; uart_hello|uart_linux|periph_access|syscon_reboot) d=;; *) d=1;; esac; \
	fl="-DMB_UART"; pl="+MB_UART"; if [ -n "$$d" ]; then fl="$$fl -DMB_DIV=$$d"; pl="$$pl +MB_DIV=$$d"; fi
endef
SOC_PERIPH_TESTS := uart_hello uart_echo uart_linux oled_spi keypad irq_stall periph_access clint_decode
SOC_PERIPH_DIR   := $(BUILD_DIR)/soc_periph
test-soc-periph: $(BUILD_DIR)
	@echo "=== Testing the peripherals through the SoC ==="
	@mkdir -p $(SOC_PERIPH_DIR)
	@$(IVERILOG) -g2012 -o $(SOC_PERIPH_DIR)/sim -s tb_soc_periph $(SRC_FILES) \
		$(SRC_DIR)/qspi_ctrl.v $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/soc_bus.v $(SRC_DIR)/uart.v \
		$(SRC_DIR)/gpio.v $(SRC_DIR)/spi.v $(SRC_DIR)/syscon.v $(SRC_DIR)/alphaone_soc.v $(TB_DIR)/qspi_pmod_model.v \
		$(TB_DIR)/req_hold_check.v $(TB_DIR)/rp2350_uart_model.v $(TB_DIR)/ssd1331_model.v \
		$(TB_DIR)/keypad_model.v $(TB_DIR)/sd_spi_model.v $(TB_DIR)/tb_soc_periph.v
	@cd $(SOC_PERIPH_DIR) && bad=0; for t in $(SOC_PERIPH_TESTS); do \
		fl=; pl=; if [ -n "$(MB_UART)" ]; then $(MB_FLAGS); fi; \
		$(TOOLCHAIN)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles $$fl \
			-T $(CURDIR)/$(TESTS_DIR)/soc/link.ld -I$(CURDIR)/$(TESTS_DIR)/soc \
			$(CURDIR)/$(TESTS_DIR)/soc/$$t.S -o $$t.elf || { bad=1; continue; }; \
		$(TOOLCHAIN)objcopy -O verilog -j .text.init -j .text -j .rodata \
			--change-addresses=-0x20000000 $$t.elf $$t.hex; \
		$(VVP) -n sim +TEST=$$t +FLASH_FILE=$(CURDIR)/$(SOC_PERIPH_DIR)/$$t.hex $$pl > $$t.log 2>&1; \
		grep -E '^(PASS|FAIL|ERROR|TIMEOUT)|^[a-z_]+: ' $$t.log | head -6; \
		if grep -qE '^(FAIL|ERROR|TIMEOUT)' $$t.log || ! grep -q '^PASS' $$t.log; then bad=1; fi; \
	done; exit $$bad

# The SD card and the shared SPI bus through the whole SoC at the chip clock (16 ns;
# tb_soc_periph.v built with -DTCLK_NS=16.0): tests/soc/sd_init.S, spi_mixed.S and
# sd_reboot.S against tb/sd_spi_model.v and the SSD1331 model, with pad delays. Each
# run is "label;program;cflags;plusargs"; the PASS lines carry exact counts, and the
# negative controls (rt 40 ns at BAUD 1, no card, DO stuck at 1) PASS only when
# the program FAILS. `make test-soc-spi MB_UART=1` also sends the reports over the UART;
# `ONLY="sd_init sd_b1"` runs just those labels.
RB_DLY_A ?= 700
RB_DLY_B ?= 900
SOC_SPI_RUNS := "sd_init;sd_init;;" "sd_init_busy0;sd_init;;+SD_BUSY=0" "sd_b1;sd_init;-DSD_HZ=15625000;" \
	"sd_b1_rt40;sd_init;-DSD_HZ=15625000;+RT_OUT=20 +RT_IN=20 +EXPECT_FAIL" \
	"sd_init_rt60;sd_init;;+RT_OUT=30 +RT_IN=30" "sd_absent;sd_init;;+EXPECT_FAIL" \
	"sd_stuck_do;sd_init;;+SD_STUCK_DO +EXPECT_FAIL" "spi_mixed;spi_mixed;;" \
	"sd_reboot_a;sd_reboot;-DRB_DLY=$(RB_DLY_A);" "sd_reboot_b;sd_reboot;-DRB_DLY=$(RB_DLY_B);"
SOC_SPI_DIR := $(BUILD_DIR)/soc_spi
test-soc-spi: $(BUILD_DIR)
	@echo "=== Testing the SD card and the shared SPI bus through the SoC (62.5 MHz) ==="
	@mkdir -p $(SOC_SPI_DIR)
	@$(IVERILOG) -g2012 -DTCLK_NS=16.0 -o $(SOC_SPI_DIR)/sim -s tb_soc_periph $(SRC_FILES) \
		$(SRC_DIR)/qspi_ctrl.v $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/soc_bus.v $(SRC_DIR)/uart.v \
		$(SRC_DIR)/gpio.v $(SRC_DIR)/spi.v $(SRC_DIR)/syscon.v $(SRC_DIR)/alphaone_soc.v $(TB_DIR)/qspi_pmod_model.v \
		$(TB_DIR)/req_hold_check.v $(TB_DIR)/rp2350_uart_model.v $(TB_DIR)/ssd1331_model.v \
		$(TB_DIR)/keypad_model.v $(TB_DIR)/sd_spi_model.v $(TB_DIR)/tb_soc_periph.v
	@cd $(SOC_SPI_DIR) && bad=0; for r in $(SOC_SPI_RUNS); do \
		IFS=';'; set -- $$r; unset IFS; [ -z "$(ONLY)" ] || case " $(ONLY) " in *" $$1 "*) ;; *) continue;; esac; label=$$1; prog=$$2; cf=$$3; pa=$$4; \
		fl=$$cf; pl=; if [ -n "$(MB_UART)" ]; then fl="$$fl -DMB_UART -DMB_DIV=1"; pl="+MB_UART +MB_DIV=1"; fi; \
		$(TOOLCHAIN)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles $$fl \
			-T $(CURDIR)/$(TESTS_DIR)/soc/link.ld -I$(CURDIR)/$(TESTS_DIR)/soc \
			$(CURDIR)/$(TESTS_DIR)/soc/$$prog.S -o $$label.elf || { bad=1; continue; }; \
		$(TOOLCHAIN)objcopy -O verilog -j .text.init -j .text -j .rodata \
			--change-addresses=-0x20000000 $$label.elf $$label.hex; \
		( ulimit -v 4000000; $(VVP) -n sim +TEST=$$label +FLASH_FILE=$(CURDIR)/$(SOC_SPI_DIR)/$$label.hex $$pl $$pa > $$label.log 2>&1 ); \
		grep -E '^(PASS|FAIL|ERROR|TIMEOUT)|^[a-z_0-9]+: ' $$label.log | head -6; \
		if grep -qE '^(FAIL|ERROR|TIMEOUT)' $$label.log || ! grep -q '^PASS' $$label.log; then bad=1; fi; \
	done; exit $$bad

# syscon through the whole SoC (tb/tb_syscon_soc.v): each tests/soc/syscon_*.S
# program boots from the QSPI Pmod model's flash; the bench checks every syscon
# load against its own model, every reboot's timing and pins, the strap path
# and the watchdog. Each run is "<program> [plusargs]"; +TEST= and +FLASH_FILE=
# are added here. A run fails on a FAIL, ERROR or TIMEOUT line or a missing
# PASS; all runs go first.
# ddr_flash@<n> is tests/soc/ddr_flash.S built for DDR_CAP point n (-DDDR_PT=n), run at device
# delays that point reads at the bench's 20 ns clock (window [delay, 20 + hold), point n captures
# at 10 * (n + 1) ns).
SYSCON_SOC_RUNS := "ddr_flash@0" "ddr_flash@1 +QSPI_DELAY=12 +QSPI_HOLD=6" "ddr_flash@2 +QSPI_DELAY=22 +QSPI_HOLD=12" "syscon_regs" "syscon_reboot" "syscon_strap" "syscon_strap $(QSPI_LATE)" "syscon_cfg" "syscon_cfg +NO_STREAM" "syscon_fail" "syscon_wdt" "syscon_wdt_split" "syscon_poweroff" "syscon_pinreset"
SYSCON_SOC_DIR  := $(BUILD_DIR)/syscon_soc
test-syscon-soc: $(BUILD_DIR)
	@echo "=== Testing syscon through the SoC ==="
	@mkdir -p $(SYSCON_SOC_DIR)
	@$(IVERILOG) -g2012 -I $(TB_DIR) -o $(SYSCON_SOC_DIR)/sim -s tb_syscon_soc $(SRC_FILES) \
		$(SRC_DIR)/qspi_ctrl.v $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/soc_bus.v $(SRC_DIR)/uart.v \
		$(SRC_DIR)/gpio.v $(SRC_DIR)/spi.v $(SRC_DIR)/syscon.v $(SRC_DIR)/alphaone_soc.v $(TB_DIR)/qspi_pmod_model.v \
		$(TB_DIR)/req_hold_check.v $(TB_DIR)/rp2350_uart_model.v $(TB_DIR)/tb_syscon_soc.v
	@cd $(SYSCON_SOC_DIR) && bad=0; n=0; for run in $(SYSCON_SOC_RUNS); do \
		set -- $$run; t=$$1; shift; n=$$((n+1)); \
		fl=; pl=; if [ -n "$(MB_UART)" ]; then $(MB_FLAGS); fi; \
		case $$t in *@*) fl="$$fl -DDDR_PT=$${t#*@}"; t=$${t%@*};; esac; \
		$(TOOLCHAIN)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles $$fl \
			-T $(CURDIR)/$(TESTS_DIR)/soc/link.ld -I$(CURDIR)/$(TESTS_DIR)/soc \
			$(CURDIR)/$(TESTS_DIR)/soc/$$t.S -o $$t.elf && \
		$(TOOLCHAIN)objcopy -O verilog -j .text.init -j .text -j .rodata \
			--change-addresses=-0x20000000 $$t.elf $$t.hex || { bad=1; continue; }; \
		$(VVP) -n sim +TEST=$$t +FLASH_FILE=$(CURDIR)/$(SYSCON_SOC_DIR)/$$t.hex $$pl "$$@" > $$t.$$n.log 2>&1; \
		grep -E '^(PASS|FAIL|ERROR|TIMEOUT|NOTE)' $$t.$$n.log | head -40; \
		if grep -qE '^(FAIL|ERROR|TIMEOUT)' $$t.$$n.log || ! grep -q '^PASS' $$t.$$n.log; then bad=1; fi; \
	done; exit $$bad

# The TinyTapeout top level through its pins alone (tb/tb_tt_um.v):
# tests/soc/tt_pins.S boots from the QSPI Pmod model's flash and reports over
# the UART. Four runs:
#   default            2 ns device delay, ui_in[0] = 0 through reset
#   QSPI_DELAY=19      just under one SCK period, which rd_late = 0 must take
#   RD_LATE, 25 ns     ui_in[0] = 1 through reset: only rd_late = 1 reads this
#   NO_STREAM          ui_in[2] = 1 through reset: QSPI_CFG.STREAM stays 0
# then tests/soc/tt_reboot.S with +TEST=reboot (a reboot at the pins), twice: the
# strap at 0 and at 1 (RD_LATE, 25 ns).
WRAPPER_SRC  := $(SRC_FILES) $(SRC_DIR)/qspi_ctrl.v $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/soc_bus.v \
                $(SRC_DIR)/uart.v $(SRC_DIR)/gpio.v $(SRC_DIR)/spi.v $(SRC_DIR)/syscon.v $(SRC_DIR)/alphaone_soc.v \
                $(SRC_DIR)/tt_um_alfadelta10010_alphaone_soc.v
WRAPPER_RUNS := "" "+QSPI_DELAY=19" "$(QSPI_LATE)" "+NO_STREAM"
WRAPPER_DIR  := $(BUILD_DIR)/wrapper
test-wrapper: $(BUILD_DIR)
	@echo "=== Testing the TinyTapeout top level ==="
	@mkdir -p $(WRAPPER_DIR)
	@$(IVERILOG) -g2012 -o $(WRAPPER_DIR)/sim -s tb_tt_um $(WRAPPER_SRC) \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/rp2350_uart_model.v $(TB_DIR)/ssd1331_model.v \
		$(TB_DIR)/keypad_model.v $(TB_DIR)/tb_tt_um.v
	@cd $(WRAPPER_DIR) && \
		$(TOOLCHAIN)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
			-T $(CURDIR)/$(TESTS_DIR)/soc/link.ld -I$(CURDIR)/$(TESTS_DIR)/soc \
			$(CURDIR)/$(TESTS_DIR)/soc/tt_pins.S -o tt_pins.elf && \
		$(TOOLCHAIN)objcopy -O verilog -j .text.init -j .text -j .rodata \
			--change-addresses=-0x20000000 tt_pins.elf tt_pins.hex && \
		$(TOOLCHAIN)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
			-T $(CURDIR)/$(TESTS_DIR)/soc/link.ld -I$(CURDIR)/$(TESTS_DIR)/soc \
			$(CURDIR)/$(TESTS_DIR)/soc/tt_reboot.S -o tt_reboot.elf && \
		$(TOOLCHAIN)objcopy -O verilog -j .text.init -j .text -j .rodata \
			--change-addresses=-0x20000000 tt_reboot.elf tt_reboot.hex && \
		for args in $(WRAPPER_RUNS); do \
			$(VVP) -n sim +FLASH_FILE=$(CURDIR)/$(WRAPPER_DIR)/tt_pins.hex $$args > tt_pins.log 2>&1; \
			grep -E '^(PASS|FAIL|ERROR|TIMEOUT)' tt_pins.log | head -6; \
			if grep -qE '^(FAIL|ERROR|TIMEOUT)' tt_pins.log || ! grep -q '^PASS' tt_pins.log; then exit 1; fi; \
		done && \
		n=0; for args in "" "$(QSPI_LATE)"; do \
			n=$$((n + 1)); \
			$(VVP) -n sim +FLASH_FILE=$(CURDIR)/$(WRAPPER_DIR)/tt_reboot.hex +TEST=reboot $$args > tt_reboot.$$n.log 2>&1; \
			grep -E '^(PASS|FAIL|ERROR|TIMEOUT|NOTE)' tt_reboot.$$n.log | head -12; \
			if grep -qE '^(FAIL|ERROR|TIMEOUT)' tt_reboot.$$n.log || ! grep -q '^PASS' tt_reboot.$$n.log; then exit 1; fi; \
		done

# The 16 mailbox programs of tests/soc through the pins (tb_tt_um.v
# +TEST=soc +PROG=<name>), on the RTL: scripts/gl/build_isa.sh PARTS=D builds
# them with -DMB_UART and each one's divisor, run_gl.sh runs the two lists. The
# same lists run on the hardened netlist on the sandbox; this is the baseline,
# one job at a time. Not part of test-components.
test-wrapper-soc:
	@echo "=== The mailbox programs through the TinyTapeout pins (RTL) ==="
	@bash scripts/gl/build_isa.sh PARTS=D OUT=$(BUILD_DIR)/wrapper_soc TOOLCHAIN=$(TOOLCHAIN)
	@for l in D10:10.0 D20:20.0; do \
		bash scripts/gl/run_gl.sh RTL=1 IVERILOG=$(IVERILOG) VVP=$(VVP) LIST=$(BUILD_DIR)/wrapper_soc/list.$${l%%:*} \
			TCLK=$${l##*:} OUT=$(BUILD_DIR)/wrapper_soc/rtl-$${l%%:*} JOBS=1 > /dev/null; \
		cat $(BUILD_DIR)/wrapper_soc/rtl-$${l%%:*}/summary; \
	done; ! grep -qE '^(FAIL|TIMEOUT) [1-9]' $(BUILD_DIR)/wrapper_soc/rtl-D10/summary $(BUILD_DIR)/wrapper_soc/rtl-D20/summary

# One tt_pins run on a gate-level netlist (the pnl from the harden, or its nl),
# the local smoke only: every set runs on a bigger machine through
# scripts/gl/run_gl.sh. The cell models come from PDK_ROOT (ciel 8afc8346), or
# from CELLS=<dir> holding primitives.v and sky130_fd_sc_hd.v.
GL_DIR := $(BUILD_DIR)/gl
test-gl:
	@test -n "$(NETLIST)" || { echo "test-gl: NETLIST=<netlist.v> is required (PDK_ROOT=<dir> or CELLS=<dir> too)"; exit 2; }
	@test -n "$(PDK_ROOT)$(CELLS)" || { echo "test-gl: PDK_ROOT=<dir> or CELLS=<dir> is required"; exit 2; }
	@echo "=== tt_pins on $(NETLIST) ==="
	@rm -rf $(GL_DIR)/smoke
	@bash scripts/gl/build_isa.sh PARTS=A OUT=$(GL_DIR) TOOLCHAIN=$(TOOLCHAIN) > /dev/null
	@bash scripts/gl/run_gl.sh NETLIST=$(abspath $(NETLIST)) PDK_ROOT=$(PDK_ROOT) CELLS=$(CELLS) \
		IVERILOG=$(IVERILOG) VVP=$(VVP) LIST=$(GL_DIR)/list.A ONLY='^tt_pins\.0$$' JOBS=1 OUT=$(GL_DIR)/smoke
	@cat $(GL_DIR)/smoke/tt_pins.0.verdict; grep -E '^(PASS|FAIL|TIMEOUT|ERROR)' $(GL_DIR)/smoke/tt_pins.0.log | head -5
	@grep -q '^PASS' $(GL_DIR)/smoke/tt_pins.0.verdict

test-components: test-alu test-branchctrl test-decoder test-signext test-controller test-regfile test-csr test-compressed test-muldiv test-pmp test-clint test-syscon test-qspi test-pmod-dtr test-uart test-gpio test-spi test-soc-periph test-syscon-soc test-wrapper
	@echo ""
	@echo "=== All component tests completed ==="

# ============================================================
#  Full CPU
# ============================================================

test-cpu: $(BUILD_DIR)
	@echo "=== Compiling full CPU ==="
	@$(IVERILOG) -Wall -o $(BUILD_DIR)/cpu_check $(SRC_FILES) $(TB_DIR)/memory_model.v $(TB_DIR)/tb_cpu.v
	@echo "CPU compilation successful."

# ============================================================
#  ASM file runner
# ============================================================

asm: $(BUILD_DIR)
ifndef FILE
	@echo "Usage: make asm FILE=<path/to/test.S>"
	@echo "  Options: QUIET=1, MAX_CYCLES=N, VCD=1"
	@exit 1
endif
	@bash $(SCRIPTS_DIR)/run_asm_test.sh $(FILE) \
		$(if $(filter 1,$(QUIET)),--quiet) \
		$(if $(MAX_CYCLES),--max-cycles $(MAX_CYCLES)) \
		$(if $(filter 1,$(VCD)),--vcd)

# ============================================================
#  Benchmarks
# ============================================================

benchmarks: $(BUILD_DIR)
	@bash $(SCRIPTS_DIR)/run_benchmarks.sh

# ============================================================
#  River Core compatible testbench
# ============================================================
# Build the river_core testbench simulator binary (reusable across tests)
#   make rivercore-build
# Run a hex file through the river_core testbench:
#   make rivercore-test HEX=tests/rv32i_basic.hex
#   make rivercore-test HEX=tests/rv32i_basic.hex DUMP=output.dump CYCLES=500000

rivercore-build: $(BUILD_DIR)
	@echo "=== Building river_core testbench ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/sim_rivercore \
		-s tb_rivercore \
		$(SRC_FILES) $(TB_DIR)/memory_model.v $(TB_DIR)/tb_rivercore.v
	@echo "River Core testbench built: $(BUILD_DIR)/sim_rivercore"

rivercore-test: $(BUILD_DIR) rivercore-build
ifndef HEX
	@echo "Usage: make rivercore-test HEX=<path/to/program.hex>"
	@echo "  Options: DUMP=<output.dump> CYCLES=<N> TOHOST=<hex_addr> START_PC=<hex>"
	@exit 1
endif
	@$(VVP) $(BUILD_DIR)/sim_rivercore \
		+INIT_FILE=$(abspath $(HEX)) \
		+DUMP_FILE=$(or $(DUMP),execution.dump) \
		$(if $(CYCLES),+MAX_CYCLES=$(CYCLES)) \
		$(if $(TOHOST),+TOHOST_ADDR=$(TOHOST)) \
		$(if $(START_PC),+START_PC=$(START_PC))

# Latency bounds of mem_ctrl + qspi_ctrl by random simulation (LP LF S LD LI, rd_late 0 and 1;
# the pdr/bmc proofs in tb/formal/mem_*.sv carry the proved ones). Not part of test-all.
# Streaming on: LP 40/41, LF 57/58, S 126, LD 182/183, LI 449/482; off: LF 56/57, LI 442/456 (DF_N=4). FAILs if
# the worst of the two differs from the defines in tb/formal/mem_props.sv.
bounds-qspi: $(BUILD_DIR)
	@$(IVERILOG) -g2012 -DDFN=$(or $(DF_N),4) -o $(BUILD_DIR)/bounds_tb $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v tb/formal/bounds_tb.v
	@cd $(BUILD_DIR) && $(VVP) bounds_tb +SE=1 | grep '^stream_en' > bounds_se1.txt; $(VVP) bounds_tb +SE=0 | grep '^stream_en' > bounds_se0.txt; cat bounds_se1.txt bounds_se0.txt
	@# F-17: the measured numbers (worst of streaming on and off) must equal the mem_props.sv defines (S = S_MAX + 1)
	@cat $(BUILD_DIR)/bounds_se1.txt $(BUILD_DIR)/bounds_se0.txt | awk -v pf=tb/formal/mem_props.sv \
	  'BEGIN { while ((getline l < pf) > 0) if (l ~ /^`define (LP|LF|LD|LI)[01] |^`define S_MAX /) { split(l, a, " "); d[a[2]] = a[3] } } \
	   { r = ""; for (i = 2; i <= NF; i++) { split($$i, kv, "="); if (kv[1] == "rd_late") r = kv[2]; else if (r != "") m[kv[1] r] = (kv[2] > m[kv[1] r] ? kv[2] : m[kv[1] r]) } } \
	   END { bad = 0; for (k in m) { n = k; sub(/[01]$$/, "", n); e = (n == "S") ? d["S_MAX"] + 1 : d[k]; \
	           if (e == "" || m[k] + 0 != e + 0) { printf "FAIL bounds %s: measured %s, mem_props.sv define %s\n", k, m[k], e; bad = 1 } } \
	         if (bad) exit 1; print "OK bounds: measured (streaming on/off, worst) equal the mem_props.sv defines" }'

# ============================================================
#  Full test suite
# ============================================================

test-all: test-components test-cpu
	@echo ""
	@echo "============================================="
	@echo " All tests completed successfully"
	@echo "============================================="

# ============================================================
#  Clean
# ============================================================

clean:
	rm -rf $(BUILD_DIR)
	rm -f $(TB_DIR)/*.vcd $(SRC_DIR)/*.vcd
	rm -f $(TESTS_DIR)/*.elf $(TESTS_DIR)/*.bin $(TESTS_DIR)/*.hex $(TESTS_DIR)/*.dis
