// WO-56 / slim-down: output pinmux (src/pinmux.v), k-induction at length 1. Every property relates one non-reset
// step to the previous one (state and inputs copied in *_q). White-box ports alt5/alt6 exposed by run.sh PRE.
//   P1 uo == mux of the previous cycle: pins 0-4 dflt, pin 5 alt5 ? rts_n : dflt, pin 6 alt6 ? pwm[0] : dflt,
//      pin 7 pwm[1] always (one flop per pin)
//   P2 after reset uo == 0x39 and alt5 == alt6 == 0
//   P3 read-back: pin 5 nibble = alt5 ? 2 : 0, pin 6 = alt6 ? 4 : 0, every other bit 0 (pin 7 has no code)
//   P4 WARL write: alt5 follows (wdata[22:20] == 2) on lane 2, alt6 (wdata[26:24] == 4) on lane 3, otherwise they
//      hold; any other code stores 0
module pinmux_props (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    input  wire [6:0]  dflt,
    input  wire        rts_n,
    input  wire [1:0]  pwm
);
    wire [31:0] rdata;
    wire [7:0]  uo;
    wire        alt5, alt6;
    pinmux dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .wdata(wdata), .rdata(rdata),
                .dflt(dflt), .rts_n(rts_n), .pwm(pwm), .uo(uo), .alt5(alt5), .alt6(alt6));

    reg armed = 1'b0, rst_q = 1'b0, armed_q = 1'b0, sel_q = 0, we_q = 0, rts_q = 0, a5_q = 0, a6_q = 0;
    reg [3:0] be_q = 0; reg [1:0] pwm_q = 0; reg [31:0] wdata_q = 0; reg [6:0] dflt_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed; sel_q <= sel; we_q <= we; be_q <= be; wdata_q <= wdata;
        dflt_q <= dflt; rts_q <= rts_n; pwm_q <= pwm; a5_q <= alt5; a6_q <= alt6;
    end
    wire step = armed_q && !rst_q;
    wire w_q  = sel_q && we_q;

    wire [7:0] exp_uo = {pwm_q[1], a6_q ? pwm_q[0] : dflt_q[6],
                         a5_q ? rts_q : dflt_q[5], dflt_q[4:0]};
    wire [31:0] exp_rd = {4'd0, 1'b0, alt6 ? 3'd4 : 3'd0, 1'b0, alt5 ? 3'd2 : 3'd0, 20'd0};
    always @(*) begin
        if (armed_q && rst_q) assert (uo == 8'h39 && !alt5 && !alt6);                   // P2
        if (armed) assert (rdata == exp_rd);                                                     // P3
        if (step) begin
            assert (uo == exp_uo);                                                               // P1
            assert (alt5 == ((w_q && be_q[2]) ? (wdata_q[22:20] == 3'd2) : a5_q));               // P4
            assert (alt6 == ((w_q && be_q[3]) ? (wdata_q[26:24] == 3'd4) : a6_q));
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (step && !a5_q && uo[5] == dflt_q[5]);
        cover (step && a5_q && rts_q && uo[5]);
        cover (step && a5_q && !rts_q && !uo[5] && dflt_q[5]);
        cover (step && !a6_q && uo[6] == dflt_q[6]);
        cover (step && a6_q && pwm_q[0] && uo[6]);
        cover (step && a6_q && !pwm_q[0] && !uo[6] && dflt_q[6]);
        cover (step && pwm_q[1] && uo[7]);
        cover (step && !pwm_q[1] && !uo[7]);
        cover (step && w_q && be_q[3] && wdata_q[30:28] == 3'd5 && rdata[31:28] == 4'd0);   // WARL: code 5 on pin 7 reads 0
        cover (step && w_q && be_q[3] && wdata_q[26:24] == 3'd5 && !alt6);                       // WARL: code 5 on pin 6 stores 0
        cover (step && w_q && be_q[2] && wdata_q[22:20] == 3'd4 && !alt5);                       // WARL: code 4 on pin 5 stores 0
        cover (step && alt5 && alt6);
    end
`endif
endmodule
