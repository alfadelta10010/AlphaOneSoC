// FyraCore — 3-stage pipelined RV32IMCA+Zicsr+Zifencei processor
//
// Pipeline stages:
//   IF  — Instruction Fetch; C-extension decompression; the numbers of the
//         registers the fetched instruction reads
//   EX  — Decode, Register Read, ALU Execute, Branch Resolve; three cycles
//         at least: the register file's (synchronous) read, the ALU and the
//         comparator, then what is decided from them (ex_rf_ok, ex_ph)
//   WB  — Memory Access, Writeback, CSR commit
//
// Hazard handling:
//   - A register the WB instruction writes is not forwarded: the EX
//     instruction that reads it waits and reads the register file (use_hazard)
//   - Branch/jump, ECALL/EBREAK/MRET, FENCE.I, PMP CSR write: no fetch
//     while it is in EX (ex_nofetch), 1-cycle bubble taken or not
//   - CSR write in WB: the next instruction waits one cycle (csr_wb_hazard)
//   - Fetch PMP check in U-mode or with a locked entry: one or two EX cycles
//   - M ops and shifts: multi-cycle in muldiv, started during the fetch wait
//   - AMO: 2-cycle WB (stall pipeline)

module fyracore #(
    // See csr.v: 0 means "no registered architecture ID". The testbench
    // overrides this to 5 so the Spike lockstep trace matches.
    parameter [31:0] MARCHID  = 32'h0000_0000,
    // Physical memory attributes -- the implemented address map.
    //
    // Anything outside these windows has no device behind it, so an access
    // raises an access fault (cause 1 / 5 / 7) rather than reaching the bus.
    // The defaults are the SoC's map (docs/soc-architecture.md):
    //
    //   0x2000_0000 - 0x20FF_FFFF  flash   16 MB  read, execute (QSPI CS0)
    //   0x8000_0000 - 0x80FF_FFFF  PSRAM   16 MB  read, write, execute,
    //                                             LR/SC (QSPI CS1 / CS2)
    //   0x0200_0000 - 0x0200_FFFF  CLINT   64 KB  data only
    //   0x1000_0000 - 0x1002_FFFF  UART / GPIO / syscon, data only
    //
    // Flash is read-only: a store, AMO or SC to it is a store access fault
    // and an LR a load access fault, because the QSPI engine has no flash
    // write path and flash has no reservation set. LR/SC need a reservation
    // set, which only PSRAM provides; IO windows take loads, stores and AMOs.
    // Fetch is allowed from flash and PSRAM only.
    //
    // A window with BASE > TOP matches nothing. The testbench uses that to
    // switch off the IO window the reference model has no device behind, and
    // widens the CLINT window to the aperture the reference model maps.
    parameter [31:0] PMA_ROM_BASE = 32'h2000_0000,  // flash
    parameter [31:0] PMA_ROM_TOP  = 32'h20FF_FFFF,
    parameter [31:0] PMA_RAM_BASE = 32'h8000_0000,  // PSRAM
    parameter [31:0] PMA_RAM_TOP  = 32'h80FF_FFFF,
    parameter [31:0] PMA_IO0_BASE = 32'h0200_0000,  // CLINT
    parameter [31:0] PMA_IO0_TOP  = 32'h0200_FFFF,
    parameter [31:0] PMA_IO1_BASE = 32'h1000_0000,  // UART, GPIO, syscon
    parameter [31:0] PMA_IO1_TOP  = 32'h1002_FFFF
)(
    input  wire        clk,
    input  wire        rst,
    // Reset vector: pc is loaded from this on every cycle rst is high, so it
    // only needs to be stable by the last one. The SoC ties it to the start
    // of flash; the core-level testbench starts in PSRAM, where Spike does.
    // Bit 0 is ignored: the pc, and so imem_addr, is always halfword-aligned.
    input  wire [31:0] boot_addr,
    // Memory interfaces: request/ready handshake.
    //
    // A request is outstanding on every cycle its *_req is high. From the
    // cycle it is raised until the cycle *_ready is sampled high with it,
    // the core holds the request's address (and for data: we, be and
    // wdata) stable; that ready cycle completes the transfer, and read data
    // is taken on it. The next request may start on the following cycle.
    // Nothing is transferred on a cycle with *_req low, whatever *_ready is.
    //
    // Instruction memory interface (read-only). imem_req is high whenever the
    // PC lies in an executable PMA window (PMA_ROM_*, PMA_RAM_*) and EX holds
    // no instruction that decides the next pc (ex_nofetch); outside them no fetch is requested at all (see
    // imem_req below). When the pipeline is stalled
    // with a fetch already completed, the same address is requested again.
    //
    // For the memory controller:
    //   - While a data request waits for dmem_ready the pipeline is stalled
    //     and imem_req stays up with the same address. A controller that
    //     shares one bus between the ports must not starve the data port --
    //     serve data first, or alternate -- and should keep the last fetched
    //     word so a repeated request for it completes without a new transfer.
    //   - A 32-bit fetch at the last halfword of a window asks for bytes
    //     past its end; any data may be returned for them (the core faults
    //     that instruction on the upper half).
    //   - imem_addr is the pc, so it is halfword-aligned, and the 4 bytes
    //     from it are wanted: imem_rdata[7:0] is the byte at imem_addr.
    //   - Store data is replicated across the byte lanes ({4{byte}},
    //     {2{half}}), so the first enabled byte of any store is also in
    //     dmem_wdata[7:0].
    output wire [31:0] imem_addr,
    output wire        imem_req,      // Fetch request
    input  wire [31:0] imem_rdata,
    input  wire        imem_ready,    // Instruction fetch data is valid
    // Data memory interface
    output wire        dmem_req,      // Load/store/AMO request (see dmem_we, dmem_be)
    output wire [31:0] dmem_addr,
    output wire [31:0] dmem_wdata,
    output wire [3:0]  dmem_be,       // byte lanes of the access, loads included
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
    // Outside the executable window nothing is fetched (imem_req low), and
    // the instruction is known to fault in EX (cause 1) whatever its bits.
    // They are forced to 0 so the doomed instruction decodes to something
    // harmless rather than whatever the port happens to hold -- in
    // simulation, rather than X.
    //
    // The mask is the window alone (if_exec), not imem_req: imem_req is also
    // low behind an instruction that decides the next pc (ex_nofetch), but
    // then IF/EX takes a bubble or holds, the register-file read goes
    // unused and pc does not take if_pc_next, so nothing looks at the
    // fetched word. Masking with imem_req put that instruction's decode in
    // front of everything IF computes: the expansion, the register file's
    // read addresses and the next pc.
    wire        if_exec;         // pc is in an executable window (assigned with imem_req)
    wire [31:0] if_fetched    = imem_rdata & {32{if_exec}};
    wire        if_compressed = (if_fetched[1:0] != 2'b11);
    // A compressed instruction is expanded here, on its way into IF/EX, so
    // that EX starts from the 32-bit form. Expanding it in EX put the
    // decompressor in front of the decoder, the operand selects, the ALU
    // and the branch decision, the longest paths in the core; here it sits
    // behind the fetched word, which in the SoC is a register.
    wire [31:0] if_expanded;
    wire        if_c_illegal_raw;
    compressed_decoder cdec(
        .instr_in (if_fetched[15:0]),
        .instr_out(if_expanded),
        .illegal  (if_c_illegal_raw)
    );
    wire [31:0] if_pc_next    = pc + (if_compressed ? 32'd2 : 32'd4);
    wire        ex_nofetch;      // EX decides the next pc (assigned after the PMP-write decode)
    // The registers the fetched instruction reads, kept in IF/EX for the
    // register file's read addresses (ifex_rf_rs1/ifex_rf_rs2, see regFile
    // below).
    wire [4:0]  if_rs1, if_rs2;
    rf_fields if_fields(
        .instr(if_fetched),
        .rs1  (if_rs1),
        .rs2  (if_rs2)
    );

    // Is an address inside [base, top]? A window with base > top is empty.
    function automatic in_win(input [31:0] a, input [31:0] base, input [31:0] top);
        in_win = (a >= base) && (a <= top);
    endfunction
    function automatic in_exec(input [31:0] a);
        in_exec = in_win(a, PMA_ROM_BASE, PMA_ROM_TOP) || in_win(a, PMA_RAM_BASE, PMA_RAM_TOP);
    endfunction

    assign imem_addr = pc;
    // A fetch outside flash and PSRAM can never execute, so it is never requested:
    // a fetch must not read an IO device (a read can have side effects, e.g.
    // popping a UART FIFO), and an address with no device behind it must not
    // wait forever for a ready that nobody will give.
    // While the instruction in EX decides the next pc, the fall-through is
    // not fetched speculatively behind it: on the SoC's one QSPI bus that
    // fetch would have to complete (~42 clocks) before the redirect could be
    // taken. See ex_nofetch. A not-taken branch then costs one bubble.
    assign if_exec   = in_exec(pc);
    assign imem_req  = if_exec && !ex_nofetch;

    // ================================================================
    //  IF/EX Pipeline Register
    // Privilege mode: 1=Machine, 0=User. Declared early so EX-stage wires can reference it.
    reg        priv_mode;
    // WFI stall: set when WFI executes, cleared when any interrupt becomes pending.
    reg        wfi_active;

    // ================================================================
    reg [31:0] ifex_pc;
    reg [31:0] ifex_instr;      // The instruction, a compressed one expanded
    reg [15:0] ifex_raw16;      // A compressed instruction's own 16 bits
    reg        ifex_compressed;
    reg        ifex_c_illegal;  // A reserved compressed encoding
    // There is no ifex_pc_next: while IF/EX holds an instruction, pc already
    // is that instruction's pc + 2 or + 4 (pc advances on exactly the cycles
    // IF/EX loads, and every other pc change flushes IF/EX).
    reg        ifex_valid;

    // The bytes as fetched, for the trace and for mtval: the 16-bit halfword
    // of a compressed instruction, the word otherwise. A 32-bit instruction
    // is not changed by expansion, so only a compressed one's 16 bits are
    // kept beside the expanded form.
    wire [31:0] ifex_raw_instr = ifex_compressed ? {16'h0, ifex_raw16} : ifex_instr;
    reg        ifetch_lo_done;  // PMP has checked the fetch at ifex_pc
    reg        ifetch_lo_denied;// ...and refused it
    reg        ifetch_hi_done;  // upper half of the straddling instruction in EX checked
    reg        ifetch_hi_denied;// ...and PMP refused it

    // ================================================================
    //  EX/WB Pipeline Register (declared here so EX-stage continuous
    //  assignments can reference them without iverilog forward-ref errors)
    // ================================================================
    reg [31:0] exwb_alu_result;
    // rs2 for a store; the new value for a CSR write; an AMO's new value
    // once its read is done
    reg [31:0] exwb_rs2_data;
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
    // The CSR write value travels in exwb_rs2_data (a CSR instruction has no
    // rs2), and the value it read in exwb_alu_result, like the link address
    // of a JAL/JALR. The name is kept for the testbench's trace.
    wire [31:0] exwb_csr_wdata = exwb_rs2_data;
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
    reg [31:0] exwb_raw_instr;  // Original fetched bytes for trace dump
    reg        exwb_compressed;

    // Forward declarations for wires assigned later in the CSR/WB section
    // (needed to break iverilog's forward-reference restriction)
    wire [31:0] csr_rdata_eff;   // driven by assign in CSR section
    wire        csr_addr_valid;  // driven by CSR unit output
    wire        pmp_allow;        // driven by the (one, time-shared) pmp instance
    wire        irq_inject;      // driven by interrupt detection logic in CSR/WB section
    wire        csr_misa_c;      // driven by CSR unit output (misa.C bit)
    wire        csr_mstatus_tw;  // driven by CSR unit output (mstatus.TW bit)
    wire        csr_mstatus_mprv;// driven by CSR unit output (mstatus.MPRV bit)
    wire        ex_ifetch_hi_phase; // PMP is checking the fetch (either half), not the data access

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

    // The register file (regFile: the rf_top macro) reads synchronously,
    // write-first: the read addresses are taken on a clock edge, and the
    // data that follows is the registers as they stand after that edge's
    // write -- what a combinational read of flops gives in the cycle after
    // the edge.
    //
    // The addresses are the EX instruction's own, straight from IF/EX
    // (ifex_rf_rs1/ifex_rf_rs2), for as long as it is in EX. So in its
    // first EX cycle the data still belongs to whatever was there before,
    // and from its second cycle on (ex_rf_ok) it is the instruction's
    // registers, read again on every edge. A write lands on the edge that
    // ends WB, so the cycle after it the data includes it; an instruction
    // that reads the register the WB instruction is still to write waits
    // for that (use_hazard, below).
    //
    // The addresses used to be those of the instruction that would be in EX
    // after the next edge -- the fetched instruction's when IF/EX was about
    // to take it, the EX instruction's own while it stayed -- which saved
    // the first cycle and put `stall` in front of the macro's address pins:
    // every wait the pipeline knows (a data access's ready, a fetch's, the
    // M unit, a fetch PMP check) and the fetched word's own decode, all in
    // front of a hard macro's setup time and of regFile's bypass compare.
    // On the routed design those were the three longest slow-corner path
    // groups. The first cycle is not seen in the SoC behind an instruction
    // with a fetch outstanding; see ex_ph for what waits and what pays.
    //
    // The numbers are the ones the instruction was fetched with (rf_fields,
    // from the raw bits), not the decoded ex_rs1/ex_rs2: the two agree
    // wherever the decoded field is not x0, and the decoder stays off the
    // macro's address inputs. They have no reset and a bubble leaves them
    // alone: a bubble uses no register.
    //
    // x0: its word in the macro is an ordinary word, never written (regFile)
    // and never read -- each port's data is masked with the decoded field,
    // which is x0 for a format without that register, whatever was read.
    reg  [4:0]  ifex_rf_rs1, ifex_rf_rs2;
    reg         ex_rf_ok;           // rf_a/rf_b are the EX instruction's registers
    wire [31:0] rf_a, rf_b;
    regFile rf(
        .clk (clk),
        .wrEn(wb_regWR),
        .rd  (wb_rd),
        .dIn (wb_data),
        .ra  (ifex_rf_rs1),
        .rb  (ifex_rf_rs2),
        .r1  (rf_a),
        .r2  (rf_b)
    );
    assign rf_r1 = (ex_rs1 == 5'b0) ? 32'b0 : rf_a;
    assign rf_r2 = (ex_rs2 == 5'b0) ? 32'b0 : rf_b;

    // Nothing is forwarded from WB. An EX instruction that reads the register
    // the WB instruction writes waits in EX for as long as that instruction
    // is in WB (use_hazard, with the stall terms below), and nothing EX
    // computes on a stalled cycle is kept. The write lands on the edge that
    // ends WB, the read addresses are the instruction's own throughout, so
    // in the next cycle the register file gives the new value (regFile is
    // write-first). A load, LR or AMO in WB always worked this way; now every
    // instruction does.
    //
    // The forwarding it replaces was the head of the core's longest paths:
    // exwb_rd, a five-bit compare, the select of two 32-bit muxes, then the
    // ALU or the comparator and everything behind them. The wait costs
    // nothing after an instruction that spends one cycle in WB: that cycle
    // is the reader's first in EX, in which it has no data yet anyway.
    wire [31:0] ex_rs1_val = rf_r1;
    wire [31:0] ex_rs2_val = rf_r2;

    // ALU operand selection
    wire [31:0] alu_d1 = ctrl_aluSrc1 ? ifex_pc   : ex_rs1_val;
    wire [31:0] alu_d2 = ctrl_aluSrc2 ? ex_rs2_val : ex_imm;

    // The comparator (branchCtrl, below) is shared: rs1 against rs2 for a
    // branch, against the ALU's second operand otherwise, which for SUB and
    // SLT(I)(U) is exactly the ALU's d1 - d2 (their d1 is always rs1).
    wire [31:0] cmp_diff;
    wire        cmp_lts, cmp_ltu;
    wire        ex_branch_valid;

    // ALU (RV32I only — M-extension handled by muldiv below)
    wire [31:0] ex_alu_result;
    alu alu_inst(
        .d1         (alu_d1),
        .d2         (alu_d2),
        .sub_res    (cmp_diff),
        .lt_signed  (cmp_lts),
        .lt_unsigned(cmp_ltu),
        .result     (ex_alu_result),
        .control    (ctrl_aluOp)
    );

    // After the register read (ex_rf_ok) EX takes two more cycles. In the
    // first the ALU and the comparator work from the operands, and their
    // results are taken into alu_r and br_r; from the next on (ex_ph)
    // everything that is decided from those results --
    // the PMA and PMP checks of a data address, the traps, the branch, the
    // next pc, and through flush the enables of every pipeline register --
    // starts at these flops instead of at the register file. In one cycle
    // that was operands, a 32-bit add or compare, the PMP checker, the trap
    // priority chain and the fan-out to the pipeline registers: the core's
    // longest paths, whichever operand they started from.
    //
    // alu_r and br_r are taken on every clock, with no enable. They are the
    // EX instruction's own once it has sat in EX for one whole cycle with its
    // operands read (ex_rf_ok) and final (no use_hazard): from then on no
    // instruction that writes a register can enter WB before this one leaves
    // EX, so the operands do not change again. ex_ph says that cycle has
    // passed; the instruction waits in EX until it has (ex_wait, with the
    // stall terms below), so nothing below is acted on before it holds.
    //
    // The two extra cycles are not seen in the SoC behind an instruction
    // that has a fetch outstanding: a fetch is at least 40 clocks and EX
    // waits for it anyway. An instruction that holds the fetch back
    // (ex_nofetch) pays them.
    reg  [31:0] alu_r;
    reg         br_r;
    reg         ex_ph;
    always @(posedge clk) begin
        alu_r <= ex_alu_result;
        br_r  <= ex_branch_valid;
    end

    // ── Multi-cycle multiply/divide unit (RV32M) ──────────────────────────────
    // Wire declarations; stall/start logic is in the Hazard Detection section
    // below (after all dependencies are in scope — iverilog requires this).
    wire        muldiv_busy;
    wire        muldiv_done;
    wire [31:0] muldiv_result;
    wire        muldiv_start;   // driven by assign in Hazard Detection
    wire        muldiv_stall;   // driven by assign in Hazard Detection

    // The shifts (aluOp 00001 SLL, 00101 SRL, 01101 SRA) run through muldiv's
    // shift register as well, one bit per cycle: the ALU has no shifter.
    // Everything below that says "M instruction" covers them too.
    wire ex_is_shift = !ctrl_aluOp[4] && (ctrl_aluOp[1:0] == 2'b01);
    wire ex_is_iter  = ctrl_isMulDiv || ex_is_shift;

    muldiv muldiv_inst(
        .clk   (clk),
        .rst   (rst),
        .start (muldiv_start),
        .op    (ctrl_aluOp[2:0]),    // op encoded in lower 3 bits of aluOp
        .shift (ex_is_shift),
        .sra   (ctrl_aluOp[3]),
        .a     (alu_d1),             // rs1 (aluSrc1=0 for M-ext and shifts)
        .b     (alu_d2),             // rs2, or the immediate shift amount
        .result(muldiv_result),
        .busy  (muldiv_busy),
        .done  (muldiv_done)
    );

    // Branch evaluation
    branchCtrl bcmp(
        .funct3     (ex_funct3),
        .r1         (ex_rs1_val),
        .r2         (ctrl_doBranch ? ex_rs2_val : alu_d2),
        .branchValid(ex_branch_valid),
        .diff       (cmp_diff),
        .lt_signed  (cmp_lts),
        .lt_unsigned(cmp_ltu)
    );

    wire ex_branch_taken = (ctrl_doBranch && br_r) || ctrl_doJump;
    // JALR clears bit 0 of target
    wire [31:0] ex_branch_target = (ex_opcode == 7'b1100111) ?
                                   {alu_r[31:1], 1'b0} : alu_r;

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
    // MRET is funct7=0011000 with rs2=00010; the other rs2 values in that
    // funct7 are reserved and must not execute as MRET.
    wire ex_is_mret   = ifex_valid && ctrl_isMret && ex_system_fields_ok && priv_mode &&
                        (ifex_instr[24:20] == 5'b00010);
    wire ex_is_fencei = ifex_valid && ctrl_isFenceI;

    // WFI: funct7=0001000 (not isMret, not isEcall, not isFenceI) — NOP in M-mode,
    // but with interrupt support we stall until an interrupt fires.
    // Encoding: opcode=1110011, funct3=000, funct7=0001000 (rs2=00101).
    // In U-mode it is a NOP unless mstatus.TW is set (ex_wfi_umode).
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

    // Everything in the funct7=0001000 family except a well-formed WFI is
    // illegal: SRET (rs2=00010) with no S-mode ("should raise an
    // illegal-instruction exception"), WFI with nonzero rd/rs1, and the
    // reserved rs2 values. The controller decodes the whole family as a NOP.
    wire ex_bad_wfi = ifex_valid && (ifex_instr[31:25] == 7'b0001000) &&
                      (ex_opcode == 7'b1110011) && (ex_funct3 == 3'b000) &&
                      !(ifex_instr[24:20] == 5'b00101 && ex_rd == 5'b0 && ex_rs1 == 5'b0);

    // LR.W has no rs2; a nonzero rs2 field is a reserved encoding.
    wire ex_bad_lr = ifex_valid && ctrl_isLR && (ex_rs2 != 5'b0);

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
    // A write to pmpcfg0 or pmpaddr0-3 changes the checks that the next
    // instruction's fetch and data access undergo, and both run in EX while
    // the write commits one stage later in WB. The CSR-write stall
    // (csr_wb_hazard) keeps the data check behind the write, but with a
    // locked entry or in U-mode the next instruction's fetch verdict can be
    // latched during that very stall cycle, against the old configuration.
    // So the write refetches the next instruction the way FENCE.I does,
    // and it reaches EX only after the write has committed. One fetch per
    // PMP write (tests/directed/pmp_refetch).
    wire ex_pmp_csr_wr = ifex_valid && ex_csr_writes &&
                         (ex_csr_addr == 12'h3A0 || ex_csr_addr[11:2] == 10'b0011_1011_00);
    // No fetch behind an instruction that decides the next pc: a branch or
    // jump, and the ones that always redirect -- ECALL and EBREAK (they
    // trap), MRET (it returns, or traps when malformed or in U-mode),
    // FENCE.I and a PMP CSR write (they refetch the fall-through, which is
    // pc). Decode-only terms: ex_trap and ex_illegal_insn can change while
    // EX waits (operands not yet written, misa.C during a CSR-write stall), and
    // imem_req must not drop while a fetch is outstanding.
    assign ex_nofetch = ex_pmp_csr_wr || (ifex_valid &&
                        (ctrl_doBranch || ctrl_doJump || ctrl_isEcall || ctrl_isEbreak ||
                         ctrl_isMret || ctrl_isFenceI));
    // CSR access requires privilege >= csr_addr[9:8] (00=U, 01=S, 11=M).
    // Since we only have M(1) and U(0): any CSR with addr[9:8] != 00 requires M-mode.
    wire ex_csr_priv_fail = !priv_mode && (ex_csr_addr[9:8] != 2'b00);
    wire ex_csr_illegal = ifex_valid && ex_csr_active && (
        !csr_addr_valid ||                     // Non-existent CSR
        (ex_csr_writes && ex_csr_readonly) ||  // Write to read-only CSR
        ex_csr_priv_fail                       // Insufficient privilege
    );

    // Misalignment detection on computed address (the ALU result, in alu_r)
    // RISC-V: LH/SH require 2-byte alignment, LW/SW require 4-byte alignment.
    // Atomics (LR/SC/AMO) always require 4-byte alignment.
    // Rather than silently aliasing to an aligned address, trap per spec.
    wire ex_mem_active = ctrl_memRD || ctrl_memWR || ctrl_isAmo || ctrl_isLR || ctrl_isSC;
    wire ex_misaligned_half = (ctrl_memSize == 2'b01) && (alu_r[0] != 1'b0);
    wire ex_misaligned_word = (ctrl_memSize == 2'b10) && (alu_r[1:0] != 2'b00);
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
    // Fetch is restricted to flash and PSRAM -- executing out of the CLINT is an
    // instruction access fault here. The reference model does NOT do this: it
    // reads the device and reports an illegal instruction (cause 2) with the
    // fetched bits in mtval. Cause 1 is the defensible hardware behaviour, so
    // this is a deliberate divergence, not an oversight.
    wire ex_pma_fetch_ok = in_exec(ifex_pc);
    // A 32-bit instruction whose address has bit 1 set straddles two words,
    // and its upper half is a separate access that the PMA and PMP must
    // allow too. Priv §3.7.1: the matching PMP entry must match all bytes of
    // an access, and on a fault in that portion mtval holds the portion's
    // address while mepc points at the start of the instruction. Checking
    // only ifex_pc executed an instruction whose upper half lay past the end
    // of memory (with junk upper bits), or in a region without X permission.
    wire        ex_straddle = !ifex_compressed && ifex_pc[1];
    // ifex_pc + 2 with no adder: for a 32-bit instruction pc is ifex_pc + 4,
    // and that word is where the upper half lives.
    wire [31:0] ex_pc_hi = {pc[31:2], 2'b00};
    wire ex_pma_fetch_hi_ok = in_exec(ex_pc_hi);
    wire ex_pma_in_rom = in_win(alu_r, PMA_ROM_BASE, PMA_ROM_TOP);
    wire ex_pma_in_ram = in_win(alu_r, PMA_RAM_BASE, PMA_RAM_TOP);
    wire ex_pma_in_io  = in_win(alu_r, PMA_IO0_BASE, PMA_IO0_TOP) ||
                         in_win(alu_r, PMA_IO1_BASE, PMA_IO1_TOP);
    // LR/SC need a reservation set, which only PSRAM can provide -- an IO
    // window is not idempotent and has no reservation set to track, and flash
    // cannot be written. The reference model agrees about IO: its reservable()
    // covers memory only, so lr.w and sc.w on the CLINT fault while amoadd.w
    // there succeeds. Flash takes plain loads only: stores, AMOs and SC are
    // writes (ex_misalign_is_store), and an LR would reserve memory that no SC
    // could ever write.
    wire ex_pma_data_ok  = ex_pma_in_ram ||
                           (ex_pma_in_rom && !ex_misalign_is_store && !ctrl_isLR) ||
                           (ex_pma_in_io && !ctrl_isLR && !ctrl_isSC);

    // Access-fault detection. Two independent reasons to refuse an access:
    // PMP says the permissions deny it, or the PMA says nothing is mapped
    // there. Both raise the same causes (1 / 5 / 7), so they are combined
    // here rather than at every use site.
    // (uses the forward-declared pmp_allow)
    //
    // Fetch: the lower half is checked at ifex_pc. For a straddling
    // instruction the upper half gets its own PMA compare. The one PMP
    // checker serves the fetch and the data access in turn: whenever PMP
    // could deny the fetch it looks at ifex_pc, then at a straddling
    // instruction's upper half, one stalled EX cycle each
    // (ex_ifetch_hi_phase), and the verdicts are kept in ifetch_lo_denied and
    // ifetch_hi_denied. No fault is raised during those cycles. The data
    // access is checked, at alu_r, on the instruction's last EX cycle.
    wire ex_ifetch_fault_lo = !ex_pma_fetch_ok || ifetch_lo_denied;
    wire ex_ifetch_fault_hi = ex_straddle && (!ex_pma_fetch_hi_ok || ifetch_hi_denied);
    wire ex_ifetch_fault = ifex_valid && !ex_ifetch_hi_phase &&
                           (ex_ifetch_fault_lo || ex_ifetch_fault_hi);
    // Data side: only when a memory op is present and it's not already misaligned
    wire ex_data_fault   = ifex_valid && ex_mem_active && !ex_misaligned &&
                           !ex_ifetch_hi_phase && (!pmp_allow || !ex_pma_data_ok);

    // Illegal instruction (cause 2). Collected into one signal so the trap
    // cause chain can test it in its spec-mandated priority position rather
    // than reaching it as the fallthrough case.
    wire ex_illegal_insn = ifex_valid && (
        (ctrl_illegal && !ctrl_isFence) ||
        ifex_c_illegal ||              // Reserved compressed encoding
        // A compressed instruction while misa.C=0. Checked here rather than
        // at IF so that it sees csr_misa_c as it stands after a csrw misa in
        // WB: at IF the write is still two stages away, and the two
        // instructions after `csrci misa, 4` used to execute compressed.
        (ifex_compressed && !csr_misa_c) ||
        ex_bad_system ||               // Malformed SYSTEM encoding
        ex_wfi_umode ||                // WFI from U-mode (illegal)
        ex_bad_wfi ||                  // SRET / malformed WFI / reserved rs2
        ex_bad_lr ||                   // LR.W with rs2 != 0
        ex_csr_illegal                 // Invalid/read-only CSR access
    );

    // Trap detection. ex_trap_decode is the part known from the instruction
    // and the fetch alone; the other three causes wait for the ALU's address.
    wire ex_trap_decode = ifex_valid && (
        ex_is_ecall || ex_is_ebreak ||
        ex_ifetch_fault ||             // Instruction access fault (PMP or PMA)
        ex_illegal_insn                // Illegal instruction
    );
    wire ex_trap = ex_trap_decode || (ifex_valid && (
        ex_misaligned ||               // Misaligned memory access
        ex_data_fault ||               // Load/store access fault (PMP or PMA)
        ex_inst_misalign               // Instruction address misaligned (branch target)
    ));

    // ================================================================
    //  Hazard Detection
    // ================================================================

    // Use hazard: the WB instruction writes a register the EX instruction
    // reads. EX waits for the write (see ex_rs1_val above). A trapping
    // instruction writes nothing; the trap has flushed EX by then, so the
    // term only says so.
    wire use_hazard = exwb_valid && exwb_regWR && !exwb_trap &&
                      exwb_rd != 5'b0 &&
                      (exwb_rd == ex_rs1 || exwb_rd == ex_rs2);

    // WB busy (AMO second cycle)
    reg wb_busy;

    // Memory handshake stalls:
    //   - IF stall: instruction memory not ready (multi-cycle fetch)
    //   - WB stall: data memory not ready during active load/store
    wire if_mem_stall = imem_req && !imem_ready;
    // The WB stall is exactly "a data request is outstanding and not yet
    // answered". dmem_req (assigned with the rest of the data interface
    // below) excludes a trapping access, which never reaches the bus, and a
    // failing SC, which writes nothing: it retires without a transaction.
    // It used to wait for dmem_ready anyway, which on a request/ready bus
    // never arrives for a request that was never made.
    wire wb_mem_stall = dmem_req && !dmem_ready;

    // flush is defined before stall so muldiv_start can reference it without
    // a forward reference (iverilog processes wire assignments linearly).
    wire flush = ex_branch_taken || ex_is_mret || ex_trap || ex_is_fencei || ex_pmp_csr_wr ||
                 irq_inject;

    // stall_other: all stall sources except muldiv (used to gate muldiv_start)
    // wfi_active stalls the pipeline until an interrupt becomes pending.
    // stall_nofetch is the same without the pending fetch: an M instruction
    // starts on it (see muldiv_start).
    //
    // csr_wb_hazard: a CSR write commits in WB, and the instruction behind it
    // waits in EX for that one cycle, so everything EX derives from CSR state
    // -- a CSR read, the trap and MRET targets, interrupt gating, MPRV/MPP for
    // the data PMP check, TW, misa.C -- sees the committed value. The
    // alternative, forwarding csr.v's post-write value into each of those, is
    // a 32-bit mux per consumer and a copy of every WARL rule on the read
    // path. In the SoC the cycle is hidden behind the next fetch.
    wire csr_wb_hazard = ifex_valid && exwb_valid && exwb_csrWR && !exwb_trap;
    // ex_wait: the EX instruction's ALU and comparator results are not in
    // alu_r and br_r yet (see ex_ph).
    //
    // use_hazard is not a stall term of its own. It keeps ex_ph from being
    // set, so the instruction it holds is already held by ex_wait; and once
    // ex_ph is set it cannot rise again, because nothing that writes a
    // register can enter WB before that instruction leaves EX (the
    // testbench checks, on every clock, that it never does). As a stall
    // term it put the decoder's register fields and a five-bit compare with
    // exwb_rd in front of `stall`.
    wire ex_wait = ifex_valid && !ex_ph;
    wire stall_nofetch = wb_busy || wb_mem_stall || wfi_active ||
                         ex_ifetch_hi_phase || csr_wb_hazard || ex_wait;
    wire stall_other = stall_nofetch || if_mem_stall;

    // muldiv stall logic (see muldiv instantiation in EX section above):
    //   muldiv_start: pulse for one cycle to launch a new M-ext operation.
    //   muldiv_stall: keep pipeline frozen while muldiv is working.
    //                 When muldiv_done fires, stall drops so the pipeline advances
    //                 and captures muldiv_result into exwb_alu_result this cycle.
    // !ex_trap_iter: a trapping M instruction (a fetch fault whose garbage
    // word decodes as MUL/DIV, say) never starts -- muldiv_start is gated on
    // flush, which contains ex_trap -- so without this muldiv_stall would
    // wait for a result that never comes and the trap would never commit.
    // It depends on neither stall nor flush, so this closes no loop.
    //
    // ex_trap_iter is all of ex_trap here. An M instruction or a shift is OP
    // or OP-IMM: it makes no memory access and no jump, so the three address
    // causes cannot be raised for it, and it is no SYSTEM instruction, CSR
    // access, LR or FENCE, which leaves a fetch fault, a bad funct7 and the
    // two compressed-instruction causes (tb_controller checks both halves
    // for every opcode, funct3 and funct7; the testbench checks
    // muldiv_want against ex_trap_decode on every clock). Using ex_trap
    // itself put the ALU, the PMA compare and the PMP check in front of
    // `stall`, and through it in front of the enable of every pipeline
    // register; all of ex_trap_decode still put the SYSTEM and CSR checks
    // there, 3.6 ns of the 21.4 ns from the opcode to those enables at the
    // slow corner.
    wire ex_trap_iter = ex_ifetch_fault || ctrl_illegal || ifex_c_illegal ||
                        (ifex_compressed && !csr_misa_c);
    wire muldiv_want = ifex_valid && ex_is_iter && !ex_trap_iter;

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

    // A pending fetch does not hold the operation back: it runs during the
    // fetch wait and is captured (muldiv_capture) once the fetch is in.
    // Waiting for the fetch as well started it on the cycle the fetch
    // completed, and muldiv_stall then dropped that fetch and fetched the
    // same word again: one extra memory read per M instruction.
    assign muldiv_start = muldiv_want && !muldiv_busy && !muldiv_have
                          && !stall_nofetch && !flush;
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
    // `flush` deliberately keeps using the ungated ex_is_mret: the IF/EX
    // bubble arm is only reached when !stall, so it cannot commit twice. The
    // next_pc redirect is gated on !stall so the fetch address stays put
    // while a fetch is outstanding.
    //
    // !irq_inject: an interrupt taken at an MRET is taken *instead of* it,
    // exactly as for every other instruction -- irq_inject suppresses the EX
    // instruction's effects and records its PC as mepc, and next_pc already
    // prefers the interrupt. Letting the MRET commit as well applied both:
    // the handler entered with MPP=U (the MRET's restore) and mepc pointing
    // at the MRET, so its own MRET re-executed that MRET from U-mode and
    // took an illegal-instruction trap. irq_inject does not depend on
    // ex_mret_commit, so this closes no loop.
    wire ex_mret_commit = ex_is_mret && !stall && !ex_trap && !irq_inject;

    // ================================================================
    //  WB Stage — Memory Access + Writeback
    // ================================================================

    // AMO state machine
    reg        amo_phase; // 0=read, 1=write
    // Between its read and its write an AMO keeps the old value in
    // exwb_trap_val, free because an AMO in WB never traps, and the new value
    // in exwb_rs2_data, whose rs2 the new value was computed from.
    wire [31:0] amo_old_val = exwb_trap_val;

    // LR/SC reservation. The reservation set is the naturally aligned word
    // holding the LR's address -- the smallest set the spec allows -- so only
    // the word address is kept. LR.W/SC.W are always word-aligned (anything
    // else traps as misaligned), so the word address names it exactly. Only
    // an SC or a trap clears it; see the reservation update in WB.
    reg        reservation_valid;
    reg [29:0] reservation_addr;
    wire       sc_success = reservation_valid &&
                            (reservation_addr == exwb_alu_result[31:2]);

    // Memory address and alignment
    wire [31:0] mem_addr_aligned = {exwb_alu_result[31:2], 2'b00};
    wire [1:0]  mem_byte_offset  = exwb_alu_result[1:0];

    // Byte lanes and store data alignment. The lanes follow from the
    // access's size and offset, and are the same for a load as for a store:
    // dmem_addr is word-aligned, so without them a device could not tell an
    // lbu of byte 1 from a load of byte 0 (an 8250 at reg-shift 0 has IER at
    // byte 1 and RBR, which a read pops, at byte 0).
    reg [31:0] store_data_shifted;
    reg [3:0]  access_be;
    always @(*) begin
        store_data_shifted = 32'b0;
        access_be = 4'b0;
        case (exwb_memSize)
            2'b00: begin // byte
                store_data_shifted = {4{exwb_rs2_data[7:0]}};
                access_be = 4'b0001 << mem_byte_offset;
            end
            2'b01: begin // halfword
                store_data_shifted = {2{exwb_rs2_data[15:0]}};
                access_be = (mem_byte_offset[1]) ? 4'b1100 : 4'b0011;
            end
            2'b10: begin // word
                store_data_shifted = exwb_rs2_data;
                access_be = 4'b1111;
            end
            default: begin
                store_data_shifted = 32'b0;
                access_be = 4'b0;
            end
        endcase
    end

    // Memory interface signals
    wire wb_mem_write = exwb_valid && !exwb_trap && (
        (exwb_memWR && !exwb_isAmo && !exwb_isSC) ||
        (exwb_isSC && sc_success) ||
        (exwb_isAmo && amo_phase)
    );

    assign dmem_addr  = mem_addr_aligned;
    assign dmem_wdata = store_data_shifted;   // an AMO's new value is in exwb_rs2_data
    // An AMO, LR or SC is a word access, so access_be is 1111 for it.
    assign dmem_be    = access_be;
    assign dmem_we    = wb_mem_write;
    assign dmem_req   = exwb_valid && !exwb_trap && (exwb_memRD || exwb_memWR) &&
                        !(exwb_isSC && !sc_success);

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

    // The link address (wbSel 10) and a CSR's old value (11) are already in
    // exwb_alu_result.
    assign wb_data = (exwb_wbSel == 2'b01) ? wb_load_or_amo : wb_alu_or_sc;

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
    wire [31:0] csr_mtvec, csr_mepc;
    wire [31:0] csr_wval;           // post-write value of the CSR WB is writing (trace only)
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
        .pc_next_misaligned (exwb_trap_pc[1]),
        .wval_out    (csr_wval)
    );

    // ── Interrupt pending detection ──────────────────────────────────────────
    // Per spec §3.1.6.1: MIE only gates M-mode; U-mode interrupts always enabled
    // (no delegation in M+U only system). Priority: external(11) > sw(3) > timer(7).
    // No interrupt is injected while a CSR write is in WB (csr_wb_hazard is
    // part of stall_other), so there is no window where one slips in after
    // csrci mstatus,8 but before the write commits.
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
    //   - Never while an M instruction is in EX (muldiv_want)
    //   - Never when EX already has a synchronous trap (trap takes priority)
    //   - Never while the pipeline is stalled
    //
    // stall_other subsumes the old wb_busy and wfi_active terms and adds
    // ex_wait (so use_hazard), if_mem_stall and wb_mem_stall. Without those, an
    // interrupt arriving during a memory stall was injected on every cycle of
    // it: the second injection latched MPIE from the MIE the first had already
    // cleared, so the following MRET restored MIE=0 and the hart never took
    // another interrupt. It also tore down an in-flight memory access, because
    // the injection path overrides the EX/WB hold.
    //
    // muldiv_want rather than muldiv_stall (or `stall`): muldiv_stall feeds
    // muldiv_start through flush, which contains irq_inject, so it would
    // close a combinational loop. Excluding any M instruction in EX -- before
    // it starts, while it runs, and on the cycle its result is captured --
    // means an interrupt never discards a finished or in-flight multiply;
    // it is taken at the next instruction instead.
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

    // ── PMP check ────────────────────────────────────────────────────────────
    // One checker, time-shared (pmp_allow is forward-declared near the top of
    // EX). While PMP could refuse a fetch the instruction spends one stalled
    // EX cycle checking ifex_pc with Execute permission (ex_ifetch_lo_phase)
    // and, if it straddles two words, one more on its upper half, latching
    // each verdict; its data access is checked on the cycle after. Checking
    // all three at once took three checkers.
    //
    // PMP can only refuse an M-mode fetch through a locked entry, so the
    // extra cycles are spent only in U-mode or when some entry is locked; an
    // M-mode kernel with unlocked (or no) PMP entries never pays them. In the
    // SoC they are hidden behind the next fetch.
    wire pmp_any_locked = csr_pmpcfg0[7] | csr_pmpcfg0[15] | csr_pmpcfg0[23] | csr_pmpcfg0[31];
    wire fetch_can_deny = !priv_mode || pmp_any_locked;
    wire ex_ifetch_lo_phase = ifex_valid && fetch_can_deny && !ifetch_lo_done;
    assign ex_ifetch_hi_phase = ex_ifetch_lo_phase ||
                                (ifex_valid && fetch_can_deny && ex_straddle && !ifetch_hi_done);

    // Data access: check alu_r with R or W permission (the address is ready on
    // every cycle the verdict is used: ex_ph).
    wire [2:0] ex_pmp_access_type = ctrl_isAmo           ? 3'b011 : // AMO: R+W
                                     ex_misalign_is_store ? 3'b010 : // Store/SC: W
                                     3'b001;                          // Load/LR: R
    // MPRV=1 makes loads and stores check as though the hart were in MPP.
    // Instruction fetch is excluded by the spec, so its check keeps priv_mode.
    // The load or store right after `csrw mstatus` waits in EX for the write
    // to commit (csr_wb_hazard), so it is checked against the new values.
    wire data_priv_mode = csr_mstatus_mprv ? (csr_mstatus_mpp == 2'b11) : priv_mode;

    pmp pmp_unit(
        .pmpcfg0    (csr_pmpcfg0),
        .pmpaddr0   (csr_pmpaddr0),
        .pmpaddr1   (csr_pmpaddr1),
        .pmpaddr2   (csr_pmpaddr2),
        .pmpaddr3   (csr_pmpaddr3),
        .addr       (ex_ifetch_lo_phase ? ifex_pc :
                     ex_ifetch_hi_phase ? ex_pc_hi : alu_r),
        .access_type(ex_ifetch_hi_phase ? 3'b100 : ex_pmp_access_type),  // Execute
        .priv_mode  (ex_ifetch_hi_phase ? priv_mode : data_priv_mode),
        .pmp_allow  (pmp_allow)
    );

    // No CSR forwarding: an instruction never reads CSR state in EX while a
    // CSR write is in WB (csr_wb_hazard stalls it for that cycle).
    assign csr_rdata_eff = csr_rdata;

    // ================================================================
    //  PC Update Logic
    // ================================================================
    // "csrw mepc, t5; mret" and "csrw mtvec, t0; ecall" read the written
    // value: csr_wb_hazard holds the MRET or the trap in EX until the write
    // has committed.
    wire [31:0] trap_target = csr_mtvec;
    wire [31:0] mret_target = csr_mepc;

    reg [31:0] next_pc;
    always @(*) begin
        // !stall: the trap is only real on the cycle its instruction leaves
        // EX. During a stall EX can be looking at operands that are not valid
        // yet -- during a use_hazard stall the register file still holds the
        // old value -- and a garbage address can raise ex_misaligned
        // or ex_data_fault for a cycle. Redirecting then sent fetch to mtvec
        // while IF/EX held the instruction; when the data arrived the trap
        // vanished, the instruction retired normally, and the handler ran
        // with no trap taken.
        //
        // Every redirect is taken only on a !stall cycle, and !stall implies
        // imem_ready, so pc -- imem_addr -- only changes on the cycle a fetch
        // completes: the address of an outstanding fetch is never withdrawn.
        if (ex_trap && !stall)
            next_pc = trap_target;
        else if (irq_inject)
            // Interrupt: redirect to mtvec; mepc will hold ifex_pc so the
            // interrupted instruction re-executes after MRET.
            next_pc = trap_target;
        else if (ex_is_mret && !stall)
            next_pc = mret_target;
        else if (ex_branch_taken && ifex_valid && !stall)
            next_pc = ex_branch_target;
        else if ((ex_is_fencei || ex_pmp_csr_wr) && ifex_valid && !stall)
            next_pc = pc;           // Re-fetch after FENCE.I or a PMP CSR write
        else if (stall || ex_nofetch)
            next_pc = pc;       // a not-taken branch: pc already is the fall-through
        else
            next_pc = if_pc_next;
    end

    // ================================================================
    //  FENCE.I flush output
    // ================================================================
    // Asserted for exactly one cycle when a FENCE.I instruction completes
    // in the EX stage: not stalled, and not replaced by a trap (a fetch
    // fault on its word) or an interrupt taken instead of it.
    assign fencei_flush = ex_is_fencei && !stall && !ex_trap && !irq_inject;

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
            pc        <= {boot_addr[31:1], 1'b0};
            priv_mode <= 1'b1; // Boot in M-mode
            // IF/EX
            ifex_pc        <= 32'b0;
            ifex_instr     <= 32'h0000_0013; // NOP
            ifex_compressed<= 1'b0;
            ifex_c_illegal <= 1'b0;
            ifex_valid     <= 1'b0;
            ex_rf_ok       <= 1'b0;
            ex_ph          <= 1'b0;
            ifetch_lo_done <= 1'b0;
            ifetch_lo_denied <= 1'b0;
            ifetch_hi_done <= 1'b0;
            ifetch_hi_denied <= 1'b0;
            // EX/WB
            exwb_alu_result <= 32'b0;
            exwb_rs2_data   <= 32'b0;
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
            exwb_isAmo      <= 1'b0;
            exwb_isLR       <= 1'b0;
            exwb_isSC       <= 1'b0;
            exwb_amoOp      <= 5'b0;
            exwb_trap       <= 1'b0;
            exwb_trap_cause <= 32'b0;
            exwb_trap_pc    <= 32'b0;
            exwb_trap_val   <= 32'b0;
            exwb_raw_instr  <= 32'h0000_0013;
            exwb_compressed <= 1'b0;
            // AMO
            amo_phase      <= 1'b0;
            wb_busy        <= 1'b0;
            // WFI
            wfi_active        <= 1'b0;
            // Reservation
            reservation_valid <= 1'b0;
            reservation_addr  <= 30'b0;
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
                // Hold IF/EX on stall. The register file has taken the
                // instruction's addresses by the end of its first cycle
                // here. Its operands were final in this cycle if they had
                // been read and it was not waiting for a register write;
                // alu_r and br_r are then its own from the next cycle on.
                ex_rf_ok <= 1'b1;
                ex_ph    <= ex_rf_ok && !use_hazard;
                // If the stall is a fetch PMP check,
                // record its verdict; the next cycle checks the next thing.
                if (ex_ifetch_lo_phase) begin
                    ifetch_lo_done   <= 1'b1;
                    ifetch_lo_denied <= !pmp_allow;
                end else if (ex_ifetch_hi_phase) begin
                    ifetch_hi_done   <= 1'b1;
                    ifetch_hi_denied <= !pmp_allow;
                end
            end else if (flush || ex_nofetch) begin
                // Insert bubble (nothing was fetched behind ex_nofetch)
                ifex_valid     <= 1'b0;
                ex_rf_ok       <= 1'b0;
                ex_ph          <= 1'b0;
                ifex_instr     <= 32'h0000_0013; // NOP
                ifex_compressed<= 1'b0;
                ifex_c_illegal <= 1'b0;
                ifetch_lo_done <= 1'b0;
                ifetch_lo_denied <= 1'b0;
                ifetch_hi_done <= 1'b0;
                ifetch_hi_denied <= 1'b0;
            end else begin
                ifex_pc        <= pc;
                ifex_instr     <= if_compressed ? if_expanded : if_fetched;
                ifex_raw16     <= if_fetched[15:0];
                ifex_compressed<= if_compressed;
                ifex_c_illegal <= if_compressed && if_c_illegal_raw;
                ifex_valid     <= 1'b1;
                ex_rf_ok       <= 1'b0;
                ex_ph          <= 1'b0;
                // The register file's read addresses while this
                // instruction is in EX.
                ifex_rf_rs1    <= if_rs1;
                ifex_rf_rs2    <= if_rs2;
                ifetch_lo_done <= 1'b0;
                ifetch_lo_denied <= 1'b0;
                ifetch_hi_done <= 1'b0;
                ifetch_hi_denied <= 1'b0;
                // misa.C is applied in EX (ex_illegal_insn).
            end

            // ---- EX/WB Pipeline Register ----
            if (wb_busy) begin
                // AMO phase transition: read → write
                if (exwb_isAmo && !amo_phase && dmem_ready) begin
                    amo_phase   <= 1'b1;
                    exwb_trap_val <= load_data;     // amo_old_val
                    exwb_rs2_data <= amo_computed;  // the write's data
                    wb_busy     <= 1'b0; // Release pipeline next cycle
                end
            end else if (wb_mem_stall) begin
                // Hold EX/WB while the data-memory access is still on the bus.
                // Bubbling here would drop exwb_memRD/exwb_memWR and so
                // withdraw dmem_addr/dmem_we before dmem_ready — the
                // transaction is lost, and because wb_mem_stall is derived
                // from those same bits the stall self-clears and nothing
                // retries it. Every other stall source still bubbles: by then
                // the WB instruction has committed, and holding it would
                // commit it a second time.
            end else if (stall) begin
                // Insert bubble into EX/WB on stall. An interrupt is never
                // injected on a stalled cycle (irq_inject needs !stall_other
                // and !muldiv_want), so these two arms need no exception for
                // it; they used to carry one, which put irq_inject's
                // !ex_trap -- the ALU and the PMP check -- on every EX/WB
                // register's enable.
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
                // The M-ext or shift result, the link address (pc is
                // ifex_pc + 2/4), a CSR's old value, or the ALU result.
                exwb_alu_result <= ex_is_iter             ? muldiv_result :
                                   (ctrl_wbSel == 2'b10)  ? pc            :
                                   (ctrl_wbSel == 2'b11)  ? csr_rdata_eff :
                                                            alu_r;
                exwb_rs2_data   <= ex_csr_active ? ex_csr_wdata : ex_rs2_val;
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
                exwb_isAmo      <= ctrl_isAmo;
                exwb_isLR       <= ctrl_isLR;
                exwb_isSC       <= ctrl_isSC;
                exwb_amoOp      <= ctrl_amoOp;
                exwb_raw_instr  <= ifex_raw_instr;
                exwb_compressed <= ifex_compressed;
                exwb_trap_pc    <= ifex_pc;

                // Trap cause and mtval assignment
                // Priority: synchronous trap > async interrupt injection
                if (ex_trap) begin
                    exwb_trap <= 1'b1;
                    if (ex_ifetch_fault) begin
                        exwb_trap_cause <= 32'd1;  // Instruction access fault (highest priority)
                        // The faulting portion: the instruction's start, or
                        // its upper half when only that half is refused.
                        exwb_trap_val   <= ex_ifetch_fault_lo ? ifex_pc : ex_pc_hi;
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
                        exwb_trap_val   <= alu_r;
                    end else if (ex_misaligned && ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd6;  // Store/AMO address misaligned
                        exwb_trap_val   <= alu_r;
                    end else if (ex_data_fault && !ex_misalign_is_store) begin
                        exwb_trap_cause <= 32'd5;  // Load access fault
                        exwb_trap_val   <= alu_r;
                    end else begin
                        // Only ex_data_fault on a store is left in ex_trap.
                        exwb_trap_cause <= 32'd7;  // Store/AMO access fault
                        exwb_trap_val   <= alu_r;
                    end
                end else if (irq_inject) begin
                    // Asynchronous interrupt: suppress instruction effects, inject trap
                    exwb_trap       <= 1'b1;
                    exwb_trap_cause <= irq_cause;
                    exwb_trap_val   <= 32'b0;
                    // mepc: if interrupted instruction is WFI, advance past it so MRET
                    // doesn't re-execute WFI. For all other instructions, point to the
                    // instruction itself so it re-executes after MRET.
                    exwb_trap_pc    <= ex_is_wfi ? pc : ifex_pc;
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
                    reservation_addr  <= exwb_alu_result[31:2];
                end else if (exwb_isSC) begin
                    reservation_valid <= 1'b0;
                end
                // A store or AMO from this hart leaves the reservation alone,
                // even one to the reserved word. The spec's must-fail list
                // covers stores by other harts and writes by other devices,
                // and this SoC has neither; what a hart's own write does is
                // left to the implementation. Keeping the reservation is what
                // Spike does, so the lockstep comparison stays aligned past
                // the SC -- clearing it made every unconstrained LR..store..SC
                // sequence diverge there, which hid ~26% of each rrag
                // program from the comparison. Forward progress is not
                // affected: a constrained LR/SC loop contains no stores.
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
            //
            // Cleared when the trap commits in WB, not when it is detected in
            // EX. An EX-stage clear could land while an older SC was still in
            // WB waiting for dmem_ready: sc_success dropped mid-handshake,
            // dmem_we was withdrawn, and rd read 1 while a bus that had
            // already latched the request performed the store anyway -- so
            // software retried an atomic update that had happened. An EX
            // clear could also fire on a trap that was never taken (EX
            // briefly sees not-yet-written operands during a stall).
            if (csr_trap_signal)
                reservation_valid <= 1'b0;
        end
    end

endmodule
