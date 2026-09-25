// FyraCore CPU Testbench
// Runs a program loaded from hex file and traces every retired instruction
// Dumps register file and optionally memory contents per instruction
`timescale 1ns / 1ps

module tb_cpu;
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
    wire        dbg_retired, dbg_trap;
    wire        fencei_flush;   // informational in sim (memory_model has no fetch buffer)

    // Interrupt signals from CLINT
    wire        timer_irq, sw_irq;
    wire [63:0] mtime_val;

    // Parameters
    parameter MEM_SIZE   = 33554432;  // 32 MB — 16 MB Flash (0x0000_0000) + 16 MB RAM (0x0100_0000)
`ifndef MAX_CYCLES
    parameter MAX_CYCLES = 100000;
`else
    parameter MAX_CYCLES = `MAX_CYCLES;
`endif
`ifndef INIT_FILE
    parameter INIT_FILE  = "program.hex";
`else
    parameter INIT_FILE  = `INIT_FILE;
`endif

    // Instantiate CPU
    fyracore cpu(
        .clk         (clk),
        .rst         (rst),
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
        .external_irq (1'b0),      // no external IRQ controller in simulation
        .sw_irq       (sw_irq),
        .mtime_in     (mtime_val),
        .fencei_flush (fencei_flush),
        .dbg_pc       (dbg_pc),
        .dbg_retired (dbg_retired),
        .dbg_instr   (dbg_instr),
        .dbg_trap    (dbg_trap)
    );

    // Instantiate Memory (includes embedded CLINT)
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
        .mtime_out (mtime_val)
    );

    // Clock generation: 10ns period
    initial clk = 0;
    always #5 clk = ~clk;

    // Instruction counter
    integer instr_count = 0;
    integer cycle_count = 0;

    // Program termination detection:
    //   1. ECALL/EBREAK trap — for tests WITHOUT trap handlers (mtvec=0).
    //      When a trap handler is installed (mtvec!=0), ecall/ebreak are
    //      handled by the handler and do NOT terminate the simulation.
    //   2. Halt loop (j . = JAL x0, 0 = 0x0000006F) — universal termination
    //      signal that works with or without trap handlers.
    wire trap_handler_set = (cpu.csr_unit.mtvec != 32'b0);
    wire is_ecall  = dbg_trap && (dbg_instr == 32'h0000_0073) && !trap_handler_set;
    wire is_ebreak = dbg_trap && (dbg_instr == 32'h0010_0073) && !trap_handler_set;
    wire is_halt   = dbg_retired && (dbg_instr == 32'h0000_006f);

    // VCD dump
    initial begin
        $dumpfile("cpu_trace.vcd");
        $dumpvars(0, tb_cpu);
    end

    // Main simulation
    initial begin
        $display("===========================================================");
        $display("  FyraCore RV32IMCA+Zicsr+Zifencei CPU Testbench");
        $display("  Memory: %0d bytes, Program: %s", MEM_SIZE, INIT_FILE);
        $display("===========================================================");

        // Reset
        rst = 1;
        #25;
        rst = 0;
        $display("\n--- Reset released, execution begins ---\n");

        // Run until ECALL/EBREAK or max cycles
        while (cycle_count < MAX_CYCLES) begin
            @(posedge clk);
            cycle_count = cycle_count + 1;

            if (dbg_retired) begin
                instr_count = instr_count + 1;
                print_state();
            end

            if (dbg_trap) begin
                $display("\n*** TRAP at PC=0x%08h, instruction=0x%08h ***", dbg_pc, dbg_instr);
            end

            if (is_ecall || is_ebreak) begin
                $display("\n--- Program terminated via %s at PC=0x%08h ---",
                         is_ecall ? "ECALL" : "EBREAK", dbg_pc);
                print_final_state();
                $finish;
            end

            if (is_halt) begin
                $display("\n--- Program halted (j .) at PC=0x%08h ---", dbg_pc);
                print_final_state();
                $finish;
            end
        end

        $display("\n--- Max cycles (%0d) reached ---", MAX_CYCLES);
        print_final_state();
        $finish;
    end

    // Print state after each retired instruction
    task print_state;
        begin
            $display("--- Instruction #%0d | PC=0x%08h | Instr=0x%08h ---",
                     instr_count, dbg_pc, dbg_instr);
            $display("  x0 (zero)=%08h  x1  (ra) =%08h  x2  (sp) =%08h  x3  (gp) =%08h",
                     32'h0, cpu.rf.reg_file[1], cpu.rf.reg_file[2], cpu.rf.reg_file[3]);
            $display("  x4  (tp) =%08h  x5  (t0) =%08h  x6  (t1) =%08h  x7  (t2) =%08h",
                     cpu.rf.reg_file[4], cpu.rf.reg_file[5], cpu.rf.reg_file[6], cpu.rf.reg_file[7]);
            $display("  x8  (s0) =%08h  x9  (s1) =%08h  x10 (a0) =%08h  x11 (a1) =%08h",
                     cpu.rf.reg_file[8], cpu.rf.reg_file[9], cpu.rf.reg_file[10], cpu.rf.reg_file[11]);
            $display("  x12 (a2) =%08h  x13 (a3) =%08h  x14 (a4) =%08h  x15 (a5) =%08h",
                     cpu.rf.reg_file[12], cpu.rf.reg_file[13], cpu.rf.reg_file[14], cpu.rf.reg_file[15]);
            $display("  x16 (a6) =%08h  x17 (a7) =%08h  x18 (s2) =%08h  x19 (s3) =%08h",
                     cpu.rf.reg_file[16], cpu.rf.reg_file[17], cpu.rf.reg_file[18], cpu.rf.reg_file[19]);
            $display("  x20 (s4) =%08h  x21 (s5) =%08h  x22 (s6) =%08h  x23 (s7) =%08h",
                     cpu.rf.reg_file[20], cpu.rf.reg_file[21], cpu.rf.reg_file[22], cpu.rf.reg_file[23]);
            $display("  x24 (s8) =%08h  x25 (s9) =%08h  x26 (s10)=%08h  x27 (s11)=%08h",
                     cpu.rf.reg_file[24], cpu.rf.reg_file[25], cpu.rf.reg_file[26], cpu.rf.reg_file[27]);
            $display("  x28 (t3) =%08h  x29 (t4) =%08h  x30 (t5) =%08h  x31 (t6) =%08h",
                     cpu.rf.reg_file[28], cpu.rf.reg_file[29], cpu.rf.reg_file[30], cpu.rf.reg_file[31]);
            $display("");
        end
    endtask

    // Print final state with memory dump
    task print_final_state;
        integer i;
        begin
            $display("\n===========================================================");
            $display("  FINAL STATE");
            $display("===========================================================");
            $display("  Cycles: %0d   Instructions retired: %0d", cycle_count, instr_count);
            if (instr_count > 0)
                $display("  IPC: %0f", $itor(instr_count) / $itor(cycle_count));
            $display("");

            // Register dump
            $display("--- Register File ---");
            $display("  x0 (zero)=%08h  x1  (ra) =%08h  x2  (sp) =%08h  x3  (gp) =%08h",
                     32'h0, cpu.rf.reg_file[1], cpu.rf.reg_file[2], cpu.rf.reg_file[3]);
            $display("  x4  (tp) =%08h  x5  (t0) =%08h  x6  (t1) =%08h  x7  (t2) =%08h",
                     cpu.rf.reg_file[4], cpu.rf.reg_file[5], cpu.rf.reg_file[6], cpu.rf.reg_file[7]);
            $display("  x8  (s0) =%08h  x9  (s1) =%08h  x10 (a0) =%08h  x11 (a1) =%08h",
                     cpu.rf.reg_file[8], cpu.rf.reg_file[9], cpu.rf.reg_file[10], cpu.rf.reg_file[11]);
            $display("  x12 (a2) =%08h  x13 (a3) =%08h  x14 (a4) =%08h  x15 (a5) =%08h",
                     cpu.rf.reg_file[12], cpu.rf.reg_file[13], cpu.rf.reg_file[14], cpu.rf.reg_file[15]);
            $display("  x16 (a6) =%08h  x17 (a7) =%08h  x18 (s2) =%08h  x19 (s3) =%08h",
                     cpu.rf.reg_file[16], cpu.rf.reg_file[17], cpu.rf.reg_file[18], cpu.rf.reg_file[19]);
            $display("  x20 (s4) =%08h  x21 (s5) =%08h  x22 (s6) =%08h  x23 (s7) =%08h",
                     cpu.rf.reg_file[20], cpu.rf.reg_file[21], cpu.rf.reg_file[22], cpu.rf.reg_file[23]);
            $display("  x24 (s8) =%08h  x25 (s9) =%08h  x26 (s10)=%08h  x27 (s11)=%08h",
                     cpu.rf.reg_file[24], cpu.rf.reg_file[25], cpu.rf.reg_file[26], cpu.rf.reg_file[27]);
            $display("  x28 (t3) =%08h  x29 (t4) =%08h  x30 (t5) =%08h  x31 (t6) =%08h",
                     cpu.rf.reg_file[28], cpu.rf.reg_file[29], cpu.rf.reg_file[30], cpu.rf.reg_file[31]);

            // Memory dump: first 256 bytes and data section (0x800-0x8FF)
            $display("\n--- Memory Dump (0x0000-0x00FF) ---");
            for (i = 0; i < 256; i = i + 16) begin
                $display("  %04h: %02h%02h%02h%02h %02h%02h%02h%02h %02h%02h%02h%02h %02h%02h%02h%02h",
                         i,
                         mem.mem[i+0],  mem.mem[i+1],  mem.mem[i+2],  mem.mem[i+3],
                         mem.mem[i+4],  mem.mem[i+5],  mem.mem[i+6],  mem.mem[i+7],
                         mem.mem[i+8],  mem.mem[i+9],  mem.mem[i+10], mem.mem[i+11],
                         mem.mem[i+12], mem.mem[i+13], mem.mem[i+14], mem.mem[i+15]);
            end

            $display("\n--- Memory Dump (0x0800-0x08FF, data section) ---");
            for (i = 2048; i < 2048+256; i = i + 16) begin
                $display("  %04h: %02h%02h%02h%02h %02h%02h%02h%02h %02h%02h%02h%02h %02h%02h%02h%02h",
                         i,
                         mem.mem[i+0],  mem.mem[i+1],  mem.mem[i+2],  mem.mem[i+3],
                         mem.mem[i+4],  mem.mem[i+5],  mem.mem[i+6],  mem.mem[i+7],
                         mem.mem[i+8],  mem.mem[i+9],  mem.mem[i+10], mem.mem[i+11],
                         mem.mem[i+12], mem.mem[i+13], mem.mem[i+14], mem.mem[i+15]);
            end
            $display("===========================================================");
        end
    endtask

endmodule
