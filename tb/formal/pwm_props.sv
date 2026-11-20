// WO-54: timer/PWM (src/pwm.v), k-induction at length 1. Every property relates one non-reset step to the
// previous one (state and inputs copied in *_q), so no state invariant is needed. White-box ports exposed by
// run.sh PRE (pwm.conf).
//   P1 pre/s: counting exactly as tick says (no zerocmp match, no pwmcount write)
//   P2 zerocmp & s >= cmp0 (or a pwmcount write) -> pre == 0 && s == 0 next cycle
//   P3 ip == lane-3 write ? wdata[31:28] : ge | sticky & ip_q
//   P4 enoneshot: cfg lane-1 write wins; else falls only on a zerocmp reset or the s wrap; never rises alone
//   P5 reads: cfg layout (deglitch/center/gang read 0), pwms, cmp; pwmcount and other offsets read 0
//   P6 reset values (ip 0, cmp FFFF) so no ip is pending after reset; pwm_o == irq == ip
module pwm_props (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [5:2]  addr,
    input  wire [31:0] wdata
);
    wire [31:0] rdata;
    wire [3:0]  pwm_o, irq, scale, ip;
    wire        sticky, zerocmp, enalways, enoneshot;
    wire [14:0] pre;
    wire [15:0] s, cmp0, cmp1, cmp2, cmp3;
    pwm dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata),
             .pwm_o(pwm_o), .irq(irq), .scale(scale), .ip(ip), .sticky(sticky), .zerocmp(zerocmp),
             .enalways(enalways), .enoneshot(enoneshot), .pre(pre), .s(s),
             .cmp0(cmp0), .cmp1(cmp1), .cmp2(cmp2), .cmp3(cmp3));

    reg armed = 1'b0, rst_q = 1'b0, armed_q = 1'b0;
    reg sel_q = 0, we_q = 0, sticky_q = 0, zerocmp_q = 0, enalways_q = 0, enoneshot_q = 0;
    reg [3:0] be_q = 0, scale_q = 0, ip_q = 0; reg [5:2] addr_q = 0; reg [31:0] wdata_q = 0;
    reg [14:0] pre_q = 0; reg [15:0] s_q = 0, c0_q = 0, c1_q = 0, c2_q = 0, c3_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed;
        sel_q <= sel; we_q <= we; be_q <= be; addr_q <= addr; wdata_q <= wdata;
        scale_q <= scale; ip_q <= ip; sticky_q <= sticky; zerocmp_q <= zerocmp; enalways_q <= enalways;
        enoneshot_q <= enoneshot; pre_q <= pre; s_q <= s; c0_q <= cmp0; c1_q <= cmp1; c2_q <= cmp2; c3_q <= cmp3;
    end

    wire step = armed_q && !rst_q;
    wire w_q    = sel_q && we_q;
    wire wcfg_q = w_q && addr_q == 4'd0;
    wire wcnt_q = w_q && addr_q == 4'd2;
    wire en_q   = enalways_q | enoneshot_q;
    wire [14:0] m_q = (15'd1 << scale_q) - 15'd1;
    wire tick_q = en_q && ((pre_q & m_q) == m_q);
    wire zr_q   = zerocmp_q && s_q >= c0_q;
    wire wrap_q = tick_q && s_q == 16'hFFFF;
    wire [3:0] ge_q = {s_q >= c3_q, s_q >= c2_q, s_q >= c1_q, s_q >= c0_q};

    function [15:0] merge(input [15:0] old, input wr, input [3:0] b, input [31:0] d);
        merge = wr ? {b[1] ? d[15:8] : old[15:8], b[0] ? d[7:0] : old[7:0]} : old;
    endfunction

    always @(*) begin
        if (armed_q && rst_q) assert (ip == 0 && s == 0 && pre == 0 && scale == 0 && !sticky && !zerocmp &&
                                      !enalways && !enoneshot && cmp0 == 16'hFFFF && cmp1 == 16'hFFFF &&
                                      cmp2 == 16'hFFFF && cmp3 == 16'hFFFF);                          // P6
        if (armed) assert (pwm_o == ip && irq == ip);
        if (armed) begin                                                                              // P5
            case (addr)
                4'd0:  assert (rdata == {ip, 12'b0, 2'b0, enoneshot, enalways, 2'b0, zerocmp, sticky, 4'b0, scale});
                4'd4:  assert (rdata == {16'b0, s});
                4'd8:  assert (rdata == {16'b0, cmp0});
                4'd9:  assert (rdata == {16'b0, cmp1});
                4'd10: assert (rdata == {16'b0, cmp2});
                4'd11: assert (rdata == {16'b0, cmp3});
                default: assert (rdata == 32'b0);
            endcase
        end
        if (step) begin
            if (wcnt_q || zr_q) assert (pre == 0 && s == 0);                                          // P2
            else begin                                                                                // P1
                assert (pre == (en_q ? pre_q + 15'd1 : pre_q));
                assert (s == (tick_q ? s_q + 16'd1 : s_q));
            end
            if (wcfg_q && be_q[3]) assert (ip == wdata_q[31:28]);                                     // P3
            else assert (ip == (ge_q | ({4{sticky_q}} & ip_q)));
            if (wcfg_q && be_q[1]) assert (enoneshot == wdata_q[13]);                                 // P4
            else if (zr_q || wrap_q) assert (!enoneshot);
            else assert (enoneshot == enoneshot_q);
            if (wcfg_q && be_q[0]) assert (scale == wdata_q[3:0]); else assert (scale == scale_q);
            if (wcfg_q && be_q[1]) assert (sticky == wdata_q[8] && zerocmp == wdata_q[9] && enalways == wdata_q[12]);
            else assert (sticky == sticky_q && zerocmp == zerocmp_q && enalways == enalways_q);
            assert (cmp0 == merge(c0_q, w_q && addr_q == 4'd8,  be_q, wdata_q));
            assert (cmp1 == merge(c1_q, w_q && addr_q == 4'd9,  be_q, wdata_q));
            assert (cmp2 == merge(c2_q, w_q && addr_q == 4'd10, be_q, wdata_q));
            assert (cmp3 == merge(c3_q, w_q && addr_q == 4'd11, be_q, wdata_q));
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (step && scale_q == 0 && tick_q && !zr_q && !wcnt_q && s == s_q + 1);   // s counts, scale 0 (the 2^16 wrap is only inductive)
        cover (step && scale_q == 2 && tick_q && !zr_q && !wcnt_q && s == s_q + 1);   // s counts, scale 2
        cover (step && zr_q && !wcnt_q);                                                          // zerocmp reset
        cover (step && enoneshot_q && !enoneshot && !wcfg_q);                                     // oneshot ends
        cover (step && sticky_q && ip_q != 0 && ge_q == 0 && ip == ip_q);                         // sticky holds ip
    end
`endif
endmodule
