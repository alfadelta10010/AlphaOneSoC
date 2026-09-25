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
              $(SRC_DIR)/regs.v \
              $(SRC_DIR)/signExt.v

# Phony targets
.PHONY: all test-all test-components test-cpu benchmarks clean help \
        test-alu test-branchctrl test-decoder test-signext test-controller \
        test-regfile test-csr test-compressed test-muldiv test-qspi asm \
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
	@$(IVERILOG) -o $(BUILD_DIR)/tb_alu $(SRC_DIR)/alu.v $(TB_DIR)/tb_alu.v
	@$(call run_tb,tb_alu)

test-branchctrl: $(BUILD_DIR)
	@echo "=== Testing Branch Controller ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_branchCtrl $(SRC_DIR)/branchCtrl.v $(TB_DIR)/tb_branchCtrl.v
	@$(call run_tb,tb_branchCtrl)

test-decoder: $(BUILD_DIR)
	@echo "=== Testing Decoder ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_decoder $(SRC_DIR)/decoder.v $(TB_DIR)/tb_decoder.v
	@$(call run_tb,tb_decoder)

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
	@$(IVERILOG) -o $(BUILD_DIR)/tb_regFile $(SRC_DIR)/regFile.v $(TB_DIR)/tb_regFile.v
	@$(call run_tb,tb_regFile)

test-csr: $(BUILD_DIR)
	@echo "=== Testing CSR ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_csr $(SRC_DIR)/csr.v $(TB_DIR)/tb_csr.v
	@$(call run_tb,tb_csr)

test-compressed: $(BUILD_DIR)
	@echo "=== Testing Compressed Decoder ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_cdec $(SRC_DIR)/compressed_decoder.v $(TB_DIR)/tb_compressed_decoder.v
	@$(call run_tb,tb_cdec)

test-muldiv: $(BUILD_DIR)
	@echo "=== Testing MulDiv Unit ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_muldiv $(SRC_DIR)/muldiv.v $(TB_DIR)/tb_muldiv.v
	@$(call run_tb,tb_muldiv)

# The memory path (mem_ctrl + qspi_ctrl) against the QSPI Pmod model:
#   default           2 ns device delay
#   QSPI_DELAY=19     just under one SCK period, which rd_late = 0 must take
#   RD_LATE, 25 ns    past one SCK period, which needs the rd_late strap
#   PSRAM_WRAP        a PSRAM that wraps at 1 KB pages (no row crossing)
#   PSRAM_QPI + FLASH_CRM, FLASH_QPI, FLASH_QPI + FLASH_CRM
#                     devices handed over in states the start-up sequence
#                     has to undo
# then tb_qspi_stress, with core-shaped request streams, twice.
QSPI_RUNS := "" "+QSPI_DELAY=19" "+RD_LATE +QSPI_DELAY=25" "+PSRAM_WRAP" \
             "+PSRAM_QPI +FLASH_CRM" "+FLASH_QPI" "+FLASH_QPI +FLASH_CRM"
test-qspi: $(BUILD_DIR)
	@echo "=== Testing QSPI memory path ==="
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_qspi $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/tb_qspi.v
	@cd $(BUILD_DIR) && for args in $(QSPI_RUNS); do \
		$(VVP) tb_qspi $$args > tb_qspi.log 2>&1; grep -E 'PASS|FAIL|ERROR|TIMEOUT' tb_qspi.log | head -3; \
		grep -q '^PASS' tb_qspi.log || exit 1; \
	done
	@$(IVERILOG) -g2012 -o $(BUILD_DIR)/tb_qspi_stress $(SRC_DIR)/mem_ctrl.v $(SRC_DIR)/qspi_ctrl.v \
		$(TB_DIR)/qspi_pmod_model.v $(TB_DIR)/tb_qspi_stress.v
	@cd $(BUILD_DIR) && for args in "" "+RD_LATE +QSPI_DELAY=25 +PSRAM_WRAP"; do \
		$(VVP) tb_qspi_stress $$args > tb_qspi_stress.log 2>&1; grep -E '^PASS|FAIL|ERROR|TIMEOUT' tb_qspi_stress.log | head -3; \
		grep -q '^PASS' tb_qspi_stress.log || exit 1; \
	done

test-components: test-alu test-branchctrl test-decoder test-signext test-controller test-regfile test-csr test-compressed test-muldiv test-qspi
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
