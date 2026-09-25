// SoC bus fabric: the core's data port fanned out to its targets.
//
// This is the core's own request/ready handshake (see src/fyracore.v), not
// APB. APB needs a two-phase transfer -- SETUP, then ACCESS with PENABLE --
// and a bridge state machine to generate it, so every access costs at least
// two cycles and some registers. A single-master bus whose master already
// holds its request until ready needs none of that: this module is an
// address decode and a read-data / ready mux, and it has no registers.
//
// Address, write data, byte enables and write enable go to every target
// unchanged (the SoC top wires them straight through); only the request is
// steered. A target sees a transfer on a cycle its select is high, and the
// transfer completes on the cycle it returns ready. Peripherals are
// single-cycle: ready is their select, and read data is combinational. A
// peripheral with a read side effect (a UART RX pop) acts on a cycle its
// select is high with we low; the core raises its request only for real
// loads, so that cycle is always one.
//
// The decode looks at a handful of address bits. That is only correct because
// the core's PMA check has already refused every address outside the mapped
// windows, so no request ever reaches this module for an address that would
// alias:
//
//   addr[31]          PSRAM    0x8000_0000   -> memory controller
//   addr[29]          flash    0x2000_0000   -> memory controller
//   addr[28]          IO       0x1000_0000   -> addr[17:16]: 0 UART, 1 GPIO, 2 syscon
//   none of those     CLINT    0x0200_0000
//
// A target with nothing behind it yet reads 0 and ignores writes.

module soc_bus (
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
    // IO peripherals
    output wire        uart_sel,
    input  wire [31:0] uart_rdata,
    output wire        gpio_sel,
    input  wire [31:0] gpio_rdata,
    output wire        syscon_sel,
    input  wire [31:0] syscon_rdata
);

    wire is_mem = d_addr[31] | d_addr[29];
    wire is_io  = !is_mem && d_addr[28];
    wire [1:0] io_idx = d_addr[17:16];

    assign mem_req    = d_req && is_mem;
    assign clint_sel  = d_req && !is_mem && !d_addr[28];
    assign uart_sel   = d_req && is_io && (io_idx == 2'd0);
    assign gpio_sel   = d_req && is_io && (io_idx == 2'd1);
    assign syscon_sel = d_req && is_io && (io_idx == 2'd2);

    assign d_ready = is_mem ? mem_ready : 1'b1;
    assign d_rdata = is_mem              ? mem_rdata    :
                     !d_addr[28]         ? clint_rdata  :
                     (io_idx == 2'd0)    ? uart_rdata   :
                     (io_idx == 2'd1)    ? gpio_rdata   :
                     (io_idx == 2'd2)    ? syscon_rdata : 32'h0000_0000;

endmodule
