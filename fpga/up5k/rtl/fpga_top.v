// UP5K top for the TinyTapeout FPGA kit: the tapeout wrapper, exact, plus the IO cells.
//   clk   = pad 20 (RP2350 clock) or, with -DINTCLK, pad 35 (24 MHz on-board oscillator)
//   rst_n = pad 37 (RP2350 reset), used exactly as the tapeout wrapper uses it
//   uio   = SB_IO tristate, per-bit output enable = uio_oe (as tt_fpga_top.v of tt-support-tools)
// Nothing is added: no reset synchroniser, no clock logic, only the IO cells.
module fpga_top (
`ifdef INTCLK
    input  wire       intclk,
`else
    input  wire       clk,
`endif
    input  wire       rst_n,
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    inout  wire [7:0] uio
);
`ifdef INTCLK
    wire clk = intclk;
`endif
    wire [7:0] uio_in, uio_out, uio_oe;

    SB_IO #(
        .PIN_TYPE(6'b1010_01)
    ) uio_pin [7:0] (
        .PACKAGE_PIN  (uio),
        .OUTPUT_ENABLE(uio_oe),
        .D_OUT_0      (uio_out),
        .D_IN_0       (uio_in)
    );

    tt_um_alfadelta10010_alphaone_soc u_dut (
        .ui_in(ui_in), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n)
    );
endmodule
