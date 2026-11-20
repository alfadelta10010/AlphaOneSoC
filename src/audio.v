// Audio: three square voices + one LFSR noise source, 4-bit linear volume each, summed into an 8-bit PWM DAC
// (clk/256 = 244.14 kHz at 62.5 MHz). Original design; no interrupt.
//   0x00,0x04,0x08 TONEx : {12'b0, V[3:0], 1'b0, O[2:0], P[11:0]}   f = clk/16 / 2^O / (2(P+1))
//   0x0C NOISE           : {12'b0, V[3:0], 13'b0, R[2:0]}           shift rate clk/16 / 2^R
//   0x10 CTRL            : {30'b0, PCM, EN}
//   0x14 PCM             : {24'b0, SAMPLE}
// EN = 0 holds every counter, q, the LFSR (to 1), the DAC and audio_o at their reset values.
// A new P takes effect at the next reload. The latched level starts a new 256-clock PWM frame.
module audio (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [4:2]  addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output reg         audio_o
);
    reg [35:0] per, c;
    reg [8:0]  oct;
    reg [11:0] vol;
    reg [2:0]  q;
    reg [2:0]  nrate;
    reg [3:0]  nvol;
    reg        en, pcm;
    reg [7:0]  smp, dc, lvl;
    reg [10:0] pre;
    reg [14:0] l;
    reg [31:0] r;

    wire w = sel & we;
    wire b = (pre[3:0] == 4'hF);

    genvar i;
    generate for (i = 0; i < 3; i = i + 1) begin : v
        wire [2:0] o  = oct[3*i +: 3];
        wire [6:0] m  = (7'd1 << o) - 7'd1;
        wire       tk = b & ((pre[10:4] & m) == m);
        wire       wr = w & (addr == i);
        always @(posedge clk) begin
            if (rst) begin
                per[12*i +: 12] <= 12'd0; oct[3*i +: 3] <= 3'd0; vol[4*i +: 4] <= 4'd0;
                c[12*i +: 12] <= 12'd0; q[i] <= 1'b0;
            end else begin
                if (wr && be[0]) per[12*i +: 8] <= wdata[7:0];
                if (wr && be[1]) begin per[12*i+8 +: 4] <= wdata[11:8]; oct[3*i +: 3] <= wdata[14:12]; end
                if (wr && be[2]) vol[4*i +: 4] <= wdata[19:16];
                if (!en) begin c[12*i +: 12] <= 12'd0; q[i] <= 1'b0; end
                else if (tk) begin
                    if (c[12*i +: 12] == 12'd0) begin c[12*i +: 12] <= per[12*i +: 12]; q[i] <= ~q[i]; end
                    else c[12*i +: 12] <= c[12*i +: 12] - 12'd1;
                end
            end
        end
    end endgenerate

    wire [6:0] nm = (7'd1 << nrate) - 7'd1;
    wire       nt = b & ((pre[10:4] & nm) == nm);
    wire [5:0] sum = (q[0] ? {2'b0, vol[3:0]} : 6'd0) + (q[1] ? {2'b0, vol[7:4]} : 6'd0)
                   + (q[2] ? {2'b0, vol[11:8]} : 6'd0) + (l[0] ? {2'b0, nvol} : 6'd0);
    wire [7:0] level = pcm ? smp : {sum, 2'b00};

    always @(posedge clk) begin
        if (rst) begin
            nrate <= 3'd0; nvol <= 4'd0; en <= 1'b0; pcm <= 1'b0; smp <= 8'd0;
            pre <= 11'd0; l <= 15'd1; dc <= 8'd0; lvl <= 8'd0; audio_o <= 1'b0;
        end else begin
            if (w && addr == 3'd3 && be[0]) nrate <= wdata[2:0];
            if (w && addr == 3'd3 && be[2]) nvol <= wdata[19:16];
            if (w && addr == 3'd4 && be[0]) begin en <= wdata[0]; pcm <= wdata[1]; end
            if (w && addr == 3'd5 && be[0]) smp <= wdata[7:0];
            if (!en) begin pre <= 11'd0; l <= 15'd1; dc <= 8'd0; lvl <= 8'd0; end
            else begin
                pre <= pre + 11'd1;
                if (nt) l <= {l[0] ^ l[1], l[14:1]};
                dc <= dc + 8'd1;
                if (dc == 8'hFF) lvl <= level;
            end
            audio_o <= en & (dc < lvl);
        end
    end

    always @(*) begin
        case (addr)
            3'd0: r = {12'b0, vol[3:0],  1'b0, oct[2:0], per[11:0]};
            3'd1: r = {12'b0, vol[7:4],  1'b0, oct[5:3], per[23:12]};
            3'd2: r = {12'b0, vol[11:8], 1'b0, oct[8:6], per[35:24]};
            3'd3: r = {12'b0, nvol, 13'b0, nrate};
            3'd4: r = {30'b0, pcm, en};
            3'd5: r = {24'b0, smp};
            default: r = 32'b0;
        endcase
    end
    assign rdata = r;
endmodule
