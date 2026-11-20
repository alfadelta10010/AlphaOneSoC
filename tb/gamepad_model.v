// TinyTapeout Gamepad Pmod, as the SoC benches drive it (LATCH, CLOCK, DATA on ui_in[4], [5], [6]).
// Protocol after Pat Deegan's gamepad_pmod.v (https://github.com/psychogenic/gamepad-pmod, Apache-2.0):
// a frame is 24 bits, pad 1 first (bits 23..12) then pad 0 (11..0), each pad's 12 bits MSB first
// (B Y SELECT START UP DOWN LEFT RIGHT A X L R, 1 = pressed). DATA changes on CLOCK's falling edge and is
// sampled on its rising edge; LATCH pulses high after the 24th bit. A pad that is absent sends all ones.
// Independent model written from the protocol; no code copied.
//
// The bench sets the state by hierarchical writes: pad0, pad1 (button bits), present0, present1, enable.
// FRAME_NS is the time from one frame's start to the next (default 1 ms), HALF_NS half a CLOCK period
// (default 5000 = 100 kHz). While enable is 0 the pins idle high (a floating DIP pull-up), so runs that
// do not use the gamepad are unchanged. With enable set a frame is sent every FRAME_NS; a frame in
// progress finishes first.
`timescale 1ns/1ps
module gamepad_model #(
    parameter integer HALF_NS  = 5000,
    parameter integer FRAME_NS = 1000000
) (
    output reg latch, clock, data
);
    reg [11:0] pad0 = 12'h000, pad1 = 12'h000;
    reg        present0 = 1'b1, present1 = 1'b0;
    reg        enable = 1'b0;
    integer    frames = 0;

    wire [11:0] w0 = present0 ? pad0 : 12'hFFF;
    wire [11:0] w1 = present1 ? pad1 : 12'hFFF;
    reg  [23:0] frame;
    integer     i;
    time        t0;

    initial begin latch = 1'b1; clock = 1'b1; data = 1'b1; end

    always begin
        wait (enable);
        t0 = $time;
        frame = {w1, w0};
        latch = 1'b0; clock = 1'b0;
        for (i = 23; i >= 0; i = i - 1) begin
            data = frame[i];
            #(HALF_NS) clock = 1'b1;
            #(HALF_NS) clock = 1'b0;
        end
        data = 1'b1;
        #(HALF_NS) latch = 1'b1;
        #(HALF_NS) latch = 1'b0;
        frames = frames + 1;
        if (($time - t0) < FRAME_NS) #(FRAME_NS - ($time - t0));
        if (!enable) begin latch = 1'b1; clock = 1'b1; data = 1'b1; end
    end
endmodule
