// CLINT — Core Local Interruptor
//
// SiFive-compatible CLINT at base address 0x0200_0000.
// Provides machine-mode timer and software interrupt support for Linux/uClinux.
//
// Memory map (offsets from CLINT base):
//   0x0000: msip      (4B) — bit 0 = software interrupt pending (MSIP)
//   0x4000: mtimecmp_lo (4B) — low 32 bits of mtimecmp
//   0x4004: mtimecmp_hi (4B) — high 32 bits of mtimecmp
//   0xBFF8: mtime_lo  (4B) — low 32 bits of mtime (read-write)
//   0xBFFC: mtime_hi  (4B) — high 32 bits of mtime
//
// mtime increments every clock cycle (simulation-accurate).
// Write to mtime is prioritised over the automatic increment in the same cycle.
//
// timer_irq is asserted when mtime >= mtimecmp.
// sw_irq    is asserted when msip[0] = 1.

module clint(
    input  wire        clk,
    input  wire        rst,
    // Bus interface — byte offset within CLINT space (0x0000–0xBFFF)
    input  wire [15:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  wmask,
    input  wire        we,
    output reg  [31:0] rdata,
    // Interrupt outputs
    output wire        timer_irq,
    output wire        sw_irq
);
    reg [31:0] msip;
    reg [63:0] mtimecmp;
    reg [63:0] mtime;

    // Simulation initial values (ignored by synthesis).
    // rst is used in hardware; initial blocks handle simulation startup.
    initial begin
        mtime    = 64'b0;
        mtimecmp = 64'hFFFF_FFFF_FFFF_FFFF; // disabled at power-on
        msip     = 32'b0;
    end

    // mtime: increment every cycle, but a write takes priority on the same edge.
    // Using a single always block avoids the two-driver race condition.
    always @(posedge clk) begin
        if (rst) begin
            mtime <= 64'b0;
        end else if (we && addr == 16'hBFF8) begin
            mtime <= {mtime[63:32],
                      wmask[3] ? wdata[31:24] : mtime[31:24],
                      wmask[2] ? wdata[23:16] : mtime[23:16],
                      wmask[1] ? wdata[15:8]  : mtime[15:8],
                      wmask[0] ? wdata[7:0]   : mtime[7:0]};
        end else if (we && addr == 16'hBFFC) begin
            mtime <= {wmask[3] ? wdata[31:24] : mtime[63:56],
                      wmask[2] ? wdata[23:16] : mtime[55:48],
                      wmask[1] ? wdata[15:8]  : mtime[47:40],
                      wmask[0] ? wdata[7:0]   : mtime[39:32],
                      mtime[31:0]};
        end else begin
            mtime <= mtime + 64'd1;
        end
    end

    assign timer_irq = (mtime >= mtimecmp);
    assign sw_irq    = msip[0];

    // CSR Read (combinational)
    always @(*) begin
        case (addr)
            16'h0000: rdata = msip;
            16'h4000: rdata = mtimecmp[31:0];
            16'h4004: rdata = mtimecmp[63:32];
            16'hBFF8: rdata = mtime[31:0];
            16'hBFFC: rdata = mtime[63:32];
            default:  rdata = 32'h0000_0000;
        endcase
    end

    // msip and mtimecmp writes (synchronous, byte-masked)
    always @(posedge clk) begin
        if (rst) begin
            msip     <= 32'b0;
            mtimecmp <= 64'hFFFF_FFFF_FFFF_FFFF;
        end else if (we) begin
            case (addr)
                16'h0000: begin
                    if (wmask[0]) msip[7:0]   <= wdata[7:0];
                    if (wmask[1]) msip[15:8]  <= wdata[15:8];
                    if (wmask[2]) msip[23:16] <= wdata[23:16];
                    if (wmask[3]) msip[31:24] <= wdata[31:24];
                end
                16'h4000: begin
                    if (wmask[0]) mtimecmp[7:0]   <= wdata[7:0];
                    if (wmask[1]) mtimecmp[15:8]  <= wdata[15:8];
                    if (wmask[2]) mtimecmp[23:16] <= wdata[23:16];
                    if (wmask[3]) mtimecmp[31:24] <= wdata[31:24];
                end
                16'h4004: begin
                    if (wmask[0]) mtimecmp[39:32] <= wdata[7:0];
                    if (wmask[1]) mtimecmp[47:40] <= wdata[15:8];
                    if (wmask[2]) mtimecmp[55:48] <= wdata[23:16];
                    if (wmask[3]) mtimecmp[63:56] <= wdata[31:24];
                end
                default: ; // mtime writes handled in separate block above
            endcase
        end
    end
endmodule
