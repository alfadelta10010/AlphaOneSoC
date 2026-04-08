module csr(
    input  wire        clk,
    input  wire        rst,
    // Dual-port: EX reads via raddr, WB writes via waddr
    input  wire [11:0] raddr,      // Read address (from EX stage)
    input  wire [11:0] waddr,      // Write address (from WB stage)
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
    input  wire        priv_mode,   // current privilege: 1=M, 0=U
    output wire [31:0] mtvec_out,
    output wire [31:0] mepc_out,
    // Counter increment
    input  wire        instret_inc,
    // Status bits
    output wire        mstatus_mie,
    output wire [1:0]  mstatus_mpp, // MPP field [12:11] — used for MRET priv restore
    // CSR address validity (for illegal instruction detection)
    output wire        csr_addr_valid  // 1 if raddr is a known/supported CSR
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
    reg [31:0] mcounteren; // 0x306: controls U-mode counter access

    // Performance counters
    reg [63:0] mcycle;
    reg [63:0] minstret;

    assign mtvec_out    = mtvec;
    assign mepc_out     = mepc;
    assign mstatus_mie  = mstatus[3];      // MIE bit
    assign mstatus_mpp  = mstatus[12:11];  // MPP field (11=M, 00=U)

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

    // CSR Read (combinational, uses EX-stage raddr)
    reg addr_valid;
    always @(*) begin
        addr_valid = 1'b1;
        case (raddr)
            // Machine Information (read-only)
            12'hF11: rdata = MVENDORID;
            12'hF12: rdata = MARCHID;
            12'hF13: rdata = MIMPID;
            12'hF14: rdata = MHARTID;
            // Machine ISA (read-only for us, WARL — writes allowed but ignored)
            12'h301: rdata = MISA;
            // Machine Status
            12'h300: rdata = mstatus;
            // Machine Trap Setup
            12'h304: rdata = mie_reg;
            12'h305: rdata = mtvec;
            12'h306: rdata = mcounteren;
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
            // User-mode counter read aliases — mcounteren gates U-mode access.
            // M-mode (priv_mode=1) always succeeds; U-mode needs the corresponding bit set.
            12'hC00: begin rdata = mcycle[31:0];    if (!priv_mode && !mcounteren[0]) addr_valid = 1'b0; end
            12'hC80: begin rdata = mcycle[63:32];   if (!priv_mode && !mcounteren[0]) addr_valid = 1'b0; end
            12'hC02: begin rdata = minstret[31:0];  if (!priv_mode && !mcounteren[2]) addr_valid = 1'b0; end
            12'hC82: begin rdata = minstret[63:32]; if (!priv_mode && !mcounteren[2]) addr_valid = 1'b0; end
            default: begin rdata = 32'b0; addr_valid = 1'b0; end
        endcase
    end
    assign csr_addr_valid = addr_valid;

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
            mie_reg      <= 32'b0;
            mip_reg      <= 32'b0;
            mcounteren   <= 32'b0;
        end else if (trap) begin
            // Enter trap: always go to M-mode
            mepc     <= trap_pc;
            mcause   <= trap_cause;
            mtval    <= trap_val;
            // Save MIE to MPIE, clear MIE; save current privilege into MPP
            // MPP = 11 when trapping from M-mode, 00 when trapping from U-mode
            mstatus <= {mstatus[31:13], {priv_mode, priv_mode}, mstatus[10:8], mstatus[3], mstatus[6:4], 1'b0, mstatus[2:0]};
        end else if (mret) begin
            // Return from trap: MIE=MPIE, MPIE=1, MPP=U (spec: MPP set to least priv after MRET)
            mstatus <= {mstatus[31:13], 2'b00, mstatus[10:8], 1'b1, mstatus[6:4], mstatus[7], mstatus[2:0]};
        end else if (we && op != 2'b00) begin
            case (waddr)
                12'h300: mstatus  <= csr_new & 32'h0000_1888; // Writable bits mask
                12'h304: mie_reg    <= csr_new;
                12'h305: mtvec      <= csr_new;
                12'h306: mcounteren <= csr_new;
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
