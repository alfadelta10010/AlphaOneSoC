// module fyracore for the UP5K twin: picorv32 behind fyracore's own port and parameter list,
// so src/alphaone_soc.v at the pin instantiates it unchanged. NOT the tapeout core: no
// CSRs, traps, interrupts, atomics, PMP, M extension. See fpga/up5k/README.md.
// picorv32 is vendored unmodified (third_party/picorv32).

module fyracore #(
    parameter [31:0] MARCHID  = 32'h0000_0000,
    parameter [31:0] PMA_ROM_BASE = 32'h2000_0000,  // flash
    parameter [31:0] PMA_ROM_TOP  = 32'h20FF_FFFF,
    parameter [31:0] PMA_RAM_BASE = 32'h8000_0000,  // PSRAM
    parameter [31:0] PMA_RAM_TOP  = 32'h80FF_FFFF,
    parameter [31:0] PMA_IO0_BASE = 32'h0200_0000,  // CLINT
    parameter [31:0] PMA_IO0_TOP  = 32'h0200_FFFF,
    parameter [31:0] PMA_IO1_BASE = 32'h1000_0000,  // UART, GPIO, syscon, PWM/audio
    parameter [31:0] PMA_IO1_TOP  = 32'h1003_FFFF,
    parameter [31:0] PMA_IO2_BASE = 32'h0C00_0000,  // PLIC (4 MB: priorities, pending, enables, context 0 at +0x200000)
    parameter [31:0] PMA_IO2_TOP  = 32'h0C3F_FFFF
)(
    input  wire        clk,
    input  wire        rst,
    input  wire [31:0] boot_addr,
    output wire [31:0] imem_addr,
    output wire        imem_req,      // Fetch request
    input  wire [31:0] imem_rdata,
    input  wire        imem_ready,    // Instruction fetch data is valid
    output wire        dmem_req,      // Load/store/AMO request (see dmem_we, dmem_be)
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_be,       // byte lanes of the access, loads included
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,    // Data access complete
    input  wire        timer_irq,     // Machine timer interrupt (MTIP)
    input  wire        external_irq,  // Machine external interrupt (MEIP)
    input  wire        sw_irq,        // Machine software interrupt (MSIP)
    input  wire [63:0] mtime_in,
    output wire        fencei_flush,
    output wire [31:0] dbg_pc,
    output wire        dbg_retired,
    output wire [31:0] dbg_instr,
    output wire        dbg_compressed,
    output wire        dbg_trap
);

    // ---- picorv32 -----------------------------------------------------------
    wire        p_valid, p_instr, p_trap;
    wire [31:0] p_addr, p_wdata;
    wire [3:0]  p_wstrb, p_la_wstrb;

    // picorv32 has one memory port; fyracore has two. A transfer is complete when
    // the port picked by mem_instr says ready. mem_ready is gated with mem_valid,
    // as the fyracore contract says nothing is transferred on a cycle with req low.
    wire p_ready = p_valid & (p_instr ? imem_ready : dmem_ready);

    picorv32 #(
        .ENABLE_COUNTERS     (0),
        .ENABLE_COUNTERS64   (0),
        .ENABLE_REGS_16_31   (1),
        .ENABLE_REGS_DUALPORT(1),
        .LATCHED_MEM_RDATA   (0),
        .TWO_STAGE_SHIFT     (1),
        .BARREL_SHIFTER      (0),
        .TWO_CYCLE_COMPARE   (0),
        .TWO_CYCLE_ALU       (0),
        .COMPRESSED_ISA      (1),
        .CATCH_MISALIGN      (1),
        .CATCH_ILLINSN       (1),
        .ENABLE_PCPI         (0),
        .ENABLE_MUL          (0),
        .ENABLE_FAST_MUL     (0),
        .ENABLE_DIV          (0),
        .ENABLE_IRQ          (0),
        .ENABLE_TRACE        (0),
        .REGS_INIT_ZERO      (0),
        .PROGADDR_RESET      (32'h2000_0000),
        .STACKADDR           (32'hffff_ffff)
    ) u_pico (
        .clk         (clk),
        .resetn      (~rst),
        .trap        (p_trap),
        .mem_valid   (p_valid),
        .mem_instr   (p_instr),
        .mem_ready   (p_ready),
        .mem_addr    (p_addr),
        .mem_wdata   (p_wdata),
        .mem_wstrb   (p_wstrb),
        .mem_rdata   (p_instr ? imem_rdata : dmem_rdata),
        .mem_la_read (),
        .mem_la_write(),
        .mem_la_addr (),
        .mem_la_wdata(),
        .mem_la_wstrb(p_la_wstrb),
        .pcpi_valid  (),
        .pcpi_insn   (),
        .pcpi_rs1    (),
        .pcpi_rs2    (),
        .pcpi_wr     (1'b0),
        .pcpi_rd     (32'b0),
        .pcpi_wait   (1'b0),
        .pcpi_ready  (1'b0),
        .irq         (32'b0),
        .eoi         (),
        .trace_valid (),
        .trace_data  ()
    );

    // ---- fyracore port conventions (src/fyracore.v at PIN: header 'Memory interfaces',
    // lines ~84-115, and the 'Byte lanes' block at ~973-1011) ---------------------------
    //  * imem_addr is the pc; picorv32 fetches word-aligned and keeps the high half of a
    //    word itself, so every fetch asks for the 4 bytes at an aligned address.
    //  * dmem_addr is word-aligned (mem_addr[1:0] is 0 in picorv32 too), the byte lanes
    //    come in dmem_be, for a load as for a store. picorv32 only gives a strobe for a
    //    store; mem_la_wstrb is the same lane function (mem_wordsize, reg_op1[1:0]) and is
    //    stable for the whole access, so it supplies the lanes of a load.
    //  * store data is replicated ({4{byte}}, {2{half}}): picorv32 does the same.
    //  * dmem_rdata is the raw aligned word and the core picks the lanes: so does picorv32.
    assign imem_req   = p_valid &  p_instr;
    assign imem_addr  = p_addr;
    assign dmem_req   = p_valid & ~p_instr;
    assign dmem_addr  = p_addr;
    assign dmem_we    = |p_wstrb;
    assign dmem_be    = dmem_we ? p_wstrb : p_la_wstrb;
    assign dmem_wdata = p_wdata;

    assign fencei_flush = 1'b0;
    assign dbg_pc         = 32'b0;
    assign dbg_retired    = 1'b0;
    assign dbg_instr      = 32'b0;
    assign dbg_compressed = 1'b0;
    assign dbg_trap       = 1'b0;

    wire _unused = &{1'b0, boot_addr, timer_irq, external_irq, sw_irq, mtime_in};

`ifndef SYNTHESIS
    // Sim-only: the fyracore request/ready contract, as tb/req_hold_check.v and
    // tb/memory_model.v check it for the real core.
    reg        r_imem_req, r_dmem_req, r_dmem_we, r_imem_rdy, r_dmem_rdy, r_rst;
    reg [31:0] r_imem_addr, r_dmem_addr, r_dmem_wdata;
    reg [3:0]  r_dmem_be;
    reg        trap_seen;
    initial trap_seen = 1'b0;
    always @(posedge clk) begin
        r_imem_req <= imem_req; r_imem_addr <= imem_addr; r_imem_rdy <= imem_ready;
        r_dmem_req <= dmem_req; r_dmem_addr <= dmem_addr; r_dmem_we <= dmem_we;
        r_dmem_be <= dmem_be; r_dmem_wdata <= dmem_wdata; r_dmem_rdy <= dmem_ready;
        r_rst <= rst;
        if (!rst && !r_rst) begin
            if (imem_req && dmem_req)
                $display("ASSERT fyracore_picorv32: imem_req and dmem_req together (%0t)", $time);
            // a request not completed last cycle is still up, same address
            if (r_imem_req && !r_imem_rdy && !(imem_req && imem_addr == r_imem_addr))
                $display("ASSERT fyracore_picorv32: imem request dropped or moved before ready (%0t)", $time);
            if (r_dmem_req && !r_dmem_rdy &&
                !(dmem_req && dmem_addr == r_dmem_addr && dmem_we == r_dmem_we &&
                  dmem_be == r_dmem_be && (!dmem_we || dmem_wdata == r_dmem_wdata)))
                $display("ASSERT fyracore_picorv32: dmem request dropped or changed before ready (%0t)", $time);
            // a store always has lanes; a load's lanes are never empty
            if (dmem_req && dmem_be == 4'b0000)
                $display("ASSERT fyracore_picorv32: dmem_be is empty on a request (%0t)", $time);
            if (dmem_req && dmem_addr[1:0] != 2'b00)
                $display("ASSERT fyracore_picorv32: dmem_addr not word-aligned (%0t)", $time);
        end
        if (rst && boot_addr[31:1] !== 32'h2000_0000 >> 1)
            $display("ASSERT fyracore_picorv32: boot_addr %h is not PROGADDR_RESET (%0t)", boot_addr, $time);
        if (p_trap && !trap_seen) begin
            trap_seen <= 1'b1;
            $display("ASSERT fyracore_picorv32: picorv32 trap (misaligned or illegal instruction) (%0t)", $time);
        end
    end
`endif

endmodule
