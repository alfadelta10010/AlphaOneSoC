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
        test-regfile test-csr test-compressed test-muldiv test-qspi test-uart test-gpio test-soc-periph \
        test-wrapper asm \
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
	@echo "  make test-compressed   Run compressed decoder testbench"
	@echo "  make test-qspi         Run memory controller + QSPI engine testbench"
	@echo "  make test-uart         Run UART testbench"
	@echo "  make test-gpio         Run GPIO + OLED SPI transmitter testbench"
	@echo "  make test-soc-periph   Run the peripheral programs through the whole SoC"
	@echo "  make test-wrapper      Run the TinyTapeout top level, pins only"
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

# Run a unit testbench and fail the target if it reported a failure. The
# testbenches print FAIL/TIMEOUT lines and then $finish, which exits 0, so
# without this check `make test-all` reported success over failing tests.
run_tb = cd $(BUILD_DIR) && $(VVP) $(1) | tee $(1).log && ! grep -qE '^(FAIL|TIMEOUT)' $(1).log

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
	@cd $(BUILD_DIR) && $(VVP) tb_regFile +RF_X | tee tb_regFile_x.log && \
		! grep -qE '^(FAIL|TIMEOUT)' tb_regFile_x.log && grep -q '^ALL REGFILE TESTS PASSED' tb_regFile_x.log
	@cd $(BUILD_DIR) && $(VVP) tb_regFile +RF_X +RF_COLLIDE_X | tee tb_regFile_cx.log && \
		! grep -qE '^(FAIL|TIMEOUT)' tb_regFile_cx.log && grep -q '^ALL REGFILE TESTS PASSED' tb_regFile_cx.log

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
QSPI_LATE := +RD_LATE +QSPI_DELAY=25 +QSPI_HOLD=12
QSPI_RUNS := "" "+QSPI_DELAY=19" "$(QSPI_LATE)" "+PSRAM_WRAP" \
             "+PSRAM_QPI +FLASH_CRM" "+FLASH_QPI" "+FLASH_QPI +FLASH_CRM" "+FLASH_DCRM" \
             "+PSRAM_A_QPI +FLASH_DCRM" "+PSRAM_B_QPI +FLASH_QPI"
QSPI_STRESS_RUNS := "" "$(QSPI_LATE) +PSRAM_WRAP" "+RESETS +QSPI_DELAY=19" "+RESETS $(QSPI_LATE) +PSRAM_WRAP +SEED=2"
test-qspi: $(BUILD_DIR)
	@echo "=== Testing QSPI memory path ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_qspi $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/req_hold_check.v $(TB_DIR)/tb_qspi.v
	@cd $(BUILD_DIR) && for args in $(QSPI_RUNS); do \
		$(VVP) tb_qspi $$args > tb_qspi.log 2>&1; grep -E 'PASS|FAIL|ERROR|TIMEOUT' tb_qspi.log | head -3; \
		grep -q '^PASS' tb_qspi.log || exit 1; \
	done
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_qspi_stress $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/req_hold_check.v $(TB_DIR)/tb_qspi_stress.v
	@cd $(BUILD_DIR) && for args in $(QSPI_STRESS_RUNS); do \
		$(VVP) tb_qspi_stress $$args > tb_qspi_stress.log 2>&1; grep -E '^PASS|FAIL|ERROR|TIMEOUT' tb_qspi_stress.log | head -3; \
		grep -q '^PASS' tb_qspi_stress.log || exit 1; \
	done

# The UART against spec-derived models: register/lane scoreboard, a
# reference receiver on TX, an asynchronous reference transmitter on RX
# (baud error, glitches, framing errors, overruns), RTS# and back-pressure
# checks, and a constrained-random run (+SEED=, +NRAND= for more).
test-uart: $(BUILD_DIR)
	@echo "=== Testing UART ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_uart $(SRC_DIR)/uart.v $(TB_DIR)/tb_uart.v
	@$(call run_tb,tb_uart)

# GPIO OUT/IN and the SPI shifter: register and pin model, a mode-3 SPI
# checker at every DIV, back-pressure, and a random run.
test-gpio: $(BUILD_DIR)
	@echo "=== Testing GPIO + SPI transmitter ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_gpio $(SRC_DIR)/gpio.v $(TB_DIR)/tb_gpio.v
	@$(call run_tb,tb_gpio)

# The peripherals through the whole SoC: each tests/soc/*.S program boots
# from the QSPI Pmod model's flash with the demo board's devices on the pins
# (RP2350 UART with CTS, SSD1331, keypad) -- tb/tb_soc_periph.v. A run fails
# on a FAIL, ERROR or TIMEOUT line or a missing PASS; all runs go first.
SOC_PERIPH_TESTS := uart_hello uart_echo uart_linux oled_spi keypad irq_stall periph_access clint_decode
SOC_PERIPH_DIR   := $(BUILD_DIR)/soc_periph
test-soc-periph: $(BUILD_DIR)
	@echo "=== Testing the peripherals through the SoC ==="
	@mkdir -p $(SOC_PERIPH_DIR)
	@$(IVERILOG) -g2012 -o $(SOC_PERIPH_DIR)/sim -s tb_soc_periph $(SRC_FILES) \
		$(SRC_DIR)/qspi_ctrl.v $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/soc_bus.v $(SRC_DIR)/uart.v \
		$(SRC_DIR)/gpio.v $(SRC_DIR)/alphaone_soc.v $(TB_DIR)/qspi_pmod_model.v \
		$(TB_DIR)/req_hold_check.v $(TB_DIR)/rp2350_uart_model.v $(TB_DIR)/ssd1331_model.v \
		$(TB_DIR)/keypad_model.v $(TB_DIR)/tb_soc_periph.v
	@cd $(SOC_PERIPH_DIR) && bad=0; for t in $(SOC_PERIPH_TESTS); do \
		$(TOOLCHAIN)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
			-T $(CURDIR)/$(TESTS_DIR)/soc/link.ld -I$(CURDIR)/$(TESTS_DIR)/soc \
			$(CURDIR)/$(TESTS_DIR)/soc/$$t.S -o $$t.elf || { bad=1; continue; }; \
		$(TOOLCHAIN)objcopy -O verilog -j .text.init -j .text -j .rodata \
			--change-addresses=-0x20000000 $$t.elf $$t.hex; \
		$(VVP) -n sim +TEST=$$t +FLASH_FILE=$(CURDIR)/$(SOC_PERIPH_DIR)/$$t.hex > $$t.log 2>&1; \
		grep -E '^(PASS|FAIL|ERROR|TIMEOUT)|^[a-z_]+: ' $$t.log | head -6; \
		if grep -qE '^(FAIL|ERROR|TIMEOUT)' $$t.log || ! grep -q '^PASS' $$t.log; then bad=1; fi; \
	done; exit $$bad

# The TinyTapeout top level through its pins alone (tb/tb_tt_um.v):
# tests/soc/tt_pins.S boots from the QSPI Pmod model's flash and reports over
# the UART. Three runs:
#   default            2 ns device delay, ui_in[0] = 0 through reset
#   QSPI_DELAY=19      just under one SCK period, which rd_late = 0 must take
#   RD_LATE, 25 ns     ui_in[0] = 1 through reset: only rd_late = 1 reads this
WRAPPER_SRC  := $(SRC_FILES) $(SRC_DIR)/qspi_ctrl.v $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/soc_bus.v \
                $(SRC_DIR)/uart.v $(SRC_DIR)/gpio.v $(SRC_DIR)/alphaone_soc.v \
                $(SRC_DIR)/tt_um_alfadelta10010_alphaone_soc.v
WRAPPER_RUNS := "" "+QSPI_DELAY=19" "$(QSPI_LATE)"
WRAPPER_DIR  := $(BUILD_DIR)/wrapper
test-wrapper: $(BUILD_DIR)
	@echo "=== Testing the TinyTapeout top level ==="
	@mkdir -p $(WRAPPER_DIR)
	@$(IVERILOG) -g2012 -o $(WRAPPER_DIR)/sim -s tb_tt_um $(WRAPPER_SRC) \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/rp2350_uart_model.v $(TB_DIR)/tb_tt_um.v
	@cd $(WRAPPER_DIR) && \
		$(TOOLCHAIN)gcc -march=rv32imac_zicsr_zifencei -mabi=ilp32 -nostdlib -nostartfiles \
			-T $(CURDIR)/$(TESTS_DIR)/soc/link.ld -I$(CURDIR)/$(TESTS_DIR)/soc \
			$(CURDIR)/$(TESTS_DIR)/soc/tt_pins.S -o tt_pins.elf && \
		$(TOOLCHAIN)objcopy -O verilog -j .text.init -j .text -j .rodata \
			--change-addresses=-0x20000000 tt_pins.elf tt_pins.hex && \
		for args in $(WRAPPER_RUNS); do \
			$(VVP) -n sim +FLASH_FILE=$(CURDIR)/$(WRAPPER_DIR)/tt_pins.hex $$args > tt_pins.log 2>&1; \
			grep -E '^(PASS|FAIL|ERROR|TIMEOUT)' tt_pins.log | head -6; \
			if grep -qE '^(FAIL|ERROR|TIMEOUT)' tt_pins.log || ! grep -q '^PASS' tt_pins.log; then exit 1; fi; \
		done

test-components: test-alu test-branchctrl test-decoder test-signext test-controller test-regfile test-csr test-compressed test-muldiv test-qspi test-uart test-gpio test-soc-periph test-wrapper
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
