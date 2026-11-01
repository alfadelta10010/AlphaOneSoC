# Bare-metal software for AlphaOneSoC (docs/ROADMAP.md section 9).
#
#   make hello            build the loader and the hello payload, and the flash image
#   make run-hello        ... and run it on the SoC bench (Verilator), check its output
#   make bench            build the software bench only
#
# Output goes to ../build/sw (make clean here removes only that).
TC      ?= riscv64-unknown-elf-
VERILATOR ?= verilator
ROOT    := $(abspath ..)
BUILD   := $(ROOT)/build/sw
ARCH    := -march=rv32imac_zicsr_zifencei -mabi=ilp32
CFLAGS  ?= -Os
CFLAGS  += $(ARCH) -mcmodel=medany -ffreestanding -fno-builtin -fno-tree-loop-distribute-patterns \
           -Wall -Wextra -Icommon
LDLIBS  := -Wl,--start-group -lc -lgcc -Wl,--end-group
COMMON  := common/crt0.S common/trap_entry.S common/trap.c common/uart.c common/exit.c

RTL := $(addprefix $(ROOT)/src/,alu branchCtrl clint compressed_decoder controller csr decoder fyracore \
        muldiv pmp regFile rf_top signExt qspi_ctrl mem_ctrl soc_bus uart gpio spi syscon alphaone_soc)
RTL := $(addsuffix .v,$(RTL))

.PHONY: all hello run-hello bench clean
all: hello

# ── the loader ──────────────────────────────────────────────────────────────
$(BUILD)/loader/loader.elf: loader/start.S loader/loader.c common/uart.c common/trap.c common/trap_entry.S \
                            common/soc.h loader/loader.ld
	@mkdir -p $(dir $@)
	$(TC)gcc $(CFLAGS) -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments -T loader/loader.ld \
	    loader/start.S loader/loader.c common/uart.c common/trap.c common/trap_entry.S -lgcc -o $@
$(BUILD)/loader/loader.bin: $(BUILD)/loader/loader.elf
	$(TC)objcopy -O binary $< $@

# ── a payload program: <name>_SRC lists its sources ─────────────────────────
define PAYLOAD
$$(BUILD)/$(1)/$(1).elf: $$($(1)_SRC) $$(COMMON) common/soc.h common/payload.ld
	@mkdir -p $$(dir $$@)
	$$(TC)gcc $$(CFLAGS) $$($(1)_CFLAGS) -nostartfiles -static -Wl,--no-warn-rwx-segments -T common/payload.ld \
	    $$($(1)_SRC) $$(COMMON) $$(LDLIBS) -o $$@
$$(BUILD)/$(1)/$(1).bin: $$(BUILD)/$(1)/$(1).elf
	$$(TC)objcopy -O binary $$< $$@
$$(BUILD)/$(1)/flash.hex: $$(BUILD)/$(1)/$(1).bin $$(BUILD)/loader/loader.bin tools/mkflash.py
	python3 tools/mkflash.py --loader $$(BUILD)/loader/loader.bin --image $$< \
	    --entry 0x$$$$($$(TC)nm $$(BUILD)/$(1)/$(1).elf | awk '$$$$3=="_start"{print $$$$1}') \
	    --out $$@ --bin $$(BUILD)/$(1)/flash.bin
$(1): $$(BUILD)/$(1)/flash.hex
run-$(1): $(1) $$(BUILD)/bench/sim
	cd $$(BUILD)/$(1) && $$(BUILD)/bench/sim +FLASH_FILE=$$(BUILD)/$(1)/flash.hex $$(RUNARGS) | tee run.log
	@grep -q '^SW-RESULT: PASS' $$(BUILD)/$(1)/run.log || { echo "$(1): no PASS"; exit 1; }
	@for s in $$($(1)_EXPECT); do grep -q -- "$$$$s" $$(BUILD)/$(1)/run.log || { echo "$(1): missing '$$$$s'"; exit 1; }; done
	@echo "$(1): ok"
endef

hello_SRC    := hello/hello.c
hello_EXPECT := "AlphaOne" "PSRAM!" "ACIMU" "sum"
$(eval $(call PAYLOAD,hello))

# ── the bench ───────────────────────────────────────────────────────────────
bench: $(BUILD)/bench/sim
$(BUILD)/bench/sim: $(RTL) $(ROOT)/tb/tb_sw.v $(ROOT)/tb/qspi_pmod_model.v $(ROOT)/tb/req_hold_check.v
	@mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD \
	    --top-module tb_sw -Mdir $(BUILD)/bench/obj -o ../sim \
	    $(RTL) $(ROOT)/tb/qspi_pmod_model.v $(ROOT)/tb/req_hold_check.v $(ROOT)/tb/tb_sw.v \
	    > $(BUILD)/bench/build.log 2>&1 || { tail -30 $(BUILD)/bench/build.log; exit 1; }

clean:
	rm -rf $(BUILD)
