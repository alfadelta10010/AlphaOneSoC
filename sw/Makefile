# Bare-metal software for AlphaOneSoC (docs/ROADMAP.md section 9).
#
#   make hello | monitor | fatfs | freertos | ddr | ddrwd | coremark | dhrystone      build the loader, the payload and its flash image
#   make run-hello | run-coremark | run-dhrystone | run-monitor | run-fatfs | run-freertos | run-ddr | run-ddrwd | run-ddr-all
#                                          ... and run it on the SoC bench (Verilator), check the output
#   make bench                             build the software bench only
#   make fetch                             fetch the third-party sources (CoreMark, Dhrystone, Embench, FatFs, FreeRTOS) at pinned commits
#
# Knobs:  BENCH_OPT=-O2 (the benchmarks' optimisation flags)   CM_ITER=1 (CoreMark iterations)
#         DDR=1 (flag the image for the loader's DDR sweep: it must service the watchdog; the monitor,
#         FreeRTOS and the ddr payloads do)
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

# 114,890 baud at 62.5 MHz (common/soc.h UART_DIVISOR); the bench checks the program ends with it
UART_DIVISOR := 34
BENCH_OPT ?= -O2
CM_ITER   ?= 1

RTL := $(addprefix $(ROOT)/src/,alu branchCtrl clint compressed_decoder controller csr decoder fyracore \
        muldiv pmp regFile rf_top regs signExt qspi_ctrl mem_ctrl cache soc_bus plic uart gamepad pwm audio pinmux gpio spi syscon alphaone_soc)
RTL := $(addsuffix .v,$(RTL))

# The third-party sources are needed to read the benchmark lists below.
# (clean and bench do not need them; a failed fetch stops make here, not later as a missing file.)
ifeq ($(filter clean bench,$(MAKECMDGOALS)),$(MAKECMDGOALS))
else ifneq ($(words $(wildcard $(TP)/embench-iot/support/main.c $(TP)/coremark/core_main.c \
        $(TP)/riscv-tests/benchmarks/dhrystone/dhrystone.c $(TP)/fatfs/source/ff.c \
        $(TP)/freertos/tasks.c)),5)
FETCH_RC := $(shell ./fetch.sh >&2; echo $$?)
ifneq ($(FETCH_RC),0)
$(error fetch.sh failed ($(FETCH_RC)); see above)
endif
endif

.PHONY: ddrdt run-ddrdt fatfsfull run-fatfsfull sdtest run-sdtest ddr ddrwd ddrrb ddrwd0 ddrdf run-ddr run-ddrwd run-ddrrb run-ddrwd0 run-ddrdf bench-icarus all hello monitor fatfs run-fatfs freertos run-freertos coremark dhrystone run-hello run-coremark run-dhrystone bench fetch clean embench embench-score
all: hello

fetch:
	./fetch.sh
$(TP)/coremark/core_main.c $(TP)/riscv-tests/benchmarks/dhrystone/dhrystone.c $(TP)/fatfs/source/ff.c $(TP)/freertos/tasks.c:
	./fetch.sh

# A <dir>/flags file holds the flags and toolchain a build used and is rewritten only when
# they change, so an ELF depends on them (BENCH_OPT, CM_ITER, GSF, CFLAGS on the command
# line all rebuild it). Headers are listed by name below, not found by a dependency scan.
.PHONY: FORCE
FORCE:
define STAMP
$$(BUILD)/$(1)/flags: FORCE
	@mkdir -p $$(dir $$@)
	@t=$$@.$$$$$$$$.new; printf '%s\n' '$$(subst ','\'',$$(TC) $$(CFLAGS) $$($(1)_CFLAGS) $$(LDLIBS) $$($(1)_SRC) $$($(1)_MKFLASH) DDR=$$(DDR))' > $$$$t; \
	 if cmp -s $$$$t $$@; then rm -f $$$$t; else mv -f $$$$t $$@; fi
endef
HDRS := $(wildcard common/*.h)

# ── the loader ──────────────────────────────────────────────────────────────
loader_CFLAGS := $(FREESTANDING) $(LOADER_DEFS)
$(eval $(call STAMP,loader))
$(BUILD)/loader/loader.elf: loader/start.S loader/loader.c loader/ddr.S common/uart.c common/trap.c common/trap_entry.S \
                            $(HDRS) loader/loader.ld $(BUILD)/loader/flags
	@mkdir -p $(dir $@)
	$(TC)gcc $(CFLAGS) $(loader_CFLAGS) -nostdlib -nostartfiles -Wl,--no-warn-rwx-segments -T loader/loader.ld \
	    loader/start.S loader/loader.c loader/ddr.S common/uart.c common/trap.c common/trap_entry.S -lgcc -o $@
$(BUILD)/loader/loader.bin: $(BUILD)/loader/loader.elf
	$(TC)objcopy -O binary $< $@

# ── a payload program: <name>_SRC lists its sources, <name>_CFLAGS its flags,
#    <name>/expect.txt what its output must show (tools/check_run.py) ────────
define PAYLOAD
$(eval $(call STAMP,$(1)))
$$(BUILD)/$(1)/$(1).elf: $$(COMMON) $$($(1)_SRC) $$(HDRS) common/payload.ld $$(BUILD)/$(1)/flags \
                         $$(wildcard $(1)/*.h $(1)/port/*.h)
	@mkdir -p $$(dir $$@)
	$$(TC)gcc $$(CFLAGS) $$($(1)_CFLAGS) -nostartfiles -static -Wl,--no-warn-rwx-segments -T common/payload.ld \
	    $$(COMMON) $$($(1)_SRC) $$(LDLIBS) -o $$@
	$$(TC)size $$@
$$(BUILD)/$(1)/$(1).bin: $$(BUILD)/$(1)/$(1).elf
	$$(TC)objcopy -O binary $$< $$@
$$(BUILD)/$(1)/flash.hex: $$(BUILD)/$(1)/$(1).bin $$(BUILD)/loader/loader.bin tools/mkflash.py
	python3 tools/mkflash.py --loader $$(BUILD)/loader/loader.bin --image $$< \
	    --entry 0x$$$$($$(TC)nm $$(BUILD)/$(1)/$(1).elf | awk '$$$$3=="_start"{print $$$$1}') \
	    --out $$@ --bin $$(BUILD)/$(1)/flash.bin $$($(1)_MKFLASH) $$(if $$(DDR),--ddr)
$(1): $$(BUILD)/$(1)/flash.hex
run-$(1): $(1) $$(BUILD)/bench/sim $$($(1)_RUNDEP)
	cd $$(BUILD)/$(1) && $$(SIMRUN) +FLASH_FILE=$$(BUILD)/$(1)/flash.hex +UART_DIV=$$(UART_DIVISOR) $$($(1)_RUNARGS) $$(RUNARGS) | tee run.log
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
monitor_RUNARGS := +UART_IN=$(BUILD)/monitor/in.hex +MAX_CYCLES=150000000   # a stalled session fails in seconds
# MON_SCRIPT picks the session the bench plays (monitor/script-scan.txt: every CSR number, see run-monitor-scan)
MON_SCRIPT ?= monitor/script.txt
$(BUILD)/monitor/in.hex: $(MON_SCRIPT) tools/mkscript.py $(BUILD)/monitor/monitor.elf FORCE
	python3 tools/mkscript.py $(MON_SCRIPT) $@.new --elf $(BUILD)/monitor/monitor.elf
	@cmp -s $@.new $@ && rm $@.new || mv $@.new $@
.PHONY: run-monitor-scan
run-monitor-scan:
	$(MAKE) run-monitor MON_SCRIPT=monitor/script-scan.txt monitor_EXPECT=monitor/expect-scan.txt
	python3 tools/csr_scan_check.py $(BUILD)/monitor/run.log
$(eval $(call PAYLOAD,monitor))

# Rung 4: FatFs on the SD card. ff.c reads ffconf.h from its own directory, so the sources
# are copied to build/sw/fatfs with the port's ffconf.h (fatfs/ffconf.sed applied to the
# vendored one). The disk image is made by tools/mkdisk.sh and the run's card checked by
# tools/fatfs_check.py.
FFB := $(BUILD)/fatfs/src
$(FFB)/ff.c: $(TP)/fatfs/source/ff.c fatfs/ffconf.sed
	@mkdir -p $(FFB)
	cp $(TP)/fatfs/source/ff.c $(TP)/fatfs/source/ff.h $(TP)/fatfs/source/diskio.h $(TP)/fatfs/source/ffunicode.c \
	   $(TP)/fatfs/source/ffsystem.c $(FFB)/
	sed -f fatfs/ffconf.sed $(TP)/fatfs/source/ffconf.h > $(FFB)/ffconf.h
fatfs_SRC    := fatfs/fatfs_test.c fatfs/diskio_sd.c common/sd.c $(FFB)/ff.c $(FFB)/ffunicode.c $(FFB)/ffsystem.c
fatfs_CFLAGS := -I$(FFB) -Wno-format -Wno-error
# DISK=fat12|fat16|mbr picks the card's image and SD=sdhc|sdsc|v1 its kind (byte addressing and
# CMD16 for sdsc, no CMD8 either for v1): make run-fatfs DISK=mbr SD=v1. fat12 on an SDHC card is
# the default; the image is rebuilt when DISK changes.
DISK ?= fat12
SD   ?= sdhc
fatfs_TYPE   := $(if $(filter fat12,$(DISK)),FAT12,FAT16)
fatfs_SDARG  := $(if $(filter sdsc,$(SD)),+SD_SDSC,$(if $(filter v1,$(SD)),+SD_V1,))
fatfs_RUNDEP := $(BUILD)/fatfs/disk-$(DISK).hex
fatfs_RUNARGS := +SD_IMAGE=$(BUILD)/fatfs/disk-$(DISK).hex +SD_DUMP=$(BUILD)/fatfs/dump.hex $(fatfs_SDARG)
fatfs_CHECK  := python3 tools/fatfs_check.py $(BUILD)/fatfs/dump.hex && grep -q "mounted $(fatfs_TYPE)" $(BUILD)/fatfs/run.log
$(BUILD)/fatfs/disk-%.hex: tools/mkdisk.sh tools/img2hex.py
	@mkdir -p $(dir $@)
	./tools/mkdisk.sh $(BUILD)/fatfs/disk-$*.img $@ $*
$(BUILD)/fatfs/fatfs.elf: $(FFB)/ff.c
$(eval $(call PAYLOAD,fatfs))
# The same test with a 128 KB card filled until it is full (-DFULL): make run-fatfsfull
fatfsfull_SRC    := $(fatfs_SRC)
fatfsfull_CFLAGS := $(fatfs_CFLAGS) -DFULL
fatfsfull_RUNDEP := $(BUILD)/fatfs/disk-tiny.hex
fatfsfull_RUNARGS := +SD_IMAGE=$(BUILD)/fatfs/disk-tiny.hex +SD_DUMP=$(BUILD)/fatfs/dump-tiny.hex
fatfsfull_EXPECT := fatfs/expect-full.txt
fatfsfull_CHECK  := python3 tools/fatfs_check.py $(BUILD)/fatfs/dump-tiny.hex --fsck-only
$(BUILD)/fatfsfull/fatfsfull.elf: $(FFB)/ff.c
$(eval $(call PAYLOAD,fatfsfull))

# Rung 5: FreeRTOS-Kernel V11.1.0 with its upstream RISC-V port (M-mode, CLINT tick, heap_4).
FR := $(TP)/freertos
RV := $(FR)/portable/GCC/RISC-V
freertos_SRC    := freertos/freertos_test.c $(addprefix $(FR)/,tasks.c queue.c list.c timers.c) \
                   $(RV)/port.c $(RV)/portASM.S $(FR)/portable/MemMang/heap_4.c
freertos_CFLAGS := -w -Ifreertos/port -I$(FR)/include -I$(RV) \
                   -I$(RV)/chip_specific_extensions/RV32I_CLINT_no_extensions
$(eval $(call PAYLOAD,freertos))
# The fault paths: one build per case, each expected to stop through its hook (expect-neg-<case>.txt).
FR_NEG := overflow malloc assert exc irq
define FRNEG
fr-$(1)_SRC    := $$(freertos_SRC)
fr-$(1)_CFLAGS := $$(freertos_CFLAGS) -DNEG_$(shell echo $(1) | tr a-z A-Z)
fr-$(1)_EXPECT := freertos/expect-neg-$(1).txt
$$(eval $$(call PAYLOAD,fr-$(1)))
endef
$(foreach c,$(FR_NEG),$(eval $(call FRNEG,$(c))))
.PHONY: run-fr-all
run-fr-all: $(addprefix run-fr-,$(FR_NEG))

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

# Rung 1's boot-time DDR sweep (loader/ddr.S): an image flagged --ddr asks the loader for it and
# promises to service the watchdog. ddr checks what the sweep left; ddrwd is the fallback, a
# payload that stops servicing the watchdog with DDR on. The default Pmod model timing has
# passing capture points; make run-ddr ddr_EXPECT=ddr/expect-sdr.txt RUNARGS=+QSPI_DELAY=<ns> runs the
# case where none does. LOADER_DEFS=-DDDR_FORCE_TRAP (or -DDDR_FORCE_MISMATCH) builds the loader so that the
# execute test fails that way. run-ddr-all runs every case (reboots, BOOT_MODE 0xDF, no flag, no-stream, late sampling).
ddr_SRC     := ddr/ddr_test.c
ddr_MKFLASH := --ddr
$(eval $(call PAYLOAD,ddr))
ddrwd_SRC     := ddr/ddr_test.c
ddrwd_CFLAGS  := -DWD
ddrwd_MKFLASH := --ddr
ddrwd_EXPECT  := ddr/expect-wd.txt
$(eval $(call PAYLOAD,ddrwd))
ddrrb_SRC := ddr/ddr_test.c
ddrrb_CFLAGS := -DRB
ddrrb_MKFLASH := --ddr
ddrrb_EXPECT := ddr/expect-rb.txt
$(eval $(call PAYLOAD,ddrrb))
ddrwd0_SRC := ddr/ddr_test.c
ddrwd0_CFLAGS := -DWD0
ddrwd0_MKFLASH := --ddr
ddrwd0_EXPECT := ddr/expect-wd0.txt
$(eval $(call PAYLOAD,ddrwd0))
ddrdf_SRC := ddr/ddr_test.c
ddrdf_CFLAGS := -DDF
ddrdf_MKFLASH := --ddr
ddrdf_EXPECT := ddr/expect-df.txt
$(eval $(call PAYLOAD,ddrdf))
ddrdt_SRC := ddr/ddr_test.c
ddrdt_CFLAGS := -DDT
ddrdt_MKFLASH := --ddr
ddrdt_EXPECT := ddr/expect-dt.txt
$(eval $(call PAYLOAD,ddrdt))
.PHONY: run-ddr-all
run-ddr-all:
	$(MAKE) run-ddr
	$(MAKE) run-ddrwd
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-sdr.txt RUNARGS="+QSPI_DELAY=20"
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-trap.txt LOADER_DEFS=-DDDR_FORCE_TRAP
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-mismatch.txt LOADER_DEFS=-DDDR_FORCE_MISMATCH
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-late.txt LOADER_DEFS=-DDDR_FORCE_LATE_MISMATCH
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-late-trap.txt LOADER_DEFS=-DDDR_FORCE_LATE_TRAP
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-late-nostream.txt LOADER_DEFS=-DDDR_FORCE_LATE_MISMATCH RUNARGS="+NO_STREAM"
	$(MAKE) run-ddrdt
	$(MAKE) run-ddrrb
	$(MAKE) run-ddrwd0
	$(MAKE) run-ddrdf
	$(MAKE) run-ddr ddr_MKFLASH= ddr_EXPECT=ddr/expect-noflag.txt
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-nostream.txt RUNARGS="+NO_STREAM"
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-nostream-sdr.txt RUNARGS="+NO_STREAM +QSPI_DELAY=20"
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-any.txt RUNARGS="+RD_LATE +QSPI_DELAY=36 +QSPI_HOLD=30"
	$(MAKE) run-ddr ddr_EXPECT=ddr/expect-any.txt RUNARGS="+NO_STREAM +RD_LATE +QSPI_DELAY=36 +QSPI_HOLD=30"

# The SD driver's paths against a card with injected faults (tb/sd_spi_model.v +SD_*, tb_sw +SD_ABSENT):
# make run-sdtest-all runs the variants listed in SDTESTS as name:plusargs (a comma separates two); each checks
# sdtest/expect-<name>.txt.
sdtest_SRC    := sdtest/sdtest.c common/sd.c
sdtest_EXPECT := sdtest/expect-sdhc.txt
sdtest_RUNDEP := $(BUILD)/fatfs/disk-fat12.hex
sdtest_RUNARGS := +SD_IMAGE=$(BUILD)/fatfs/disk-fat12.hex +SD_EXPECT
$(eval $(call PAYLOAD,sdtest))
SDTESTS := sdhc: sdsc:+SD_SDSC v1:+SD_V1 rderr:+SD_RDERR=123 wrerr:+SD_WRRESP=0d wrcrc:+SD_WRRESP=0b \
           wrerr1:+SD_WRRESP=0d,+SD_WRONCE \
           staterr:+SD_STATUS=01 absent:+SD_ABSENT stuck:+SD_STUCK_DO never:+SD_BUSY=5000 \
           slow:+SD_BUSY=1500 cmd8bad:+SD_CMD8BAD no16:+SD_SDSC,+SD_NO16
.PHONY: run-sdtest-all
run-sdtest-all: sdtest $(BUILD)/bench/sim $(sdtest_RUNDEP)
	@for v in $(SDTESTS); do n=$${v%%:*}; a=$$(echo "$${v#*:}" | tr ',' ' '); \
	  echo "== sdtest $$n: $$a"; \
	  (cd $(BUILD)/sdtest && $(SIMRUN) +FLASH_FILE=$(BUILD)/sdtest/flash.hex +UART_DIV=$(UART_DIVISOR) $(sdtest_RUNARGS) $$a $(RUNARGS) > run-$$n.log 2>&1); \
	  python3 tools/check_run.py $(BUILD)/sdtest/run-$$n.log sdtest/expect-$$n.txt || exit 1; \
	done; echo "sdtest: all variants ok"

# ── everything ──────────────────────────────────────────────────────────────
# make check runs every test of the ladder on the bench (about 25 minutes of Verilator on one core): the
# runs one after the other, each checking its own expect file, then the damaged-image and timing-matrix
# tools. check-bench adds the benchmarks (CoreMark, Dhrystone, Embench: about 30 minutes more, in parallel).
# SIM=<command> runs the tools on another bench build, for example SIM="vvp build/sw/bench/tb_sw.vvp".
.PHONY: check check-bench
check:
	$(MAKE) run-hello
	$(MAKE) run-monitor
	$(MAKE) run-monitor DDR=1 LOADER_DEFS=-DDDR_FINAL_TOP=6 monitor_EXPECT=monitor/expect-ddr.txt
	$(MAKE) run-monitor-scan
	$(MAKE) run-fatfs DISK=fat12 SD=sdhc
	$(MAKE) run-fatfs DISK=fat16 SD=sdsc
	$(MAKE) run-fatfs DISK=mbr SD=v1
	$(MAKE) run-fatfsfull
	$(MAKE) run-freertos
	$(MAKE) run-freertos DDR=1 LOADER_DEFS=-DDDR_FINAL_TOP=6 freertos_EXPECT=freertos/expect-ddr.txt
	$(MAKE) run-fr-all
	$(MAKE) run-fr-assert DDR=1 LOADER_DEFS=-DDDR_FINAL_TOP=6 fr-assert_EXPECT=freertos/expect-neg-assert-ddr.txt
	$(MAKE) run-fr-malloc DDR=1 LOADER_DEFS=-DDDR_FINAL_TOP=6 fr-malloc_EXPECT=freertos/expect-neg-malloc-ddr.txt
	$(MAKE) run-ddr-all
	$(MAKE) run-sdtest-all
	tools/loader_neg.sh
	tools/ddr_matrix.sh
	@echo "make check: everything passed"
check-bench:
	$(MAKE) run-dhrystone
	$(MAKE) run-coremark CM_ITER=70 RUNARGS=+MAX_CYCLES=2000000000
	$(MAKE) embench
	tools/run_embench.sh 3

# ── the bench ───────────────────────────────────────────────────────────────
# Verilator by default. The same bench builds with Icarus (the reference simulator, about 30x
# slower): make bench-icarus, then  make run-hello SIMRUN='vvp $(BUILD)/bench/tb_sw.vvp'
SIMRUN ?= $(BUILD)/bench/sim
bench-icarus: $(BUILD)/bench/tb_sw.vvp
$(BUILD)/bench/tb_sw.vvp: $(RTL) $(ROOT)/tb/tb_sw.v $(ROOT)/tb/qspi_pmod_model.v $(ROOT)/tb/req_hold_check.v $(ROOT)/tb/sd_spi_model.v
	@mkdir -p $(dir $@)
	iverilog -g2012 -o $@ -s tb_sw $(RTL) $(ROOT)/tb/qspi_pmod_model.v $(ROOT)/tb/req_hold_check.v \
	    $(ROOT)/tb/sd_spi_model.v $(ROOT)/tb/tb_sw.v
bench: $(BUILD)/bench/sim
$(BUILD)/bench/sim: $(RTL) $(ROOT)/tb/tb_sw.v $(ROOT)/tb/qspi_pmod_model.v $(ROOT)/tb/req_hold_check.v $(ROOT)/tb/sd_spi_model.v
	@mkdir -p $(dir $@)
	$(VERILATOR) --binary --timing -j 0 -Wno-fatal -Wno-lint -Wno-style -Wno-WIDTH -Wno-TIMESCALEMOD \
	    --top-module tb_sw -Mdir $(BUILD)/bench/obj -o ../sim \
	    $(RTL) $(ROOT)/tb/qspi_pmod_model.v $(ROOT)/tb/req_hold_check.v $(ROOT)/tb/sd_spi_model.v $(ROOT)/tb/tb_sw.v \
	    > $(BUILD)/bench/build.log 2>&1 || { tail -30 $(BUILD)/bench/build.log; exit 1; }

clean:
	rm -rf $(BUILD)
