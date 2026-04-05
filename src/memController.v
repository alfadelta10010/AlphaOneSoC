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
// Memory Map (calibrated to fill the target FPGA's available QSPI address space):
//   0x0000_0000 – 0x007F_FFFF : Instruction Memory  (8 MB)
//   0x0080_0000 – 0x00FF_FFFF : Data Memory          (8 MB)
//   0x0100_0000 – 0x0100_0007 : GPIO Output           (8 B, memory-mapped I/O)
//   0x0100_0008 – 0x0100_000F : GPIO Input            (8 B, memory-mapped I/O)
//
// Notes on address parameters:
//   IM_START/IM_STOP  — Instruction memory address window.  The CPU's PC
//                        must stay within this range.  Code is fetched via
//                        the imem port; data loads/stores to this range also
//                        work (self-modifying code, boot-time init, etc.).
//   DM_START/DM_STOP  — Data memory address window.  Stack, heap, and .data
//                        sections live here on hardware.  In simulation the
//                        test linker may place everything in the IM range for
//                        simplicity; both ranges are read/write.
//   GPO_START/GPO_STOP — GPIO output registers.  Directly memory-mapped;
//                         no QSPI transaction is generated.
//   GPI_START/GPI_STOP — GPIO input registers.  Read-only memory-mapped;
//                         returns the external gpi_data bus.

module memController #(
    parameter SIM_MODE  = 1,           // 1 = simulation (internal SRAM), 0 = hardware (QSPI)

    // --- Address map (must match hardware board layout) ---
    parameter IM_START  = 32'h0000_0000,  // Instruction memory base
    parameter IM_STOP   = 32'h007F_FFFF,  // Instruction memory top  (8 MB)
    parameter DM_START  = 32'h0080_0000,  // Data memory base
    parameter DM_STOP   = 32'h00FF_FFFF,  // Data memory top         (8 MB)
    parameter GPO_START = 32'h0100_0000,  // GPIO output base
    parameter GPO_STOP  = 32'h0100_0007,  // GPIO output top
    parameter GPI_START = 32'h0100_0008,  // GPIO input base
    parameter GPI_STOP  = 32'h0100_000F   // GPIO input top
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
    // directly drives the external QSPI flash/PSRAM controller
    output reg         qspi_req,       // transaction request strobe
    output reg         qspi_wr,        // 1 = write, 0 = read
    output reg  [23:0] qspi_addr,      // byte address within QSPI device
    output reg  [31:0] qspi_wdata,     // write data
    input  wire [31:0] qspi_rdata,     // read data (valid when qspi_ready=1)
    input  wire        qspi_ready,     // transaction complete flag

    // GPIO interface — directly memory-mapped, no QSPI involvement
    output reg  [31:0] gpo_data,       // data written by CPU to GPO range
    output reg         gpo_we,         // single-cycle write-enable pulse
    output reg  [3:0]  gpo_addr,       // byte offset within GPO range
    input  wire [31:0] gpi_data,       // external input pins, directly returned on GPI read
    input  wire [3:0]  gpi_addr_in     // byte offset within GPI range (active read)
);

    // Total byte-addressable memory size (IM + DM combined = 16 MB)
    // In sim mode this is allocated as a flat byte array.
    // MEM_BYTES must be a power of two so the address mask works.
    localparam MEM_BYTES = (IM_STOP - IM_START + 1) + (DM_STOP - DM_START + 1); // 16 MB

    // ==================================================================
    //  Address-range decode helpers (active on dmem_addr)
    // ==================================================================
    wire in_im_range  = (dmem_addr >= IM_START)  && (dmem_addr <= IM_STOP);
    wire in_dm_range  = (dmem_addr >= DM_START)  && (dmem_addr <= DM_STOP);
    wire in_mem_range = in_im_range || in_dm_range;  // any SRAM/QSPI range
    wire in_gpo_range = (dmem_addr >= GPO_START) && (dmem_addr <= GPO_STOP);
    wire in_gpi_range = (dmem_addr >= GPI_START) && (dmem_addr <= GPI_STOP);

    // ==================================================================
    //  Simulation Mode: Internal byte-addressable SRAM
    // ==================================================================
    //  Flat 16 MB array covers both IM and DM ranges.  The address is
    //  used directly as the index (bits [23:0] cover 0–16 MB).  Instruction
    //  fetches use the imem port; data loads/stores use the dmem port.
    //  Both ports can access either range, matching the Von-Neumann view
    //  that the test programs expect (code and data in the same space).
    // ==================================================================
    generate
        if (SIM_MODE == 1) begin : sim_mem

            reg [7:0] mem [0:MEM_BYTES-1];
            integer i;

            // Zero-fill on startup; the testbench or $readmemh fills code
            initial begin
                for (i = 0; i < MEM_BYTES; i = i + 1)
                    mem[i] = 8'h00;
            end

            // --- Instruction read (combinational, word-aligned) ---
            // Uses low 24 bits of imem_addr as byte index into flat array
            wire [23:0] ia = imem_addr[23:0];
            assign imem_rdata = {mem[ia+3], mem[ia+2], mem[ia+1], mem[ia]};

            // --- Data read (combinational) ---
            // Translate dmem_addr into a flat byte index.
            // IM range: offset = addr - IM_START = addr[23:0] (since IM_START=0)
            // DM range: offset = addr - DM_START + (IM_STOP - IM_START + 1)
            //         = addr[23:0] (since DM_START = IM_STOP + 1 and the array
            //           is laid out contiguously).  So dmem_addr[23:0] works
            //           directly for both ranges with the current map.
            wire [23:0] da = dmem_addr[23:0];

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

            // --- QSPI signals unused in sim mode — tie off ---
            always @(posedge clk) begin
                qspi_req   <= 1'b0;
                qspi_wr    <= 1'b0;
                qspi_addr  <= 24'b0;
                qspi_wdata <= 32'b0;
            end

        end
    endgenerate

    // ==================================================================
    //  Hardware Mode: QSPI controller interface
    // ==================================================================
    //  In hardware the memory controller does NOT instantiate any SRAM.
    //  Instead every memory access is serialized through the QSPI
    //  controller which talks to external flash/PSRAM.
    //
    //  Simple FSM prioritizes data accesses over instruction fetches to
    //  minimise pipeline stalls on loads/stores.
    //
    //  GPIO writes are handled locally (no QSPI transaction).
    // ==================================================================
    generate
        if (SIM_MODE == 0) begin : hw_mem

            // FSM states
            localparam IDLE       = 3'd0;  // waiting for a request
            localparam IFETCH     = 3'd1;  // instruction fetch request sent
            localparam IFETCH_W   = 3'd2;  // waiting for QSPI read-back (ifetch)
            localparam DREAD      = 3'd3;  // data read request sent
            localparam DREAD_W    = 3'd4;  // waiting for QSPI read-back (dread)
            localparam DWRITE     = 3'd5;  // data write request sent
            localparam DWRITE_W   = 3'd6;  // waiting for QSPI write-ack

            reg [2:0] state;
            reg [31:0] ifetch_buf;    // latched instruction word from QSPI
            reg [31:0] dread_buf;     // latched data word from QSPI
            reg ifetch_valid;         // ifetch_buf holds a valid instruction
            reg dread_valid;          // dread_buf holds valid load data

            assign imem_rdata = ifetch_buf;

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
                    qspi_wr      <= 1'b0;
                    qspi_addr    <= 24'b0;
                    qspi_wdata   <= 32'b0;
                    gpo_data     <= 32'b0;
                    gpo_we       <= 1'b0;
                    gpo_addr     <= 4'b0;
                end else begin
                    gpo_we <= 1'b0;  // default: clear single-cycle pulse

                    case (state)
                        IDLE: begin
                            // Priority: data write > data read > instruction fetch
                            // Data accesses are prioritized so the pipeline doesn't
                            // stall longer than necessary on load/store instructions.
                            if (dmem_we && in_gpo_range) begin
                                // GPIO write — handled locally, no QSPI needed
                                gpo_data <= dmem_wdata;
                                gpo_we   <= 1'b1;
                                gpo_addr <= dmem_addr[3:0];
                            end else if (dmem_we && in_mem_range) begin
                                // Data write via QSPI
                                qspi_req   <= 1'b1;
                                qspi_wr    <= 1'b1;
                                qspi_addr  <= dmem_addr[23:0];
                                qspi_wdata <= dmem_wdata;
                                state      <= DWRITE;
                            end else if (!dmem_we && in_mem_range && (dmem_wmask != 4'b0)) begin
                                // Data read via QSPI (wmask != 0 indicates an active load)
                                qspi_req    <= 1'b1;
                                qspi_wr     <= 1'b0;
                                qspi_addr   <= dmem_addr[23:0];
                                dread_valid <= 1'b0;
                                state       <= DREAD;
                            end else begin
                                // No data access pending — fetch next instruction
                                qspi_req     <= 1'b1;
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
