// FyraCore — 3-stage pipelined RV32IMCA+Zicsr+Zifencei processor
//
// Pipeline stages:
//   IF  — Instruction Fetch + C-extension decompression
//   EX  — Decode, Register Read, ALU Execute, Branch Resolve
//   WB  — Memory Access, Writeback, CSR commit
//
// Hazard handling:
//   - Data forwarding from WB → EX
//   - Load-use stall (1 cycle)
//   - Branch/jump flush (1 cycle penalty)
//   - AMO: 2-cycle WB (stall pipeline)

module fyracore #(
    parameter [31:0] RESET_PC = 32'h0000_0000,
    // See csr.v: 0 means "no registered architecture ID". The testbench
    // overrides this to 5 so the Spike lockstep trace matches.
    parameter [31:0] MARCHID  = 32'h0000_0000,
    // Physical memory attributes -- the implemented address map.
    //
    // Anything outside these windows has no device behind it, so an access
    // must raise an access fault rather than silently succeeding.
    //
    // The defaults are the SoC's real map, matching src/memController.v and
    // docs/FyraCore_CPU_Reference.md:
    //
    //   0x0000_0000 - 0x00FF_FFFF  Flash  16 MB  XIP code (QSPI CS0)
    //   0x0100_0000 - 0x01FF_FFFF  RAM    16 MB  stack/heap/.data (QSPI CS1)
    //   0x0200_0000 - 0x0200_BFFF  CLINT  48 KB
    //   0x0300_0000 - 0x0300_000F  GPIO   16 B   GPO 0x00-0x07, GPI 0x08-0x0F
    //
    // Flash and RAM are contiguous, so one window covers both. Fetch is
    // allowed anywhere in it and nowhere else: the design is Von Neumann, so
    // XIP from flash and executing from RAM must both work, but fetching out
    // of CLINT or GPIO is an instruction access fault.
    //
    // The verification flow cannot use this map. Spike's boot ROM is fixed at
    // 0x1000 and cannot be disabled, so it would sit inside flash, and Spike
    // only places RAM at DRAM_BASE 0x8000_0000. tb/tb_rivercore.v therefore
    // overrides these to a Spike-compatible window; the remap lives in the
    // testbench so the core keeps describing the hardware being built.
    parameter [31:0] PMA_MEM_BASE = 32'h0000_0000,
    parameter [31:0] PMA_MEM_TOP  = 32'h01FF_FFFF,  // Flash + RAM, 32 MB
    parameter [31:0] PMA_IO0_BASE = 32'h0200_0000,  // CLINT
    parameter [31:0] PMA_IO0_TOP  = 32'h0200_BFFF,
    parameter [31:0] PMA_IO1_BASE = 32'h0300_0000,  // GPIO
    parameter [31:0] PMA_IO1_TOP  = 32'h0300_000F
)(
    input  wire        clk,
    input  wire        rst,
    // Instruction memory interface (read-only, combinational)
    output wire [31:0] imem_addr,
    input  wire [31:0] imem_rdata,
    input  wire        imem_ready,    // Instruction fetch data is valid
    // Data memory interface
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_wmask,
    output wire        dmem_we,
    input  wire [31:0] dmem_rdata,
    input  wire        dmem_ready,    // Data access complete
    // External interrupt inputs (from CLINT / PLIC)
    input  wire        timer_irq,     // Machine timer interrupt (MTIP)
    input  wire        external_irq,  // Machine external interrupt (MEIP)
    input  wire        sw_irq,        // Machine software interrupt (MSIP)
    // mtime value from CLINT (for CSR time/timeh reads)
    input  wire [63:0] mtime_in,
    // FENCE.I flush signal — asserted for one cycle when FENCE.I executes.
    // In hardware mode the memory controller uses this to invalidate its
    // instruction-fetch buffer, forcing a fresh fetch after any stores to
    // the instruction stream.  In simulation (no icache) it is informational.
    output wire        fencei_flush,
    // Debug / trace
    output wire [31:0] dbg_pc,
    output wire        dbg_retired,
    output wire [31:0] dbg_instr,
    output wire        dbg_compressed,
    output wire        dbg_trap
);

    // ================================================================
    //  IF Stage
    // ================================================================
    reg  [31:0] pc;
    wire [31:0] if_fetched    = imem_rdata;
    wire        if_compressed = (if_fetched[1:0] != 2'b11);
    wire [31:0] if_instr_decompressed;
    wire        if_c_illegal;
    wire [31:0] if_instr      = if_compressed ? if_instr_decompressed : if_fetched;
    wire [31:0] if_pc_next    = pc + (if_compressed ? 32'd2 : 32'd4);

    assign imem_addr = pc;

    compressed_decoder cdec(
        .instr_in (if_fetched[15:0]),
        .instr_out(if_instr_decompressed),
        .illegal  (if_c_illegal)
    );

    // ================================================================
    //  IF/EX Pipeline Register
    // Privilege mode: 1=Machine, 0=User. Declared early so EX-stage wires can reference it.
    reg        priv_mode;
    // WFI stall: set when WFI executes, cleared when any interrupt becomes pending.
    reg        wfi_active;

    // ================================================================
    reg [31:0] ifex_pc;
    reg [31:0] ifex_instr;
    reg [31:0] ifex_raw_instr;  // Original fetched bytes (16-bit if compressed)
    reg        ifex_compressed;
    reg [31:0] ifex_pc_next;
    reg        ifex_valid;
    reg        ifex_c_illegal;  // Compressed decoder flagged illegal encoding

    // ================================================================
    //  EX/WB Pipeline Register (declared here so EX-stage continuous
    //  assignments can reference them without iverilog forward-ref errors)
    // ================================================================
    reg [31:0] exwb_alu_result;
    reg [31:0] exwb_rs2_data;
    reg [31:0] exwb_pc_next;
    reg [4:0]  exwb_rd;
    reg        exwb_regWR;
    reg        exwb_memRD;
    reg        exwb_memWR;
    reg [1:0]  exwb_memSize;
    reg        exwb_memUnsigned;
    reg [1:0]  exwb_wbSel;
    reg        exwb_valid;
    // CSR pipeline regs
    reg        exwb_csrWR;
    reg [11:0] exwb_csr_addr;
    reg [31:0] exwb_csr_wdata;
    reg [31:0] exwb_csr_rdata;
    // Atomics pipeline regs
    reg        exwb_isAmo;
    reg        exwb_isLR;
    reg        exwb_isSC;
    reg [4:0]  exwb_amoOp;
    // Trap pipeline regs
    reg        exwb_trap;
    reg [31:0] exwb_trap_cause;
    reg [31:0] exwb_trap_pc;
    reg [31:0] exwb_trap_val;   // mtval: faulting addr (misalign) or instr (illegal), else 0
    reg [31:0] exwb_instr;
    reg [31:0] exwb_raw_instr;  // Original fetched bytes for trace dump
    reg        exwb_compressed;

    // Forward declarations for wires assigned later in the CSR/WB section
    // (needed to break iverilog's forward-reference restriction)
    wire [31:0] csr_rdata_eff;   // driven by assign in CSR section
    wire        csr_addr_valid;  // driven by CSR unit output
    wire        pmp_ifetch_allow; // driven by pmp_ifetch instance
    wire        pmp_data_allow;   // driven by pmp_data instance
    wire        irq_inject;      // driven by interrupt detection logic in CSR/WB section
    wire        csr_misa_c;      // driven by CSR unit output (misa.C bit)
    wire        csr_mstatus_tw;  // driven by CSR unit output (mstatus.TW bit)
    wire        csr_mstatus_mprv;// driven by CSR unit output (mstatus.MPRV bit)

    // ================================================================
    //  EX Stage — Decode + Control + Regfile Read + ALU + Branch
    // ================================================================

    // Decoder
    wire [6:0]  ex_opcode;
    wire [4:0]  ex_rd, ex_rs1, ex_rs2;
    wire [2:0]  ex_funct3;
    wire [6:0]  ex_funct7;

    decoder dec(
        .instIn(ifex_instr),
        .opcode(ex_opcode),
        .rd    (ex_rd),
        .rs1   (ex_rs1),
        .rs2   (ex_rs2),
        .funct3(ex_funct3),
        .funct7(ex_funct7)
    );

    // Controller
    wire        ctrl_regWR, ctrl_memRD, ctrl_memWR;
    wire [4:0]  ctrl_aluOp;
    wire        ctrl_aluSrc1, ctrl_aluSrc2;
    wire [1:0]  ctrl_memSize;
    wire        ctrl_memUnsigned;
    wire [1:0]  ctrl_wbSel;
    wire        ctrl_doBranch, ctrl_doJump;
    wire [1:0]  ctrl_csrOp;
    wire        ctrl_csrSrc;
    wire        ctrl_isAmo, ctrl_isLR, ctrl_isSC;
    wire [4:0]  ctrl_amoOp;
    wire        ctrl_isEcall, ctrl_isEbreak, ctrl_isMret;
    wire        ctrl_isFence, ctrl_isFenceI;
    wire        ctrl_isMulDiv;
    wire        ctrl_illegal;

    controller ctrl(
        .opcode     (ex_opcode),
        .funct3     (ex_funct3),
        .funct7     (ex_funct7),
        .regWR      (ctrl_regWR),
        .aluOp      (ctrl_aluOp),
        .aluSrc1    (ctrl_aluSrc1),
        .aluSrc2    (ctrl_aluSrc2),
        .memRD      (ctrl_memRD),
        .memWR      (ctrl_memWR),
        .memSize    (ctrl_memSize),
        .memUnsigned(ctrl_memUnsigned),
        .wbSel      (ctrl_wbSel),
        .doBranch   (ctrl_doBranch),
        .doJump     (ctrl_doJump),
        .csrOp      (ctrl_csrOp),
        .csrSrc     (ctrl_csrSrc),
        .isAmo      (ctrl_isAmo),
        .isLR       (ctrl_isLR),
        .isSC       (ctrl_isSC),
        .amoOp      (ctrl_amoOp),
        .isEcall    (ctrl_isEcall),
        .isEbreak   (ctrl_isEbreak),
        .isMret     (ctrl_isMret),
        .isFence    (ctrl_isFence),
        .isFenceI   (ctrl_isFenceI),
        .isMulDiv   (ctrl_isMulDiv),
        .illegal    (ctrl_illegal)
    );

    // Sign extension / Immediate generation
    wire [31:0] ex_imm;
    signExt sext(
        .opcode(ex_opcode),
        .instIn(ifex_instr),
        .immOut(ex_imm)
    );

    // Register file read
    wire [31:0] rf_r1, rf_r2;
    wire        wb_regWR;
    wire [4:0]  wb_rd;
    wire [31:0] wb_data;

    regFile #(32) rf(
        .clk (clk),
        .rst (rst),
        .wrEn(wb_regWR),
        .rs1 (ex_rs1),
        .rs2 (ex_rs2),
        .rd  (wb_rd),
        .dIn (wb_data),
        .r1  (rf_r1),
        .r2  (rf_r2)
    );

    // Data forwarding from WB → EX
    wire fwd_rs1 = (exwb_valid && exwb_regWR && exwb_rd != 5'b0 && exwb_rd == ex_rs1);
    wire fwd_rs2 = (exwb_valid && exwb_regWR && exwb_rd != 5'b0 && exwb_rd == ex_rs2);
    wire [31:0] ex_rs1_val = fwd_rs1 ? wb_data : rf_r1;
    wire [31:0] ex_rs2_val = fwd_rs2 ? wb_data : rf_r2;

    // ALU operand selection
    wire [31:0] alu_d1 = ctrl_aluSrc1 ? ifex_pc   : ex_rs1_val;
    wire [31:0] alu_d2 = ctrl_aluSrc2 ? ex_rs2_val : ex_imm;

    // ALU (RV32I only — M-extension handled by muldiv below)
    wire [31:0] ex_alu_result;
    alu alu_inst(
        .d1     (alu_d1),
        .d2     (alu_d2),
        .result (ex_alu_result),
        .control(ctrl_aluOp)
    );

    // ── Multi-cycle multiply/divide unit (RV32M) ──────────────────────────────
    // Wire declarations; stall/start logic is in the Hazard Detection section
    // below (after all dependencies are in scope — iverilog requires this).
    wire        muldiv_busy;
    wire        muldiv_done;
    wire [31:0] muldiv_result;
    wire        muldiv_start;   // driven by assign in Hazard Detection
    wire        muldiv_stall;   // driven by assign in Hazard Detection

    muldiv muldiv_inst(
        .clk   (clk),
        .rst   (rst),
        .start (muldiv_start),
        .op    (ctrl_aluOp[2:0]),    // op encoded in lower 3 bits of aluOp
        .a     (alu_d1),             // rs1 (aluSrc1=0 for all M-ext R-type)
        .b     (alu_d2),             // rs2 (aluSrc2=1 for all M-ext R-type)
        .result(muldiv_result),
        .busy  (muldiv_busy),
        .done  (muldiv_done)
    );

    // Branch evaluation
    wire ex_branch_valid;
    branchCtrl bcmp(
        .funct3     (ex_funct3),
        .r1         (ex_rs1_val),
        .r2         (ex_rs2_val),
        .branchValid(ex_branch_valid)
    );

    wire ex_branch_taken = (ctrl_doBranch && ex_branch_valid) || ctrl_doJump;
    // JALR clears bit 0 of target
    wire [31:0] ex_branch_target = (ex_opcode == 7'b1100111) ?
                                   {ex_alu_result[31:1], 1'b0} : ex_alu_result;

    // CSR read (in EX, write deferred to WB)
    wire [31:0] csr_rdata;
    wire [11:0] ex_csr_addr = ifex_instr[31:20];
    wire [31:0] ex_csr_wdata_src = ctrl_csrSrc ? {27'b0, ex_rs1} : ex_rs1_val; // zimm or rs1
    wire [31:0] ex_csr_wdata;

    // Compute new CSR value based on operation
    assign ex_csr_wdata = (ctrl_csrOp == 2'b01) ? ex_csr_wdata_src :                    // CSRRW
                          (ctrl_csrOp == 2'b10) ? (csr_rdata_eff | ex_csr_wdata_src) : // CSRRS
                          (ctrl_csrOp == 2'b11) ? (csr_rdata_eff & ~ex_csr_wdata_src): // CSRRC
                          32'b0;

    // SYSTEM instruction field validation (ECALL/EBREAK/MRET require rd=0, rs1=0)
    wire ex_system_fields_ok = (ex_rd == 5'b0) && (ex_rs1 == 5'b0);
    wire ex_is_ecall  = ifex_valid && ctrl_isEcall && ex_system_fields_ok &&
                        (ifex_instr[24:20] == 5'b00000);
    wire ex_is_ebreak = ifex_valid && ctrl_isEbreak && ex_system_fields_ok &&
                        (ifex_instr[24:20] == 5'b00001);
    wire ex_is_mret   = ifex_valid && ctrl_isMret && ex_system_fields_ok && priv_mode;
    wire ex_is_fencei = ifex_valid && ctrl_isFenceI;

    // WFI: funct7=0001000 (not isMret, not isEcall, not isFenceI) — NOP in M-mode,
    // but with interrupt support we stall until an interrupt fires.
    // Encoding: opcode=1110011, funct3=000, funct7=0001000 (rs2=00101).
    // U-mode WFI traps as illegal instruction (spec Section 3.3.3).
    wire ex_is_wfi = ifex_valid && (ifex_instr[31:20] == 12'b000100000101) &&
                     (ex_opcode == 7'b1110011) && (ex_funct3 == 3'b000) &&
                     (ex_rd == 5'b0) && (ex_rs1 == 5'b0) && priv_mode;

    // U-mode WFI traps as illegal only when mstatus.TW is set. With no S-mode
    // and TW=0 the spec permits WFI in U-mode; it then decodes as a NOP, which
    // the spec also permits.
    wire ex_wfi_umode = ifex_valid && (ifex_instr[31:20] == 12'b000100000101) &&
                        (ex_opcode == 7'b1110011) && (ex_funct3 == 3'b000) &&
                        (ex_rd == 5'b0) && (ex_rs1 == 5'b0) && !priv_mode &&
                        csr_mstatus_tw;

    // WFI with invalid rd/rs1 fields: trap as illegal instruction
    wire ex_bad_wfi = ifex_valid && (ifex_instr[31:25] == 7'b0001000) &&
                      (ex_opcode == 7'b1110011) && (ex_funct3 == 3'b000) &&
                      (ifex_instr[24:20] == 5'b00101) &&
                      !(ex_rd == 5'b0 && ex_rs1 == 5'b0);

    // Bad SYSTEM encoding: controller recognized the funct7 family but the full
    // encoding doesn't match any valid instruction (wrong rd/rs1/rs2 fields)
    wire ex_bad_system = ifex_valid && (ctrl_isEcall || ctrl_isEbreak || ctrl_isMret) &&
                         !(ex_is_ecall || ex_is_ebreak || ex_is_mret);

    // CSR access validation (Zicsr spec):
    //   - Access to non-existent CSR → illegal instruction
    //   - Write to read-only CSR → illegal instruction
    //   - CSRRS/CSRRC with rs1=0 and CSRRSI/CSRRCI with uimm=0 are read-only
    //     operations, so they do NOT trap even for read-only CSRs.
    wire ex_csr_active = (ctrl_csrOp != 2'b00);
    wire ex_csr_writes = ex_csr_active && (
        ctrl_csrOp == 2'b01 ||   // CSRRW/CSRRWI always write
        ex_rs1 != 5'b0            // CSRRS/CSRRC write only if rs1/uimm != 0
    );
    wire ex_csr_readonly = (ex_csr_addr[11:10] == 2'b11);
    // CSR access requires privilege >= csr_addr[9:8] (00=U, 01=S, 11=M).
    // Since we only have M(1) and U(0): any CSR with addr[9:8] != 00 requires M-mode.
    wire ex_csr_priv_fail = !priv_mode && (ex_csr_addr[9:8] != 2'b00);
    wire ex_csr_illegal = ifex_valid && ex_csr_active && (
        !csr_addr_valid ||                     // Non-existent CSR
        (ex_csr_writes && ex_csr_readonly) ||  // Write to read-only CSR
        ex_csr_priv_fail                       // Insufficient privilege
    );

    // Misalignment detection on computed address (ALU result)
    // RISC-V: LH/SH require 2-byte alignment, LW/SW require 4-byte alignment.
    // Atomics (LR/SC/AMO) always require 4-byte alignment.
    // Rather than silently aliasing to an aligned address, trap per spec.
    wire ex_mem_active = ctrl_memRD || ctrl_memWR || ctrl_isAmo || ctrl_isLR || ctrl_isSC;
    wire ex_misaligned_half = (ctrl_memSize == 2'b01) && (ex_alu_result[0] != 1'b0);
    wire ex_misaligned_word = (ctrl_memSize == 2'b10) && (ex_alu_result[1:0] != 2'b00);
    wire ex_misaligned = ifex_valid && ex_mem_active &&
                         (ex_misaligned_half || ex_misaligned_word);
    wire ex_misalign_is_store = ctrl_memWR || ctrl_isSC || ctrl_isAmo;

    // Instruction-address-misaligned: branch/jump target must be 4-byte aligned
    // when misa.C=0. When C enabled, target[0]==0 is enforced by encoding.
    // (Unprivileged spec, RV32I control transfer: the exception is reported on
    // the branch/jump, not on the target instruction.)
    wire ex_inst_misalign = ifex_valid && ex_branch_taken &&
                            !csr_misa_c && ex_branch_target[1];

    // PMA check: is there a device at this address at all?
    // Fetch is restricted to RAM -- executing out of the CLINT is an
    // instruction access fault here. The reference model does NOT do this: it
    // reads the device and reports an illegal instruction (cause 2) with the
    // fetched bits in mtval. Cause 1 is the defensible hardware behaviour, so
    // this is a deliberate divergence, not an oversight.
    wire ex_pma_fetch_ok = (ifex_pc >= PMA_MEM_BASE) && (ifex_pc <= PMA_MEM_TOP);
    // A window with BASE > TOP matches nothing, which is how the testbench
    // switches off the ports the simulation does not model.
    wire ex_pma_in_mem = (ex_alu_result >= PMA_MEM_BASE) &&
                         (ex_alu_result <= PMA_MEM_TOP);
    wire ex_pma_in_io  = ((ex_alu_result >= PMA_IO0_BASE) &&
                          (ex_alu_result <= PMA_IO0_TOP))  ||
                         ((ex_alu_result >= PMA_IO1_BASE) &&
                          (ex_alu_result <= PMA_IO1_TOP));
    // LR/SC need a reservation set, which only main memory can provide -- an
    // IO window is not idempotent and has no reservation set to track. The
    // reference model agrees: its reservable() covers memory only, so lr.w and
    // sc.w on the CLINT fault while amoadd.w there succeeds.
    wire ex_pma_data_ok  = ex_pma_in_mem ||
                           (ex_pma_in_io && !ctrl_isLR && !ctrl_isSC);

    // Access-fault detection. Two independent reasons to refuse an access:
    // PMP says the permissions deny it, or the PMA says nothing is mapped
    // there. Both raise the same causes (1 / 5 / 7), so they are combined
    // here rather than at every use site.
    // (uses forward-declared pmp_ifetch_allow / pmp_data_allow)
    wire ex_ifetch_fault = ifex_valid && (!pmp_ifetch_allow || !ex_pma_fetch_ok);
    // Data side: only when a memory op is present and it's not already misaligned
    wire ex_data_fault   = ifex_valid && ex_mem_active && !ex_misaligned &&
                           (!pmp_data_allow || !ex_pma_data_ok);

    // Illegal instruction (cause 2). Collected into one signal so the trap
    // cause chain can test it in its spec-mandated priority position rather
    // than reaching it as the fallthrough case.
    wire ex_illegal_insn = ifex_valid && (
        (ctrl_illegal && !ctrl_isFence) ||
        ifex_c_illegal ||              // Illegal compressed instruction from IF
        ex_bad_system ||               // Malformed SYSTEM encoding
        ex_wfi_umode ||                // WFI from U-mode (illegal)
        ex_bad_wfi ||                  // WFI with bad rd/rs1 fields
        ex_csr_illegal                 // Invalid/read-only CSR access
    );

    // Trap detection
    wire ex_trap = ifex_valid && (
        ex_is_ecall || ex_is_ebreak ||
        ex_ifetch_fault ||             // Instruction access fault (PMP or PMA)
        ex_illegal_insn ||             // Illegal instruction
        ex_misaligned ||               // Misaligned memory access
        ex_data_fault ||               // Load/store access fault (PMP or PMA)
        ex_inst_misalign               // Instruction address misaligned (branch target)
    );

    // ================================================================
    //  Hazard Detection
    // ================================================================

    // Load-use hazard: WB stage has a load and EX needs the result
    wire load_use_hazard = exwb_valid && exwb_memRD &&
                           exwb_rd != 5'b0 &&
                           (exwb_rd == ex_rs1 || exwb_rd == ex_rs2);

    // WB busy (AMO second cycle)
    reg wb_busy;

    // Memory handshake stalls:
    //   - IF stall: instruction memory not ready (multi-cycle fetch)
    //   - WB stall: data memory not ready during active load/store
    wire if_mem_stall = !imem_ready;
    // !exwb_trap: a trapping load/store never reaches the bus, so there is no
    // handshake to wait for and the EX/WB hold below must not engage.
    // A failing SC is included — it stalls without accessing memory, which
    // costs cycles but is harmless; the core has no request strobe the memory
    // could use to tell the two apart.
    wire wb_mem_stall = exwb_valid && !exwb_trap &&
                        (exwb_memRD || exwb_memWR) && !dmem_ready;

    // flush is defined before stall so muldiv_start can reference it without
    // a forward reference (iverilog processes wire assignments linearly).
    wire flush = ex_branch_taken || ex_is_mret || ex_trap || ex_is_fencei || irq_inject;

    // stall_other: all stall sources except muldiv (used to gate muldiv_start)
    // wfi_active stalls the pipeline until an interrupt becomes pending.
    wire stall_other = load_use_hazard || wb_busy || if_mem_stall || wb_mem_stall || wfi_active;

    // muldiv stall logic (see muldiv instantiation in EX section above):
    //   muldiv_start: pulse for one cycle to launch a new M-ext operation.
    //   muldiv_stall: keep pipeline frozen while muldiv is working.
    //                 When muldiv_done fires, stall drops so the pipeline advances
    //                 and captures muldiv_result into exwb_alu_result this cycle.
    // !ex_trap: a trapping M instruction (a fetch fault whose garbage word
    // decodes as MUL/DIV, say) never starts -- muldiv_start is gated on
    // flush, which contains ex_trap -- so without this muldiv_stall would
    // wait for a result that never comes and the trap would never commit.
    // ex_trap depends on neither stall nor flush, so this closes no loop.
    wire muldiv_want = ifex_valid && ctrl_isMulDiv && !ex_trap;

    // Sticky completion. muldiv_done is a one-cycle pulse; holding it here
    // means the pipeline can take the result on whatever later cycle it is
    // able to, instead of losing it if that one cycle happened to be stalled.
    reg  muldiv_ready;
    // The result is available from the done cycle itself, not only from the
    // cycle after it. muldiv.v drops busy on the done cycle, and muldiv_ready
    // is only set at its end, so testing muldiv_ready alone leaves the done
    // cycle looking idle: muldiv_start fired again and relaunched the same
    // operation, and that phantom's done later set muldiv_ready for the
    // *next* M instruction, which then captured the previous result.
    wire muldiv_have = muldiv_ready || muldiv_done;
    // The cycle EX/WB actually captures muldiv_result into exwb_alu_result.
    wire muldiv_capture = muldiv_want && muldiv_have && !stall_other && !flush;

    assign muldiv_start = muldiv_want && !muldiv_busy && !muldiv_have
                          && !stall_other && !flush;
    assign muldiv_stall = muldiv_want && !muldiv_have;

    always @(posedge clk) begin
        // flush first: the operation's instruction is being discarded, so the
        // result must not survive to be captured by its own re-execution.
        // capture before done: a result taken on its own done cycle must not
        // be left sticky for the next M instruction.
        if (rst || flush)        muldiv_ready <= 1'b0;
        else if (muldiv_capture) muldiv_ready <= 1'b0;
        else if (muldiv_done)    muldiv_ready <= 1'b1;
    end

    wire stall = stall_other || muldiv_stall;

    // MRET commit point.
    //
    // ex_is_mret is a combinational EX decode with no stall qualifier, and
    // csr.v applies the entire MRET mstatus update on every cycle its `mret`
    // input is high. Across a two-cycle stall that runs twice: the first pass
    // sets MPIE=1, the second reloads MIE from that freshly-set MPIE, so MIE
    // ends up 1 where it should be 0. priv_mode meanwhile was already
    // !stall-gated, so it sampled an MPP csr.v had forced to 00 on the first
    // pass and the hart dropped to U-mode.
    //
    // Gating the commit the way fencei_flush already is makes it one-shot, and
    // because priv_mode now samples csr_mstatus_mpp on the same edge csr.v
    // updates mstatus, it sees the pre-update MPP.
    //
    // `flush` and next_pc deliberately keep using the ungated ex_is_mret: the
    // IF/EX bubble arm is only reached when !stall, and the redirect is
    // idempotent, so neither can commit twice.
    wire ex_mret_commit = ex_is_mret && !stall && !ex_trap;

    // ================================================================
    //  WB Stage — Memory Access + Writeback
    // ================================================================

    // AMO state machine
    reg        amo_phase; // 0=read, 1=write
    reg [31:0] amo_old_val;
    reg [31:0] amo_new_val;

    // LR/SC reservation
    reg        reservation_valid;
    reg [31:0] reservation_addr;
    wire       sc_success = reservation_valid && (reservation_addr == exwb_alu_result);

    // Memory address and alignment
    wire [31:0] mem_addr_aligned = {exwb_alu_result[31:2], 2'b00};
    wire [1:0]  mem_byte_offset  = exwb_alu_result[1:0];

    // Store data alignment
    reg [31:0] store_data_shifted;
    reg [3:0]  store_wmask;
    always @(*) begin
        store_data_shifted = 32'b0;
        store_wmask = 4'b0;
        case (exwb_memSize)
            2'b00: begin // SB
                store_data_shifted = {4{exwb_rs2_data[7:0]}};
                store_wmask = 4'b0001 << mem_byte_offset;
            end
            2'b01: begin // SH
                store_data_shifted = {2{exwb_rs2_data[15:0]}};
                store_wmask = (mem_byte_offset[1]) ? 4'b1100 : 4'b0011;
            end
            2'b10: begin // SW
                store_data_shifted = exwb_rs2_data;
                store_wmask = 4'b1111;
            end
            default: begin
                store_data_shifted = 32'b0;
                store_wmask = 4'b0;
            end
        endcase
    end

    // AMO write data (during amo_phase=1)
    wire [31:0] amo_write_data = amo_phase ? amo_new_val : store_data_shifted;
    wire [3:0]  amo_write_mask = amo_phase ? 4'b1111 : store_wmask;

    // Memory interface signals
    wire wb_mem_write = exwb_valid && !exwb_trap && (
        (exwb_memWR && !exwb_isAmo && !exwb_isSC) ||
        (exwb_isSC && sc_success) ||
        (exwb_isAmo && amo_phase)
    );

    assign dmem_addr  = mem_addr_aligned;
    assign dmem_wdata = (exwb_isAmo && amo_phase) ? amo_new_val : store_data_shifted;
    assign dmem_wmask = wb_mem_write ? ((exwb_isAmo && amo_phase) ? 4'b1111 : store_wmask) : 4'b0;
    assign dmem_we    = wb_mem_write;

    // Load data extraction and sign extension
    wire [31:0] raw_load = dmem_rdata;
    reg  [31:0] load_data;
    always @(*) begin
        case (exwb_memSize)
            2'b00: begin // LB/LBU
                case (mem_byte_offset)
                    2'b00: load_data = exwb_memUnsigned ? {24'b0, raw_load[7:0]}   : {{24{raw_load[7]}},  raw_load[7:0]};
                    2'b01: load_data = exwb_memUnsigned ? {24'b0, raw_load[15:8]}  : {{24{raw_load[15]}}, raw_load[15:8]};
                    2'b10: load_data = exwb_memUnsigned ? {24'b0, raw_load[23:16]} : {{24{raw_load[23]}}, raw_load[23:16]};
                    2'b11: load_data = exwb_memUnsigned ? {24'b0, raw_load[31:24]} : {{24{raw_load[31]}}, raw_load[31:24]};
                endcase
            end
            2'b01: begin // LH/LHU
                if (mem_byte_offset[1])
                    load_data = exwb_memUnsigned ? {16'b0, raw_load[31:16]} : {{16{raw_load[31]}}, raw_load[31:16]};
                else
                    load_data = exwb_memUnsigned ? {16'b0, raw_load[15:0]}  : {{16{raw_load[15]}}, raw_load[15:0]};
            end
            2'b10: // LW
                load_data = raw_load;
            default:
                load_data = 32'b0;
        endcase
    end

    // AMO computation
    reg [31:0] amo_computed;
    always @(*) begin
        case (exwb_amoOp)
            5'b00001: amo_computed = exwb_rs2_data;                    // AMOSWAP
            5'b00000: amo_computed = load_data + exwb_rs2_data;        // AMOADD
            5'b00100: amo_computed = load_data ^ exwb_rs2_data;        // AMOXOR
            5'b01100: amo_computed = load_data & exwb_rs2_data;        // AMOAND
            5'b01000: amo_computed = load_data | exwb_rs2_data;        // AMOOR
            5'b10000: amo_computed = ($signed(load_data) < $signed(exwb_rs2_data)) ? load_data : exwb_rs2_data; // AMOMIN
            5'b10100: amo_computed = ($signed(load_data) > $signed(exwb_rs2_data)) ? load_data : exwb_rs2_data; // AMOMAX
            5'b11000: amo_computed = (load_data < exwb_rs2_data) ? load_data : exwb_rs2_data; // AMOMINU
            5'b11100: amo_computed = (load_data > exwb_rs2_data) ? load_data : exwb_rs2_data; // AMOMAXU
            default:  amo_computed = 32'b0;
        endcase
    end

    // Writeback data mux
    wire [31:0] wb_alu_or_sc = exwb_isSC ? {31'b0, !sc_success} : exwb_alu_result;
    wire [31:0] wb_load_or_amo = (exwb_isAmo && amo_phase) ? amo_old_val : load_data;

    assign wb_data = (exwb_wbSel == 2'b00) ? wb_alu_or_sc :
                     (exwb_wbSel == 2'b01) ? wb_load_or_amo :
                     (exwb_wbSel == 2'b10) ? exwb_pc_next :
                     exwb_csr_rdata; // 2'b11

    // !wb_mem_stall: with EX/WB now held across a memory stall, writeback would
    // otherwise fire on every cycle of it, and a load would latch dmem_rdata
    // before the handshake completes.
    assign wb_regWR = exwb_valid && exwb_regWR && !exwb_trap &&
                      !(exwb_isAmo && !amo_phase) && // AMO writes rd on phase 1
                      !wb_mem_stall;
    assign wb_rd    = exwb_rd;

    wire [1:0]  csr_mstatus_mpp;
    wire [31:0] csr_pmpcfg0, csr_pmpaddr0, csr_pmpaddr1, csr_pmpaddr2, csr_pmpaddr3;

    // CSR unit
    wire        csr_trap_signal = exwb_valid && exwb_trap;
    wire        csr_mret_signal = 1'b0; // MRET handled via PC redirect in EX
    wire [31:0] csr_mtvec, csr_mepc;
    wire        csr_mstatus_mie;
    wire [31:0] csr_mie;            // full mie register (for per-bit IRQ gating)
    // csr_misa_c forward-declared at top of EX stage; driven by CSR unit port
    // csr_addr_valid is forward-declared at the top of EX stage; driven by CSR unit port

    csr #(.MARCHID_VAL(MARCHID)) csr_unit(
        .clk        (clk),
        .rst        (rst),
        .raddr      (ex_csr_addr),        // EX reads its own CSR address
        .waddr      (exwb_csr_addr),      // WB writes its own CSR address
        .wdata      (exwb_csr_wdata),
        .op         (exwb_valid && exwb_csrWR ? 2'b01 : 2'b00), // Always CSRRW: EX pre-computes value
        .we         (exwb_valid && exwb_csrWR && !exwb_trap),
        .rdata      (csr_rdata),
        .trap       (csr_trap_signal),
        .mret       (ex_mret_commit),
        .trap_pc    (exwb_trap_pc),
        .trap_cause (exwb_trap_cause),
        .trap_val   (exwb_trap_val),
        .priv_mode  (priv_mode),
        .mtvec_out  (csr_mtvec),
        .mepc_out   (csr_mepc),
        .instret_inc(exwb_valid && !exwb_trap && !wb_busy && !wb_mem_stall),
        .mstatus_mie(csr_mstatus_mie),
        .mstatus_mpp(csr_mstatus_mpp),
        .pmpcfg0_out (csr_pmpcfg0),
        .pmpaddr0_out(csr_pmpaddr0),
        .pmpaddr1_out(csr_pmpaddr1),
        .pmpaddr2_out(csr_pmpaddr2),
        .pmpaddr3_out(csr_pmpaddr3),
        .csr_addr_valid(csr_addr_valid),
        .timer_irq   (timer_irq),
        .external_irq(external_irq),
        .sw_irq      (sw_irq),
        .mie_out     (csr_mie),
        .misa_c        (csr_misa_c),
        .mstatus_tw    (csr_mstatus_tw),
        .mstatus_mprv  (csr_mstatus_mprv),
        .mtime_in    (mtime_in),
        // misa.C WARL gate: refuse C clear if next-PC[1]=1. csrrci/csrrw to
        // misa is always 32-bit (system opcode), so post-PC[1] = exwb_trap_pc[1].
        .pc_next_misaligned (exwb_trap_pc[1])
    );

    // ── Interrupt pending detection ──────────────────────────────────────────
    // Per spec §3.1.6.1: MIE only gates M-mode; U-mode interrupts always enabled
    // (no delegation in M+U only system). Priority: external(11) > sw(3) > timer(7).
    // Forward mstatus.MIE from WB to avoid 1-cycle window where an interrupt
    // slips in after csrci mstatus,8 (MIE 1→0) but before the write commits.
    wire mstatus_mie_eff = (exwb_valid && exwb_csrWR && !exwb_trap && exwb_csr_addr == 12'h300)
        ? (exwb_csr_wdata[3] != 1'b0)  // forwarded MIE bit
        : csr_mstatus_mie;
    wire irq_global_en     = !priv_mode || mstatus_mie_eff;
    wire irq_external_pend = external_irq & csr_mie[11] & irq_global_en;
    wire irq_sw_pend       = sw_irq       & csr_mie[3]  & irq_global_en;
    wire irq_timer_pend    = timer_irq    & csr_mie[7]  & irq_global_en;
    wire any_irq_pend      = irq_external_pend | irq_sw_pend | irq_timer_pend;

    // Select highest-priority pending IRQ cause (bit 31 = interrupt flag per spec)
    wire [31:0] irq_cause =
        irq_external_pend ? {1'b1, 31'd11} :  // Machine External Interrupt
        irq_sw_pend       ? {1'b1, 31'd3}  :  // Machine Software Interrupt
                            {1'b1, 31'd7};     // Machine Timer Interrupt

    // Gate interrupt injection:
    //   - Only when a valid instruction is in EX (gives clean mepc)
    //   - Never mid-muldiv (muldiv_busy)
    //   - Never when EX already has a synchronous trap (trap takes priority)
    //   - Never while the pipeline is stalled
    //
    // stall_other subsumes the old wb_busy and wfi_active terms and adds
    // load_use_hazard, if_mem_stall and wb_mem_stall. Without those, an
    // interrupt arriving during a memory stall was injected on every cycle of
    // it: the second injection latched MPIE from the MIE the first had already
    // cleared, so the following MRET restored MIE=0 and the hart never took
    // another interrupt. It also tore down an in-flight memory access, because
    // the injection path overrides the EX/WB hold.
    //
    // muldiv_stall is deliberately NOT used here. It feeds muldiv_start, which
    // is gated on flush, which contains irq_inject -- taking `stall` would
    // close a combinational loop. muldiv_busy covers every cycle of a multiply
    // except the first, and on that first cycle muldiv_start is itself
    // suppressed by flush, so the operation never starts.
    assign irq_inject = any_irq_pend && ifex_valid && !ex_trap
                      && !muldiv_want && !stall_other;

    // WFI wake conditions (spec §3.3.3: implementation may wake on any condition):
    //   (a) An individually-enabled interrupt source fires (regardless of MIE global bit).
    //   (b) No interrupt sources are individually enabled in mie → WFI degenerates to NOP.
    //       This prevents WFI from stalling forever when mie=0 (e.g. during M-mode tests
    //       that don't set up any interrupt enables). The spec explicitly permits treating
    //       WFI as NOP.
    wire wfi_has_enabled_irq = csr_mie[7] | csr_mie[3] | csr_mie[11]; // MTIE|MSIE|MEIE
    wire wfi_wake = (timer_irq & csr_mie[7]) | (sw_irq & csr_mie[3]) |
                    (external_irq & csr_mie[11]) |
                    !wfi_has_enabled_irq;  // NOP when no sources enabled

    // ── PMP checks ───────────────────────────────────────────────────────────
    // pmp_ifetch_allow and pmp_data_allow are forward-declared near top of EX stage.
    // Instruction fetch: check ifex_pc with Execute permission (EX stage).
    pmp pmp_ifetch(
        .pmpcfg0    (csr_pmpcfg0),
        .pmpaddr0   (csr_pmpaddr0),
        .pmpaddr1   (csr_pmpaddr1),
        .pmpaddr2   (csr_pmpaddr2),
        .pmpaddr3   (csr_pmpaddr3),
        .addr       (ifex_pc),
        .access_type(3'b100),       // Execute
        .priv_mode  (priv_mode),
        .pmp_allow  (pmp_ifetch_allow)
    );

    // Data access: check ex_alu_result with R or W permission (EX stage, address ready).
    wire [2:0] ex_pmp_access_type = ctrl_isAmo           ? 3'b011 : // AMO: R+W
                                     ex_misalign_is_store ? 3'b010 : // Store/SC: W
                                     3'b001;                          // Load/LR: R
    // MPRV=1 makes loads and stores check as though the hart were in MPP.
    // Instruction fetch is excluded by the spec, so pmp_ifetch keeps priv_mode.
    //
    // These are consumed here in EX, but a csrw to mstatus does not commit
    // until WB, so without forwarding the load or store in the instruction
    // immediately after `csrw mstatus` would be checked against the stale
    // MPRV/MPP. Zicsr requires the write's effects to be observable by the
    // very next instruction, so forward the pending write the same way
    // csr_fwd_data already does for CSR reads.
    wire mstatus_wb_wr = exwb_valid && exwb_csrWR && !exwb_trap &&
                         (exwb_csr_addr == 12'h300);
    wire [1:0] mstatus_wb_mpp =
        (exwb_csr_wdata[12:11] == 2'b11 || exwb_csr_wdata[12:11] == 2'b00)
            ? exwb_csr_wdata[12:11] : csr_mstatus_mpp;
    wire       eff_mprv = mstatus_wb_wr ? exwb_csr_wdata[17] : csr_mstatus_mprv;
    wire [1:0] eff_mpp  = mstatus_wb_wr ? mstatus_wb_mpp     : csr_mstatus_mpp;
    wire data_priv_mode = eff_mprv ? (eff_mpp == 2'b11) : priv_mode;

    pmp pmp_data(
        .pmpcfg0    (csr_pmpcfg0),
        .pmpaddr0   (csr_pmpaddr0),
        .pmpaddr1   (csr_pmpaddr1),
        .pmpaddr2   (csr_pmpaddr2),
        .pmpaddr3   (csr_pmpaddr3),
        .addr       (ex_alu_result),
        .access_type(ex_pmp_access_type),
        .priv_mode  (data_priv_mode),
        .pmp_allow  (pmp_data_allow)
    );

    // CSR forwarding: when WB writes the same CSR that EX reads, forward the write value.
    // Apply the same per-CSR masking that csr.v applies on write, so the forwarded value
    // matches what will actually be read back.
    //
    // PMP lock suppression: if the write targets a locked PMP address, csr.v silently
    // discards it. Don't forward in that case — let EX read the register directly.
    // TOR locking: entry i+1 with A=TOR and L=1 also locks pmpaddr[i].
    wire pmp_fwd_blocked =
        (exwb_csr_addr == 12'h3B0 && (csr_pmpcfg0[7]  || (csr_pmpcfg0[12:11] == 2'b01 && csr_pmpcfg0[15]))) ||
        (exwb_csr_addr == 12'h3B1 && (csr_pmpcfg0[15] || (csr_pmpcfg0[20:19] == 2'b01 && csr_pmpcfg0[23]))) ||
        (exwb_csr_addr == 12'h3B2 && (csr_pmpcfg0[23] || (csr_pmpcfg0[28:27] == 2'b01 && csr_pmpcfg0[31]))) ||
        (exwb_csr_addr == 12'h3B3 && csr_pmpcfg0[31]);
    wire csr_fwd = exwb_valid && exwb_csrWR && !exwb_trap &&
                   (exwb_csr_addr == ex_csr_addr) && !pmp_fwd_blocked;
    // For pmpcfg0, locked bytes are preserved — forward the post-mask value.
    // Also mask reserved A=2'b10 to 2'b00 (WARL) to match csr.v write behavior.
    wire [7:0] pmp_fwd_byte0 = csr_pmpcfg0[7]  ? csr_pmpcfg0[7:0]   :
        {exwb_csr_wdata[7], 2'b00, exwb_csr_wdata[4:0]};
    wire [7:0] pmp_fwd_byte1 = csr_pmpcfg0[15] ? csr_pmpcfg0[15:8]   :
        {exwb_csr_wdata[15], 2'b00, exwb_csr_wdata[12:8]};
    wire [7:0] pmp_fwd_byte2 = csr_pmpcfg0[23] ? csr_pmpcfg0[23:16] :
        {exwb_csr_wdata[23], 2'b00, exwb_csr_wdata[20:16]};
    wire [7:0] pmp_fwd_byte3 = csr_pmpcfg0[31] ? csr_pmpcfg0[31:24] :
        {exwb_csr_wdata[31], 2'b00, exwb_csr_wdata[28:24]};
    wire [31:0] pmpcfg0_fwd_val = {pmp_fwd_byte3, pmp_fwd_byte2, pmp_fwd_byte1, pmp_fwd_byte0};
    // mstatus WARL forward: MPP coercion preserves old [12:11] when new is illegal.
    wire [1:0] mstatus_fwd_mpp =
        (exwb_csr_wdata[12:11] == 2'b11 || exwb_csr_wdata[12:11] == 2'b00)
            ? exwb_csr_wdata[12:11] : csr_unit.mstatus[12:11];
    wire [31:0] mstatus_fwd_val =
        (csr_unit.mstatus & ~32'h0022_1888)
        | (exwb_csr_wdata & 32'h0022_0088)
        | {19'b0, mstatus_fwd_mpp, 11'b0};
    // misa forward: only C(2) writable; refused when clearing C and post-PC misaligned.
    wire misa_clear_refused = !exwb_csr_wdata[2] && exwb_trap_pc[1];
    wire misa_eff_c         = misa_clear_refused ? 1'b1 : exwb_csr_wdata[2];
    wire [31:0] misa_fwd_val = 32'h4010_1101 | {29'b0, misa_eff_c, 2'b00};
    wire [31:0] csr_fwd_data =
        (exwb_csr_addr == 12'h300) ? mstatus_fwd_val :
        (exwb_csr_addr == 12'h301) ? misa_fwd_val :
        (exwb_csr_addr == 12'h304) ? (exwb_csr_wdata & 32'h0000_0888) : // mie
        (exwb_csr_addr == 12'h305) ? {exwb_csr_wdata[31:2], 2'b00} :    // mtvec: force direct mode
        (exwb_csr_addr == 12'h306) ? (exwb_csr_wdata & 32'h0000_0007) : // mcounteren: CY/TM/IR
        (exwb_csr_addr == 12'h320) ? (exwb_csr_wdata & 32'h0000_0005) : // mcountinhibit: TM reserved
        (exwb_csr_addr == 12'h344) ? (exwb_csr_wdata & ~32'h0000_0888) : // mip: writable bits
        // mepc: bit 0 always 0, and bit 1 reads 0 while IALIGN=32 (misa.C=0),
        // which is the same masking csr.v applies on the read port.
        (exwb_csr_addr == 12'h341) ?
            {exwb_csr_wdata[31:2], (csr_misa_c ? exwb_csr_wdata[1] : 1'b0), 1'b0} :
        (exwb_csr_addr == 12'h3A0) ? pmpcfg0_fwd_val :                   // pmpcfg0: respect locks + A mask
        exwb_csr_wdata;
    assign csr_rdata_eff = csr_fwd ? csr_fwd_data : csr_rdata;

    // ================================================================
    //  PC Update Logic
    // ================================================================
    // Forward mtvec/mepc from WB CSR write to avoid stale redirect targets.
    // Without this, sequences like "csrw mepc, t5; mret" read the old mepc
    // because the WB write hasn't committed when EX computes next_pc.
    wire mtvec_fwd = exwb_valid && exwb_csrWR && !exwb_trap && (exwb_csr_addr == 12'h305);
    wire mepc_fwd  = exwb_valid && exwb_csrWR && !exwb_trap && (exwb_csr_addr == 12'h341);
    wire [31:0] trap_target = mtvec_fwd ? {exwb_csr_wdata[31:2], 2'b00} : csr_mtvec;
    // Priv spec §3.1.15: mepc[1] masks to 0 on reads when IALIGN=32 (misa.C=0).
    wire [31:0] mret_target = mepc_fwd  ?
        {exwb_csr_wdata[31:2], (csr_misa_c ? exwb_csr_wdata[1] : 1'b0), 1'b0} :
        csr_mepc;

    reg [31:0] next_pc;
    always @(*) begin
        if (ex_trap)
            next_pc = trap_target;
        else if (irq_inject)
            // Interrupt: redirect to mtvec; mepc will hold ifex_pc so the
            // interrupted instruction re-executes after MRET.
            next_pc = trap_target;
        else if (ex_is_mret)
            next_pc = mret_target;
        else if (ex_branch_taken && ifex_valid && !stall)
            next_pc = ex_branch_target;
        else if (ex_is_fencei && ifex_valid && !stall)
            next_pc = ifex_pc_next; // Re-fetch instruction after FENCE.I
        else if (stall)
            next_pc = pc;
        else
            next_pc = if_pc_next;
    end

    // ================================================================
    //  FENCE.I flush output
    // ================================================================
    // Asserted for exactly one cycle when a FENCE.I instruction completes
    // in the EX stage (not stalled, not already flushed by something else).
    assign fencei_flush = ex_is_fencei && !stall;

    // ================================================================
    //  Debug / Trace outputs
    // ================================================================
    assign dbg_pc         = exwb_valid ? exwb_trap_pc : 32'b0;
    assign dbg_retired    = exwb_valid && !wb_busy && !exwb_trap && !wb_mem_stall;
    assign dbg_instr      = exwb_raw_instr;
    assign dbg_compressed = exwb_compressed;
    assign dbg_trap       = exwb_valid && exwb_trap;

    // ================================================================
    //  Pipeline Register Updates
    // ================================================================
    always @(posedge clk) begin
        if (rst) begin
            pc        <= RESET_PC;
            priv_mode <= 1'b1; // Boot in M-mode
            // IF/EX
            ifex_pc        <= 32'b0;
            ifex_instr     <= 32'h0000_0013; // NOP
            ifex_raw_instr <= 32'h0000_0013;
            ifex_compressed<= 1'b0;
            ifex_pc_next   <= 32'b0;
            ifex_valid     <= 1'b0;
            ifex_c_illegal <= 1'b0;
            // EX/WB
            exwb_alu_result <= 32'b0;
            exwb_rs2_data   <= 32'b0;
            exwb_pc_next    <= 32'b0;
            exwb_rd         <= 5'b0;
            exwb_regWR      <= 1'b0;
            exwb_memRD      <= 1'b0;
            exwb_memWR      <= 1'b0;
            exwb_memSize    <= 2'b0;
            exwb_memUnsigned<= 1'b0;
            exwb_wbSel      <= 2'b0;
            exwb_valid      <= 1'b0;
            exwb_csrWR      <= 1'b0;
            exwb_csr_addr   <= 12'b0;
            exwb_csr_wdata  <= 32'b0;
            exwb_csr_rdata  <= 32'b0;
            exwb_isAmo      <= 1'b0;
            exwb_isLR       <= 1'b0;
            exwb_isSC       <= 1'b0;
            exwb_amoOp      <= 5'b0;
            exwb_trap       <= 1'b0;
            exwb_trap_cause <= 32'b0;
            exwb_trap_pc    <= 32'b0;
            exwb_trap_val   <= 32'b0;
            exwb_instr      <= 32'h0000_0013;
            exwb_raw_instr  <= 32'h0000_0013;
            exwb_compressed <= 1'b0;
            // AMO
            amo_phase      <= 1'b0;
            amo_old_val    <= 32'b0;
            amo_new_val    <= 32'b0;
            wb_busy        <= 1'b0;
            // WFI
            wfi_active        <= 1'b0;
            // Reservation
            reservation_valid <= 1'b0;
            reservation_addr  <= 32'b0;
        end else begin
            // ---- PC ----
            pc <= next_pc;

            // ---- Privilege mode update ----
            // Trap (WB stage): always enter M-mode
            // IRQ inject (EX stage): always enter M-mode
            // MRET (EX stage): restore from MPP, sampled on the same edge csr.v
            //   applies its update, so this is the pre-update MPP
            // Otherwise: hold current privilege
            if (csr_trap_signal)
                priv_mode <= 1'b1;                              // trap/interrupt → M-mode
            else if (ex_mret_commit)
                priv_mode <= (csr_mstatus_mpp == 2'b11);       // restore from MPP

            // ---- WFI stall management ----
            // Set wfi_active when WFI reaches EX and is not otherwise stalled/flushed.
            // Clear when an enabled interrupt source becomes pending (even if MIE=0).
            if (ex_is_wfi && !ex_trap && !stall && !flush)
                wfi_active <= 1'b1;
            else if (wfi_wake || irq_inject)
                wfi_active <= 1'b0;

            // ---- IF/EX Pipeline Register ----
            if (stall) begin
                // Hold IF/EX on stall
            end else if (flush) begin
                // Insert bubble
                ifex_valid     <= 1'b0;
                ifex_instr     <= 32'h0000_0013; // NOP
                ifex_raw_instr <= 32'h0000_0013;
                ifex_compressed<= 1'b0;
                ifex_c_illegal <= 1'b0;
            end else begin
                ifex_pc        <= pc;
                ifex_instr     <= if_instr;
                ifex_raw_instr <= if_compressed ? {16'h0, if_fetched[15:0]} : if_fetched;
                ifex_compressed<= if_compressed;
                ifex_pc_next   <= if_pc_next;
                ifex_valid     <= 1'b1;
                // Compressed encoding while misa.C=0 → illegal-instruction trap.
                ifex_c_illegal <= if_compressed && (if_c_illegal || !csr_misa_c);
            end

            // ---- EX/WB Pipeline Register ----
            if (wb_busy) begin
                // AMO phase transition: read → write
                if (exwb_isAmo && !amo_phase && dmem_ready) begin
                    amo_phase   <= 1'b1;
                    amo_old_val <= load_data;
                    amo_new_val <= amo_computed;
                    wb_busy     <= 1'b0; // Release pipeline next cycle
                end
            end else if (wb_mem_stall && !irq_inject) begin
                // Hold EX/WB while the data-memory access is still on the bus.
                // Bubbling here would drop exwb_memRD/exwb_memWR and so
                // withdraw dmem_addr/dmem_we before dmem_ready — the
                // transaction is lost, and because wb_mem_stall is derived
                // from those same bits the stall self-clears and nothing
                // retries it. Every other stall source still bubbles: by then
                // the WB instruction has committed, and holding it would
                // commit it a second time.
            end else if (stall && !irq_inject) begin
                // Insert bubble into EX/WB on stall (but not when irq_inject overrides)
                exwb_valid  <= 1'b0;
                exwb_regWR  <= 1'b0;
                exwb_memRD  <= 1'b0;
                exwb_memWR  <= 1'b0;
                exwb_csrWR  <= 1'b0;
                exwb_isAmo  <= 1'b0;
                exwb_isLR   <= 1'b0;
                exwb_isSC   <= 1'b0;
                exwb_trap   <= 1'b0;
                exwb_trap_val <= 32'b0;
            end else begin
                // For M-ext ops, use the muldiv result; for all others, use the ALU result.
                exwb_alu_result <= ctrl_isMulDiv ? muldiv_result : ex_alu_result;
                exwb_rs2_data   <= ex_rs2_val;
                exwb_pc_next    <= ifex_pc_next;
                exwb_rd         <= ex_rd;
                exwb_regWR      <= ctrl_regWR;
                exwb_memRD      <= ctrl_memRD;
                exwb_memWR      <= ctrl_memWR;
                exwb_memSize    <= ctrl_memSize;
                exwb_memUnsigned<= ctrl_memUnsigned;
                exwb_wbSel      <= ctrl_wbSel;
                exwb_valid      <= ifex_valid;
                exwb_csrWR      <= ex_csr_writes; // No write for CSRRS/CSRRC when rs1=0
                exwb_csr_addr   <= ex_csr_addr;
                exwb_csr_wdata  <= ex_csr_wdata;
                exwb_csr_rdata  <= csr_rdata_eff;
                exwb_isAmo      <= ctrl_isAmo;
                exwb_isLR       <= ctrl_isLR;
                exwb_isSC       <= ctrl_isSC;
                exwb_amoOp      <= ctrl_amoOp;
                exwb_instr      <= ifex_instr;
                exwb_raw_instr  <= ifex_raw_instr;
                exwb_compressed <= ifex_compressed;
                exwb_trap_pc    <= ifex_pc;

                // Trap cause and mtval assignment
                // Priority: synchronous trap > async interrupt injection
                if (ex_trap) begin
                    exwb_trap <= 1'b1;
                    if (ex_ifetch_fault) begin
                        exwb_trap_cause <= 32'd1;  // Instruction access fault (highest priority)
                        exwb_trap_val   <= ifex_pc; // faulting fetch address
                    end else if (ex_illegal_insn) begin
                        // Priv spec v1.12 Table 3.7: illegal instruction ranks
                        // directly below instruction access fault, above the
                        // address-misaligned and access-fault causes.
                        exwb_trap_cause <= 32'd2;  // Illegal instruction
                        // Priv spec §3.1.16 permits 0 or the faulting encoding;
                        // report the encoding, which is what the reference
                        // model does. ifex_raw_instr is the 16-bit halfword for
                        // a compressed instruction and the full word otherwise.
                        exwb_trap_val   <= ifex_raw_instr;
                    end else if (ex_inst_misalign) begin
                        exwb_trap_cause <= 32'd0;  // Instruction address misaligned
                        exwb_trap_val   <= ex_branch_target;
                    end else if (ex_is_ecall) begin
                        exwb_trap_cause <= priv_mode ? 32'd11 : 32'd8; // M-mode=11, U-mode=8
                        exwb_trap_val   <= 32'b0;
                    end else if (ex_is_ebreak) begin
                        exwb_trap_cause <= 32'd3;  // Breakpoint
                        // Priv spec §3.1.16: on a breakpoint trap mtval holds the
                        // address of the EBREAK instruction itself.
                        exwb_trap_val   <= ifex_pc;
                    end else if (ex_misaligned && !ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd4;  // Load address misaligned
                        exwb_trap_val   <= ex_alu_result;
                    end else if (ex_misaligned && ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd6;  // Store/AMO address misaligned
                        exwb_trap_val   <= ex_alu_result;
                    end else if (ex_data_fault && !ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd5;  // Load access fault
                        exwb_trap_val   <= ex_alu_result;
                    end else begin
                        // Only ex_data_fault on a store is left in ex_trap.
                        exwb_trap_cause <= 32'd7;  // Store/AMO access fault
                        exwb_trap_val   <= ex_alu_result;
                    end
                end else if (irq_inject) begin
                    // Asynchronous interrupt: suppress instruction effects, inject trap
                    exwb_trap       <= 1'b1;
                    exwb_trap_cause <= irq_cause;
                    exwb_trap_val   <= 32'b0;
                    // mepc: if interrupted instruction is WFI, advance past it so MRET
                    // doesn't re-execute WFI. For all other instructions, point to the
                    // instruction itself so it re-executes after MRET.
                    exwb_trap_pc    <= ex_is_wfi ? ifex_pc_next : ifex_pc;
                    exwb_valid      <= 1'b1;
                    exwb_regWR      <= 1'b0;  // suppress writeback
                    exwb_memRD      <= 1'b0;
                    exwb_memWR      <= 1'b0;
                    exwb_csrWR      <= 1'b0;
                    exwb_isAmo      <= 1'b0;
                    exwb_isLR       <= 1'b0;
                    exwb_isSC       <= 1'b0;
                end else begin
                    exwb_trap     <= 1'b0;
                    exwb_trap_val <= 32'b0;
                end

                // AMO: enter busy state on first cycle
                if (ifex_valid && ctrl_isAmo && !flush) begin
                    wb_busy   <= 1'b1;
                    amo_phase <= 1'b0;
                end else begin
                    amo_phase <= 1'b0;
                end
            end

            // ---- LR/SC Reservation Management ----
            // !wb_mem_stall: the reservation follows the memory access, so it
            // must not be set or cleared until that access completes.
            if (exwb_valid && !exwb_trap && !wb_mem_stall) begin
                if (exwb_isLR) begin
                    reservation_valid <= 1'b1;
                    reservation_addr  <= exwb_alu_result;
                end else if (exwb_isSC) begin
                    reservation_valid <= 1'b0;
                end else if (exwb_memWR) begin
                    // Any local write overlapping the reservation invalidates
                    // it -- a plain store and an AMO alike. The `!exwb_isAmo`
                    // that used to be here made a store clear the reservation
                    // while an AMO to the same address did not, so two paths
                    // independently decided the same semantics and disagreed.
                    //
                    // Clearing on a same-hart write is not required (the
                    // must-fail list covers other harts and devices, not this
                    // one) but is explicitly permitted, and it cannot threaten
                    // the forward-progress guarantee: a constrained LR/SC
                    // sequence may not contain loads or stores between the LR
                    // and the SC, and an AMO is not in the base I set, so
                    // neither clear is reachable inside a constrained loop.
                    if (reservation_valid && reservation_addr == exwb_alu_result)
                        reservation_valid <= 1'b0;
                end
            end

            // Clear reservation on trap or interrupt. Not required by the
            // spec -- "H traps" is a listed satisfying event of the
            // eventuality guarantee, and a handler's loads, stores and SYSTEM
            // instructions take the sequence outside the constrained set,
            // where an implementation may fail an SC unconditionally. Kept as
            // defence in depth for bare-metal and bootloader code; Linux
            // additionally clears it in software with a dummy SC on every
            // exception return.
            //
            // There is deliberately no external-agent term: this SoC has a
            // single hart and no other bus master. Revisit if a debug module
            // with system-bus access is ever added.
            if (ex_trap || irq_inject)
                reservation_valid <= 1'b0;
        end
    end

endmodule
