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
    // The value to write. The pipeline computes the whole read-modify-write
    // in EX, so this unit only ever writes: there is no CSRRS/CSRRC here.
    input  wire [31:0] wdata,
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
    // mstatus.MPRV — data accesses use MPP's privilege instead of the current
    // one (Priv spec: must be writable when U-mode is supported)
    output wire        mstatus_mprv,
    // mtime value from CLINT (for time/timeh CSR reads)
    input  wire [63:0] mtime_in,
    // misa.C WARL gate: refuse to clear C if next-PC would be 2-byte aligned
    // (Priv spec §3.1.1 — implementation may decline writes that violate
    // alignment requirements). Set by fyracore from current WB-stage PC[1].
    input  wire        pc_next_misaligned,
    // The value the CSR at waddr reads back once this cycle's write has
    // committed -- see `wval` below. Only the testbench's trace uses it.
    output wire [31:0] wval_out
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
    assign pmpcfg0_out  = pmpcfg0;
    assign pmpaddr0_out = pmpaddr0;
    assign pmpaddr1_out = pmpaddr1;
    assign pmpaddr2_out = pmpaddr2;
    assign pmpaddr3_out = pmpaddr3;

    // TOR locking: entry i with A=TOR and L=1 also locks pmpaddr[i-1]
    wire tor_lock_addr0 = pmpcfg0[7]  || (pmpcfg0[12:11] == 2'b01 && pmpcfg0[15]);
    wire tor_lock_addr1 = pmpcfg0[15] || (pmpcfg0[20:19] == 2'b01 && pmpcfg0[23]);
    wire tor_lock_addr2 = pmpcfg0[23] || (pmpcfg0[28:27] == 2'b01 && pmpcfg0[31]);
    wire tor_lock_addr3 = pmpcfg0[31];

    // mip: MSIP(3), MTIP(7), MEIP(11) are the live interrupt wires, and
    // nothing else exists. With no S-mode, SSIP/STIP/SEIP are read-only zero
    // (Priv §3.1.9), and LCOFIP is read-only zero without Sscofpmf, so mip
    // has no writable bits at all: a write is accepted and ignored.
    wire [31:0] mip_live = (sw_irq       ? 32'h0000_0008 : 32'b0) |  // MSIP bit 3
                           (timer_irq    ? 32'h0000_0080 : 32'b0) |  // MTIP bit 7
                           (external_irq ? 32'h0000_0800 : 32'b0);   // MEIP bit 11

    // The value being written. It used to fall back to the EX read port
    // (rdata | wdata, rdata & ~wdata) for CSRRS/CSRRC ops the pipeline never
    // sends. That dead mux put the EX read decode on a path into every
    // post-write export (misa.C -> mepc_eff -> rdata closed a lint-level
    // loop) and from there into interrupt gating and next_pc.
    wire [31:0] csr_new = wdata;

    // Counter update model: auto-increment happens every retire/cycle (when not
    // inhibited). An explicit write to either half of mcycle or minstret is
    // done *instead of* that cycle's increment -- Zicsr: "If a CSR access
    // instruction writes such a CSR, the explicit write is done instead of
    // the update from the side effect" -- so the half that is not written
    // keeps its current value, and a write to the high half does not bump the
    // low half either. Upstream Spike does the same since 51835fd7, and
    // riscv-tests rv32mi-instret_overflow checks it for minstret.
    //
    // *_next is both the register's next value and what the EX read port
    // returns, so the increment is suppressed at its enable.
    //
    // fyracore holds the instruction after a CSR write in EX for one cycle
    // (csr_wb_hazard), so an rdcycle right after `csrw mcycle` reads a cycle
    // later than the write, where the cycle count has moved on by one. The
    // reference model counts instructions, not clocks, and reads the written
    // value there. mcycle_wr_q skips the one increment in between, so that
    // read returns what was written, as it did when EX was forwarded the
    // write. (minstret needs nothing: the stall's bubble retires nothing.)
    wire        mcycle_we     = we && (waddr == 12'hB00 || waddr == 12'hB80);
    wire        minstret_we   = we && (waddr == 12'hB02 || waddr == 12'hB82);
    reg         mcycle_wr_q;
    always @(posedge clk) mcycle_wr_q <= !rst && mcycle_we;
    wire [63:0] mcycle_next   = (!mcountinhibit[0] && !mcycle_we && !mcycle_wr_q) ?
                                mcycle + 64'd1 : mcycle;
    wire [63:0] minstret_next = (instret_inc && !mcountinhibit[2] && !minstret_we) ?
                                minstret + 64'd1 : minstret;

    // mstatus as it will stand after a CSR write in WB commits this cycle:
    // the legal value the write stores. A trap or an MRET never coincides
    // with that write -- the instruction behind a CSR write waits in EX until
    // it has committed (fyracore's csr_wb_hazard) -- so they always see the
    // stored mstatus.
    // M+U only: MPP's legal values are 00 (U) and 11 (M). A write of 01 (S,
    // absent) or 10 (reserved) is legalised to U, the least-privileged
    // mode -- one AND gate, and what the reference model does. (Keeping the
    // old MPP is equally legal WARL behaviour, but diverged from Spike on
    // every such write.) MPRV and TW exist because U-mode does.
    reg [31:0] mstatus_after_we;
    always @(*) begin
        mstatus_after_we = mstatus;
        if (we && waddr == 12'h300) begin
            mstatus_after_we[3]  = csr_new[3];   // MIE
            mstatus_after_we[7]  = csr_new[7];   // MPIE
            mstatus_after_we[17] = csr_new[17];  // MPRV
            mstatus_after_we[21] = csr_new[21];  // TW
            mstatus_after_we[12:11] = {2{csr_new[12] & csr_new[11]}};
        end
    end

    // The mstatus fields fyracore consumes -- the MRET privilege restore
    // (MPP), interrupt gating (MIE), the data PMP check (MPRV, MPP) and the
    // U-mode WFI check (TW) -- sit in EX, one stage ahead of the write.
    // Zicsr requires a write's effects to be visible to the very next
    // instruction (`csrw mstatus, <MPP=M>; mret` returns to M-mode), and
    // fyracore provides that by holding the next instruction in EX until the
    // write has committed (csr_wb_hazard), so the stored value is exported.
    assign mstatus_mie  = mstatus[3];
    assign mstatus_mpp  = mstatus[12:11];  // MPP field (11=M, 00=U)
    assign mstatus_mprv = mstatus[17];
    assign mstatus_tw   = mstatus[21];

    // mie likewise: Priv §3.1.9 requires the interrupt conditions to be
    // re-evaluated immediately after an explicit write to mie, so the
    // instruction right after `csrs mie` is already interruptible and the
    // one right after `csrc mie` is not; it reaches EX after the write.
    assign mie_out = mie_reg;

    // misa as it will stand after a WB write: only C is writable, and a
    // clear is refused when it would leave the next PC misaligned.
    wire        misa_we_ok    = we && waddr == 12'h301 &&
                                (csr_new[2] || !pc_next_misaligned);
    wire [31:0] misa_after_we = misa_we_ok ? {misa_reg[31:3], csr_new[2], misa_reg[1:0]}
                                           : misa_reg;
    // misa.C gates compressed decode, the branch-target alignment check and
    // the mepc read mask, all of which fyracore applies in EX -- after the
    // write, like the mstatus fields, so the instruction right after
    // `csrci misa, 4` is already checked with C=0, as Zicsr requires.
    assign misa_c = misa_reg[2];
    // Priv spec §3.1.15: when IALIGN=32 (misa.C=0), mepc[1] masked on reads.
    wire [31:0] mepc_eff = {mepc[31:2], (misa_c ? mepc[1] : 1'b0), 1'b0};
    assign mepc_out      = mepc_eff;

    // A pmpcfg byte as written, made legal: L, A, X and R as given, bits
    // [6:5] zero, and W only alongside R.
    function [7:0] pmpcfg_legal;
        input [7:0] b;
        pmpcfg_legal = {b[7], 2'b00, b[4:2], b[1] & b[0], b[0]};
    endfunction

    // ===== Legal values =========================================================
    // Each writable register's value after a write of csr_new, every WARL
    // rule in one place, one wire per register. The write case below stores
    // these wires register by register, so a bit that no write can set is a
    // constant 0 that synthesis removes, flop and all; storing the shared
    // `wval` mux instead hid that and kept all 32 flops of every WARL
    // register. `wval` selects the same wires, so the rules cannot drift
    // between the two.
    wire [31:0] mie_legal     = csr_new & 32'h0000_0888;    // MSIE/MTIE/MEIE
    wire [31:0] mtvec_legal   = {csr_new[31:2], 2'b00};     // direct mode only
    wire [31:0] mcounteren_legal    = csr_new & 32'h0000_0007;  // CY/TM/IR
    wire [31:0] mcountinhibit_legal = csr_new & 32'h0000_0005;  // TM reserved
    // pmpcfg0: a locked byte keeps its value; otherwise bits [6:5] are
    // reserved and read 0. A = 2'b10 (NA4) is legal at G=0 and pmp.v
    // implements it, so it is stored as written. R/W/X form a collective
    // WARL field in which R=0,W=1 is reserved (Priv §3.7.1): W is legalised
    // to 0 when R is 0, as Spike does.
    wire [31:0] pmpcfg0_legal = {pmpcfg0[31] ? pmpcfg0[31:24] : pmpcfg_legal(csr_new[31:24]),
                                 pmpcfg0[23] ? pmpcfg0[23:16] : pmpcfg_legal(csr_new[23:16]),
                                 pmpcfg0[15] ? pmpcfg0[15:8]  : pmpcfg_legal(csr_new[15:8]),
                                 pmpcfg0[7]  ? pmpcfg0[7:0]   : pmpcfg_legal(csr_new[7:0])};
    // pmpaddr[i]: locked by its own L bit, or by entry i+1 when that entry is
    // TOR and locked.
    wire [31:0] pmpaddr0_legal = tor_lock_addr0 ? pmpaddr0 : csr_new;
    wire [31:0] pmpaddr1_legal = tor_lock_addr1 ? pmpaddr1 : csr_new;
    wire [31:0] pmpaddr2_legal = tor_lock_addr2 ? pmpaddr2 : csr_new;
    wire [31:0] pmpaddr3_legal = tor_lock_addr3 ? pmpaddr3 : csr_new;

    // ===== Post-write value ======================================================
    // What a read of waddr returns once this cycle's write has committed
    // (mepc and mip store a little more than they read back, noted there).
    // fyracore exports it only to the testbench, which logs it as the
    // written value; synthesis drops it. Only meaningful while a write is in
    // WB.
    reg [31:0] wval;
    always @(*) begin
        case (waddr)
            12'h300: wval = mstatus_after_we;
            12'h301: wval = misa_after_we;
            12'h304: wval = mie_legal;
            12'h305: wval = mtvec_legal;
            12'h306: wval = mcounteren_legal;
            12'h320: wval = mcountinhibit_legal;
            12'h340: wval = csr_new;                         // mscratch
            // mepc: bit 0 is always 0; bit 1 is stored but reads 0 while
            // IALIGN=32 (misa.C=0).
            12'h341: wval = {csr_new[31:2], (misa_reg[2] ? csr_new[1] : 1'b0), 1'b0};
            12'h342: wval = csr_new;                         // mcause
            12'h343: wval = csr_new;                         // mtval
            12'h344: wval = mip_live;                        // mip: no writable bits
            12'h3A0: wval = pmpcfg0_legal;
            12'h3B0: wval = pmpaddr0_legal;
            12'h3B1: wval = pmpaddr1_legal;
            12'h3B2: wval = pmpaddr2_legal;
            12'h3B3: wval = pmpaddr3_legal;
            // Counters: the written half takes the value outright.
            12'hB00, 12'hB80, 12'hB02, 12'hB82: wval = csr_new;
            // Everything else that can be written without trapping reads 0
            // (the unimplemented pmpcfg/pmpaddr registers and csr_read_zero).
            default: wval = 32'b0;
        endcase
    end
    assign wval_out = wval;

    always @(posedge clk) begin
        if (rst)
            mcycle <= 64'b0;
        else if (we && waddr == 12'hB00)
            mcycle <= {mcycle[63:32], csr_new};
        else if (we && waddr == 12'hB80)
            mcycle <= {csr_new, mcycle[31:0]};
        else
            mcycle <= mcycle_next;
    end

    always @(posedge clk) begin
        if (rst)
            minstret <= 64'b0;
        else if (we && waddr == 12'hB02)
            minstret <= {minstret[63:32], csr_new};
        else if (we && waddr == 12'hB82)
            minstret <= {csr_new, minstret[31:0]};
        else
            minstret <= minstret_next;
    end

    // CSRs that must exist on this core but hold nothing: they read 0 and
    // ignore writes (wval's default arm is 0, and nothing stores them).
    //   mhpmcounter3-31, mhpmcounter3h-31h, mhpmevent3-31: "All counters
    //     should be implemented, but a legal implementation is to make both
    //     the counter and its corresponding event selector be read-only 0."
    //   mstatush (0x310): mandatory on RV32; MBE/SBE are 0 (little-endian).
    //   menvcfg/menvcfgh (0x30A/0x31A): exist whenever U-mode does; with no
    //     S-mode FIOM may be read-only zero, and no other field applies.
    // The user-level hpmcounter3-31 aliases stay unimplemented (Zihpm).
    wire csr_read_zero =
        (raddr[11:5] == 7'b1011_000 && raddr[4:0] >= 5'd3) ||   // mhpmcounter3-31
        (raddr[11:5] == 7'b1011_100 && raddr[4:0] >= 5'd3) ||   // mhpmcounter3h-31h
        (raddr[11:5] == 7'b0011_001 && raddr[4:0] >= 5'd3) ||   // mhpmevent3-31
        raddr == 12'h310 || raddr == 12'h30A || raddr == 12'h31A;

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
            default: begin rdata = 32'b0; addr_valid = csr_read_zero; end
        endcase
    end
    assign csr_addr_valid = addr_valid;

    always @(posedge clk) begin
        if (rst) begin
            // Priv §3.4: MIE and MPRV reset to 0; MPP's reset value is left
            // to the implementation. 0 (U) matches the reference model, so
            // no trace diverges on it before software first writes mstatus.
            mstatus  <= 32'h0000_0000;
            mtvec    <= 32'h0000_0000;
            mscratch <= 32'b0;
            mepc     <= 32'b0;
            mcause   <= 32'b0;
            mtval    <= 32'b0;
            mie_reg      <= 32'b0;
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
            // Each register stores its legal value (see "Legal values"),
            // except where noted. Counters are written in their own blocks
            // above; mip has nothing to store.
            if (we) begin
            case (waddr)
                12'h300: mstatus       <= mstatus_after_we;
                12'h301: misa_reg      <= misa_after_we;
                12'h304: mie_reg       <= mie_legal;
                12'h305: mtvec         <= mtvec_legal;
                12'h306: mcounteren    <= mcounteren_legal;
                12'h320: mcountinhibit <= mcountinhibit_legal;
                12'h340: mscratch      <= csr_new;
                // mepc keeps bit 1 even while IALIGN=32 hides it on reads, so
                // it reappears if C is re-enabled.
                12'h341: mepc          <= {csr_new[31:1], 1'b0};
                12'h342: mcause        <= csr_new;
                12'h343: mtval         <= csr_new;
                12'h3A0: pmpcfg0       <= pmpcfg0_legal;
                12'h3B0: pmpaddr0      <= pmpaddr0_legal;
                12'h3B1: pmpaddr1      <= pmpaddr1_legal;
                12'h3B2: pmpaddr2      <= pmpaddr2_legal;
                12'h3B3: pmpaddr3      <= pmpaddr3_legal;
                default: ;
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
                // Return from trap: MIE=MPIE, MPIE=1, MPP=U (spec: MPP set to least priv after MRET).
                // MPRV is also cleared whenever the return is to a mode less
                // privileged than M.
                mstatus <= {mstatus_after_we[31:13], 2'b00, mstatus_after_we[10:8],
                            1'b1, mstatus_after_we[6:4], mstatus_after_we[7], mstatus_after_we[2:0]}
                           & ((mstatus_after_we[12:11] == 2'b11) ? 32'hFFFF_FFFF
                                                                 : ~32'h0002_0000);
            end
        end
    end
endmodule
