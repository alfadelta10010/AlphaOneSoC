// Audio: one square-wave tone voice, nothing else (user decision 2026-11-21, "ultra basic tone generator,
// basic 8-bit music is fine, play Tetris"). Original design; no interrupt. audio_o is the voice's square flop.
//   0x00 TONE0 : {13'b0, 1'b0, O[2:0], P[11:0]}   f = clk/16 / 2^O / (2(P+1)) = 1953125 / (2^O (P+1)) Hz at 62.5 MHz
//   0x10 CTRL  : {31'b0, EN}
// The registers alias every 0x20 (addr[4:2] only); other offsets in that span read 0 and ignore writes; bits above the fields read 0 (there is no volume, noise or PCM).
// EN = 0 holds the counters and the pin at their reset values. A new P takes effect at the next reload.
// Range at 62.5 MHz: O = 0 gives 477 Hz (P = 4095) to 1.953 MHz (P = 0); O = 7 reaches 3.7 Hz. Pick the smallest O with
// P <= 4095 for the best resolution. Worked note: A4 = 440 Hz -> O = 1, P = 2218: 1953125 / (2 * 2219) = 440.09 Hz.
// Tetris (Korobeiniki) notes, smallest O, equal-tempered A4 = 440 (cents error is tuning only, below 0.5):
//   note   O    P     Hz        cents      note   O    P     Hz        cents
//   E2     3   2962   82.40    -0.2        C5     0   3732  523.21    -0.2
//   A2     3   2218  110.02    +0.4        D5     0   3324  587.41    +0.2
//   E4     1   2962  329.59    -0.2        E5     0   2962  659.17    -0.2
//   A4     1   2218  440.09    +0.4        F5     0   2795  698.54    +0.2
//   B4     0   3954  493.84    -0.2        G5     0   2490  784.07    +0.2
//                                          A5     0   2218  880.18    +0.4
module audio (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [4:2]  addr,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    output reg         audio_o
);
    reg [11:0] per, c;
    reg [2:0]  oct;
    reg        en;
    reg [10:0] pre;

    wire w  = sel & we;
    wire b  = (pre[3:0] == 4'hF);
    wire [6:0] m  = (7'd1 << oct) - 7'd1;
    wire       tk = b & ((pre[10:4] & m) == m);

    always @(posedge clk) begin
        if (rst) begin
            per <= 12'd0; oct <= 3'd0; c <= 12'd0; audio_o <= 1'b0; en <= 1'b0; pre <= 11'd0;
        end else begin
            if (w && addr == 3'd0 && be[0]) per[7:0] <= wdata[7:0];
            if (w && addr == 3'd0 && be[1]) begin per[11:8] <= wdata[11:8]; oct <= wdata[14:12]; end
            if (w && addr == 3'd4 && be[0]) en <= wdata[0];
            if (!en) begin pre <= 11'd0; c <= 12'd0; audio_o <= 1'b0; end
            else begin
                pre <= pre + 11'd1;
                if (tk) begin
                    if (c == 12'd0) begin c <= per; audio_o <= ~audio_o; end
                    else c <= c - 12'd1;
                end
            end
        end
    end

    assign rdata = (addr == 3'd0) ? {17'b0, oct, per} :
                   (addr == 3'd4) ? {31'b0, en} : 32'b0;
endmodule
