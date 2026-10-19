`timescale 1ns / 1ps
// inc64 (src/csr.v): q + 1 with the carry into the upper half from a flop.
// The flag is right only if it follows every value the owner loads, so the
// owner here does what mcycle, minstret and mtime do -- count, hold, or load
// a written value -- and q_inc is compared with q + 1 after every edge. Loads
// land on and around the points where the low 16, 32, 48 or 64 bits are all
// ones, and on the low half all ones but for a single bit: a flag that left a
// bit out of its AND would be set there.
module tb_inc64;
    reg         clk = 0;
    reg  [63:0] q;
    reg         load, hold;
    reg  [63:0] ld;
    wire [63:0] q_inc;
    wire [63:0] d = load ? ld : hold ? q : q_inc;
    integer     pass_count = 0, fail_count = 0, k, w;

    inc64 uut(.clk(clk), .q(q), .d(d), .q_inc(q_inc));
    always @(posedge clk) q <= d;
    always #5 clk = ~clk;

    initial begin
        $display("=== inc64 Testbench ===");
        load = 1; hold = 0; ld = 64'b0;
        @(posedge clk); #1;
        for (k = 0; k < 400000; k = k + 1) begin
            if (q_inc === q + 64'd1) pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                if (fail_count <= 10)
                    $display("FAIL: q=0x%016h q_inc=0x%016h (exp 0x%016h)", q, q_inc, q + 64'd1);
            end
            @(negedge clk);
            load = (($random & 15) == 0);
            hold = (($random & 7) == 0);
            // Under random upper bits: a value whose low 16*(w+1) bits are
            // all ones, less 0..3; or one whose low 32 bits are all ones but
            // for one bit (any of the 32, or none); or anything.
            w  = $random & 3;
            ld = {$random, $random};
            case ($random & 7)
                0:       ;
                1, 2, 3: ld = (ld | (64'hFFFF_FFFF_FFFF_FFFF >> (48 - 16 * w))) - ($random & 3);
                default: begin
                    ld = ld | 64'h0000_0000_FFFF_FFFF;
                    if (($random & 7) != 0) ld[$random & 31] = 1'b0;
                end
            endcase
            @(posedge clk); #1;
        end
        $display("\n=== inc64 Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("PASS tb_inc64 (%0d checks)", pass_count);
        else                 $display("FAIL tb_inc64: %0d failures", fail_count);
        $finish;
    end
endmodule
