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

module memory_model #(
    parameter MEM_SIZE  = 33554432,      // 32 MB (0x0000_0000 – 0x01FF_FFFF)
    parameter INIT_FILE = "program.hex"  // hex file loaded at address 0
)(
    input  wire        clk,
    input  wire        rst,
    // Instruction port (read-only, combinational)
    input  wire [31:0] imem_addr,
    output wire [31:0] imem_rdata,
    // Data port (read/write)
    input  wire [31:0] dmem_addr,
    input  wire [31:0] dmem_wdata,
    input  wire [3:0]  dmem_wmask,
    input  wire        dmem_we,
    output wire [31:0] dmem_rdata,
    // Memory ready signals (always 1 for combinational sim memory)
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
    assign imem_ready = 1'b1;
    assign dmem_ready = 1'b1;

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
        else if (dmem_we && in_extirq && dmem_wmask[0])
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
    assign imem_rdata = {mem[ia+3], mem[ia+2], mem[ia+1], mem[ia]};

    // --- Data read (combinational) ---
    wire [24:0] da = dmem_addr[24:0];
    wire [31:0] mem_rdata = {mem[da+3], mem[da+2], mem[da+1], mem[da]};

    // --- Data write (synchronous, byte-lane masked) ---
    always @(posedge clk) begin
        if (dmem_we && in_mem) begin
            if (dmem_wmask[0]) mem[da]   <= dmem_wdata[7:0];
            if (dmem_wmask[1]) mem[da+1] <= dmem_wdata[15:8];
            if (dmem_wmask[2]) mem[da+2] <= dmem_wdata[23:16];
            if (dmem_wmask[3]) mem[da+3] <= dmem_wdata[31:24];
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
        .wmask    (dmem_wmask),
        .we       (dmem_we && in_clint_reg),
        .rdata    (clint_rdata),
        .timer_irq(timer_irq),
        .sw_irq   (sw_irq),
        .mtime_out(mtime_out)
    );

    // --- Data read mux: MEIP hook, CLINT registers, CLINT padding, or SRAM ---
    // in_extirq is first because its address lies inside the CLINT aperture.
    assign dmem_rdata = in_extirq    ? {31'b0, extirq_reg} :
                        in_clint_reg ? clint_rdata :
                        in_clint     ? 32'h0000_0000 : mem_rdata;

endmodule
