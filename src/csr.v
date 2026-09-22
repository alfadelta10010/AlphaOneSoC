module csr #(
    // marchid 5 is Spike's registered architecture ID, allocated by RISC-V
    // International. Silicon must not claim it, so this defaults to 0
    // (unimplemented); the testbench overrides it to 5 for lockstep.
    parameter [31:0] MARCHID_VAL = 32'h0
)(
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
    output wire [31:0] mie_out,
    // misa.C — gates compressed-instruction decode (WARL bit)
    output wire        misa_c,
    // mstatus.TW — traps WFI in U-mode (Priv spec: must be writable when a
    // less-privileged mode exists, which misa.U says it does)
    output wire        mstatus_tw,
    // mtime value from CLINT (for time/timeh CSR reads)
    input  wire [63:0] mtime_in,
    // misa.C WARL gate: refuse to clear C if next-PC would be 2-byte aligned
    // (Priv spec §3.1.1 — implementation may decline writes that violate
    // alignment requirements). Set by fyracore from current WB-stage PC[1].
    input  wire        pc_next_misaligned
);
    // ===== CSR Registers =====
    // Machine Information
    localparam [31:0] MVENDORID = 32'h0;
    localparam [31:0] MARCHID   = MARCHID_VAL;
    localparam [31:0] MIMPID    = 32'h0;  // matches Spike default
    localparam [31:0] MHARTID   = 32'h0;

    // Machine ISA: RV32IMACU
    // misa[31:30] = 01 (XLEN=32)
    // Bits: A(0)=1, C(2)=1, I(8)=1, M(12)=1, U(20)=1
    localparam [31:0] MISA_RESET = 32'h4010_1105;

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
    reg [31:0] mcountinhibit; // 0x320: inhibit specific perf counters
    reg [31:0] misa_reg; // 0x301: WARL — only the C bit is writable

    // PMP registers
    reg [31:0] pmpcfg0;                         // 0x3A0: 4 packed 8-bit config bytes
    reg [31:0] pmpaddr0, pmpaddr1, pmpaddr2, pmpaddr3; // 0x3B0-0x3B3

    // Performance counters
    reg [63:0] mcycle;
    reg [63:0] minstret;

    assign mtvec_out    = mtvec;
    // Priv spec §3.1.15: when IALIGN=32 (misa.C=0), mepc[1] masked on reads.
    wire [31:0] mepc_eff = {mepc[31:2], (misa_reg[2] ? mepc[1] : 1'b0), 1'b0};
    assign mepc_out     = mepc_eff;
    assign mstatus_mie  = mstatus[3];      // MIE bit
    assign pmpcfg0_out  = pmpcfg0;
    assign pmpaddr0_out = pmpaddr0;
    assign pmpaddr1_out = pmpaddr1;
    assign pmpaddr2_out = pmpaddr2;
    assign pmpaddr3_out = pmpaddr3;
    assign mie_out      = mie_reg;
    assign misa_c       = misa_reg[2];
    assign mstatus_tw   = mstatus[21];

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

    // CSR write-value computation (declared early for counter blocks)
    // NOTE: rdata is from the combinational read block below (uses raddr, not waddr).
    // In practice, the pipeline always sends op=01 (CSRRW) so csr_new = wdata.
    wire [31:0] csr_new;

    // Counter update model: auto-increment happens every retire/cycle (when not
    // inhibited), and the CSR write — if any — overwrites the *post-increment*
    // half. This matches Spike's ordering: a write to the low half doesn't
    // discard a 64-bit carry into the high half from this cycle's increment.
    wire [63:0] mcycle_next   = (!mcountinhibit[0]) ? mcycle + 64'd1 : mcycle;
    wire [63:0] minstret_next = (instret_inc && !mcountinhibit[2]) ? minstret + 64'd1 : minstret;

    // mstatus as it will stand after a CSR write in WB commits this cycle.
    // A trap or an MRET can coincide with a csrw to mstatus, and the csrw is
    // the older instruction, so its value is what they must transform. Mirrors
    // the 12'h300 arm of the write case below -- keep the two in step.
    reg [31:0] mstatus_after_we;
    always @(*) begin
        mstatus_after_we = mstatus;
        if (we && op != 2'b00 && waddr == 12'h300) begin
            mstatus_after_we[3]  = csr_new[3];   // MIE
            mstatus_after_we[7]  = csr_new[7];   // MPIE
            mstatus_after_we[21] = csr_new[21];  // TW
            if (csr_new[12:11] == 2'b11 || csr_new[12:11] == 2'b00)
                mstatus_after_we[12:11] = csr_new[12:11];
        end
    end

    // MPP as it will stand after a WB CSR write commits. The MRET privilege
    // restore consumes this, so a `csrw mstatus, <MPP=M>; mret` pair returns to
    // M-mode rather than to the MPP that was there before the write.
    assign mstatus_mpp  = mstatus_after_we[12:11];  // MPP field (11=M, 00=U)

    always @(posedge clk) begin
        if (rst)
            mcycle <= 64'b0;
        else if (we && op != 2'b00 && waddr == 12'hB00)
            mcycle <= {mcycle_next[63:32], csr_new};
        else if (we && op != 2'b00 && waddr == 12'hB80)
            mcycle <= {csr_new, mcycle_next[31:0]};
        else
            mcycle <= mcycle_next;
    end

    always @(posedge clk) begin
        if (rst)
            minstret <= 64'b0;
        else if (we && op != 2'b00 && waddr == 12'hB02)
            minstret <= {minstret_next[63:32], csr_new};
        else if (we && op != 2'b00 && waddr == 12'hB82)
            minstret <= {csr_new, minstret_next[31:0]};
        else
            minstret <= minstret_next;
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
            12'hF15: rdata = 32'b0;  // mconfigptr: no config data structure
            // Machine ISA (WARL — C bit writable, others hardwired)
            12'h301: rdata = misa_reg;
            // Machine counter inhibit (bits 2:0 = IR, _, CY)
            12'h320: rdata = mcountinhibit;
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
            12'h341: rdata = mepc_eff;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h344: rdata = mip_live;  // mip: MTIP/MEIP/MSIP reflect live external signals
            // Performance Counters — return the post-this-cycle value so a CSR
            // read at EX sees increments committed in the same cycle's WB.
            12'hB00: rdata = mcycle_next[31:0];
            12'hB80: rdata = mcycle_next[63:32];
            12'hB02: rdata = minstret_next[31:0];
            12'hB82: rdata = minstret_next[63:32];
            // User-mode counter read aliases — mcounteren gates U-mode access.
            // M-mode (priv_mode=1) always succeeds; U-mode needs the corresponding bit set.
            12'hC00: begin rdata = mcycle_next[31:0];    if (!priv_mode && !mcounteren[0]) addr_valid = 1'b0; end
            12'hC80: begin rdata = mcycle_next[63:32];   if (!priv_mode && !mcounteren[0]) addr_valid = 1'b0; end
            12'hC01: begin rdata = mtime_in[31:0];        if (!priv_mode && !mcounteren[1]) addr_valid = 1'b0; end
            12'hC81: begin rdata = mtime_in[63:32];       if (!priv_mode && !mcounteren[1]) addr_valid = 1'b0; end
            12'hC02: begin rdata = minstret_next[31:0];  if (!priv_mode && !mcounteren[2]) addr_valid = 1'b0; end
            12'hC82: begin rdata = minstret_next[63:32]; if (!priv_mode && !mcounteren[2]) addr_valid = 1'b0; end
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
    assign csr_new = (op == 2'b01) ? wdata :           // CSRRW
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
            mcountinhibit<= 32'b0;
            misa_reg     <= MISA_RESET;
            pmpcfg0      <= 32'b0;
            pmpaddr0     <= 32'b0;
            pmpaddr1     <= 32'b0;
            pmpaddr2     <= 32'b0;
            pmpaddr3     <= 32'b0;
        end else begin
            // ---- 1. Commit the WB-stage CSR write ----------------------
            // This runs BEFORE the trap/MRET transform below, because the csrw
            // is the older instruction. The trap/MRET arms reassign mstatus
            // afterwards and so still take priority over a write to mstatus
            // itself, but a write to any other CSR now survives.
            if (we && op != 2'b00) begin
            case (waddr)
                12'h300: begin
                    // mstatus WARL. M+U-only: MPP legal values are 00 (U) and
                    // 11 (M). Writes of 01/10 are reserved → keep old MPP
                    // (Priv spec §3.1.6.5: WARL reads must return legal values).
                    mstatus[3]  <= csr_new[3];   // MIE
                    mstatus[7]  <= csr_new[7];   // MPIE
                    mstatus[21] <= csr_new[21];  // TW
                    if (csr_new[12:11] == 2'b11 || csr_new[12:11] == 2'b00)
                        mstatus[12:11] <= csr_new[12:11];
                end
                // misa (0x301): WARL. Only C bit writable. Refuse to clear C
                // when next-PC[1]=1 (would create immediately-misaligned fetch).
                // Setting C to 1 always allowed.
                12'h301: if (csr_new[2] == 1'b1 || !pc_next_misaligned)
                             misa_reg[2] <= csr_new[2];
                12'h304: mie_reg    <= csr_new & 32'h0000_0888;
                12'h305: mtvec      <= {csr_new[31:2], 2'b00}; // Force direct mode (WARL)
                // mcounteren: bits CY(0), TM(1), IR(2) writable for U-mode counter access.
                12'h306: mcounteren <= csr_new & 32'h0000_0007;
                12'h320: mcountinhibit <= csr_new & 32'h0000_0005; // bits IR(2), CY(0); bit 1 (TM) reserved=0
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
                // WARL: bits [6:5] of every byte are reserved and read as
                // zero. A = 2'b10 (NA4) is legal at granularity G=0, pmp.v
                // implements it and the reference model keeps it, so it is
                // stored as written.
                12'h3A0: begin
                    pmpcfg0[7:0]   <= pmpcfg0[7]  ? pmpcfg0[7:0]   : {csr_new[7],  2'b00, csr_new[4:0]};
                    pmpcfg0[15:8]  <= pmpcfg0[15] ? pmpcfg0[15:8]  : {csr_new[15], 2'b00, csr_new[12:8]};
                    pmpcfg0[23:16] <= pmpcfg0[23] ? pmpcfg0[23:16] : {csr_new[23], 2'b00, csr_new[20:16]};
                    pmpcfg0[31:24] <= pmpcfg0[31] ? pmpcfg0[31:24] : {csr_new[31], 2'b00, csr_new[28:24]};
                end
                // pmpaddr[i] locked by own L bit or by entry i+1 if TOR+locked
                12'h3B0: if (!tor_lock_addr0) pmpaddr0 <= csr_new;
                12'h3B1: if (!tor_lock_addr1) pmpaddr1 <= csr_new;
                12'h3B2: if (!tor_lock_addr2) pmpaddr2 <= csr_new;
                12'h3B3: if (!tor_lock_addr3) pmpaddr3 <= csr_new;
                default: ; // Ignore writes to read-only CSRs
            endcase
            end

            // ---- 2. Trap / MRET, applied on top of the write -----------
            // Both transform mstatus_after_we, not mstatus, so a
            // `csrw mstatus, X; mret` pair returns using X.
            if (trap) begin
                // Enter trap: always go to M-mode
                mepc     <= trap_pc;
                mcause   <= trap_cause;
                mtval    <= trap_val;
                // Save MIE to MPIE, clear MIE; save current privilege into MPP
                // MPP = 11 when trapping from M-mode, 00 when trapping from U-mode
                mstatus <= {mstatus_after_we[31:13], {priv_mode, priv_mode}, mstatus_after_we[10:8],
                            mstatus_after_we[3], mstatus_after_we[6:4], 1'b0, mstatus_after_we[2:0]};
            end else if (mret) begin
                // Return from trap: MIE=MPIE, MPIE=1, MPP=U (spec: MPP set to least priv after MRET)
                mstatus <= {mstatus_after_we[31:13], 2'b00, mstatus_after_we[10:8],
                            1'b1, mstatus_after_we[6:4], mstatus_after_we[7], mstatus_after_we[2:0]};
            end
        end
    end
endmodule
