// Unit testbench for src/gpio.v: GPIO OUT and IN, the SPICTL EN bit, the
// reserved slots and the pin flops. The SPI engine itself (src/spi.v) is
// checked by its own bench; here it only has to leave the pins alone.
//
// Written from the header of src/gpio.v, not from the RTL:
//   * OUT resets to 0x89; bits 5:4 read 0 and ignore writes; reads return the
//     pins; with EN = 0 every other bit follows OUT writes; with EN = 1 writes
//     to bits 3 and 1 are ignored;
//   * IN reads the input as sampled two clocks earlier;
//   * slots 0x08, 0x10-0x1C and 0x34-0x3C read 0 and ignore writes; the
//     window aliases every 64 bytes;
//   * only byte lane 0 writes a register.
`timescale 1ns/1ps
module tb_gpio;
    reg         clk = 0, rst = 1;
    reg         sel = 0, we = 0;
    reg  [3:0]  be = 4'hF;
    reg  [5:2]  addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire        ready;
    reg  [7:0]  in = 0;
    wire [7:0]  out;
    integer     errors = 0, checks = 0;

    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(in), .out(out));

    always #5 clk = ~clk;

    task chk(input [255:0] what, input [31:0] got, input [31:0] want);
        begin
            checks = checks + 1;
            if (got !== want) begin
                errors = errors + 1;
                $display("FAIL %0s: got %h, want %h", what, got, want);
            end
        end
    endtask

    task wr(input [5:2] a, input [3:0] b, input [31:0] d);
        begin
            @(negedge clk); sel = 1; we = 1; addr = a; be = b; wdata = d; #1;
            if (!ready) chk("write waited with the engine idle", 1, 0);   // ready before the edge that takes the write
            @(posedge clk); #1;
            sel = 0; we = 0; be = 4'hF;
        end
    endtask

    task rd(input [5:2] a, output [31:0] v);
        begin
            @(negedge clk); sel = 1; we = 0; addr = a; #1 v = rdata;
            chk("read never waits", ready, 1);
            @(posedge clk); #1 sel = 0;
        end
    endtask

    reg [31:0] v;
    integer    i;
    initial begin
        repeat (3) @(posedge clk);
        #1 chk("out during reset", out, 8'h89);
        rst = 0;
        rd(0, v); chk("OUT after reset", v, 32'h89);
        rd(3, v); chk("SPICTL after reset", v, 32'h0);
        // EN = 0: OUT bits follow writes, bits 5:4 do not
        wr(0, 4'hF, 32'hFFFF_FFFF); rd(0, v); chk("OUT 0xFF", v, 32'hCF);
        chk("pins 0xFF", out, 8'hCF);
        wr(0, 4'hF, 32'h0000_0000); rd(0, v); chk("OUT 0x00", v, 32'h00);
        wr(0, 4'h1, 32'h0000_0042); rd(0, v); chk("OUT byte", v, 32'h42);
        wr(0, 4'h2, 32'h0000_7E00); rd(0, v); chk("OUT lane 1 ignored", v, 32'h42);
        wr(0, 4'hE, 32'hFFFF_FF00); rd(0, v); chk("OUT lanes 1-3 ignored", v, 32'h42);
        // EN = 1: bits 3 and 1 belong to the engine (idle: SCK high, MOSI low)
        wr(0, 4'hF, 32'h0000_0000);
        wr(3, 4'hF, 32'h1); rd(3, v); chk("EN set", v, 32'h1);
        chk("SCK idle high with EN", out[3], 1);
        wr(0, 4'hF, 32'h0000_00FF); rd(0, v); chk("OUT bits 3, 1 ignored with EN", v, 32'hC5 | 32'h08);
        chk("pins with EN", out, 8'hCD);
        wr(3, 4'hF, 32'h0); rd(3, v); chk("EN clear", v, 32'h0);
        wr(0, 4'hF, 32'h0000_0000); rd(0, v); chk("OUT follows again", v, 32'h0);
        // IN
        in = 8'hA5; repeat (3) @(posedge clk); #1;
        rd(1, v); chk("IN", v, 32'hA5);
        in = 8'h3C; @(negedge clk); sel = 1; we = 0; addr = 1; #1;
        chk("IN is two clocks behind", rdata, 32'hA5);
        @(posedge clk); #1 sel = 0; repeat (2) @(posedge clk); #1;
        rd(1, v); chk("IN settled", v, 32'h3C);
        wr(1, 4'hF, 32'hFF); rd(1, v); chk("IN ignores writes", v, 32'h3C);
        // reserved slots and aliasing
        for (i = 2; i < 16; i = i + 1)
            if (i != 3 && i != 8 && i != 9 && i != 10 && i != 11 && i != 12) begin
                wr(i[3:0], 4'hF, 32'hFFFF_FFFF);
                rd(i[3:0], v); chk("reserved slot reads 0", v, 32'h0);
            end
        rd(0, v); chk("OUT untouched by reserved writes", v, 32'h0);
        // reset restores everything
        wr(0, 4'hF, 32'h0000_0045); wr(3, 4'hF, 32'h1);
        rst = 1; repeat (2) @(posedge clk); #1 rst = 0;
        rd(0, v); chk("OUT after second reset", v, 32'h89);
        rd(3, v); chk("EN after second reset", v, 32'h0);
        if (errors == 0) $display("PASS tb_gpio: %0d checks", checks);
        else $display("FAIL tb_gpio: %0d errors, %0d checks", errors, checks);
        $finish;
    end
endmodule
