// WO-54b: pin-level rules of the QSPI engine, over the real engine (negedge flops included) with free
// inputs. Each clock is two steps (clk2fflogic via sby `multiclock on`); the block at the end makes clk
// alternate (starting low) and lets every input but io_in change only at the step where clk rises, as
// a synchronous environment would. Every assert is gated on `armed` (a reset has been applied) and on
// !rst (the registered outputs show the previous cycle while rst is high).
//   (a) CS0 is never low while CS1 or CS2 is low (asserted for the whole run, start-up included;
//       the start-up selects are 3'b110 or 3'b001, never mixed)
//   (b) between one CS-low period and the next every CS is high for >= 2 clocks (tCPH), and a CS
//       never moves from one chip straight to another
//   (c) engine idle with CS0 low (a stream is open): SCK low and io_oe 0
//   (c') the same for a PSRAM burst: engine idle with any chip select low: SCK low, bus released, and that
//       state lasts one clock at most (a request is taken, or chip select rises at once)
//   (e) not a rule here: the SCK count of a PSRAM window needs the engine's request-hold contract (nbytes_m1 is read live), so it is
//       checked by tb_qspi_burst (model: <= 4 words, no 1 KB page crossing, CE# low <= tCEM) and, in composition, by mem_tcem_burst
//   (d) an EDh command (8 bits on IO0 in the first 8 SCK rising edges of a CS0 window, taken at the
//       rising edge: io_out one step before it) only after ddr has been high at some clock
module qspi_pins_props (
    input  wire        clk, rst, rd_late, stream_en, ddr, burst,
    input  wire [2:0]  ddr_cap,
    input  wire        start, we,
    input  wire [1:0]  cs_sel, nbytes_m1,
    input  wire [23:0] addr,
    input  wire [31:0] wdata,
    input  wire [3:0]  io_in
);
    wire        idle, done, sck, ctl_oe, io_oe;
    wire [31:0] rdata;
    wire [2:0]  cs_n;
    wire [3:0]  io_out;
    qspi_ctrl dut (.clk(clk), .rst(rst), .rd_late(rd_late), .stream_en(stream_en), .ddr(ddr), .ddr_cap(ddr_cap), .burst(burst),
        .start(start), .cs_sel(cs_sel), .addr(addr), .we(we), .nbytes_m1(nbytes_m1), .wdata(wdata),
        .idle(idle), .done(done), .rdata(rdata), .sck(sck), .cs_n(cs_n), .ctl_oe(ctl_oe), .io_out(io_out),
        .io_oe(io_oe), .io_in(io_in));

    reg armed = 1'b0;
    always @(posedge clk) if (rst) armed <= 1'b1;
    wire live = armed && !rst;

    // (b) monitor
    reg [2:0] cs_q = 3'b111;
    reg [1:0] hi = 2'd0;                    // clocks (saturating at 2) the chip selects were all high, up to the previous clock
    reg seen_low = 1'b0, ps_low = 1'b0, ddr_ever = 1'b0;
    always @(posedge clk) begin
        cs_q <= cs_n;
        hi <= (cs_n == 3'b111) ? (hi == 2'd2 ? hi : hi + 2'd1) : 2'd0;
        if (cs_n != 3'b111) seen_low <= 1'b1;
        if (!cs_n[1] || !cs_n[2]) ps_low <= 1'b1;
        if (ddr) ddr_ever <= 1'b1;
    end
    wire fall   = cs_n != 3'b111 && cs_q == 3'b111;
    wire switch = cs_n != 3'b111 && cs_q != 3'b111 && cs_n != cs_q;

    // (d) monitor: the pin one step before a rising SCK edge is what the flash samples
    reg sck_q = 1'b0, io0_q = 1'b0;
    reg [4:0] ec = 5'd0;
    reg okED = 1'b1;
    wire edge0 = !cs_n[0] && sck && !sck_q;
    wire edbit = 8'hED >> (~ec[2:0]);
    wire ed_now = okED && (io0_q == edbit);
    wire ed_full = edge0 && ec == 5'd7 && ed_now;
    always @(posedge clk) begin
        sck_q <= sck; io0_q <= io_out[0];
        if (rst || cs_n[0]) begin ec <= 5'd0; okED <= 1'b1; end
        else if (edge0) begin
            if (ec != 5'd31) ec <= ec + 5'd1;
            if (ec < 5'd8) okED <= ed_now;
        end
    end

    // (c')/(e) monitors
    wire ps_cs = !cs_n[1] || !cs_n[2];
    reg [5:0] pn = 6'd0;                    // SCK rises of the PSRAM window so far
    reg burst_ever = 1'b0, idle_q = 1'b0;
    wire edgeP = ps_cs && sck && !sck_q;
    wire [5:0] pn_now = !ps_cs ? 6'd0 : edgeP ? (pn == 6'd63 ? pn : pn + 6'd1) : pn;
    always @(posedge clk) begin
        pn <= rst ? 6'd0 : pn_now;
        if (burst) burst_ever <= 1'b1;
        idle_q <= idle && ps_cs && !start;
    end

    always @(*) if (live) begin
        if (idle && cs_n != 3'b111) assert (!sck && !io_oe);                              // (c')
        if (idle && ps_cs && !start) assert (!idle_q);                                    // (c') one clock (a flash stream, CS0, may idle open)
        assert (!(!cs_n[0] && (!cs_n[1] || !cs_n[2])));                                   // (a)
        if (fall && seen_low) assert (hi == 2'd2);                                        // (b) gap
        assert (!switch);                                                                 // (b) no direct move
        if (idle && !cs_n[0]) assert (!sck && !io_oe);                                    // (c)
        if (ed_full) assert (ddr_ever);                                                   // (d)
    end

    // clock model
    (* gclk *) reg gclk;
    reg gseen = 1'b0, clk_p = 1'b0;
    wire [69:0] ins = {rst, rd_late, stream_en, ddr, burst, ddr_cap, start, we, cs_sel, nbytes_m1, addr, wdata};
    reg  [69:0] ins_p;
    always @(posedge gclk) begin gseen <= 1'b1; clk_p <= clk; ins_p <= ins; end
    always @(*) begin
        assume (gseen || !clk);
        assume (!gseen || clk != clk_p);
        assume (!gseen || (clk && !clk_p) || ins == ins_p);
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (live && idle && !cs_n[0] && !sck && !io_oe);                               // an open stream, idle
        cover (live && fall && seen_low && hi == 2'd2);                                   // a CS gap of exactly 2 clocks
        cover (live && !cs_n[0] && ps_low);                                               // CS0 after a PSRAM transfer
        cover (live && ed_full && ddr_ever);
        cover (live && pn_now == 6'd44);                                                  // a full 4-word PSRAM line in one window
        cover (live && idle && ps_cs && !sck && !io_oe);                                  // a PSRAM burst open, idle                                              // an EDh command
    end
`endif
endmodule
