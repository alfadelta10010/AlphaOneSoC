// SNES gamepad Pmod receiver (TinyTapeout Gamepad Pmod), two pads, read only, with a change interrupt.
// Protocol as TinyTapeout's gamepad_pmod.v (Pat Deegan, psychogenic.com); independent implementation.
//
// The Pmod shifts 24 bits (pad 1 then pad 0, 12 bits each: B Y SELECT START UP DOWN LEFT RIGHT A X L R,
// MSB first, 1 = pressed) on rising CLOCK and pulses LATCH after the last bit. A missing pad reads all
// ones (0xFFF, an impossible combination), which is the presence test. A single-pad frame (12 bits) loads
// pad 0 and marks pad 1 absent. A frame with any other bit count is ignored.
// If CLOCK and LATCH rise in the same cycle, the latch sees the old shift state and the shift still happens.
//   +0x10 GAMEPAD (read only): {pr1, 3'b0, pad1[11:0] (0 if absent), pr0, 3'b0, pad0[11:0] (0 if absent)}
//   +0x14 GPSTAT: read {30'b0, ie, chg}; write be[0]: ie <= wdata[1]; wdata[0] = 1 clears chg (W1C;
//         a load of a new value in the same cycle wins). Writes never stall.
// irq = chg & ie. Inputs latch_s, pclk_s, data_s are already synchronised to clk.
module gamepad (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire        addr2,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    input  wire        latch_s, pclk_s, data_s,
    output wire        irq
);
    reg        pclk_p, latch_p, chg, ie;
    reg [4:0]  nb;
    reg [23:0] sh, d;

    wire pclk_r  = pclk_s  & ~pclk_p;
    wire latch_r = latch_s & ~latch_p;
    wire ld24 = latch_r & (nb == 5'd24);
    wire ld12 = latch_r & (nb == 5'd12);
    wire [23:0] dn = ld24 ? sh : {12'hFFF, sh[11:0]};
    wire load = ld24 | ld12;
    wire w1c  = sel & we & be[0] & addr2 & wdata[0];

    always @(posedge clk) begin
        if (rst) begin
            pclk_p <= 1'b0; latch_p <= 1'b0; chg <= 1'b0; ie <= 1'b0;
            nb <= 5'd0; sh <= 24'hFFFFFF; d <= 24'hFFFFFF;
        end else begin
            pclk_p <= pclk_s; latch_p <= latch_s;
            if (pclk_r) sh <= {sh[22:0], data_s};
            if (latch_r) nb <= 5'd0;
            else if (pclk_r && nb != 5'd31) nb <= nb + 5'd1;
            if (load) d <= dn;
            if (load && dn != d) chg <= 1'b1;
            else if (w1c) chg <= 1'b0;
            if (sel & we & be[0] & addr2) ie <= wdata[1];
        end
    end

    wire pr0 = d[11:0]  != 12'hFFF;
    wire pr1 = d[23:12] != 12'hFFF;
    assign rdata = addr2 ? {30'b0, ie, chg}
                         : {pr1, 3'b0, pr1 ? d[23:12] : 12'h0, pr0, 3'b0, pr0 ? d[11:0] : 12'h0};
    assign irq = chg & ie;
endmodule
