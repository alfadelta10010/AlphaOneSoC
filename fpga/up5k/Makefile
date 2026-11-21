# UP5K twin (WO-F1). Runs on the sandbox from ~/regr/fpga-up5k/wo-f1/up5k with the pin extracted
# in ../pin (scripts/sync.sh does both). make clean only removes build/.
export PATH := /home/mempool/tools/oss-cad-suite/bin:$(PATH)
PINDIR  ?= ../pin
F_MHZ   ?= 18
SEED    ?= 1
INTCLK  ?= 0
BUILD   := build
SOC_SRC := $(addprefix $(PINDIR)/,$(shell grep -hv '^\#' srclist.txt))
OWN_SRC := rtl/fyracore_picorv32.v rtl/rf_top_fpga.v rtl/fpga_top.v third_party/picorv32/picorv32.v
DEFS    := -DSYNTHESIS $(if $(filter 1,$(INTCLK)),-DINTCLK)
PCF     := up5k.pcf

all: $(BUILD)/up5k.bin

manifest:
	scripts/manifest.sh

ports:
	scripts/port_check.sh

$(BUILD)/fpga_top.json: $(SOC_SRC) $(OWN_SRC) pin.sums
	scripts/manifest.sh
	yosys -q -l $(BUILD)/synth.log -p "read_verilog $(DEFS) $(SOC_SRC) $(OWN_SRC); \
	  synth_ice40 -top fpga_top -json $@; tee -o $(BUILD)/synth.stat stat" > /dev/null

$(BUILD)/up5k.asc: $(BUILD)/fpga_top.json $(PCF)
	nextpnr-ice40 --up5k --package sg48 --json $< --pcf $(PCF) --asc $@ --freq $(F_MHZ) --seed $(SEED) \
	  --report $(BUILD)/pnr.rpt.json -l $(BUILD)/pnr.log > /dev/null 2>&1; \
	  rc=$$?; grep -E "ICESTORM_LC:|SB_RAM40_4K:|Max frequency|Info: Max" $(BUILD)/pnr.log | tail -6; exit $$rc

$(BUILD)/up5k.bin: $(BUILD)/up5k.asc
	icepack $< $@
	@echo "built $@ at F_MHZ=$(F_MHZ) seed=$(SEED) intclk=$(INTCLK)"

clean:
	rm -rf $(BUILD)

.PHONY: all manifest ports clean
