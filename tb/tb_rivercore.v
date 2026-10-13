// River Core Compatible Testbench for FyraCore
// Produces per-instruction execution logs in the format expected by river_core:
//   core   0: <priv> 0x<PC> (0x<instr>) [x<rd> 0x<value>] [mem 0x<addr>]
//
// Plusargs:
//   +INIT_FILE=<path>    — hex program to load (default: program.hex)
//   +DUMP_FILE=<path>    — output dump file (default: execution.dump)
//   +MAX_CYCLES=<n>      — simulation timeout (default: 1000000)
//   +TOHOST_ADDR=<hex>   — tohost address for riscv-tests termination
//   +START_PC=<hex>      — PC at which to begin logging (default: 0x0, log from start)
//   +VCD                 — enable VCD waveform dump (off by default)
`timescale 1ns / 1ps

module tb_rivercore;
    reg clk, rst;

    // Memory interface
    wire [31:0] imem_addr, imem_rdata;
    wire        imem_ready;
    wire        imem_req, dmem_req;
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_be;
    wire        dmem_we;
    wire        dmem_ready;

    // Debug
    wire [31:0] dbg_pc, dbg_instr;
    wire        dbg_retired, dbg_trap, dbg_compressed;
    wire        fencei_flush;

    // Interrupt signals from CLINT
    wire        timer_irq, sw_irq, ext_irq;
    wire [63:0] mtime_val;

    // Parameters
    //
    // The core runs on the SoC's own memory map (src/fyracore.v PMA_*
    // defaults): 16 MB of PSRAM at 0x8000_0000, which tb/memory_model.v
    // models, and 16 MB of flash at 0x2000_0000, which it answers with
    // zeros. The program is loaded into PSRAM and the core is started there
    // (boot_addr), where Spike starts too; the SoC itself boots from flash.
    //
    // The memory windows must match plugins/river-config.ini:
    //   [spike] mem_flags = -m0x20000000:0x1000000,0x80000000:0x1000000
    // Change one and you must change the other, or the DUT and the reference
    // disagree about which addresses are mapped -- the bug the PMA check
    // exists to catch.
    //
    // Spike has no read-only memory, so a store to flash succeeds there and
    // is a store access fault here. That divergence is deliberate and
    // spec-legal; no test stores to flash on purpose.
    parameter MEM_SIZE = 16777216; // 16 MB of PSRAM
    parameter MEM_BASE = 32'h8000_0000;

    // IO0 is the CLINT window, and its size is dictated by the reference
    // model, not by the CLINT the hardware will have. Spike maps CLINT_SIZE =
    // 0xC0000 from the CLINT base and ignores the size in its device tree, so
    // every address in 0x02000000-0x020BFFFF answers loads and stores on
    // spike: the register block at 0x0000/0x4000/0xBFF8 and plain zeros
    // everywhere else. Sizing IO0 to the real CLINT's 48 KB instead made every
    // access in between fault on the DUT and succeed on the reference.
    //
    // tb/memory_model.v mirrors the same shape: CLINT registers below offset
    // 0x10000, zeros above, and the write side ignored above -- not the
    // address aliasing a 16-bit offset decode would give.
    //
    // The testbench-only MEIP hook at 0x0200C000 lies inside this window and
    // reads back 0 until a test writes it, which is what spike returns there
    // too, so it stays invisible to lockstep comparison.
    //
    // IO0_BASE must match the clint@ node in
    // plugins/helpers/spike-fyracore.dts; the base is the one thing that DTS
    // can move.
    parameter IO0_BASE = 32'h0200_0000;
    parameter IO0_TOP  = 32'h020B_FFFF;
    // No UART, GPIO or syscon is modelled, and spike has no device there
    // either (plugins/helpers/spike-fyracore.dts drops its UART), so IO1 is
    // switched off by making BASE > TOP -- a window that matches nothing.
    parameter IO1_BASE = 32'hFFFF_FFFF;
    parameter IO1_TOP  = 32'h0000_0000;

`ifdef SOC_TB
    // ── The whole SoC ────────────────────────────────────────────────────
    //
    // Built with -DSOC_TB (tests/directed/run.sh soc), the core runs through
    // the complete memory path -- bus fabric, memory controller and QSPI
    // engine -- against a behavioural QSPI Pmod, instead of memory_model's
    // ideal memory. Everything below this block is shared: the trace reads
    // the core through `CPU, and the tb-level port wires are views of the
    // core's own ports.
    //
    // The SoC always boots from flash. A test linked in PSRAM (the usual
    // case) is loaded into the model's PSRAM through the back door, as
    // memory_model does, and the testbench forces the core's boot_addr to
    // 0x8000_0000, so the first fetch goes through the fabric and the QSPI
    // engine to PSRAM. Every register is 0 on entry, as it is on Spike, which
    // starts the hart at --pc directly; the reference is the same Spike run
    // as the core-level flow. A test given +FLASH_FILE= is a flash-booting
    // program (MANIFEST mode `flash`): it is the flash image, boots from the
    // real boot_addr, and is traced from reset.
    //
    // The CLINT gets dmem_addr[15:0], so the part of Spike's 0xC0000 CLINT
    // aperture above 0x0200_FFFF aliases the registers here instead of
    // reading 0 as memory_model does. No directed test touches it.
    //
    // +RD_LATE sets the QSPI read-latency strap; +QSPI_DELAY (read by the
    // model) sets the device + pad delay it has to cover.
    reg rd_late;
    initial rd_late = $test$plusargs("RD_LATE");
    wire       qspi_sck, qspi_ctl_oe, qspi_io_oe, pmod_oe;
    wire [2:0] qspi_cs_n;
    wire [3:0] qspi_io_out, pmod_io;
    // The pins as the SoC sees them. Nobody driving reads X, so sampling an
    // undriven bus cannot quietly return plausible data.
    wire [3:0] qspi_io_in = pmod_oe ? pmod_io : (qspi_io_oe ? qspi_io_out : 4'bxxxx);

    alphaone_soc #(
        // Match the reference model's marchid so the lockstep dump agrees.
        .MARCHID     (32'd5),
        .PMA_IO0_BASE(IO0_BASE),
        .PMA_IO0_TOP (IO0_TOP),
        .PMA_IO1_BASE(IO1_BASE),
        .PMA_IO1_TOP (IO1_TOP)
    ) soc (
        .clk        (clk),
        .rst        (rst),
        .qspi_rd_late(rd_late),
        .qspi_sck   (qspi_sck),
        .qspi_cs_n  (qspi_cs_n),
        .qspi_ctl_oe(qspi_ctl_oe),
        .qspi_io_out(qspi_io_out),
        .qspi_io_oe (qspi_io_oe),
        .qspi_io_in (qspi_io_in),
        // IO1 is off in this testbench (see IO1_BASE), so the peripherals
        // are unreachable; their pins are only tied to idle levels.
        .uart_rx    (1'b1),
        .uart_tx    (),
        .uart_rts_n (),
        .gpio_in    (8'h00),
        .gpio_out   ()
    );

    qspi_pmod_model pmod (
        .host_sck   (qspi_sck),
        .host_cs_n  (qspi_cs_n),
        .host_ctl_oe(qspi_ctl_oe),
        .host_io    (qspi_io_out),
        .host_oe    (qspi_io_oe),
        .dev_io     (pmod_io),
        .dev_oe     (pmod_oe)
    );

    assign imem_addr      = soc.cpu.imem_addr;
    assign imem_req       = soc.cpu.imem_req;
    assign imem_rdata     = soc.cpu.imem_rdata;
    assign imem_ready     = soc.cpu.imem_ready;
    assign dmem_req       = soc.cpu.dmem_req;
    assign dmem_addr      = soc.cpu.dmem_addr;
    assign dmem_wdata     = soc.cpu.dmem_wdata;
    assign dmem_be        = soc.cpu.dmem_be;
    assign dmem_we        = soc.cpu.dmem_we;
    assign dmem_rdata     = soc.cpu.dmem_rdata;
    assign dmem_ready     = soc.cpu.dmem_ready;
    assign fencei_flush   = soc.cpu.fencei_flush;
    assign dbg_pc         = soc.cpu.dbg_pc;
    assign dbg_retired    = soc.cpu.dbg_retired;
    assign dbg_instr      = soc.cpu.dbg_instr;
    assign dbg_compressed = soc.cpu.dbg_compressed;
    assign dbg_trap       = soc.cpu.dbg_trap;

    // Handshake checkers (tb/req_hold_check.v): memory_model checks the
    // core's side of its ports in the core-level testbench, and there is no
    // memory_model here, where every wait is 40-60 clocks rather than a few.
    // Checked: the core's two ports, the data port as it reaches mem_ctrl
    // through the bus fabric, and mem_ctrl's requests to the QSPI engine.
    req_hold_check #(.W(32), .NAME("imem request")) chk_imem (
        .clk(clk), .rst(rst), .take(imem_req), .hold(imem_req), .done(imem_ready),
        .payload(imem_addr));
    req_hold_check #(.W(69), .NAME("dmem request")) chk_dmem (
        .clk(clk), .rst(rst), .take(dmem_req), .hold(dmem_req), .done(dmem_ready),
        .payload({dmem_addr, dmem_we, dmem_be, dmem_we ? dmem_wdata : 32'h0}));
    req_hold_check #(.W(69), .NAME("mem_ctrl data request")) chk_memd (
        .clk(clk), .rst(rst), .take(soc.memc.d_req), .hold(soc.memc.d_req),
        .done(soc.memc.d_ready),
        .payload({soc.memc.d_addr, soc.memc.d_we, soc.memc.d_be,
                  soc.memc.d_we ? soc.memc.d_wdata : 32'h0}));
    req_hold_check #(.W(61), .NAME("QSPI transaction"), .DONE_NEEDS_REQ(1)) chk_qspi (
        .clk(clk), .rst(rst), .take(soc.qspi.idle && soc.qspi.start),
        .hold(soc.qspi.start), .done(soc.qspi.done),
        .payload({soc.qspi.cs_sel, soc.qspi.addr, soc.qspi.we, soc.qspi.nbytes_m1,
                  soc.qspi.we ? soc.qspi.wdata : 32'h0}));
`define CPU    soc.cpu
`define MEMARR pmod.ram
`else
    fyracore #(
        // Match the reference model's marchid so the lockstep dump agrees.
        .MARCHID     (32'd5),
        .PMA_IO0_BASE(IO0_BASE),
        .PMA_IO0_TOP (IO0_TOP),
        .PMA_IO1_BASE(IO1_BASE),
        .PMA_IO1_TOP (IO1_TOP)
    ) cpu(
        .clk         (clk),
        .rst         (rst),
        .boot_addr   (MEM_BASE),
        .imem_addr   (imem_addr),
        .imem_req    (imem_req),
        .imem_rdata  (imem_rdata),
        .imem_ready  (imem_ready),
        .dmem_req    (dmem_req),
        .dmem_addr   (dmem_addr),
        .dmem_wdata  (dmem_wdata),
        .dmem_be     (dmem_be),
        .dmem_we     (dmem_we),
        .dmem_rdata  (dmem_rdata),
        .dmem_ready  (dmem_ready),
        .timer_irq    (timer_irq),
        .external_irq (ext_irq),
        .sw_irq       (sw_irq),
        .mtime_in     (mtime_val),
        .fencei_flush (fencei_flush),
        .dbg_pc       (dbg_pc),
        .dbg_retired  (dbg_retired),
        .dbg_instr    (dbg_instr),
        .dbg_compressed(dbg_compressed),
        .dbg_trap     (dbg_trap)
    );

    // Instantiate Memory (includes embedded CLINT)
    // INIT_FILE parameter is a placeholder; runtime +INIT_FILE plusarg overrides it.
    // Default INIT_FILE is empty — use +INIT_FILE plusarg at runtime instead.
    // Can also be set at compile time via -DINIT_FILE=\"file.hex\"
`ifndef INIT_FILE
    parameter INIT_FILE = "";
`else
    parameter INIT_FILE = `INIT_FILE;
`endif
    memory_model #(
        .MEM_SIZE (MEM_SIZE),
        .INIT_FILE(INIT_FILE)
    ) mem(
        .clk       (clk),
        .rst       (rst),
        .imem_req  (imem_req),
        .imem_addr (imem_addr),
        .imem_rdata(imem_rdata),
        .dmem_req  (dmem_req),
        .dmem_addr (dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_be   (dmem_be),
        .dmem_we   (dmem_we),
        .dmem_rdata(dmem_rdata),
        .imem_ready(imem_ready),
        .dmem_ready(dmem_ready),
        .timer_irq (timer_irq),
        .sw_irq    (sw_irq),
        .ext_irq   (ext_irq),
        .mtime_out (mtime_val)
    );

`define CPU    cpu
`define MEMARR mem.mem
`endif

    // Clock generation: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // ================================================================
    //  Plusarg handling
    // ================================================================
    integer    dump_fd;
    integer    init_i;
    // 1024 chars each. These must comfortably exceed the longest work-dir path
    // the verification flow passes in: $value$plusargs silently truncates a
    // path that overflows the buffer, which loads an empty memory and produces
    // an empty dump rather than an error.
    reg [8191:0] dump_file_str;
    reg [8191:0] init_file_str;
    integer    max_cycles;
    integer    max_instr;
    reg [31:0] tohost_addr;
    reg        tohost_enabled;
    reg        have_init_file;
    // Spin detection: see the always block below.
    reg [31:0] spin_last_pc;
    integer    spin_count;
    integer    spin_limit;
    reg [31:0] start_pc;
    reg        logging_active;

    initial begin
        // Dump file path
        if (!$value$plusargs("DUMP_FILE=%s", dump_file_str))
            dump_file_str = "execution.dump";
        dump_fd = $fopen(dump_file_str, "w");
        if (dump_fd == 0) begin
            $display("ERROR: Cannot open dump file: %0s", dump_file_str);
            $finish;
        end

        // Max cycles
        // Two independent watchdogs, because they catch different failures:
        //
        //   MAX_CYCLES  a hung pipeline -- a stall that never clears and
        //               retires *nothing*. An instruction bound never fires
        //               for that case.
        //   MAX_INSTR   a program that loops forever while making progress.
        //               riscv-dv generates these: a 16-instruction loop ending
        //               in `bge x31, x31, <backward>` compares a register with
        //               itself, so the branch is always taken and the loop can
        //               never exit. The cycle bound only stops it after ~900k
        //               retires and a 50 MB dump.
        //
        // MAX_INSTR is also what makes the reference comparable: ref.dump is
        // cut to MAX_INSTR commit-log lines, so both models present the same
        // number of retired instructions instead of one running to a cycle
        // limit and the other to a file-size limit.
        //
        // Either bound firing now appends a DUT-ABORT line to the dump (see
        // emit_abort_marker), because two equally truncated traces otherwise
        // compare equal and a program that never terminated was reported as
        // Passed.
        //
        // Measured over 1200 passing tests, the largest legitimate run is
        // 85,111 retires (p99 = 78,012), so 200,000 is ~2.3x headroom. At the
        // worst observed IPC (0.14) that needs ~1.4M cycles, hence 3,000,000
        // for the cycle backstop -- MAX_INSTR should normally be the one that
        // fires.
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 3000000;
        if (!$value$plusargs("MAX_INSTR=%d", max_instr))
            max_instr = 200000;

        // tohost address (riscv-tests convention)
        tohost_enabled = $value$plusargs("TOHOST_ADDR=%h", tohost_addr);

        // Start PC for logging
        if (!$value$plusargs("START_PC=%h", start_pc)) begin
            start_pc = 32'h0;
            logging_active = 1'b1;
        end else begin
            logging_active = 1'b0;
        end

        // Runtime hex file override (takes precedence over compile-time
        // INIT_FILE). Only the plusarg is read here; the load itself happens
        // at #1 below, see the note there.
        have_init_file = $value$plusargs("INIT_FILE=%s", init_file_str);

        // Optional VCD dump
        if ($test$plusargs("VCD")) begin
            $dumpfile("cpu_trace.vcd");
            $dumpvars(0, tb_rivercore);
        end
    end

    // Program load, deliberately at #1 rather than time 0.
    //
    // memory_model's own initial block zero-fills all MEM_SIZE bytes before
    // applying its compile-time INIT_FILE. Verilog does not define the relative
    // order of initial blocks in different modules, so loading the program at
    // time 0 here could be undone by that fill. #1 is strictly after every
    // time-0 initial block, and reset is held until #25, so the core has not
    // fetched anything yet.
    //
    // This also drops a second 33.5M-iteration zero-fill that used to run here.
    // Duplicating memory_model's fill cost roughly half of each simulation's
    // startup, which across a 1000+ test regression was the single largest
    // contributor to wall-clock time.
    initial begin
        #1;
        if (have_init_file) begin
            $readmemh(init_file_str, `MEMARR);
            // A missing or truncated INIT_FILE leaves memory zero-filled, which
            // otherwise runs to MAX_CYCLES and writes an empty dump - a silent
            // failure the comparison stage reports as a DUT bug. Empty dumps
            // also compare equal to each other, so this must fail loudly.
            // boot_addr 0x80000000 is mem[0] (memory_model indexes PSRAM by [23:0]).
            if ({`MEMARR[3], `MEMARR[2], `MEMARR[1], `MEMARR[0]} === 32'h0) begin
                $display("ERROR: no program loaded at reset PC from INIT_FILE=%0s",
                         init_file_str);
                $fatal(1);
            end
        end
    end


`ifdef SOC_TB
    // A PSRAM-linked test boots straight into PSRAM (see the SoC block
    // above). This used to be a two-instruction flash stub -- lui t0, 0x80000;
    // jr t0 -- which left t0 = 0x8000_0000 on entry. That matched the boot ROM
    // of the Spike of the time, which ended in the same state; current Spike
    // runs no ROM and enters with t0 = 0, so the stub would now diverge on any
    // test that reads t0 before writing it. At #1, after the plusargs above
    // and long before reset ends.
    initial begin
        #1;
        if (!$test$plusargs("FLASH_FILE")) begin
            force soc.cpu.boot_addr = 32'h8000_0000;
            start_pc       = 32'h8000_0000;
            logging_active = 1'b0;
        end
    end
`endif

    // ================================================================
    //  Counters
    // ================================================================
    integer instr_count = 0;
    integer cycle_count = 0;

    // ================================================================
    //  Termination detection
    // ================================================================
    wire trap_handler_set = (`CPU.csr_unit.mtvec != 32'b0);
    wire is_ecall  = dbg_trap && (dbg_instr == 32'h0000_0073) && !trap_handler_set;
    wire is_ebreak = dbg_trap && (dbg_instr == 32'h0010_0073) && !trap_handler_set;
    wire is_halt   = dbg_retired && (dbg_instr == 32'h0000_006f);
    wire is_tohost = tohost_enabled && dmem_we &&
                     (dmem_addr == tohost_addr) && (dmem_wdata != 32'b0);

    // ================================================================
    //  Termination flag — set on detection cycle, acted on next cycle
    //  so the dump always block can flush the last line first.
    //
    //  ecall/ebreak/halt: terminate immediately (one extra retire).
    //  tohost: spike continues retiring through write_tohost's high-word
    //  store and fence.i before halting. Drain up to 4 extra retires (or
    //  stop on fence.i retire) so the trace matches.
    // ================================================================
    reg     terminate    = 1'b0;
    reg     saw_tohost   = 1'b0;
    integer post_tohost_retires = 0;
    wire    is_fencei_retire = dbg_retired && (dbg_instr == 32'h0000_100f);

    // ================================================================
    //  Spin detection
    //
    //  A core that loses its way -- e.g. a corrupted privilege/PC after a bad
    //  trap return -- typically ends up on a branch-to-self and retires the
    //  same PC until MAX_CYCLES. That costs a full timeout per test and writes
    //  a dump of hundreds of thousands of identical lines, which is both slow
    //  and useless: the reference dump for such a test is only tens of
    //  thousands of lines, so the length mismatch is the symptom, not the bug.
    //
    //  Abort once the same PC has retired SPIN_LIMIT times consecutively. The
    //  dump keeps everything up to that point, which is what diagnosis needs,
    //  and the run fails in seconds instead of minutes.
    //
    //  The default is deliberately generous. A test may legitimately park in a
    //  self-loop waiting for an interrupt, and cutting that short would turn a
    //  passing test into a failure -- a far worse outcome than a slow one. At
    //  100000 the limit is still an order of magnitude below MAX_CYCLES, so a
    //  genuine hang is caught early, while no plausible interrupt wait comes
    //  close.
    //
    //  +SPIN_LIMIT=0 disables this, for a test with a legitimate long spin.
    // ================================================================
    initial begin
        spin_last_pc = 32'hFFFF_FFFF;
        spin_count   = 0;
        if (!$value$plusargs("SPIN_LIMIT=%d", spin_limit))
            spin_limit = 100000;
    end

    always @(posedge clk) begin
        if (!rst && dbg_retired && !terminate && spin_limit != 0) begin
            if (dbg_pc == spin_last_pc) begin
                spin_count = spin_count + 1;
                if (spin_count >= spin_limit) begin
                    $display("ERROR: spinning at PC 0x%08h (same PC retired %0d times), aborting",
                             dbg_pc, spin_count);
                    emit_abort_marker;
                    $fclose(dump_fd);
                    $finish;
                end
            end else begin
                spin_last_pc = dbg_pc;
                spin_count   = 0;
            end
        end
    end


    always @(posedge clk) begin
        if (!rst && !terminate) begin
            if (is_ecall || is_ebreak)
                terminate <= 1'b1;
            if (is_halt)
                terminate <= 1'b1;
            if (is_tohost)
                saw_tohost <= 1'b1;
            if (saw_tohost && dbg_retired)
                post_tohost_retires <= post_tohost_retires + 1;
            if (saw_tohost && (is_fencei_retire || post_tohost_retires >= 3))
                terminate <= 1'b1;
        end
    end

    // ================================================================
    //  START_PC gating — logging starts with the instruction at start_pc
    // ================================================================
    // logging_on includes the retire of that first instruction itself;
    // logging_active, a register, only turns on after it, so gating the dump
    // on it alone dropped the first line.
    wire logging_on = logging_active || (dbg_retired && dbg_pc == start_pc);
    always @(posedge clk) begin
        if (logging_on)
            logging_active <= 1'b1;
    end

    // ================================================================
    //  Dump line emission — one line per retired instruction
    // ================================================================
    // Uses combinational writeback signals from fyracore:
    //   cpu.wb_regWR  — register write enable
    //   cpu.wb_rd     — destination register index
    //   cpu.wb_data   — value being written
    //   cpu.exwb_memRD — load indicator
    //   dmem_we       — store indicator (top-level port)
    //   dmem_addr     — memory address (top-level port)
    //   cpu.priv_mode — privilege: 1=M, 0=U (non-blocking update, reads OLD value)
    // CSR commit values are printed from cpu.csr_wval: csr.v's own post-write
    // value, i.e. exactly what the register holds once the write commits
    // (Spike logs the post-WARL value). This used to be a fourth copy of the
    // WARL rules, recomputed here, and it drifted -- it printed mepc without
    // the IALIGN mask and ignored locked PMP entries, so the trace claimed
    // values the DUT never held.

    // priv_mode is updated at EX stage on mret; by the time the mret retires at
    // WB the register already holds the post-mret priv. Spike emits the priv at
    // execution time, so override to M (3) for mret retire lines.
    wire is_mret_retire = (dbg_instr == 32'h30200073);
    wire [1:0] dump_priv = is_mret_retire ? 2'd3 : (`CPU.priv_mode ? 2'd3 : 2'd0);

    always @(posedge clk) begin
        // The retire-budget test belongs here rather than only in the main
        // loop: the loop checks after the write has already happened, which
        // emitted max_instr+1 lines. Spike stops at exactly --instructions,
        // so one extra line would fail every bounded test on length.
        if (!rst && dbg_retired && logging_on && !terminate &&
            (max_instr == 0 || instr_count < max_instr)) begin
            // Header: core <hart>: <priv> 0x<PC> (0x<instr>)
            // Compressed instructions print as 4 hex digits to match Spike.
            if (dbg_compressed)
                $fwrite(dump_fd, "core   0: %0d 0x%08h (0x%04h)",
                        dump_priv,
                        dbg_pc,
                        dbg_instr[15:0]);
            else
                $fwrite(dump_fd, "core   0: %0d 0x%08h (0x%08h)",
                        dump_priv,
                        dbg_pc,
                        dbg_instr);

            // Register change (only if rd != x0)
            if (`CPU.wb_regWR && `CPU.wb_rd != 5'b0)
                $fwrite(dump_fd, " x%0d 0x%08h", `CPU.wb_rd, `CPU.wb_data);

            // CSR commit (Spike format: c<addr_dec>_<name> 0x<value>)
            if (`CPU.exwb_csrWR) begin
                case (`CPU.exwb_csr_addr)
                    12'h300: $fwrite(dump_fd, " c768_mstatus 0x%08h",   `CPU.csr_wval);
                    // A refused misa.C clear leaves misa unchanged, and Spike
                    // logs nothing for it.
                    12'h301: if (`CPU.exwb_csr_wdata[2] == 1'b1 || !`CPU.exwb_trap_pc[1])
                                  $fwrite(dump_fd, " c769_misa 0x%08h", `CPU.csr_wval);
                    12'h304: $fwrite(dump_fd, " c772_mie 0x%08h",       `CPU.csr_wval);
                    12'h305: $fwrite(dump_fd, " c773_mtvec 0x%08h",     `CPU.csr_wval);
                    12'h306: $fwrite(dump_fd, " c774_mcounteren 0x%08h",`CPU.csr_wval);
                    12'h320: $fwrite(dump_fd, " c800_mcountinhibit 0x%08h", `CPU.csr_wval);
                    12'h340: $fwrite(dump_fd, " c832_mscratch 0x%08h",  `CPU.csr_wval);
                    12'h341: $fwrite(dump_fd, " c833_mepc 0x%08h",      `CPU.csr_wval);
                    12'h342: $fwrite(dump_fd, " c834_mcause 0x%08h",    `CPU.csr_wval);
                    12'h343: $fwrite(dump_fd, " c835_mtval 0x%08h",     `CPU.csr_wval);
                    12'h344: $fwrite(dump_fd, " c836_mip 0x%08h",       `CPU.csr_wval);
                    // A PMP write that a lock discards entirely is not
                    // logged by Spike: pmpcfg0 only when every byte is
                    // locked, pmpaddr[i] when its own or entry i+1's TOR
                    // lock holds it.
                    12'h3A0: if (!(`CPU.csr_pmpcfg0[7]  && `CPU.csr_pmpcfg0[15] &&
                                   `CPU.csr_pmpcfg0[23] && `CPU.csr_pmpcfg0[31]))
                                  $fwrite(dump_fd, " c928_pmpcfg0 0x%08h",  `CPU.csr_wval);
                    12'h3B0: if (!`CPU.csr_unit.tor_lock_addr0)
                                  $fwrite(dump_fd, " c944_pmpaddr0 0x%08h", `CPU.csr_wval);
                    12'h3B1: if (!`CPU.csr_unit.tor_lock_addr1)
                                  $fwrite(dump_fd, " c945_pmpaddr1 0x%08h", `CPU.csr_wval);
                    12'h3B2: if (!`CPU.csr_unit.tor_lock_addr2)
                                  $fwrite(dump_fd, " c946_pmpaddr2 0x%08h", `CPU.csr_wval);
                    12'h3B3: if (!`CPU.csr_unit.tor_lock_addr3)
                                  $fwrite(dump_fd, " c947_pmpaddr3 0x%08h", `CPU.csr_wval);
                    12'hB00: $fwrite(dump_fd, " c2816_mcycle 0x%08h",   `CPU.csr_wval);
                    12'hB02: $fwrite(dump_fd, " c2818_minstret 0x%08h", `CPU.csr_wval);
                    12'hB80: $fwrite(dump_fd, " c2944_mcycleh 0x%08h",  `CPU.csr_wval);
                    12'hB82: $fwrite(dump_fd, " c2946_minstreth 0x%08h",`CPU.csr_wval);
                    // Read-only-zero CSRs Spike does log a write to.
                    12'h30A: $fwrite(dump_fd, " c778_menvcfg 0x%08h",   `CPU.csr_wval);
                    12'h31A: $fwrite(dump_fd, " c794_menvcfgh 0x%08h",  `CPU.csr_wval);
                    // pmpaddr4-15 beyond the 4 implemented regions: Spike
                    // (since 4850489d) accepts the write, keeps 0 and logs it.
                    12'h3B4, 12'h3B5, 12'h3B6, 12'h3B7,
                    12'h3B8, 12'h3B9, 12'h3BA, 12'h3BB,
                    12'h3BC, 12'h3BD, 12'h3BE, 12'h3BF:
                        $fwrite(dump_fd, " c%0d_pmpaddr%0d 0x%08h",
                                `CPU.exwb_csr_addr, `CPU.exwb_csr_addr[3:0], `CPU.csr_wval);
                    // Writes Spike accepts without logging: the
                    // unimplemented pmpcfg1-3, mstatush and
                    // mhpmcounter3-31(h), all of which read 0.
                    default:
                        if (`CPU.exwb_csr_addr[11:5] == 7'b0011_001 &&
                            `CPU.exwb_csr_addr[4:0] >= 5'd3)    // mhpmevent3-31
                            $fwrite(dump_fd, " c%0d_mhpmevent%0d 0x%08h",
                                    `CPU.exwb_csr_addr, `CPU.exwb_csr_addr[4:0], `CPU.csr_wval);
                endcase
            end

            // MRET commit: csr.v applies MPP<-00, MPIE<-1, MIE<-MPIE in the EX
            // cycle (when mret is detected). At this WB-stage retire cycle,
            // mstatus already holds the post-MRET value, so emit it raw.
            if (is_mret_retire) begin
                $fwrite(dump_fd, " c768_mstatus 0x%08h", `CPU.csr_unit.mstatus);
            end

            // Memory access marker. Spike format: loads emit "mem 0x<addr>";
            // stores emit "mem 0x<addr> 0x<value>". Spike logs the architectural
            // (unaligned) effective address and the natural-width store data,
            // so we use exwb_alu_result instead of dmem_addr and width-mask
            // exwb_rs2_data instead of using the bus-shifted store_data.
            if (`CPU.exwb_memRD) begin
                $fwrite(dump_fd, " mem 0x%08h", `CPU.exwb_alu_result);
                // An AMO reads and writes in the same retire, and Spike logs
                // both markers on one line. Emitting only the read leaves the
                // written value uncompared: river_core's dump parser pairs the
                // change tokens two at a time and silently drops the odd
                // trailing one, so a wrong AMO result still compares equal.
                // Gated on dmem_we, not just on the AMO phase: the marker must
                // record a write the core actually put on the bus. Printing it
                // from the decode alone would keep the dump matching Spike even
                // if the store were dropped, which is exactly the failure the
                // trace exists to catch.
                if (`CPU.exwb_isAmo && `CPU.amo_phase && dmem_we)
                    $fwrite(dump_fd, " mem 0x%08h 0x%08h",
                            `CPU.exwb_alu_result, dmem_wdata);
            end
            else if (dmem_we) begin
                case (`CPU.exwb_memSize)
                    2'b00: $fwrite(dump_fd, " mem 0x%08h 0x%02h",
                                   `CPU.exwb_alu_result, `CPU.exwb_rs2_data[7:0]);
                    2'b01: $fwrite(dump_fd, " mem 0x%08h 0x%04h",
                                   `CPU.exwb_alu_result, `CPU.exwb_rs2_data[15:0]);
                    default: $fwrite(dump_fd, " mem 0x%08h 0x%08h",
                                     `CPU.exwb_alu_result, `CPU.exwb_rs2_data);
                endcase
            end

            $fwrite(dump_fd, "\n");

            instr_count = instr_count + 1;
        end
    end

    // ================================================================
    //  Register-file read check
    //
    //  The register file (src/regFile.v, the rf_top macro) reads
    //  synchronously: in every cycle the core must put on its read
    //  addresses the registers the instruction in EX will use in the next
    //  one. A slip reads another register, or the right one a cycle stale,
    //  and the trace only shows it if the value happens to differ. So on
    //  every cycle with an instruction in EX, for each source register it
    //  names other than x0, this checks that the macro took that register's
    //  address on the edge that started the cycle, and that the data equals
    //  a shadow register file kept from the write port. A mismatch ends the
    //  run with an ERROR line and a DUT-ABORT marker in the dump.
    // ================================================================
    reg [31:0] rf_shadow [0:31];
    reg [4:0]  rf_ra_q, rf_rb_q;
    reg        rf_chk_armed = 1'b0;
    integer    rf_chk_n = 0;
    integer    rf_i;
    initial begin
        #1;     // after rf_top's own initial block
        for (rf_i = 0; rf_i < 32; rf_i = rf_i + 1)
            rf_shadow[rf_i] = `CPU.rf.rf_macro.storage[rf_i];
    end
    task rf_read_mismatch(input [8*3-1:0] port, input [4:0] want, input [4:0] took,
                          input [31:0] got, input [31:0] exp);
        begin
            $display("ERROR: register-file read, port %0s at pc 0x%08h cycle %0d: needs x%0d, macro took x%0d, data 0x%08h, shadow 0x%08h",
                     port, `CPU.ifex_pc, cycle_count, want, took, got, exp);
            emit_abort_marker;
            $fclose(dump_fd);
            $finish;
        end
    endtask
    always @(posedge clk) begin
        if (!rst && rf_chk_armed && `CPU.ifex_valid) begin
            if (`CPU.ex_rs1 != 5'd0) begin
                rf_chk_n = rf_chk_n + 1;
                if (rf_ra_q !== `CPU.ex_rs1 || `CPU.rf_a !== rf_shadow[`CPU.ex_rs1])
                    rf_read_mismatch("rs1", `CPU.ex_rs1, rf_ra_q, `CPU.rf_a, rf_shadow[`CPU.ex_rs1]);
            end
            if (`CPU.ex_rs2 != 5'd0) begin
                rf_chk_n = rf_chk_n + 1;
                if (rf_rb_q !== `CPU.ex_rs2 || `CPU.rf_b !== rf_shadow[`CPU.ex_rs2])
                    rf_read_mismatch("rs2", `CPU.ex_rs2, rf_rb_q, `CPU.rf_b, rf_shadow[`CPU.ex_rs2]);
            end
        end
        if (`CPU.wb_regWR && `CPU.wb_rd != 5'd0)
            rf_shadow[`CPU.wb_rd] = `CPU.wb_data;
        rf_ra_q = `CPU.rf.ra;
        rf_rb_q = `CPU.rf.rb;
        rf_chk_armed = 1'b1;
    end

    // ================================================================
    //  Reduced-term check
    //
    //  muldiv_want leaves most of the trap decode out, on the argument
    //  that those causes cannot be raised for an M instruction or a shift
    //  (src/fyracore.v, ex_trap_iter). This holds it to the full term on
    //  every clock of every run.
    // ================================================================
    always @(posedge clk) begin
        if (!rst && `CPU.muldiv_want !==
                    (`CPU.ifex_valid && `CPU.ex_is_iter && !`CPU.ex_trap_decode)) begin
            $display("ERROR: muldiv_want %b differs from the full trap decode at pc 0x%08h cycle %0d (ex_trap_decode %b)",
                     `CPU.muldiv_want, `CPU.ifex_pc, cycle_count, `CPU.ex_trap_decode);
            emit_abort_marker;
            $fclose(dump_fd);
            $finish;
        end
    end

    // ================================================================
    //  use_hazard check
    //
    //  use_hazard holds an instruction in EX only by keeping ex_ph clear
    //  (src/fyracore.v, ex_wait). That is enough only if it can never rise
    //  once ex_ph is set: no instruction that writes a register the EX
    //  instruction reads may reach WB before that instruction leaves.
    // ================================================================
    always @(posedge clk) begin
        if (!rst && `CPU.ifex_valid && `CPU.ex_ph && `CPU.use_hazard) begin
            $display("ERROR: use_hazard with ex_ph set at pc 0x%08h cycle %0d (WB writes x%0d)",
                     `CPU.ifex_pc, cycle_count, `CPU.exwb_rd);
            emit_abort_marker;
            $fclose(dump_fd);
            $finish;
        end
    end

    // ================================================================
    //  Main simulation loop
    // ================================================================
    initial begin
        $display("===========================================================");
        $display("  FyraCore River Core Compatible Testbench");
        $display("  Dump file: %0s", dump_file_str);
        $display("===========================================================");

        // Reset
        rst = 1;
        #25;
        rst = 0;

        // Run until termination, the retire budget, or the cycle backstop
        while (cycle_count < max_cycles) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            if (max_instr != 0 && instr_count >= max_instr) begin
                $display("--- Max instructions (%0d) reached ---", max_instr);
                emit_abort_marker;
                $fclose(dump_fd);
                print_summary();
                $finish;
            end

            // terminate is set on the detection cycle; we act one cycle later
            // so the always block has time to $fwrite the last dump line.
            if (terminate) begin
                // Wait one extra cycle for the dump always block to flush
                @(posedge clk);
                cycle_count = cycle_count + 1;
                $fclose(dump_fd);
                print_summary();
                $finish;
            end
        end

        $display("--- Max cycles (%0d) reached ---", max_cycles);
        emit_abort_marker;
        $fclose(dump_fd);
        print_summary();
        $finish;
    end

    // ================================================================
    //  Abort marker
    //
    //  Every abort path here ends in $finish, i.e. exit status 0, and leaves a
    //  dut.dump that is simply short. The reference is bounded at the same
    //  retire count, so a program that never terminates produced two equally
    //  truncated traces that compared EQUAL and were reported as Passed --
    //  true as far as it went (N retires matched) but not what "Passed" is
    //  read to mean.
    //
    //  Write a line that cannot appear in ref.dump instead. river_core's
    //  compare_dumps parses each differing line with its commit-log regex; a
    //  line that does not match raises IndexError inside the walk, which it
    //  already handles by setting the verdict to Failed. So an unterminated,
    //  spinning or hung run now fails loudly, and sim.log says which it was.
    // ================================================================
    task emit_abort_marker;
        begin
            $fwrite(dump_fd,
                    "DUT-ABORT: run did not reach tohost (retires %0d, cycles %0d) -- trace truncated, not a pass\n",
                    instr_count, cycle_count);
        end
    endtask

    // ================================================================
    //  Summary statistics
    // ================================================================
    task print_summary;
        begin
            $display("  Cycles: %0d   Instructions logged: %0d", cycle_count, instr_count);
            if (instr_count > 0)
                $display("  IPC: %0f", $itor(instr_count) / $itor(cycle_count));
            $display("  Register-file reads checked: %0d", rf_chk_n);
            $display("  Dump: %0s", dump_file_str);
        end
    endtask

endmodule
