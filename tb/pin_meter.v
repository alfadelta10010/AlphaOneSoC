// A pin monitor for the PWM outputs: per period, the high time and the distance between rising edges,
// in clocks. A phase sets the expected values and pulses clr; hi_ok counts pulses of exactly exp_hi
// clocks, per_ok counts rising-edge distances of exactly exp_per, n_hi every high clock since clr.
module pin_meter (
    input  wire clk, pin, clr,
    input  wire [31:0] exp_hi, exp_per,
    output reg  [31:0] hi_ok, per_ok, n_hi, n_pulse
);
    integer c = 0, rise = -1, prev_rise = -1;
    reg     p = 1'b0;
    initial begin hi_ok = 0; per_ok = 0; n_hi = 0; n_pulse = 0; end
    always @(posedge clk) begin
        c <= c + 1;
        if (clr) begin hi_ok = 0; per_ok = 0; n_hi = 0; n_pulse = 0; rise = -1; prev_rise = -1; end
        else begin
            if (pin === 1'b1) n_hi = n_hi + 1;
            if (pin === 1'b1 && p === 1'b0) begin
                prev_rise = rise; rise = c;
                if (prev_rise >= 0 && rise - prev_rise == exp_per) per_ok = per_ok + 1;
            end
            if (pin !== 1'b1 && p === 1'b1 && rise >= 0) begin
                n_pulse = n_pulse + 1;
                if (c - rise == exp_hi) hi_ok = hi_ok + 1;
            end
        end
        p <= (pin === 1'b1);
    end
endmodule
