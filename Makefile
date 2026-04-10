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
        test-regfile test-csr test-compressed test-muldiv asm

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
	@echo "  make test-components   Run all component tests"
	@echo ""
	@echo "CPU tests:"
	@echo "  make test-cpu          Compile full CPU (syntax check)"
	@echo "  make asm FILE=test.S   Assemble and run any .S file"
	@echo "  make benchmarks        Run all test programs"
	@echo ""
	@echo "  make test-all          Run everything"
	@echo "  make clean             Remove build artifacts"

$(BUILD_DIR):
	@mkdir -p $(BUILD_DIR)

# ============================================================
#  Component Testbenches
# ============================================================

test-alu: $(BUILD_DIR)
	@echo "=== Testing ALU ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_alu $(SRC_DIR)/alu.v $(TB_DIR)/tb_alu.v
	@cd $(BUILD_DIR) && $(VVP) tb_alu

test-branchctrl: $(BUILD_DIR)
	@echo "=== Testing Branch Controller ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_branchCtrl $(SRC_DIR)/branchCtrl.v $(TB_DIR)/tb_branchCtrl.v
	@cd $(BUILD_DIR) && $(VVP) tb_branchCtrl

test-decoder: $(BUILD_DIR)
	@echo "=== Testing Decoder ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_decoder $(SRC_DIR)/decoder.v $(TB_DIR)/tb_decoder.v
	@cd $(BUILD_DIR) && $(VVP) tb_decoder

test-signext: $(BUILD_DIR)
	@echo "=== Testing Sign Extension ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_signExt $(SRC_DIR)/signExt.v $(TB_DIR)/tb_signExt.v
	@cd $(BUILD_DIR) && $(VVP) tb_signExt

test-controller: $(BUILD_DIR)
	@echo "=== Testing Controller ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_controller $(SRC_DIR)/controller.v $(TB_DIR)/tb_controller.v
	@cd $(BUILD_DIR) && $(VVP) tb_controller

test-regfile: $(BUILD_DIR)
	@echo "=== Testing Register File ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_regFile $(SRC_DIR)/regFile.v $(TB_DIR)/tb_regFile.v
	@cd $(BUILD_DIR) && $(VVP) tb_regFile

test-csr: $(BUILD_DIR)
	@echo "=== Testing CSR ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_csr $(SRC_DIR)/csr.v $(TB_DIR)/tb_csr.v
	@cd $(BUILD_DIR) && $(VVP) tb_csr

test-compressed: $(BUILD_DIR)
	@echo "=== Testing Compressed Decoder ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_cdec $(SRC_DIR)/compressed_decoder.v $(TB_DIR)/tb_compressed_decoder.v
	@cd $(BUILD_DIR) && $(VVP) tb_cdec

test-muldiv: $(BUILD_DIR)
	@echo "=== Testing MulDiv Unit ==="
	@$(IVERILOG) -o $(BUILD_DIR)/tb_muldiv $(SRC_DIR)/muldiv.v $(TB_DIR)/tb_muldiv.v
	@cd $(BUILD_DIR) && $(VVP) tb_muldiv

test-components: test-alu test-branchctrl test-decoder test-signext test-controller test-regfile test-csr test-compressed test-muldiv
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
