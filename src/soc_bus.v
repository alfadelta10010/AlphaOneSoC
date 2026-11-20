// SoC bus fabric: the core's data port fanned out to its targets.
//
// This is the core's own request/ready handshake (see src/fyracore.v), not
// APB. Memory accesses (flash, PSRAM) pass straight through to the memory
// controller. Every IO access (CLINT, PLIC, UART, GPIO, syscon) takes two
// phases and goes through a register (decision D14: the read data of every IO
// target reaches the core's load path from a flop, which keeps the placer
// from packing the IO slot against that path):
//
//   phase 1 (ph = 0): the target's select is high. The access completes on
//     the edge where select and the target's ready are both high; that edge
//     captures the read data into io_q and sets ph. UART TX / SPI
//     back-pressure keeps the target's ready low, which lengthens phase 1.
//   phase 2 (ph = 1): every IO select is low; d_ready is high and d_rdata is
//     io_q; the core completes and ph clears on the next edge.
//
// A target therefore sees exactly one select && ready edge per access, so a
// UART RX pop, an LSR error clear, a PLIC claim, a W1C and every write act
// once. The core holds d_req, address and data stable until it sees d_ready,
// so phase 2 always sees the request of phase 1. An IO target's ready may be
// low only on a cycle its select is high, so the bus ANDs them instead of
// decoding which one to listen to. Each IO access costs one clock more than a
// combinational bus would.
//
// Address, write data, byte enables and write enable go to every target
// unchanged (the SoC top wires them straight through); only the request is
// steered.
//
// The decode looks at a handful of address bits. That is only correct because
// the core's PMA check has already refused every address outside the mapped
// windows, so no request ever reaches this module for an address that would
// alias:
//
//   addr[31]          PSRAM    0x8000_0000   -> memory controller
//   addr[29]          flash    0x2000_0000   -> memory controller
//   addr[28]          IO       0x1000_0000   -> addr[17:16]: 0 UART, 1 GPIO, 2 syscon
//   addr[27]          PLIC     0x0C00_0000   (PMA IO2 is the only admitted range with bit 27
//                                             set below 0x1000_0000)
//   none of those     CLINT    0x0200_0000
//
// syscon (src/syscon.v) decodes its own offset bits and never holds ready low.

module soc_bus (
    input  wire        clk,
    input  wire        rst,
    // Core data port
    input  wire        d_req,
    input  wire [31:0] d_addr,
    output wire [31:0] d_rdata,
    output wire        d_ready,
    // Memory controller (flash and PSRAM)
    output wire        mem_req,
    input  wire [31:0] mem_rdata,
    input  wire        mem_ready,
    // CLINT
    output wire        clint_sel,
    input  wire [31:0] clint_rdata,
    // PLIC
    output wire        plic_sel,
    input  wire [31:0] plic_rdata,
    // IO peripherals
    output wire        uart_sel,
    input  wire [31:0] uart_rdata,
    input  wire        uart_ready,
    output wire        gpio_sel,
    input  wire [31:0] gpio_rdata,
    input  wire        gpio_ready,
    output wire        syscon_sel,
    input  wire [31:0] syscon_rdata
);

    wire is_mem = d_addr[31] | d_addr[29];
    wire is_io  = !is_mem && d_addr[28];
    wire [1:0] io_idx = d_addr[17:16];

    reg         ph;                     // 1 = phase 2: the core completes this clock
    reg  [31:0] io_q;                   // IO read data captured on the phase-1 completing edge

    wire io_req   = d_req && !is_mem;
    wire phase1   = io_req && !ph;
    wire io_ready = uart_ready && gpio_ready;
    wire io_done  = phase1 && io_ready;

    assign mem_req    = d_req && is_mem;
    assign clint_sel  = phase1 && !d_addr[28] && !d_addr[27];
    assign plic_sel   = phase1 && !d_addr[28] && d_addr[27];
    assign uart_sel   = phase1 && is_io && (io_idx == 2'd0);
    assign gpio_sel   = phase1 && is_io && (io_idx == 2'd1);
    assign syscon_sel = phase1 && is_io && (io_idx == 2'd2);

    wire [31:0] io_rdata = d_addr[28] ? ((io_idx == 2'd0) ? uart_rdata   :
                                         (io_idx == 2'd1) ? gpio_rdata   :
                                         (io_idx == 2'd2) ? syscon_rdata : 32'h0000_0000) :
                           d_addr[27] ? plic_rdata : clint_rdata;

    always @(posedge clk) begin
        if (rst)          ph <= 1'b0;
        else if (io_done) ph <= 1'b1;
        else if (ph)      ph <= 1'b0;
    end
    always @(posedge clk) if (io_done) io_q <= io_rdata;

    assign d_ready = is_mem ? mem_ready : ph;
    assign d_rdata = is_mem ? mem_rdata : io_q;

endmodule
