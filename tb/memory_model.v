// Simple byte-addressable memory model for simulation
//
// Unified 32 MB flat address space:
//   0x0000_0000 – 0x00FF_FFFF : Flash (16 MB) — code and read-only data
//   0x0100_0000 – 0x01FF_FFFF : RAM   (16 MB) — stack, heap, .data/.bss
//   0x0200_0000 – 0x020B_FFFF : CLINT aperture — see CLINT_TOP below
//
// Both instruction fetch and data access ports index into the same array for
// the Flash/RAM region. CLINT is handled by an instantiated clint module.
//
// Dual-port: simultaneous instruction fetch and data access.
// Instruction port is read-only and combinational.
// Data port supports byte-lane-masked synchronous writes.
//
// Wait states
// -----------
// The tapeout target is external QSPI flash + PSRAM, which never answers in
// the same cycle.  This model can therefore hold imem_ready / dmem_ready low
// for a configurable number of cycles so that the core's stall and handshake
// logic is actually exercised in simulation.
//
//   IMEM_WAIT / DMEM_WAIT   0 = combinational (ready always 1, the historical
//                           behaviour).  N > 0 = ready is asserted 1 cycle in
//                           every N+1, i.e. N wait states per access.
//   IMEM_RANDOM/DMEM_RANDOM 1 = ready is instead asserted pseudo-randomly with
//                           probability 1/(WAIT+1), from a reproducible LFSR.
//   MEM_SEED                LFSR seed, so a randomised run can be replayed.
//
// All six are overridable at run time with the matching plusargs
// (+IMEM_WAIT=n, +DMEM_RANDOM=1, +MEM_SEED=n, ...) so one compiled simulation
// can be re-run under several memory timings.
//
// Two properties make the wait states meaningful rather than cosmetic:
//   * a write only commits on the cycle dmem_ready is high, so a request that
//     the core withdraws early is genuinely lost;
//   * read data is driven to X while ready is low, so a core that samples
//     rdata before the handshake completes propagates X instead of silently
//     getting the right answer from the combinational array.
//
// X is not enough on its own, though. iverilog evaluates `if (X)` as false,
// so a control decision made from not-yet-valid data (an address computed
// from a load still on the bus, say) silently takes the harmless branch in
// simulation. Real buses return zeros or whatever was last on the wires, and
// there the same decision can go the other way. NOTREADY_DATA (+NOTREADY_DATA)
// selects what rdata carries while ready is low:
//
//   0  X (default)
//   1  all zeros
//   2  LFSR garbage, different every cycle

module memory_model #(
    parameter MEM_SIZE    = 33554432,      // 32 MB (0x0000_0000 – 0x01FF_FFFF)
    parameter INIT_FILE   = "program.hex", // hex file loaded at address 0
    parameter IMEM_WAIT   = 0,             // instruction-port wait states
    parameter DMEM_WAIT   = 0,             // data-port wait states
    parameter IMEM_RANDOM = 0,             // randomise instruction-port ready
    parameter DMEM_RANDOM = 0,             // randomise data-port ready
    parameter MEM_SEED    = 32'h1234_5678, // LFSR seed for the random modes
    parameter NOTREADY_DATA = 0            // rdata while !ready: 0=X 1=zero 2=garbage
)(
    input  wire        clk,
    input  wire        rst,
    // Instruction port (read-only, combinational)
    input  wire        imem_req,
    input  wire [31:0] imem_addr,
    output wire [31:0] imem_rdata,
    // Data port (read/write)
    input  wire        dmem_req,
    input  wire [31:0] dmem_addr,
    input  wire [31:0] dmem_wdata,
    input  wire [3:0]  dmem_be,      // byte lanes, loads included
    input  wire        dmem_we,
    output wire [31:0] dmem_rdata,
    // Memory ready signals (see the wait-state notes in the header)
    output wire        imem_ready,
    output wire        dmem_ready,
    // Interrupt outputs (from embedded CLINT)
    output wire        timer_irq,
    output wire        sw_irq,
    // Machine external interrupt (MEIP), software-triggered -- see EXTIRQ below
    output wire        ext_irq,
    // mtime value for CSR time/timeh reads
    output wire [63:0] mtime_out
);
    // ── Wait-state generation ───────────────────────────────────────────────
    integer imem_wait_n, dmem_wait_n, imem_random, dmem_random, mem_seed;
    integer notready_data;

    initial begin
        imem_wait_n = IMEM_WAIT;
        dmem_wait_n = DMEM_WAIT;
        imem_random = IMEM_RANDOM;
        dmem_random = DMEM_RANDOM;
        mem_seed    = MEM_SEED;
        notready_data = NOTREADY_DATA;
        if ($value$plusargs("IMEM_WAIT=%d",   imem_wait_n)) ;
        if ($value$plusargs("DMEM_WAIT=%d",   dmem_wait_n)) ;
        if ($value$plusargs("IMEM_RANDOM=%d", imem_random)) ;
        if ($value$plusargs("DMEM_RANDOM=%d", dmem_random)) ;
        if ($value$plusargs("MEM_SEED=%d",    mem_seed))    ;
        if ($value$plusargs("NOTREADY_DATA=%d", notready_data)) ;
        if (imem_wait_n < 0) imem_wait_n = 0;
        if (dmem_wait_n < 0) dmem_wait_n = 0;
        if (mem_seed   == 0) mem_seed    = 32'h1234_5678; // an all-zero LFSR is stuck
    end

    reg [15:0] i_cnt;
    reg [15:0] d_cnt;
    reg [31:0] lfsr;

    initial begin
        i_cnt = 16'd0;
        d_cnt = 16'd0;
        lfsr  = MEM_SEED ? MEM_SEED : 32'h1234_5678;
    end

    always @(posedge clk) begin
        if (rst) begin
            i_cnt <= imem_wait_n[15:0];
            d_cnt <= dmem_wait_n[15:0];
            lfsr  <= mem_seed[31:0];
        end else begin
            // Free-running down-counters: ready for one cycle in every WAIT+1,
            // not timed from the start of each request. Every access still
            // sees between 0 and WAIT wait states, and a fixed period against
            // a fixed-latency core is exactly what exposes phase-lock bugs.
            i_cnt <= (i_cnt == 16'd0) ? imem_wait_n[15:0] : i_cnt - 16'd1;
            d_cnt <= (d_cnt == 16'd0) ? dmem_wait_n[15:0] : d_cnt - 16'd1;
            lfsr  <= {lfsr[30:0], lfsr[31] ^ lfsr[21] ^ lfsr[1] ^ lfsr[0]};
        end
    end

    // In random mode ready is high with probability 1/(WAIT+1); WAIT=0 makes
    // the modulo 1, so both modes collapse to "always ready" at zero waits.
    wire imem_rnd_ready = ((lfsr[7:0]  % (imem_wait_n + 1)) == 0);
    wire dmem_rnd_ready = ((lfsr[15:8] % (dmem_wait_n + 1)) == 0);

    assign imem_ready = imem_random ? imem_rnd_ready : (i_cnt == 16'd0);
    assign dmem_ready = dmem_random ? dmem_rnd_ready : (d_cnt == 16'd0);

    // ── Address decode ───────────────────────────────────────────────────────
    //
    // The CLINT *aperture* is 0xC0000 wide, not the 48 KB the register block
    // needs, because that is what the reference model does and the two have to
    // agree about which addresses exist. Spike maps CLINT_SIZE = 0xC0000 from
    // the CLINT base and ignores the size in its device tree: measured on
    // spike 1.1.1-dev, a load or store anywhere in 0x02000000-0x020BFFFF
    // succeeds, returning the register at 0x0000/0x4000/0xBFF8/0xBFFC and
    // plain zeros everywhere else, and 0x020C0000 is the first address that
    // faults.
    //
    // Zeros, not aliases: clint_inst is addressed with a 16-bit offset, so
    // handing it 0x0201_0000 would read back msip. Spike returns 0 there, so
    // anything at or above offset 0x1_0000 is answered with 0 here and its
    // writes are dropped -- CLINT_REG_TOP is the line between the two.
    localparam CLINT_BASE    = 32'h0200_0000;
    localparam CLINT_TOP     = 32'h020B_FFFF;  // = CLINT_BASE + 0xC0000 - 1
    localparam CLINT_REG_TOP = 32'h0200_FFFF;  // highest offset clint_inst sees

    // Software-triggered machine external interrupt.
    //
    // Unlike MTIP and MSIP, MEIP has no source both the DUT and the reference
    // model agree on: timer and software interrupts are derived from mtimecmp
    // and msip, which the program itself writes, so Spike's own CLINT computes
    // the same values. Spike models no interrupt controller for MEIP -- it only
    // supports MMIO plugin devices loaded via --extlib/--device.
    //
    // Driving ext_irq from anything testbench-local would therefore desync the
    // DUT trace from the reference on every test. Instead expose a single
    // register a program can write deliberately: bit 0 sets MEIP, and it stays
    // asserted until cleared. No generated test knows this address, so it reads
    // as inert for the whole regression, while directed tests can reach the
    // MEIP path.
    //
    // NOTE: a test that uses this will NOT match Spike until a matching device
    // plugin exists on the Spike side. It is a hook for DUT-only directed
    // tests, not for lockstep comparison.
    localparam EXTIRQ_ADDR = 32'h0200_C000;

    wire in_extirq = (dmem_addr == EXTIRQ_ADDR);
    wire in_clint  = (dmem_addr >= CLINT_BASE) && (dmem_addr <= CLINT_TOP);
    // Only the bottom 64 KiB of the aperture reaches the CLINT registers; the
    // rest of it reads 0 and swallows writes, which is what spike does.
    // The MEIP hook is carved out explicitly: widening the aperture put its
    // address inside it, and without this it would answer from clint_inst's
    // default case (0) and lose its read-back.
    wire in_clint_reg = in_clint && (dmem_addr <= CLINT_REG_TOP) && !in_extirq;
    wire in_mem    = !in_clint && !in_extirq;  // Flash + RAM; ignore GPIO for sim simplicity

    reg extirq_reg;
    always @(posedge clk) begin
        if (rst)
            extirq_reg <= 1'b0;
        else if (dmem_req && dmem_we && dmem_ready && in_extirq && dmem_be[0])
            extirq_reg <= dmem_wdata[0];
    end
    assign ext_irq = extirq_reg;

    // ── SRAM array ──────────────────────────────────────────────────────────
    reg [7:0] mem [0:MEM_SIZE-1];
    integer i;

    initial begin
        // Zero-fill first, then overlay the program hex
        for (i = 0; i < MEM_SIZE; i = i + 1)
            mem[i] = 8'h00;
        if (INIT_FILE != "")
            $readmemh(INIT_FILE, mem);
    end

    // --- Instruction read (combinational) ---
    // 25-bit index covers the full 32 MB range (0x0000_0000 – 0x01FF_FFFF).
    wire [24:0] ia = imem_addr[24:0];
    wire [31:0] imem_word = {mem[ia+3], mem[ia+2], mem[ia+1], mem[ia]};
    // Not valid until the handshake completes: a core that captures the fetch
    // while imem_ready is low latches junk rather than the right instruction.
    // See NOTREADY_DATA in the header for why X alone is not enough.
    wire [31:0] notready_word = (notready_data == 1) ? 32'h0000_0000 :
                                (notready_data == 2) ? {lfsr[15:0], lfsr[31:16]} :
                                                       32'hxxxx_xxxx;
    assign imem_rdata = imem_ready ? imem_word : notready_word;

    // --- Data read (combinational) ---
    wire [24:0] da = dmem_addr[24:0];
    wire [31:0] mem_rdata = {mem[da+3], mem[da+2], mem[da+1], mem[da]};

    // --- Data write (synchronous, byte-lane masked) ---
    // The write commits only on the cycle the handshake completes, so a store
    // whose request is withdrawn before dmem_ready never reaches the array.
    always @(posedge clk) begin
        if (dmem_req && dmem_we && dmem_ready && in_mem) begin
            if (dmem_be[0]) mem[da]   <= dmem_wdata[7:0];
            if (dmem_be[1]) mem[da+1] <= dmem_wdata[15:8];
            if (dmem_be[2]) mem[da+2] <= dmem_wdata[23:16];
            if (dmem_be[3]) mem[da+3] <= dmem_wdata[31:24];
        end
    end

    // ── CLINT instance ──────────────────────────────────────────────────────
    wire [31:0] clint_rdata;
    wire [15:0] clint_offset = dmem_addr[15:0];  // offset within CLINT space

    clint clint_inst(
        .clk      (clk),
        .rst      (rst),
        .addr     (clint_offset),
        .wdata    (dmem_wdata),
        .wmask    (dmem_be),
        .we       (dmem_req && dmem_we && dmem_ready && in_clint_reg),
        .rdata    (clint_rdata),
        .timer_irq(timer_irq),
        .sw_irq   (sw_irq),
        .mtime_out(mtime_out)
    );

    // --- Data read mux: MEIP hook, CLINT registers, CLINT padding, or SRAM ---
    // in_extirq is first because its address lies inside the CLINT aperture.
    // Masked by dmem_ready for the same reason as imem_rdata above.
    wire [31:0] dmem_word = in_extirq    ? {31'b0, extirq_reg} :
                            in_clint_reg ? clint_rdata :
                            in_clint     ? 32'h0000_0000 : mem_rdata;
    wire [31:0] notready_dword = (notready_data == 1) ? 32'h0000_0000 :
                                 (notready_data == 2) ? ~lfsr :
                                                        32'hxxxx_xxxx;
    assign dmem_rdata = dmem_ready ? dmem_word : notready_dword;

    // ── Handshake checker ───────────────────────────────────────────────────
    // The core's side of the contract (see src/fyracore.v): once a request
    // is raised it stays raised, with the same address -- and for data the
    // same we/be/wdata -- until the cycle ready is seen with it. A core
    // that withdraws or changes a request mid-wait would lose or corrupt the
    // transfer on a real request/ready bus, even where this model's
    // combinational array happens to hide it. Any violation stops the run.
    reg        i_pend, d_pend;
    reg [31:0] i_addr_q, d_addr_q, d_wdata_q;
    reg [3:0]  d_be_q;
    reg        d_we_q;
    always @(posedge clk) begin
        if (rst) begin
            i_pend <= 1'b0;
            d_pend <= 1'b0;
        end else begin
            if (i_pend && (!imem_req || imem_addr !== i_addr_q)) begin
                $display("ERROR: imem request changed before ready (addr %08h -> %08h, req %b)",
                         i_addr_q, imem_addr, imem_req);
                $fatal(1);
            end
            if (d_pend && (!dmem_req || dmem_addr !== d_addr_q || dmem_we !== d_we_q ||
                           dmem_be !== d_be_q || (d_we_q && dmem_wdata !== d_wdata_q))) begin
                $display("ERROR: dmem request changed before ready (addr %08h -> %08h, we %b -> %b, req %b)",
                         d_addr_q, dmem_addr, d_we_q, dmem_we, dmem_req);
                $fatal(1);
            end
            i_pend    <= imem_req && !imem_ready;
            d_pend    <= dmem_req && !dmem_ready;
            i_addr_q  <= imem_addr;
            d_addr_q  <= dmem_addr;
            d_we_q    <= dmem_we;
            d_be_q    <= dmem_be;
            d_wdata_q <= dmem_wdata;
        end
    end

endmodule
