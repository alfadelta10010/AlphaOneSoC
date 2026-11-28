// Gate FSM invariant (WO-24 closure): the four one-hot FSMs of the netlist
// hold exactly one set bit in every state reachable from their reset code.
module fsm_inv_props(input clk, input rst_n, input ena, input [7:0] ui_in, input [7:0] uio_in);
  wire [7:0] uo_out, uio_out, uio_oe;
  wire [2:0] ms; wire [9:0] qs; wire [2:0] sp;
`ifdef MULDIV5   // PX-6 removed S_SH: 5 muldiv states
  wire [4:0] st; localparam [4:0] ST0 = 5'b00001;
`else
  wire [5:0] st; localparam [5:0] ST0 = 6'b000001;
`endif
  tt_um_alfadelta10010_alphaone_soc dut (.clk(clk), .rst_n(rst_n), .ena(ena), .ui_in(ui_in), .uio_in(uio_in),
    .uo_out(uo_out), .uio_out(uio_out), .uio_oe(uio_oe),
    .\soc.cpu.exwb_memSize (ms), .\soc.cpu.muldiv_inst.st (st), .\soc.qspi.state (qs), .\soc.gpio_inst.spi_inst.st (sp));
`ifdef NEG
  always @* assert (qs == 10'b0000000001 && st == ST0 && ms == 3'b001 && sp == 3'b001);   // must FAIL: the FSMs move
`else
  always @* begin
    assert ($onehot(ms));
    assert ($onehot(st));
    assert ($onehot(qs));
    assert ($onehot(sp));
  end
`endif
endmodule
