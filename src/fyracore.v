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

module fyracore(
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

    // Forward declarations for wires assigned later in the CSR/WB section
    // (needed to break iverilog's forward-reference restriction)
    wire [31:0] csr_rdata_eff;   // driven by assign in CSR section
    wire        csr_addr_valid;  // driven by CSR unit output
    wire        pmp_ifetch_allow; // driven by pmp_ifetch instance
    wire        pmp_data_allow;   // driven by pmp_data instance
    wire        irq_inject;      // driven by interrupt detection logic in CSR/WB section

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

    // U-mode WFI: trap as illegal instruction
    wire ex_wfi_umode = ifex_valid && (ifex_instr[31:20] == 12'b000100000101) &&
                        (ex_opcode == 7'b1110011) && (ex_funct3 == 3'b000) &&
                        (ex_rd == 5'b0) && (ex_rs1 == 5'b0) && !priv_mode;

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

    // PMP fault detection (uses forward-declared pmp_ifetch_allow / pmp_data_allow)
    wire ex_pmp_ifetch_fail = ifex_valid && !pmp_ifetch_allow;
    // Data PMP: only when a memory op is present and it's not already misaligned
    wire ex_pmp_data_fail   = ifex_valid && ex_mem_active && !ex_misaligned && !pmp_data_allow;

    // Trap detection
    wire ex_trap = ifex_valid && (
        ex_is_ecall || ex_is_ebreak ||
        ex_pmp_ifetch_fail ||          // Instruction access fault (PMP)
        (ctrl_illegal && !ctrl_isFence) ||
        ifex_c_illegal ||              // Illegal compressed instruction from IF
        ex_bad_system ||               // Malformed SYSTEM encoding
        ex_wfi_umode ||                // WFI from U-mode (illegal)
        ex_bad_wfi ||                  // WFI with bad rd/rs1 fields
        ex_csr_illegal ||              // Invalid/read-only CSR access
        ex_misaligned ||               // Misaligned memory access
        ex_pmp_data_fail               // Load/store access fault (PMP)
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
    wire wb_mem_stall = exwb_valid && (exwb_memRD || exwb_memWR) && !dmem_ready;

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
    wire muldiv_want = ifex_valid && ctrl_isMulDiv;
    assign muldiv_start = muldiv_want && !muldiv_busy && !muldiv_done
                          && !stall_other && !flush;
    assign muldiv_stall = muldiv_want && (muldiv_start || muldiv_busy);

    wire stall = stall_other || muldiv_stall;

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

    assign wb_regWR = exwb_valid && exwb_regWR && !exwb_trap &&
                      !(exwb_isAmo && !amo_phase); // AMO writes rd on phase 1
    assign wb_rd    = exwb_rd;

    wire [1:0]  csr_mstatus_mpp;
    wire [31:0] csr_pmpcfg0, csr_pmpaddr0, csr_pmpaddr1, csr_pmpaddr2, csr_pmpaddr3;

    // CSR unit
    wire        csr_trap_signal = exwb_valid && exwb_trap;
    wire        csr_mret_signal = 1'b0; // MRET handled via PC redirect in EX
    wire [31:0] csr_mtvec, csr_mepc;
    wire        csr_mstatus_mie;
    wire [31:0] csr_mie;            // full mie register (for per-bit IRQ gating)
    // csr_addr_valid is forward-declared at the top of EX stage; driven by CSR unit port

    csr csr_unit(
        .clk        (clk),
        .rst        (rst),
        .raddr      (ex_csr_addr),        // EX reads its own CSR address
        .waddr      (exwb_csr_addr),      // WB writes its own CSR address
        .wdata      (exwb_csr_wdata),
        .op         (exwb_valid && exwb_csrWR ? 2'b01 : 2'b00), // Always CSRRW: EX pre-computes value
        .we         (exwb_valid && exwb_csrWR && !exwb_trap),
        .rdata      (csr_rdata),
        .trap       (csr_trap_signal),
        .mret       (ex_is_mret),
        .trap_pc    (exwb_trap_pc),
        .trap_cause (exwb_trap_cause),
        .trap_val   (exwb_trap_val),
        .priv_mode  (priv_mode),
        .mtvec_out  (csr_mtvec),
        .mepc_out   (csr_mepc),
        .instret_inc(exwb_valid && !exwb_trap && !wb_busy),
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
        .mtime_in    (mtime_in)
    );

    // ── Interrupt pending detection ──────────────────────────────────────────
    // Per spec §3.1.6.1: MIE only gates M-mode; U-mode interrupts always enabled
    // (no delegation in M+U only system). Priority: external(11) > sw(3) > timer(7).
    wire irq_global_en     = !priv_mode || csr_mstatus_mie;
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
    //   - Never mid-muldiv or mid-AMO (wb_busy)
    //   - Never when EX already has a synchronous trap (trap takes priority)
    //   - Never during WFI stall: WFI special-cases mepc advancement
    assign irq_inject = any_irq_pend && ifex_valid && !ex_trap
                      && !muldiv_busy && !wb_busy && !wfi_active;

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
    pmp pmp_data(
        .pmpcfg0    (csr_pmpcfg0),
        .pmpaddr0   (csr_pmpaddr0),
        .pmpaddr1   (csr_pmpaddr1),
        .pmpaddr2   (csr_pmpaddr2),
        .pmpaddr3   (csr_pmpaddr3),
        .addr       (ex_alu_result),
        .access_type(ex_pmp_access_type),
        .priv_mode  (priv_mode),
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
        {exwb_csr_wdata[7:5],  (exwb_csr_wdata[4:3]   == 2'b10 ? 2'b00 : exwb_csr_wdata[4:3]),   exwb_csr_wdata[2:0]};
    wire [7:0] pmp_fwd_byte1 = csr_pmpcfg0[15] ? csr_pmpcfg0[15:8]  :
        {exwb_csr_wdata[15:13],(exwb_csr_wdata[12:11]  == 2'b10 ? 2'b00 : exwb_csr_wdata[12:11]), exwb_csr_wdata[10:8]};
    wire [7:0] pmp_fwd_byte2 = csr_pmpcfg0[23] ? csr_pmpcfg0[23:16] :
        {exwb_csr_wdata[23:21],(exwb_csr_wdata[20:19]  == 2'b10 ? 2'b00 : exwb_csr_wdata[20:19]), exwb_csr_wdata[18:16]};
    wire [7:0] pmp_fwd_byte3 = csr_pmpcfg0[31] ? csr_pmpcfg0[31:24] :
        {exwb_csr_wdata[31:29],(exwb_csr_wdata[28:27]  == 2'b10 ? 2'b00 : exwb_csr_wdata[28:27]), exwb_csr_wdata[26:24]};
    wire [31:0] pmpcfg0_fwd_val = {pmp_fwd_byte3, pmp_fwd_byte2, pmp_fwd_byte1, pmp_fwd_byte0};
    wire [31:0] csr_fwd_data =
        (exwb_csr_addr == 12'h300) ? (exwb_csr_wdata & 32'h0000_1888) : // mstatus: writable mask
        (exwb_csr_addr == 12'h305) ? {exwb_csr_wdata[31:2], 2'b00} :    // mtvec: force direct mode
        (exwb_csr_addr == 12'h341) ? {exwb_csr_wdata[31:1], 1'b0} :     // mepc: bit 0 always 0
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
    wire [31:0] trap_target = mtvec_fwd ? exwb_csr_wdata : csr_mtvec;
    wire [31:0] mret_target = mepc_fwd  ? {exwb_csr_wdata[31:1], 1'b0} : csr_mepc;

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
    assign dbg_pc      = exwb_valid ? exwb_trap_pc : 32'b0;
    assign dbg_retired = exwb_valid && !wb_busy && !exwb_trap;
    assign dbg_instr   = exwb_instr;
    assign dbg_trap    = exwb_valid && exwb_trap;

    // ================================================================
    //  Pipeline Register Updates
    // ================================================================
    always @(posedge clk) begin
        if (rst) begin
            pc        <= 32'h0000_0000;
            priv_mode <= 1'b1; // Boot in M-mode
            // IF/EX
            ifex_pc        <= 32'b0;
            ifex_instr     <= 32'h0000_0013; // NOP
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
            // MRET (EX stage): restore from MPP (current mstatus[12:11] before CSR write clears it)
            // Otherwise: hold current privilege
            if (csr_trap_signal)
                priv_mode <= 1'b1;                              // trap/interrupt → M-mode
            else if (ex_is_mret && !stall)
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
                ifex_c_illegal <= 1'b0;
            end else begin
                ifex_pc        <= pc;
                ifex_instr     <= if_instr;
                ifex_pc_next   <= if_pc_next;
                ifex_valid     <= 1'b1;
                ifex_c_illegal <= if_compressed && if_c_illegal;
            end

            // ---- EX/WB Pipeline Register ----
            if (wb_busy) begin
                // AMO phase transition: read → write
                if (exwb_isAmo && !amo_phase) begin
                    amo_phase   <= 1'b1;
                    amo_old_val <= load_data;
                    amo_new_val <= amo_computed;
                    wb_busy     <= 1'b0; // Release pipeline next cycle
                end
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
                exwb_trap_pc    <= ifex_pc;

                // Trap cause and mtval assignment
                // Priority: synchronous trap > async interrupt injection
                if (ex_trap) begin
                    exwb_trap <= 1'b1;
                    if (ex_pmp_ifetch_fail) begin
                        exwb_trap_cause <= 32'd1;  // Instruction access fault (highest priority)
                        exwb_trap_val   <= ifex_pc; // faulting fetch address
                    end else if (ex_is_ecall) begin
                        exwb_trap_cause <= priv_mode ? 32'd11 : 32'd8; // M-mode=11, U-mode=8
                        exwb_trap_val   <= 32'b0;
                    end else if (ex_is_ebreak) begin
                        exwb_trap_cause <= 32'd3;  // Breakpoint
                        exwb_trap_val   <= 32'b0;
                    end else if (ex_misaligned && !ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd4;  // Load address misaligned
                        exwb_trap_val   <= ex_alu_result;
                    end else if (ex_misaligned && ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd6;  // Store/AMO address misaligned
                        exwb_trap_val   <= ex_alu_result;
                    end else if (ex_pmp_data_fail && !ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd5;  // Load access fault
                        exwb_trap_val   <= ex_alu_result;
                    end else if (ex_pmp_data_fail && ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd7;  // Store/AMO access fault
                        exwb_trap_val   <= ex_alu_result;
                    end else begin
                        exwb_trap_cause <= 32'd2;  // Illegal instruction
                        exwb_trap_val   <= ifex_instr;
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
            if (exwb_valid && !exwb_trap) begin
                if (exwb_isLR) begin
                    reservation_valid <= 1'b1;
                    reservation_addr  <= exwb_alu_result;
                end else if (exwb_isSC) begin
                    reservation_valid <= 1'b0;
                end else if (exwb_memWR && !exwb_isAmo) begin
                    // Any store to reservation address invalidates it
                    if (reservation_valid && reservation_addr == exwb_alu_result)
                        reservation_valid <= 1'b0;
                end
            end

            // Clear reservation on trap or interrupt
            if (ex_trap || irq_inject)
                reservation_valid <= 1'b0;
        end
    end

endmodule
