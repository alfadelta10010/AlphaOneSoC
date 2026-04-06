// Simple byte-addressable memory model for simulation
//
// Provides a unified flat memory covering the full 16 MB address space
// (instruction memory 0x0000_0000–0x007F_FFFF + data memory
//  0x0080_0000–0x00FF_FFFF) so that test programs can freely place
// code and data anywhere within the range.
//
// Dual-port: simultaneous instruction fetch and data access.
// Instruction port is read-only and combinational.
// Data port supports byte-lane-masked synchronous writes.
//
// The INIT_FILE (one hex byte per line, produced by scripts/asm2hex.sh)
// is loaded starting at address 0 — matching the default linker origin.

module memory_model #(
    parameter MEM_SIZE  = 16777216,     // 16 MB — matches hardware IM+DM range
                                        // (0x0000_0000 to 0x00FF_FFFF)
    parameter INIT_FILE = "program.hex" // hex file loaded at address 0
)(
    input  wire        clk,
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
    output wire        dmem_ready
);
    assign imem_ready = 1'b1;
    assign dmem_ready = 1'b1;
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
    // Mask address to stay within array bounds.
    // Supports unaligned fetches for C-extension (16-bit instructions
    // can start at any 2-byte boundary).
    wire [23:0] ia = imem_addr[23:0];
    assign imem_rdata = {mem[ia+3], mem[ia+2], mem[ia+1], mem[ia]};

    // --- Data read (combinational) ---
    wire [23:0] da = dmem_addr[23:0];
    assign dmem_rdata = {mem[da+3], mem[da+2], mem[da+1], mem[da]};

    // --- Data write (synchronous, byte-lane masked) ---
    // Each bit of dmem_wmask enables the corresponding byte lane,
    // allowing SB (1 byte), SH (2 bytes), and SW (4 bytes) stores.
    always @(posedge clk) begin
        if (dmem_we) begin
            if (dmem_wmask[0]) mem[da]   <= dmem_wdata[7:0];
            if (dmem_wmask[1]) mem[da+1] <= dmem_wdata[15:8];
            if (dmem_wmask[2]) mem[da+2] <= dmem_wdata[23:16];
            if (dmem_wmask[3]) mem[da+3] <= dmem_wdata[31:24];
        end
    end
endmodule
