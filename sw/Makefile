# Bare-metal software for AlphaOneSoC (docs/ROADMAP.md section 9).
#
#   make hello | monitor | coremark | dhrystone      build the loader, the payload and its flash image
#   make run-hello | run-coremark | run-dhrystone | run-monitor
#                                          ... and run it on the SoC bench (Verilator), check the output
#   make bench                             build the software bench only
#   make fetch                             fetch the third-party sources (CoreMark, Dhrystone) at pinned commits
#
# Knobs:  BENCH_OPT=-O2 (the benchmarks' optimisation flags)   CM_ITER=1 (CoreMark iterations)
#         CFLAGS=-Os (everything else)   RUNARGS=+MAX_CYCLES=...
#
# Output goes to ../build/sw (make clean here removes only that).
TC      ?= riscv64-unknown-elf-
VERILATOR ?= verilator
ROOT    := $(abspath ..)
BUILD   := $(ROOT)/build/sw
TP      := $(BUILD)/third_party
ARCH    := -march=rv32imac_zicsr_zifencei -mabi=ilp32
CFLAGS  ?= -Os
CFLAGS  += $(ARCH) -mcmodel=medany -Wall -Wextra -Icommon
# The loader and the runtime must not turn a loop into a call to memcpy.
FREESTANDING := -ffreestanding -fno-builtin -fno-tree-loop-distribute-patterns
LDLIBS  := -Wl,--start-group -lc -lm -lgcc -Wl,--end-group
COMMON  := common/crt0.S common/trap_entry.S common/trap.c common/uart.c common/exit.c common/printf.c

BENCH_OPT ?= -O2
CM_ITER   ?= 1

RTL := $(addprefix $(ROOT)/src/,alu branchCtrl clint compressed_decoder controller csr decoder fyracore \
        muldiv pmp regFile rf_top signExt qspi_ctrl mem_ctrl soc_bus uart gpio spi syscon alphaone_soc)
RTL := $(addsuffix .v,$(RTL))

# The third-party sources are needed to read the benchmark lists below.
ifneq ($(words $(wildcard $(TP)/embench-iot/support/main.c $(TP)/coremark/core_main.c \
        $(TP)/riscv-tests/benchmarks/dhrystone/dhrystone.c)),3)
$(shell ./fetch.sh >&2)
endif

.PHONY: all hello monitor coremark dhrystone run-hello run-coremark run-dhrystone bench fetch clean embench embench-score
all: hello

fetch:
	./fetch.sh
$(TP)/coremark/core_main.c $(TP)/riscv-tests/benchmarks/dhrystone/dhrystone.c:
	./fetch.sh

# ── the loader ──────────────────────────────────────────────────────────────
$(BUILD)/loader/loader.elf: loader/start.S loader/loader.c common/uart.c common/trap.c common/trap_entry.S \
                            common/soc.h loader/loader.ld
	@mkdir -p $(dir $@)
	$(TC)gcc $(CFLAGS) $(FREESTANDING) -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments -T loader/loader.ld \
	    loader/start.S loader/loader.c common/uart.c common/trap.c common/trap_entry.S -lgcc -o $@
$(BUILD)/loader/loader.bin: $(BUILD)/loader/loader.elf
	$(TC)objcopy -O binary $< $@

# ── a payload program: <name>_SRC lists its sources, <name>_CFLAGS its flags,
#    <name>/expect.txt what its output must show (tools/check_run.py) ────────
define PAYLOAD
$$(BUILD)/$(1)/$(1).elf: $$(COMMON) $$($(1)_SRC) common/soc.h common/payload.ld
	@mkdir -p $$(dir $$@)
	$$(TC)gcc $$(CFLAGS) $$($(1)_CFLAGS) -nostartfiles -static -Wl,--no-warn-rwx-segments -T common/payload.ld \
	    $$(COMMON) $$($(1)_SRC) $$(LDLIBS) -o $$@
	$$(TC)size $$@
$$(BUILD)/$(1)/$(1).bin: $$(BUILD)/$(1)/$(1).elf
	$$(TC)objcopy -O binary $$< $$@
$$(BUILD)/$(1)/flash.hex: $$(BUILD)/$(1)/$(1).bin $$(BUILD)/loader/loader.bin tools/mkflash.py
	python3 tools/mkflash.py --loader $$(BUILD)/loader/loader.bin --image $$< \
	    --entry 0x$$$$($$(TC)nm $$(BUILD)/$(1)/$(1).elf | awk '$$$$3=="_start"{print $$$$1}') \
	    --out $$@ --bin $$(BUILD)/$(1)/flash.bin
$(1): $$(BUILD)/$(1)/flash.hex
run-$(1): $(1) $$(BUILD)/bench/sim $$($(1)_RUNDEP)
	cd $$(BUILD)/$(1) && $$(BUILD)/bench/sim +FLASH_FILE=$$(BUILD)/$(1)/flash.hex $$($(1)_RUNARGS) $$(RUNARGS) | tee run.log
	python3 tools/check_run.py $$(BUILD)/$(1)/run.log $$(or $$($(1)_EXPECT),$(1)/expect.txt)
	$$($(1)_CHECK)
	@echo "$(1): ok"
endef

hello_SRC := hello/hello.c
$(eval $(call PAYLOAD,hello))

monitor_SRC    := monitor/monitor.c monitor/mon_asm.S
monitor_CFLAGS := -Wno-format   # uint32_t is long on this target; the mini printf takes both as 32 bits
monitor_EXPECT := monitor/expect.txt
monitor_RUNDEP := $(BUILD)/monitor/in.hex
monitor_RUNARGS := +UART_IN=$(BUILD)/monitor/in.hex
$(BUILD)/monitor/in.hex: monitor/script.txt tools/mkscript.py $(BUILD)/monitor/monitor.elf
	python3 tools/mkscript.py monitor/script.txt $@ --elf $(BUILD)/monitor/monitor.elf
$(eval $(call PAYLOAD,monitor))

CM := $(TP)/coremark
coremark_SRC    := $(addprefix $(CM)/,core_main.c core_list_join.c core_matrix.c core_state.c core_util.c) \
                   coremark/port/core_portme.c
coremark_CFLAGS := $(BENCH_OPT) -w -I$(CM) -Icoremark/port -DPERFORMANCE_RUN=1 -DITERATIONS=$(CM_ITER) \
                   -DFLAGS_STR='"$(BENCH_OPT) $(ARCH)"'
$(eval $(call PAYLOAD,coremark))

DH := $(TP)/riscv-tests/benchmarks/dhrystone
dhrystone_SRC    := $(DH)/dhrystone_main.c $(DH)/dhrystone.c
dhrystone_CFLAGS := $(BENCH_OPT) -w -Wno-error=implicit-int -Wno-error=implicit-function-declaration \
                    -Wno-error=int-conversion -Wno-error=incompatible-pointer-types -I$(DH) -Idhrystone/port \
                    -Wl,--allow-multiple-definition   # printf.c supplies the debug_printf the vendored file stubs out
dhrystone_CHECK  := python3 tools/dhry_check.py $(BUILD)/dhrystone/run.log
$(eval $(call PAYLOAD,dhrystone))

# Embench-IoT: one payload per benchmark, built the way the suite's sconstruct
# does (the benchmark's sources, support/main.c, support/beebsc.c, a board
# support file). GSF is Embench's global scale factor (the suite's own unit is
# one reference-CPU MHz of work: ca. 4 s on the Cortex-M4 reference at gsf 16).
# RUN-EMBENCH scores every run found under build/sw (tools/embench_report.py).
EMB      := $(TP)/embench-iot
EMB_LIST := aha-mont64 crc32 depthconv edn huffbench matmult-int md5sum nettle-aes nettle-sha256 \
            nsichneu picojpeg qrduino sglib-combined slre statemate tarfind ud wikisort xgboost
GSF      ?= 1
define EMBENCH
embench-$(1)_SRC    := $$(wildcard $$(EMB)/src/$(1)/*.c) $$(EMB)/support/main.c $$(EMB)/support/beebsc.c \
                       embench/port/boardsupport.c
embench-$(1)_CFLAGS := $$(BENCH_OPT) -w -I$$(EMB)/support -Iembench/port -DHAVE_BOARDSUPPORT_H \
                       -DWARMUP_HEAT=0 -DGLOBAL_SCALE_FACTOR=$$(GSF) -DBENCH_NAME='"$(1)"' -DCPU_MHZ=$$(GSF) \
                       -fdata-sections -ffunction-sections -Wl,--gc-sections
embench-$(1)_EXPECT := embench/expect.txt
$$(eval $$(call PAYLOAD,embench-$(1)))
endef
$(foreach b,$(EMB_LIST),$(eval $(call EMBENCH,$(b))))
embench: $(addprefix embench-,$(EMB_LIST))
embench-score:
	python3 tools/embench_report.py $(EMB)/baseline-data/speed.json $(GSF) $(BUILD)

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
