// Memory Controller — Dual-mode: QSPI hardware or direct simulation memory
//
// Mode selection via SIM_MODE parameter:
//   SIM_MODE=1: Direct byte-addressable memory for simulation testbenches.
//               Instantiates internal SRAM arrays so the design can be
//               tested without any external memory or QSPI IP.
//   SIM_MODE=0: QSPI controller interface for real hardware.
//               All memory reads/writes are forwarded to an external QSPI
//               flash/PSRAM controller.  No internal SRAM is synthesized.
//
// Unified Memory Map (flat Von Neumann, no hard IMEM/DMEM split):
//   0x0000_0000 – 0x00FF_FFFF : Flash (16 MB) — XIP code, read-only data
//   0x0100_0000 – 0x01FF_FFFF : RAM   (16 MB) — stack, heap, .data/.bss
//   0x0200_0000 – 0x0200_BFFF : CLINT (future)
//   0x0300_0000 – 0x0300_000F : GPIO  (8B output + 8B input)
//   0x0400_0000+              : Future peripherals
//
// Both instruction fetch and data access can target either Flash or RAM.
// In hardware, the memory controller routes by address: Flash via QSPI CS0,
// RAM via QSPI CS1.  In simulation a single 32MB byte array covers both.

module memController #(
    parameter SIM_MODE    = 1,           // 1 = simulation (internal SRAM), 0 = hardware (QSPI)

    // --- Address map ---
    parameter FLASH_START = 32'h0000_0000,  // Flash base (16 MB)
    parameter FLASH_STOP  = 32'h00FF_FFFF,  // Flash top
    parameter RAM_START   = 32'h0100_0000,  // RAM base   (16 MB)
    parameter RAM_STOP    = 32'h01FF_FFFF,  // RAM top
    parameter GPO_START   = 32'h0300_0000,  // GPIO output base
    parameter GPO_STOP    = 32'h0300_0007,  // GPIO output top
    parameter GPI_START   = 32'h0300_0008,  // GPIO input base
    parameter GPI_STOP    = 32'h0300_000F   // GPIO input top
)(
    input  wire        clk,
    input  wire        rst,

    // CPU instruction fetch interface (active every cycle, combinational read)
    input  wire [31:0] imem_addr,
    output wire [31:0] imem_rdata,

    // CPU data interface (active on load/store, combinational read, synchronous write)
    input  wire [31:0] dmem_addr,
    input  wire [31:0] dmem_wdata,
    input  wire [3:0]  dmem_wmask,
    input  wire        dmem_we,
    output reg  [31:0] dmem_rdata,

    // QSPI controller interface (active only when SIM_MODE=0)
    // qspi_cs selects device: 0=Flash, 1=RAM
    output reg         qspi_req,       // transaction request strobe
    output reg         qspi_cs,        // chip select: 0=Flash, 1=RAM
    output reg         qspi_wr,        // 1 = write, 0 = read
    output reg  [23:0] qspi_addr,      // byte address within selected device
    output reg  [31:0] qspi_wdata,     // write data
    input  wire [31:0] qspi_rdata,     // read data (valid when qspi_ready=1)
    input  wire        qspi_ready,     // transaction complete flag

    // GPIO interface — directly memory-mapped, no QSPI involvement
    output reg  [31:0] gpo_data,       // data written by CPU to GPO range
    output reg         gpo_we,         // single-cycle write-enable pulse
    output reg  [3:0]  gpo_addr,       // byte offset within GPO range
    input  wire [31:0] gpi_data,       // external input pins, directly returned on GPI read
    input  wire [3:0]  gpi_addr_in,   // byte offset within GPI range (active read)

    // Memory ready signals — pipeline stalls when not ready
    output wire        imem_ready,    // Instruction fetch data is valid
    output wire        dmem_ready,    // Data access is complete
    // FENCE.I flush — invalidates the instruction-fetch buffer in hardware mode
    input  wire        fencei_flush   // 1-cycle pulse from CPU on FENCE.I
);

    // Total unified memory size: 32 MB (Flash 16MB + RAM 16MB)
    localparam MEM_BYTES = 32 * 1024 * 1024;

    // ==================================================================
    //  Address-range decode helpers
    // ==================================================================
    wire in_flash_range = (dmem_addr >= FLASH_START) && (dmem_addr <= FLASH_STOP);
    wire in_ram_range   = (dmem_addr >= RAM_START)   && (dmem_addr <= RAM_STOP);
    wire in_mem_range   = in_flash_range || in_ram_range;
    wire in_gpo_range   = (dmem_addr >= GPO_START)   && (dmem_addr <= GPO_STOP);
    wire in_gpi_range   = (dmem_addr >= GPI_START)   && (dmem_addr <= GPI_STOP);

    // ==================================================================
    //  Simulation Mode: Internal byte-addressable SRAM
    // ==================================================================
    //  Single 32 MB array (addr[24:0] covers 0x0000_0000 – 0x01FF_FFFF).
    //  Both imem and dmem ports index the same array — Von Neumann view.
    // ==================================================================
    generate
        if (SIM_MODE == 1) begin : sim_mem

            reg [7:0] mem [0:MEM_BYTES-1];
            integer i;

            initial begin
                for (i = 0; i < MEM_BYTES; i = i + 1)
                    mem[i] = 8'h00;
            end

            // --- Instruction read (combinational, word-aligned) ---
            wire [24:0] ia = imem_addr[24:0];
            assign imem_rdata = {mem[ia+3], mem[ia+2], mem[ia+1], mem[ia]};

            // --- Data read (combinational) ---
            // addr[24:0] maps Flash (0x0000_0000+) and RAM (0x0100_0000+)
            // directly into the flat array without any translation.
            wire [24:0] da = dmem_addr[24:0];

            always @(*) begin
                if (in_gpi_range)
                    dmem_rdata = gpi_data;
                else if (in_mem_range)
                    dmem_rdata = {mem[da+3], mem[da+2], mem[da+1], mem[da]};
                else
                    dmem_rdata = 32'h0000_0000;  // unmapped: read as zero
            end

            // --- Data write (synchronous, byte-lane masked) ---
            always @(posedge clk) begin
                if (!rst && dmem_we && in_mem_range) begin
                    if (dmem_wmask[0]) mem[da]   <= dmem_wdata[7:0];
                    if (dmem_wmask[1]) mem[da+1] <= dmem_wdata[15:8];
                    if (dmem_wmask[2]) mem[da+2] <= dmem_wdata[23:16];
                    if (dmem_wmask[3]) mem[da+3] <= dmem_wdata[31:24];
                end
            end

            // --- GPO write detection ---
            always @(posedge clk) begin
                if (rst) begin
                    gpo_data <= 32'b0;
                    gpo_we   <= 1'b0;
                    gpo_addr <= 4'b0;
                end else if (dmem_we && in_gpo_range) begin
                    gpo_data <= dmem_wdata;
                    gpo_we   <= 1'b1;
                    gpo_addr <= dmem_addr[3:0];
                end else begin
                    gpo_we <= 1'b0;
                end
            end

            // --- Memory ready: always ready in sim mode ---
            assign imem_ready = 1'b1;
            assign dmem_ready = 1'b1;

            // --- QSPI signals unused in sim mode — tie off ---
            always @(posedge clk) begin
                qspi_req   <= 1'b0;
                qspi_cs    <= 1'b0;
                qspi_wr    <= 1'b0;
                qspi_addr  <= 24'b0;
                qspi_wdata <= 32'b0;
            end

        end
    endgenerate

    // ==================================================================
    //  Hardware Mode: QSPI controller interface
    // ==================================================================
    //  Flash (0x0000_0000–0x00FF_FFFF) → qspi_cs=0, addr = dmem_addr[23:0]
    //  RAM   (0x0100_0000–0x01FF_FFFF) → qspi_cs=1, addr = dmem_addr[23:0]
    //  The lower 24 bits are the offset within each QSPI device (both are 16MB).
    // ==================================================================
    generate
        if (SIM_MODE == 0) begin : hw_mem

            // FSM states
            localparam IDLE       = 3'd0;
            localparam IFETCH     = 3'd1;
            localparam IFETCH_W   = 3'd2;
            localparam DREAD      = 3'd3;
            localparam DREAD_W    = 3'd4;
            localparam DWRITE     = 3'd5;
            localparam DWRITE_W   = 3'd6;

            reg [2:0] state;
            reg [31:0] ifetch_buf;
            reg [31:0] dread_buf;
            reg ifetch_valid;
            reg dread_valid;

            // Chip select: 0=Flash (addr<0x01000000), 1=RAM (addr>=0x01000000)
            wire imem_cs = imem_addr[24];   // bit 24 set → RAM
            wire dmem_cs = dmem_addr[24];   // bit 24 set → RAM

            assign imem_rdata = ifetch_buf;
            assign imem_ready = ifetch_valid;
            assign dmem_ready = dread_valid || (state == IDLE && !dmem_we);

            always @(*) begin
                if (dread_valid)
                    dmem_rdata = dread_buf;
                else if (in_gpi_range)
                    dmem_rdata = gpi_data;
                else
                    dmem_rdata = 32'h0000_0000;
            end

            always @(posedge clk) begin
                if (rst) begin
                    state        <= IDLE;
                    ifetch_buf   <= 32'b0;
                    dread_buf    <= 32'b0;
                    ifetch_valid <= 1'b0;
                    dread_valid  <= 1'b0;
                    qspi_req     <= 1'b0;
                    qspi_cs      <= 1'b0;
                    qspi_wr      <= 1'b0;
                    qspi_addr    <= 24'b0;
                    qspi_wdata   <= 32'b0;
                    gpo_data     <= 32'b0;
                    gpo_we       <= 1'b0;
                    gpo_addr     <= 4'b0;
                end else begin
                    gpo_we <= 1'b0;

                    // FENCE.I: invalidate the buffered instruction word so the
                    // next fetch goes back to QSPI rather than returning stale data.
                    if (fencei_flush)
                        ifetch_valid <= 1'b0;

                    case (state)
                        IDLE: begin
                            if (dmem_we && in_gpo_range) begin
                                gpo_data <= dmem_wdata;
                                gpo_we   <= 1'b1;
                                gpo_addr <= dmem_addr[3:0];
                            end else if (dmem_we && in_mem_range) begin
                                qspi_req   <= 1'b1;
                                qspi_cs    <= dmem_cs;
                                qspi_wr    <= 1'b1;
                                qspi_addr  <= dmem_addr[23:0];
                                qspi_wdata <= dmem_wdata;
                                state      <= DWRITE;
                            end else if (!dmem_we && in_mem_range && (dmem_wmask != 4'b0)) begin
                                qspi_req    <= 1'b1;
                                qspi_cs     <= dmem_cs;
                                qspi_wr     <= 1'b0;
                                qspi_addr   <= dmem_addr[23:0];
                                dread_valid <= 1'b0;
                                state       <= DREAD;
                            end else begin
                                qspi_req     <= 1'b1;
                                qspi_cs      <= imem_cs;
                                qspi_wr      <= 1'b0;
                                qspi_addr    <= imem_addr[23:0];
                                ifetch_valid <= 1'b0;
                                state        <= IFETCH;
                            end
                        end

                        IFETCH: begin
                            if (qspi_ready) begin
                                qspi_req <= 1'b0;
                                state    <= IFETCH_W;
                            end
                        end

                        IFETCH_W: begin
                            ifetch_buf   <= qspi_rdata;
                            ifetch_valid <= 1'b1;
                            state        <= IDLE;
                        end

                        DREAD: begin
                            if (qspi_ready) begin
                                qspi_req <= 1'b0;
                                state    <= DREAD_W;
                            end
                        end

                        DREAD_W: begin
                            dread_buf   <= qspi_rdata;
                            dread_valid <= 1'b1;
                            state       <= IDLE;
                        end

                        DWRITE: begin
                            if (qspi_ready) begin
                                qspi_req <= 1'b0;
                                state    <= DWRITE_W;
                            end
                        end

                        DWRITE_W: begin
                            state <= IDLE;
                        end

                        default: state <= IDLE;
                    endcase
                end
            end
        end
    endgenerate

endmodule
