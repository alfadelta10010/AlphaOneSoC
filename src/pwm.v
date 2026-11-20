// Timer/PWM, SiFive pwm0 register layout (FE310-G002 ch. 20, Linux drivers/pwm/pwm-sifive.c), four 16-bit
// comparators on a scaled counter. ip[3:0] drive both the pwm_o pins (via the pinmux) and the timer irqs.
//   0x00 pwmcfg  : {ip[3:0], 12'b0 (gang, center), 2'b0, enoneshot, enalways, 2'b0 (deglitch ignored),
//                   zerocmp, sticky, 4'b0, scale[3:0]}   lane 3 write sets/clears ip directly
//   0x08 pwmcount: reads 0 (departure); any write restarts the prescaler and the scaled count
//   0x10 pwms    : {16'b0, s}; read-only, as in sifive-blocks (Timer.scala s_desc access R; the manual's RW is not built)
//   0x20..0x2C pwmcmp0..3: {16'b0, cmp}, lanes 0 and 1; pwmcmp2/3 read 0, writes ignored (not built)
// Departure (WO-63, area for the cache): 2 of 4 comparators built; pwm-sifive's npwm = 4 still probes, channels 2-3
// never fire: ip[3:2], pwm_o[3:2], irq[3:2] are constant 0 and cfg lane-3 writes to ip[3:2] are ignored.
// Counter: tick = en & (pre & (2^scale - 1)) == 2^scale - 1; s counts on tick. zerocmp & s >= cmp0 resets
// pre and s one cycle after the match. enoneshot clears on that reset or on the s wrap (FE310-G002 20.8/20.12:
// with zerocmp clear the reset condition is the carry out of the top pwms bit).
// Pin polarity: pwm_o = ip, high while the registered pwms >= pwmcmpX (manual 20.7/20.9, PWM.scala gpio = ip).
// pwm-sifive.c's header claims the opposite, but its arithmetic (cmp = 0xFFFF - duty) requires this. Do not invert.
// A cfg write takes effect next clock; a pwmcount write wins over counting.
module pwm (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [5:2]  addr,
    input  wire [31:0] wdata,
    output reg  [31:0] rdata,
    output wire [3:0]  pwm_o,
    output wire [3:0]  irq
);
    reg [3:0]  scale;
    reg [1:0]  ip;
    reg        sticky, zerocmp, enalways, enoneshot;
    reg [14:0] pre;
    reg [15:0] s, cmp0, cmp1;

    wire w     = sel & we;
    wire wcfg  = w & (addr == 4'd0);
    wire wcnt  = w & (addr == 4'd2);
    wire wc0   = w & (addr == 4'd8);
    wire wc1   = w & (addr == 4'd9);

    wire [1:0]  ge  = {s >= cmp1, s >= cmp0};
    wire        en  = enalways | enoneshot;
    wire [14:0] m   = (15'd1 << scale) - 15'd1;
    wire        tick = en & ((pre & m) == m);
    wire        zr   = zerocmp & ge[0];
    wire        wrap = tick & (s == 16'hFFFF);

    always @(posedge clk) begin
        if (rst) begin
            scale <= 4'd0; sticky <= 1'b0; zerocmp <= 1'b0; enalways <= 1'b0; enoneshot <= 1'b0;
            ip <= 2'd0; pre <= 15'd0; s <= 16'd0;
            cmp0 <= 16'hFFFF; cmp1 <= 16'hFFFF;
        end else begin
            if (wcnt || zr) begin pre <= 15'd0; s <= 16'd0; end
            else if (en) begin
                pre <= pre + 15'd1;
                if (tick) s <= s + 16'd1;
            end
            if (zr || wrap) enoneshot <= 1'b0;
            if (wcfg && be[0]) scale <= wdata[3:0];
            if (wcfg && be[1]) begin
                sticky <= wdata[8]; zerocmp <= wdata[9]; enalways <= wdata[12]; enoneshot <= wdata[13];
            end
            if (wcfg && be[3]) ip <= wdata[29:28];
            else ip <= ge | ({2{sticky}} & ip);
            if (wc0 && be[0]) cmp0[7:0]  <= wdata[7:0];
            if (wc0 && be[1]) cmp0[15:8] <= wdata[15:8];
            if (wc1 && be[0]) cmp1[7:0]  <= wdata[7:0];
            if (wc1 && be[1]) cmp1[15:8] <= wdata[15:8];
        end
    end

    always @(*) begin
        case (addr)
            4'd0:  rdata = {2'b0, ip, 12'b0, 2'b0, enoneshot, enalways, 2'b0, zerocmp, sticky, 4'b0, scale};
            4'd4:  rdata = {16'b0, s};
            4'd8:  rdata = {16'b0, cmp0};
            4'd9:  rdata = {16'b0, cmp1};
            default: rdata = 32'b0;
        endcase
    end
    assign pwm_o = {2'b0, ip};
    assign irq   = {2'b0, ip};
endmodule
