// Simple byte-addressable memory model for simulation
//
// Unified 32 MB flat address space:
//   0x0000_0000 – 0x00FF_FFFF : Flash (16 MB) — code and read-only data
//   0x0100_0000 – 0x01FF_FFFF : RAM   (16 MB) — stack, heap, .data/.bss
//   0x0200_0000 – 0x0200_BFFF : CLINT — timer and software interrupt registers
//
// Both instruction fetch and data access ports index into the same array for
// the Flash/RAM region. CLINT is handled by an instantiated clint module.
//
// Dual-port: simultaneous instruction fetch and data access.
// Instruction port is read-only and combinational.
// Data port supports byte-lane-masked synchronous writes.

module memory_model #(
    parameter MEM_SIZE  = 33554432,      // 32 MB (0x0000_0000 – 0x01FF_FFFF)
    parameter INIT_FILE = "program.hex"  // hex file loaded at address 0
)(
    input  wire        clk,
    input  wire        rst,
    // Instruction port (read-only, combinational)
    input  wire [31:0] imem_addr,
    output wire [31:0] imem_rdata,
    // Data port (read/write)
    input  wire [31:0] dmem_addr,
    input  wire [31:0] dmem_wdata,
    input  wire [3:0]  dmem_wmask,
    input  wire        dmem_we,
    output wire [31:0] dmem_rdata,
    // Memory ready signals (always 1 for combinational sim memory)
    output wire        imem_ready,
    output wire        dmem_ready,
    // Interrupt outputs (from embedded CLINT)
    output wire        timer_irq,
    output wire        sw_irq
);
    assign imem_ready = 1'b1;
    assign dmem_ready = 1'b1;

    // ── Address decode ───────────────────────────────────────────────────────
    localparam CLINT_BASE = 32'h0200_0000;
    localparam CLINT_TOP  = 32'h0200_BFFF;

    wire in_clint = (dmem_addr >= CLINT_BASE) && (dmem_addr <= CLINT_TOP);
    wire in_mem   = !in_clint;  // Flash + RAM; ignore GPIO for sim simplicity

    // ── SRAM array ──────────────────────────────────────────────────────────
    reg [7:0] mem [0:MEM_SIZE-1];
    integer i;

    initial begin
        // Zero-fill first, then overlay the program hex
        for (i = 0; i < MEM_SIZE; i = i + 1)
            mem[i] = 8'h00;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // --- Instruction read (combinational) ---
    // 25-bit index covers the full 32 MB range (0x0000_0000 – 0x01FF_FFFF).
    wire [24:0] ia = imem_addr[24:0];
    assign imem_rdata = {mem[ia+3], mem[ia+2], mem[ia+1], mem[ia]};

    // --- Data read (combinational) ---
    wire [24:0] da = dmem_addr[24:0];
    wire [31:0] mem_rdata = {mem[da+3], mem[da+2], mem[da+1], mem[da]};

    // --- Data write (synchronous, byte-lane masked) ---
    always @(posedge clk) begin
        if (dmem_we && in_mem) begin
            if (dmem_wmask[0]) mem[da]   <= dmem_wdata[7:0];
            if (dmem_wmask[1]) mem[da+1] <= dmem_wdata[15:8];
            if (dmem_wmask[2]) mem[da+2] <= dmem_wdata[23:16];
            if (dmem_wmask[3]) mem[da+3] <= dmem_wdata[31:24];
        end
    end

    // ── CLINT instance ──────────────────────────────────────────────────────
    wire [31:0] clint_rdata;
    wire [15:0] clint_offset = dmem_addr[15:0];  // offset within CLINT space

    clint clint_inst(
        .clk      (clk),
        .rst      (rst),
        .addr     (clint_offset),
        .wdata    (dmem_wdata),
        .wmask    (dmem_wmask),
        .we       (dmem_we && in_clint),
        .rdata    (clint_rdata),
        .timer_irq(timer_irq),
        .sw_irq   (sw_irq)
    );

    // --- Data read mux: CLINT or SRAM ---
    assign dmem_rdata = in_clint ? clint_rdata : mem_rdata;

endmodule
