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
    // PMP CSR outputs (fed to pmp checker instances in fyracore)
    output wire [31:0] pmpcfg0_out,
    output wire [31:0] pmpaddr0_out,
    output wire [31:0] pmpaddr1_out,
    output wire [31:0] pmpaddr2_out,
    output wire [31:0] pmpaddr3_out,
    // CSR address validity (for illegal instruction detection)
    output wire        csr_addr_valid,  // 1 if raddr is a known/supported CSR
    // External interrupt inputs — reflected live in mip reads (not stored)
    input  wire        timer_irq,       // MTIP: timer interrupt pending (from CLINT)
    input  wire        external_irq,    // MEIP: external interrupt pending
    input  wire        sw_irq,          // MSIP: software interrupt pending (from CLINT)
    // mie export — allows fyracore to gate irq_pending per-bit
    output wire [31:0] mie_out
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

    // PMP registers
    reg [31:0] pmpcfg0;                         // 0x3A0: 4 packed 8-bit config bytes
    reg [31:0] pmpaddr0, pmpaddr1, pmpaddr2, pmpaddr3; // 0x3B0-0x3B3

    // Performance counters
    reg [63:0] mcycle;
    reg [63:0] minstret;

    assign mtvec_out    = mtvec;
    assign mepc_out     = mepc;
    assign mstatus_mie  = mstatus[3];      // MIE bit
    assign mstatus_mpp  = mstatus[12:11];  // MPP field (11=M, 00=U)
    assign pmpcfg0_out  = pmpcfg0;
    assign pmpaddr0_out = pmpaddr0;
    assign pmpaddr1_out = pmpaddr1;
    assign pmpaddr2_out = pmpaddr2;
    assign pmpaddr3_out = pmpaddr3;
    assign mie_out      = mie_reg;

    // TOR locking: entry i with A=TOR and L=1 also locks pmpaddr[i-1]
    wire tor_lock_addr0 = pmpcfg0[7]  || (pmpcfg0[12:11] == 2'b01 && pmpcfg0[15]);
    wire tor_lock_addr1 = pmpcfg0[15] || (pmpcfg0[20:19] == 2'b01 && pmpcfg0[23]);
    wire tor_lock_addr2 = pmpcfg0[23] || (pmpcfg0[28:27] == 2'b01 && pmpcfg0[31]);
    wire tor_lock_addr3 = pmpcfg0[31];

    // Live mip value: MSIP(3), MTIP(7), MEIP(11) reflect external pins;
    // other bits come from the writable mip_reg.
    wire [31:0] mip_live = (mip_reg & ~32'h0000_0888) |
                           (sw_irq       ? 32'h0000_0008 : 32'b0) |  // MSIP bit 3
                           (timer_irq    ? 32'h0000_0080 : 32'b0) |  // MTIP bit 7
                           (external_irq ? 32'h0000_0800 : 32'b0);   // MEIP bit 11

    // Cycle counter: merged auto-increment + CSR write (write takes priority)
    always @(posedge clk) begin
        if (rst)
            mcycle <= 64'b0;
        else if (we && op != 2'b00 && waddr == 12'hB00)
            mcycle <= {mcycle[63:32], csr_new};
        else if (we && op != 2'b00 && waddr == 12'hB80)
            mcycle <= {csr_new, mcycle[31:0]};
        else
            mcycle <= mcycle + 1;
    end

    // Instruction retired counter: merged auto-increment + CSR write
    always @(posedge clk) begin
        if (rst)
            minstret <= 64'b0;
        else if (we && op != 2'b00 && waddr == 12'hB02)
            minstret <= {minstret[63:32], csr_new};
        else if (we && op != 2'b00 && waddr == 12'hB82)
            minstret <= {csr_new, minstret[31:0]};
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
            // PMP configuration and addresses
            12'h3A0: rdata = pmpcfg0;
            12'h3B0: rdata = pmpaddr0;
            12'h3B1: rdata = pmpaddr1;
            12'h3B2: rdata = pmpaddr2;
            12'h3B3: rdata = pmpaddr3;
            // Machine Trap Handling
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h344: rdata = mip_live;  // mip: MTIP/MEIP/MSIP reflect live external signals
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
            // Unimplemented PMP registers — hardwired to zero (WARL)
            12'h3A1, 12'h3A2, 12'h3A3: rdata = 32'b0;
            12'h3B4, 12'h3B5, 12'h3B6, 12'h3B7,
            12'h3B8, 12'h3B9, 12'h3BA, 12'h3BB,
            12'h3BC, 12'h3BD, 12'h3BE, 12'h3BF: rdata = 32'b0;
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
            pmpcfg0      <= 32'b0;
            pmpaddr0     <= 32'b0;
            pmpaddr1     <= 32'b0;
            pmpaddr2     <= 32'b0;
            pmpaddr3     <= 32'b0;
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
                12'h304: mie_reg    <= csr_new & 32'h0000_0888;
                12'h305: mtvec      <= csr_new;
                12'h306: mcounteren <= csr_new & 32'h0000_0007;
                12'h340: mscratch <= csr_new;
                12'h341: mepc     <= {csr_new[31:1], 1'b0}; // Bit 0 always 0
                12'h342: mcause   <= csr_new;
                12'h343: mtval    <= csr_new;
                12'h344: mip_reg  <= csr_new & ~32'h0000_0888;
                // Counters: writes handled in dedicated always blocks above
                12'hB00: ;
                12'hB80: ;
                12'hB02: ;
                12'hB82: ;
                // PMP: write only unlocked bytes/entries.
                // pmpcfg0: each byte is independently locked by its own L bit.
                12'h3A0: pmpcfg0 <= {
                    pmpcfg0[31] ? pmpcfg0[31:24] : csr_new[31:24],
                    pmpcfg0[23] ? pmpcfg0[23:16] : csr_new[23:16],
                    pmpcfg0[15] ? pmpcfg0[15:8]  : csr_new[15:8],
                    pmpcfg0[7]  ? pmpcfg0[7:0]   : csr_new[7:0]
                };
                // pmpaddr[i] locked by own L bit or by entry i+1 if TOR+locked
                12'h3B0: if (!tor_lock_addr0) pmpaddr0 <= csr_new;
                12'h3B1: if (!tor_lock_addr1) pmpaddr1 <= csr_new;
                12'h3B2: if (!tor_lock_addr2) pmpaddr2 <= csr_new;
                12'h3B3: if (!tor_lock_addr3) pmpaddr3 <= csr_new;
                default: ; // Ignore writes to read-only CSRs
            endcase
        end
    end
endmodule
