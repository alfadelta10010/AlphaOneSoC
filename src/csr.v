module csr(
    input  wire        clk,
    input  wire        rst,
    // Read/Write port
    input  wire [11:0] addr,
    input  wire [31:0] wdata,
    input  wire [1:0]  op,       // 00=none, 01=RW, 10=RS, 11=RC
    input  wire        we,
    output reg  [31:0] rdata,
    // Trap interface
    input  wire        trap,
    input  wire        mret,
    input  wire [31:0] trap_pc,
    input  wire [31:0] trap_cause,
    input  wire [31:0] trap_val,
    output wire [31:0] mtvec_out,
    output wire [31:0] mepc_out,
    // Counter increment
    input  wire        instret_inc,
    // Status bits
    output wire        mstatus_mie
);
    // ===== CSR Registers =====
    // Machine Information
    localparam [31:0] MVENDORID = 32'h0;
    localparam [31:0] MARCHID   = 32'h0;
    localparam [31:0] MIMPID    = 32'h1;
    localparam [31:0] MHARTID   = 32'h0;

    // Machine ISA: RV32IMAC
    // misa[31:30] = 01 (XLEN=32)
    // Bits: I(8)=1, M(12)=1, A(0)=1, C(2)=1
    localparam [31:0] MISA = {2'b01, 4'b0, 26'b00000000000001000100000101};

    // Machine Status
    reg [31:0] mstatus;
    reg [31:0] mtvec;
    reg [31:0] mscratch;
    reg [31:0] mepc;
    reg [31:0] mcause;
    reg [31:0] mtval;
    reg [31:0] mie_reg;
    reg [31:0] mip_reg;

    // Performance counters
    reg [63:0] mcycle;
    reg [63:0] minstret;

    assign mtvec_out    = mtvec;
    assign mepc_out     = mepc;
    assign mstatus_mie  = mstatus[3]; // MIE bit

    // Cycle counter always increments
    always @(posedge clk) begin
        if (rst)
            mcycle <= 64'b0;
        else
            mcycle <= mcycle + 1;
    end

    // Instruction retired counter
    always @(posedge clk) begin
        if (rst)
            minstret <= 64'b0;
        else if (instret_inc)
            minstret <= minstret + 1;
    end

    // CSR Read (combinational)
    always @(*) begin
        case (addr)
            // Machine Information (read-only)
            12'hF11: rdata = MVENDORID;
            12'hF12: rdata = MARCHID;
            12'hF13: rdata = MIMPID;
            12'hF14: rdata = MHARTID;
            // Machine ISA (read-only for us)
            12'h301: rdata = MISA;
            // Machine Status
            12'h300: rdata = mstatus;
            // Machine Trap Setup
            12'h304: rdata = mie_reg;
            12'h305: rdata = mtvec;
            // Machine Trap Handling
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h344: rdata = mip_reg;
            // Performance Counters
            12'hB00: rdata = mcycle[31:0];
            12'hB80: rdata = mcycle[63:32];
            12'hB02: rdata = minstret[31:0];
            12'hB82: rdata = minstret[63:32];
            // User-mode counter read aliases
            12'hC00: rdata = mcycle[31:0];
            12'hC80: rdata = mcycle[63:32];
            12'hC02: rdata = minstret[31:0];
            12'hC82: rdata = minstret[63:32];
            default: rdata = 32'b0;
        endcase
    end

    // CSR Write
    wire [31:0] csr_new = (op == 2'b01) ? wdata :           // CSRRW
                          (op == 2'b10) ? (rdata | wdata) :  // CSRRS
                          (op == 2'b11) ? (rdata & ~wdata) : // CSRRC
                          rdata;

    always @(posedge clk) begin
        if (rst) begin
            mstatus  <= 32'h0000_1800; // MPP=11 (M-mode)
            mtvec    <= 32'h0000_0000;
            mscratch <= 32'b0;
            mepc     <= 32'b0;
            mcause   <= 32'b0;
            mtval    <= 32'b0;
            mie_reg  <= 32'b0;
            mip_reg  <= 32'b0;
        end else if (trap) begin
            // Enter trap
            mepc     <= trap_pc;
            mcause   <= trap_cause;
            mtval    <= trap_val;
            // Save MIE to MPIE, clear MIE, set MPP=M-mode
            // Use full-word assignment to avoid iverilog bit-select NBA issues
            mstatus <= {mstatus[31:13], 2'b11, mstatus[10:8], mstatus[3], mstatus[6:4], 1'b0, mstatus[2:0]};
        end else if (mret) begin
            // Return from trap: MIE=MPIE, MPIE=1, MPP=M-mode
            mstatus <= {mstatus[31:13], 2'b11, mstatus[10:8], 1'b1, mstatus[6:4], mstatus[7], mstatus[2:0]};
        end else if (we && op != 2'b00) begin
            case (addr)
                12'h300: mstatus  <= csr_new & 32'h0000_1888; // Writable bits mask
                12'h304: mie_reg  <= csr_new;
                12'h305: mtvec    <= csr_new;
                12'h340: mscratch <= csr_new;
                12'h341: mepc     <= {csr_new[31:1], 1'b0}; // Bit 0 always 0
                12'h342: mcause   <= csr_new;
                12'h343: mtval    <= csr_new;
                12'h344: mip_reg  <= csr_new;
                // Counters writable
                12'hB00: mcycle[31:0]    <= csr_new;
                12'hB80: mcycle[63:32]   <= csr_new;
                12'hB02: minstret[31:0]  <= csr_new;
                12'hB82: minstret[63:32] <= csr_new;
                default: ; // Ignore writes to read-only CSRs
            endcase
        end
    end
endmodule
