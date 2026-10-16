`timescale 1ns / 1ps
// regFile (src/regFile.v) around the rf_top macro model (src/rf_top.v).
//
// The contract fyracore relies on: ra/rb are taken on a rising edge; r1/r2 then
// give those registers, as they stand after that edge's write (write-first),
// and hold them until the next edge, whatever ra/rb do in between. x0 is
// never written. Run three times by make test-regfile: plain (registers start
// at 0), with +RF_X (they start at X), and with +RF_COLLIDE_X as well, where
// the macro model returns X for a read of the word being written -- so
// write-first has to come from regFile's own bypass, not from the macro.
module tb_regFile;
    reg         clk, wrEn;
    reg  [4:0]  ra, rb, rd;
    reg  [31:0] dIn;
    wire [31:0] r1, r2;
    integer pass_count = 0, fail_count = 0, i, k;
    reg         rf_x;
    reg  [31:0] init;           // 0, or X under +RF_X

    regFile uut(
        .clk(clk), .wrEn(wrEn), .rd(rd), .dIn(dIn),
        .ra(ra), .rb(rb), .r1(r1), .r2(r2)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    task expect2(input [31:0] e1, input [31:0] e2, input [255:0] name);
        begin
            if (r1 === e1 && r2 === e2) pass_count = pass_count + 1;
            else begin
                fail_count = fail_count + 1;
                $display("FAIL: %0s | ra=%0d rb=%0d | r1=0x%08h (exp 0x%08h) r2=0x%08h (exp 0x%08h)",
                         name, ra, rb, r1, e1, r2, e2);
            end
        end
    endtask

    // One clock: set the write and read addresses before the edge (at the
    // falling edge), then look just after the edge.
    task cycle(input we, input [4:0] w, input [31:0] d, input [4:0] a, input [4:0] b);
        begin
            @(negedge clk);
            wrEn = we; rd = w; dIn = d; ra = a; rb = b;
            @(posedge clk);
            #1;
        end
    endtask

    // Shadow for the random run: what each register holds.
    reg [31:0] shadow [0:31];
    reg [31:0] exp1, exp2;
    reg        we_r;
    reg [4:0]  w_r, a_r, b_r;
    reg [31:0] d_r;

    initial begin
        $display("=== Register File (rf_top macro) Testbench ===");
        rf_x = $test$plusargs("RF_X");
        init = rf_x ? 32'hxxxx_xxxx : 32'h0000_0000;
        $display("registers start at %0s", rf_x ? "X (+RF_X)" : "0");
        wrEn = 0; rd = 0; dIn = 0; ra = 0; rb = 0;

        // Start state: every register reads as the model's initial value.
        for (i = 0; i < 32; i = i + 1) begin
            cycle(0, 0, 0, i[4:0], 31 - i);
            expect2(init, init, "start state");
        end

        // Write every register, reading the same one on port A and the
        // previous one on port B on the same edge: port A sees the new value
        // (write-first), port B the value written one edge earlier.
        for (i = 1; i < 32; i = i + 1) begin
            cycle(1, i[4:0], 32'hA000_0000 + i, i[4:0], i - 1);
            expect2(32'hA000_0000 + i, (i == 1) ? init : 32'hA000_0000 + i - 1,
                    "write-first on A, previous on B");
        end

        // x0 is never written, even with wrEn: its word keeps its start value.
        cycle(1, 0, 32'hDEAD_BEEF, 0, 0);
        expect2(init, init, "x0 write ignored, same edge");
        cycle(0, 0, 0, 0, 0);
        expect2(init, init, "x0 write ignored, next edge");

        // Write-first on both ports at once, same address.
        cycle(1, 5'd7, 32'h7777_0001, 5'd7, 5'd7);
        expect2(32'h7777_0001, 32'h7777_0001, "write-first on both ports");
        // ...and on port B only.
        cycle(1, 5'd9, 32'h9999_0001, 5'd8, 5'd9);
        expect2(32'hA000_0008, 32'h9999_0001, "write-first on B, A unaffected");

        // Synchronous read: the output follows the address taken on the
        // edge, not the address now on the pins.
        cycle(0, 0, 0, 5'd3, 5'd4);
        expect2(32'hA000_0003, 32'hA000_0004, "read x3/x4");
        ra = 5'd10; rb = 5'd11;          // move the address after the edge
        #3;
        expect2(32'hA000_0003, 32'hA000_0004, "address moved mid-cycle, output held");
        @(posedge clk); #1;
        expect2(32'hA000_000A, 32'hA000_000B, "taken on the next edge");

        // Address held for several edges: output held, also while other
        // registers are written; then a write to the held register shows
        // from the edge that writes it.
        for (k = 0; k < 4; k = k + 1) begin
            cycle(1, 5'd20 + k, 32'h2020_0000 + k, 5'd12, 5'd12);
            expect2(32'hA000_000C, 32'hA000_000C, "held address, writes elsewhere");
        end
        cycle(1, 5'd12, 32'h1212_0001, 5'd12, 5'd12);
        expect2(32'h1212_0001, 32'h1212_0001, "held address, written on this edge");
        cycle(0, 5'd12, 32'hFFFF_FFFF, 5'd12, 5'd12);
        expect2(32'h1212_0001, 32'h1212_0001, "wrEn low writes nothing");

        // Back-to-back writes to one register, read on every edge.
        cycle(1, 5'd30, 32'h3030_0001, 5'd30, 5'd29);
        expect2(32'h3030_0001, 32'hA000_001D, "b2b write 1");
        cycle(1, 5'd30, 32'h3030_0002, 5'd30, 5'd30);
        expect2(32'h3030_0002, 32'h3030_0002, "b2b write 2");
        cycle(1, 5'd30, 32'h3030_0003, 5'd29, 5'd30);
        expect2(32'hA000_001D, 32'h3030_0003, "b2b write 3");

        // Random run against a shadow: each edge, a random write and two
        // random reads; after the edge each port must give its register as
        // the shadow holds it after that write.
        for (i = 0; i < 32; i = i + 1) shadow[i] = uut.rf_macro.storage[i];
        for (k = 0; k < 20000; k = k + 1) begin
            we_r = $random; w_r = $random; d_r = $random; a_r = $random; b_r = $random;
            cycle(we_r, w_r, d_r, a_r, b_r);
            if (we_r && w_r != 5'd0) shadow[w_r] = d_r;
            exp1 = shadow[a_r]; exp2 = shadow[b_r];
            expect2(exp1, exp2, "random vs shadow");
        end

        $display("\n=== RegFile Results: %0d passed, %0d failed ===", pass_count, fail_count);
        if (fail_count == 0) $display("ALL REGFILE TESTS PASSED");
        $finish;
    end
endmodule
