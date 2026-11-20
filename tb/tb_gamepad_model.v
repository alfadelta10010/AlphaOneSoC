`timescale 1ns / 1ps
// tb/gamepad_model.v driving src/gamepad.v through a two-flop synchroniser: after each frame the receiver's
// GAMEPAD register must show the bench-set buttons, with the present bits right for 0, 1 and 2 pads, and
// the change flag must rise only when a new frame differs. Fast frame rate (HALF_NS 400, FRAME_NS 40 us).
module tb_gamepad_model;
    reg clk = 0, rst = 1;
    reg sel = 0, we = 0, addr2 = 0;
    reg [3:0] be = 0;
    reg [31:0] wdata = 0;
    wire [31:0] rdata;
    wire irq, latch, pclk, data;
    reg l1 = 0, l2 = 0, p1 = 0, p2 = 0, d1 = 0, d2 = 0;
    always #8 clk = ~clk;
    always @(posedge clk) begin l1 <= latch; l2 <= l1; p1 <= pclk; p2 <= p1; d1 <= data; d2 <= d1; end
    gamepad uut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr2(addr2), .wdata(wdata),
                 .rdata(rdata), .latch_s(l2), .pclk_s(p2), .data_s(d2), .irq(irq));
    gamepad_model #(.HALF_NS(400), .FRAME_NS(40000)) pad (.latch(latch), .clock(pclk), .data(data));

    integer errors = 0, checks = 0;
    reg [31:0] v;
    task rd(input a2); begin
        @(negedge clk); addr2 = a2; sel = 1; #1 v = rdata; @(negedge clk); sel = 0; addr2 = 0;
    end endtask
    task wr_stat(input [31:0] d); begin
        @(negedge clk); addr2 = 1; sel = 1; we = 1; be = 4'h1; wdata = d;
        @(negedge clk); sel = 0; we = 0; addr2 = 0; be = 0;
    end endtask
    task settle; begin
        wait (pad.frames >= 1 + fbase); fbase = pad.frames;       // one frame done ...
        wait (pad.frames >= 1 + fbase); fbase = pad.frames;       // ... and a full one with the new state
        #2000;
    end endtask
    integer fbase = 0;
    task check(input [11:0] b0, input pr0, input [11:0] b1, input pr1, input expchg);
        reg [31:0] exp;
        begin
            exp = {pr1, 3'b0, pr1 ? b1 : 12'h0, pr0, 3'b0, pr0 ? b0 : 12'h0};
            rd(0); checks = checks + 1;
            if (v !== exp) begin errors = errors + 1; $display("GAMEPAD %h expected %h", v, exp); end
            rd(1); checks = checks + 1;
            if (v[0] !== expchg) begin errors = errors + 1; $display("GPSTAT chg %b expected %b", v[0], expchg); end
            wr_stat(32'h1);                                         // W1C
        end
    endtask

    initial begin
        repeat (4) @(posedge clk); rst = 0;
        #1000 pad.enable = 1;
        // two pads
        pad.pad0 = 12'hA5C; pad.pad1 = 12'h3D2; pad.present0 = 1; pad.present1 = 1; settle;
        check(12'hA5C, 1, 12'h3D2, 1, 1);
        settle; check(12'hA5C, 1, 12'h3D2, 1, 0);                   // same frame again: no change
        // one pad (pad 1 absent: all ones)
        pad.pad0 = 12'h801; pad.present1 = 0; settle;
        check(12'h801, 1, 12'h000, 0, 1);
        // zero pads
        pad.present0 = 0; settle;
        check(12'h000, 0, 12'h000, 0, 1);
        // pad 1 only
        pad.present1 = 1; pad.pad1 = 12'h7FE; settle;
        check(12'h000, 0, 12'h7FE, 1, 1);
        // all buttons but one released and the all-ones corner: 0xFFE is present
        pad.present0 = 1; pad.pad0 = 12'hFFE; pad.pad1 = 12'h001; settle;
        check(12'hFFE, 1, 12'h001, 1, 1);
        pad.enable = 0;
        if (errors == 0) $display("PASS tb_gamepad_model (%0d checks, %0d frames)", checks, pad.frames);
        else $display("FAIL tb_gamepad_model: %0d errors", errors);
        $finish;
    end
    initial begin #20000000; $display("TIMEOUT tb_gamepad_model"); $finish; end
endmodule
