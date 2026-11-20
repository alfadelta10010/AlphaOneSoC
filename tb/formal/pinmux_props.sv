// WO-56: output pinmux (src/pinmux.v), k-induction at length 1. Every property relates one non-reset step to
// the previous one (state and inputs copied in *_q). White-box port `codes` exposed by run.sh PRE.
//   P1 uo == mux(codes, sources) of the previous cycle (one flop per pin)
//   P2 after reset uo == 0x39 and codes == 0
//   P3 read-back == stored codes, bit 3 of each nibble 0
//   P4 a write changes only the nibbles of enabled lanes
module pinmux_props (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    input  wire [7:0]  dflt, gpio,
    input  wire        rts_n, audio,
    input  wire [3:0]  pwm
);
    wire [31:0] rdata;
    wire [7:0]  uo;
    wire [23:0] codes;
    pinmux dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .wdata(wdata), .rdata(rdata),
                .dflt(dflt), .gpio(gpio), .rts_n(rts_n), .audio(audio), .pwm(pwm), .uo(uo), .codes(codes));

    reg armed = 1'b0, rst_q = 1'b0, armed_q = 1'b0, sel_q = 0, we_q = 0, rts_q = 0, aud_q = 0;
    reg [3:0] be_q = 0, pwm_q = 0; reg [31:0] wdata_q = 0; reg [7:0] dflt_q = 0, gpio_q = 0;
    reg [23:0] codes_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed; sel_q <= sel; we_q <= we; be_q <= be; wdata_q <= wdata;
        dflt_q <= dflt; gpio_q <= gpio; rts_q <= rts_n; aud_q <= audio; pwm_q <= pwm; codes_q <= codes;
    end
    wire step = armed_q && !rst_q;
    wire w_q  = sel_q && we_q;

    reg [7:0] exp_uo; reg [23:0] exp_codes; integer j;
    always @(*) begin
        for (j = 0; j < 8; j = j + 1) begin
            case (codes_q[3*j +: 3])
                3'd0: exp_uo[j] = dflt_q[j];
                3'd1: exp_uo[j] = gpio_q[j];
                3'd2: exp_uo[j] = rts_q;
                3'd3: exp_uo[j] = aud_q;
                3'd4: exp_uo[j] = pwm_q[0];
                3'd5: exp_uo[j] = pwm_q[1];
                3'd6: exp_uo[j] = pwm_q[2];
                default: exp_uo[j] = pwm_q[3];
            endcase
            exp_codes[3*j +: 3] = (w_q && be_q[j/2]) ? wdata_q[4*j +: 3] : codes_q[3*j +: 3];
        end
        if (armed_q && rst_q) assert (uo == 8'h39 && codes == 24'd0);                    // P2
        if (armed) begin                                                                 // P3
            for (j = 0; j < 8; j = j + 1) assert (rdata[4*j +: 4] == {1'b0, codes[3*j +: 3]});
        end
        if (step) begin
            assert (uo == exp_uo);                                                       // P1
            assert (codes == exp_codes);                                                 // P4
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (step && codes_q[2:0] == 3'd0 && uo[0] == dflt_q[0]);
        cover (step && codes_q[2:0] == 3'd1);
        cover (step && codes_q[2:0] == 3'd2);
        cover (step && codes_q[2:0] == 3'd3);
        cover (step && codes_q[2:0] == 3'd4 && pwm_q[0] && uo[0]);
        cover (step && codes_q[2:0] == 3'd5);
        cover (step && codes_q[2:0] == 3'd6);
        cover (step && codes_q[2:0] == 3'd7 && pwm_q[3] && uo[0]);
        cover (step && codes_q[23:21] == 3'd0);
        cover (step && codes_q[23:21] == 3'd1);
        cover (step && codes_q[23:21] == 3'd2);
        cover (step && codes_q[23:21] == 3'd3);
        cover (step && codes_q[23:21] == 3'd4 && pwm_q[0] && uo[7]);
        cover (step && codes_q[23:21] == 3'd5);
        cover (step && codes_q[23:21] == 3'd6);
        cover (step && codes_q[23:21] == 3'd7 && pwm_q[3] && uo[7]);
    end
`endif
endmodule
