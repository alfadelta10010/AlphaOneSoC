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
    wire [31:0] dmem_addr, dmem_wdata, dmem_rdata;
    wire [3:0]  dmem_wmask;
    wire        dmem_we;
    wire        dmem_ready;

    // Debug
    wire [31:0] dbg_pc, dbg_instr;
    wire        dbg_retired, dbg_trap, dbg_compressed;
    wire        fencei_flush;

    // Interrupt signals from CLINT
    wire        timer_irq, sw_irq;
    wire [63:0] mtime_val;

    // Parameters
    parameter MEM_SIZE = 33554432; // 32 MB

    // Instantiate CPU
    // RESET_PC = 0x80000000 — matches Spike's default DRAM_BASE so the
    // verification flow can use riscv-tests' env/p/link.ld unchanged.
    fyracore #(.RESET_PC(32'h8000_0000)) cpu(
        .clk         (clk),
        .rst         (rst),
        .imem_addr   (imem_addr),
        .imem_rdata  (imem_rdata),
        .imem_ready  (imem_ready),
        .dmem_addr   (dmem_addr),
        .dmem_wdata  (dmem_wdata),
        .dmem_wmask  (dmem_wmask),
        .dmem_we     (dmem_we),
        .dmem_rdata  (dmem_rdata),
        .dmem_ready  (dmem_ready),
        .timer_irq    (timer_irq),
        .external_irq (1'b0),
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
        .imem_addr (imem_addr),
        .imem_rdata(imem_rdata),
        .dmem_addr (dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_wmask(dmem_wmask),
        .dmem_we   (dmem_we),
        .dmem_rdata(dmem_rdata),
        .imem_ready(imem_ready),
        .dmem_ready(dmem_ready),
        .timer_irq (timer_irq),
        .sw_irq    (sw_irq),
        .mtime_out (mtime_val)
    );

    // Clock generation: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // ================================================================
    //  Plusarg handling
    // ================================================================
    integer    dump_fd;
    integer    init_i;
    reg [1023:0] dump_file_str;
    reg [1023:0] init_file_str;
    integer    max_cycles;
    reg [31:0] tohost_addr;
    reg        tohost_enabled;
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
        if (!$value$plusargs("MAX_CYCLES=%d", max_cycles))
            max_cycles = 1000000;

        // tohost address (riscv-tests convention)
        tohost_enabled = $value$plusargs("TOHOST_ADDR=%h", tohost_addr);

        // Start PC for logging
        if (!$value$plusargs("START_PC=%h", start_pc)) begin
            start_pc = 32'h0;
            logging_active = 1'b1;
        end else begin
            logging_active = 1'b0;
        end

        // Runtime hex file override (takes precedence over compile-time INIT_FILE)
        if ($value$plusargs("INIT_FILE=%s", init_file_str)) begin
            for (init_i = 0; init_i < MEM_SIZE; init_i = init_i + 1)
                mem.mem[init_i] = 8'h00;
            $readmemh(init_file_str, mem.mem);
        end

        // Optional VCD dump
        if ($test$plusargs("VCD")) begin
            $dumpfile("cpu_trace.vcd");
            $dumpvars(0, tb_rivercore);
        end
    end

    // ================================================================
    //  Counters
    // ================================================================
    integer instr_count = 0;
    integer cycle_count = 0;

    // ================================================================
    //  Termination detection
    // ================================================================
    wire trap_handler_set = (cpu.csr_unit.mtvec != 32'b0);
    wire is_ecall  = dbg_trap && (dbg_instr == 32'h0000_0073) && !trap_handler_set;
    wire is_ebreak = dbg_trap && (dbg_instr == 32'h0010_0073) && !trap_handler_set;
    wire is_halt   = dbg_retired && (dbg_instr == 32'h0000_006f);
    wire is_tohost = tohost_enabled && dmem_we &&
                     (dmem_addr == tohost_addr) && (dmem_wdata != 32'b0);

    // ================================================================
    //  Termination flag — set on detection cycle, acted on next cycle
    //  so the dump always block can flush the last line first.
    // ================================================================
    reg terminate = 1'b0;

    always @(posedge clk) begin
        if (!rst && !terminate) begin
            if (is_ecall || is_ebreak)
                terminate <= 1'b1;
            if (is_halt)
                terminate <= 1'b1;
            if (is_tohost)
                terminate <= 1'b1;
        end
    end

    // ================================================================
    //  START_PC gating — activate logging when PC matches start_pc
    // ================================================================
    always @(posedge clk) begin
        if (!logging_active && dbg_retired && dbg_pc == start_pc)
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
    // Apply WARL masks to a CSR write so the dumped commit value matches
    // what gets stored in csr.v (Spike emits the post-WARL value).
    function automatic [31:0] csr_committed;
        input [11:0] addr;
        input [31:0] new_val;
        begin
            case (addr)
                12'h300: csr_committed = new_val & 32'h0000_1888; // mstatus
                12'h304: csr_committed = new_val & 32'h0000_0888; // mie
                12'h305: csr_committed = {new_val[31:2], 2'b00};   // mtvec (direct mode)
                12'h306: csr_committed = new_val & 32'h0000_0007; // mcounteren
                12'h341: csr_committed = {new_val[31:1], 1'b0};    // mepc
                12'h344: csr_committed = new_val & ~32'h0000_0888; // mip (writable bits)
                12'h3A0: csr_committed = {                          // pmpcfg0: mask reserved A=10
                    new_val[31:29], (new_val[28:27]==2'b10 ? 2'b00 : new_val[28:27]), new_val[26:24],
                    new_val[23:21], (new_val[20:19]==2'b10 ? 2'b00 : new_val[20:19]), new_val[18:16],
                    new_val[15:13], (new_val[12:11]==2'b10 ? 2'b00 : new_val[12:11]), new_val[10:8],
                    new_val[7:5],   (new_val[4:3]  ==2'b10 ? 2'b00 : new_val[4:3]),   new_val[2:0]};
                default: csr_committed = new_val;
            endcase
        end
    endfunction

    always @(posedge clk) begin
        if (!rst && dbg_retired && logging_active && !terminate) begin
            // Header: core <hart>: <priv> 0x<PC> (0x<instr>)
            // Compressed instructions print as 4 hex digits to match Spike.
            if (dbg_compressed)
                $fwrite(dump_fd, "core   0: %0d 0x%08h (0x%04h)",
                        cpu.priv_mode ? 3 : 0,
                        dbg_pc,
                        dbg_instr[15:0]);
            else
                $fwrite(dump_fd, "core   0: %0d 0x%08h (0x%08h)",
                        cpu.priv_mode ? 3 : 0,
                        dbg_pc,
                        dbg_instr);

            // Register change (only if rd != x0)
            if (cpu.wb_regWR && cpu.wb_rd != 5'b0)
                $fwrite(dump_fd, " x%0d 0x%08h", cpu.wb_rd, cpu.wb_data);

            // CSR commit (Spike format: c<addr_dec>_<name> 0x<value>)
            if (cpu.exwb_csrWR) begin
                case (cpu.exwb_csr_addr)
                    12'h300: $fwrite(dump_fd, " c768_mstatus 0x%08h",   csr_committed(12'h300, cpu.exwb_csr_wdata));
                    12'h301: $fwrite(dump_fd, " c769_misa 0x%08h",      cpu.exwb_csr_wdata);
                    12'h304: $fwrite(dump_fd, " c772_mie 0x%08h",       csr_committed(12'h304, cpu.exwb_csr_wdata));
                    12'h305: $fwrite(dump_fd, " c773_mtvec 0x%08h",     csr_committed(12'h305, cpu.exwb_csr_wdata));
                    12'h306: $fwrite(dump_fd, " c774_mcounteren 0x%08h",csr_committed(12'h306, cpu.exwb_csr_wdata));
                    12'h340: $fwrite(dump_fd, " c832_mscratch 0x%08h",  cpu.exwb_csr_wdata);
                    12'h341: $fwrite(dump_fd, " c833_mepc 0x%08h",      csr_committed(12'h341, cpu.exwb_csr_wdata));
                    12'h342: $fwrite(dump_fd, " c834_mcause 0x%08h",    cpu.exwb_csr_wdata);
                    12'h343: $fwrite(dump_fd, " c835_mtval 0x%08h",     cpu.exwb_csr_wdata);
                    12'h344: $fwrite(dump_fd, " c836_mip 0x%08h",       csr_committed(12'h344, cpu.exwb_csr_wdata));
                    12'h3A0: $fwrite(dump_fd, " c928_pmpcfg0 0x%08h",   csr_committed(12'h3A0, cpu.exwb_csr_wdata));
                    12'h3B0: $fwrite(dump_fd, " c944_pmpaddr0 0x%08h",  cpu.exwb_csr_wdata);
                    12'h3B1: $fwrite(dump_fd, " c945_pmpaddr1 0x%08h",  cpu.exwb_csr_wdata);
                    12'h3B2: $fwrite(dump_fd, " c946_pmpaddr2 0x%08h",  cpu.exwb_csr_wdata);
                    12'h3B3: $fwrite(dump_fd, " c947_pmpaddr3 0x%08h",  cpu.exwb_csr_wdata);
                    12'hB00: $fwrite(dump_fd, " c2816_mcycle 0x%08h",   cpu.exwb_csr_wdata);
                    12'hB02: $fwrite(dump_fd, " c2818_minstret 0x%08h", cpu.exwb_csr_wdata);
                    12'hB80: $fwrite(dump_fd, " c2944_mcycleh 0x%08h",  cpu.exwb_csr_wdata);
                    12'hB82: $fwrite(dump_fd, " c2946_minstreth 0x%08h",cpu.exwb_csr_wdata);
                    default: $fwrite(dump_fd, " c%0d 0x%08h", cpu.exwb_csr_addr, cpu.exwb_csr_wdata);
                endcase
            end

            // MRET commit: csr.v applies MPP<-00, MPIE<-1, MIE<-MPIE on retire.
            // Emit the post-MRET mstatus so the trace matches Spike's commit log.
            if (dbg_instr == 32'h30200073) begin
                $fwrite(dump_fd, " c768_mstatus 0x%08h",
                    {cpu.csr_unit.mstatus[31:13], 2'b00,
                     cpu.csr_unit.mstatus[10:8], 1'b1,
                     cpu.csr_unit.mstatus[6:4], cpu.csr_unit.mstatus[7],
                     cpu.csr_unit.mstatus[2:0]});
            end

            // Memory access marker. Spike format: loads emit "mem 0x<addr>";
            // stores emit "mem 0x<addr> 0x<value>".
            if (cpu.exwb_memRD)
                $fwrite(dump_fd, " mem 0x%08h", dmem_addr);
            else if (dmem_we)
                $fwrite(dump_fd, " mem 0x%08h 0x%08h", dmem_addr, dmem_wdata);

            $fwrite(dump_fd, "\n");

            instr_count = instr_count + 1;
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

        // Run until termination or max cycles
        while (cycle_count < max_cycles) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

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
        $fclose(dump_fd);
        print_summary();
        $finish;
    end

    // ================================================================
    //  Summary statistics
    // ================================================================
    task print_summary;
        begin
            $display("  Cycles: %0d   Instructions logged: %0d", cycle_count, instr_count);
            if (instr_count > 0)
                $display("  IPC: %0f", $itor(instr_count) / $itor(cycle_count));
            $display("  Dump: %0s", dump_file_str);
        end
    endtask

endmodule
