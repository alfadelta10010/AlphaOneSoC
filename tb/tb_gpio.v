// Unit testbench for src/gpio.v: GPIO OUT and IN, the SPICTL EN bit, the
// reserved slots and the pin flops. The SPI engine itself (src/spi.v) is
// checked by its own bench; here it only has to leave the pins alone.
//
// Written from the header of src/gpio.v, not from the RTL:
//   * OUT resets to 0xB9 (bits 5:4 are real GPIO outputs); reads return the
//     outputs; with EN = 0 every other bit follows OUT writes; with EN = 1 writes
//     to bits 3 and 1 are ignored;
//   * IN reads the input as sampled two clocks earlier;
//   * slots 0x08, 0x10-0x1C and 0x34-0x3C read 0 and ignore writes; the
//     window aliases every 64 bytes;
//   * only byte lane 0 writes a register;
//   * IN_IE (0x18) is read/write [7:0], IN_IP (0x1C) reads the pending edges and a
//     write clears the bits written (W1C); IP sets on either edge of the
//     synchronised input (two flops, then one more for the compare) whatever IE
//     says, a same-clock set beats a W1C; in_irq = |(IP & IE); neither slot ever
//     waits; no phantom edge after a reset with the pins held high.
`timescale 1ns/1ps
module tb_gpio;
    reg         clk = 0, rst = 1;
    reg         sel = 0, we = 0;
    reg  [3:0]  be = 4'hF;
    reg  [5:2]  addr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] rdata;
    wire        ready;
    reg  [7:0]  in = 8'hFF;      // pins high from power-up: no phantom edge
    wire [7:0]  out, in_sync;
    wire        spi_irq, in_irq;
    integer     errors = 0, checks = 0;

    gpio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata),
              .rdata(rdata), .ready(ready), .in(in), .out(out), .in_sync(in_sync), .spi_irq(spi_irq), .in_irq(in_irq));

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

    // ---- spec model of the input-change block, independent of the RTL
    reg [7:0] m_m = 0, m_s = 0, m_p = 0, m_ip = 0, m_ie = 0;
    wire      m_wr = sel && we && be[0];
    always @(posedge clk) begin
        m_m <= in; m_s <= m_m; m_p <= m_s;
        if (rst) begin m_ip <= 0; m_ie <= 0; end
        else begin
            if (m_wr && addr == 6) m_ie <= wdata[7:0];
            m_ip <= ((m_wr && addr == 7) ? (m_ip & ~wdata[7:0]) : m_ip) | (m_s ^ m_p);
        end
    end
    reg model_on = 0;
    always @(negedge clk) if (model_on) begin
        #3;                                 // after the stimulus of this negedge has settled
        chk("in_irq == |(IP & IE)", in_irq, |(m_ip & m_ie));
        if (sel && !we && addr == 6) chk("IE read", rdata, {24'b0, m_ie});
        if (sel && !we && addr == 7) chk("IP read", rdata, {24'b0, m_ip});
        if (sel && (addr == 6 || addr == 7)) chk("IE/IP never wait", ready, 1);
    end
    reg [31:0] rnd;
    integer    n;
    task rnd_cycle;
        begin
            @(negedge clk);
            rnd = $random;
            if (rnd[2:0] == 0) in = in ^ (8'h01 << rnd[5:3]);
            if (rnd[9:8] == 0) in = $random;
            sel = rnd[12]; we = rnd[13]; be = rnd[17:14] | {3'b0, rnd[18]}; addr = rnd[19] ? 4'd7 : 4'd6;
            wdata = $random;
            if (rnd[31:24] == 0 && model_on) begin rst = 1; end else rst = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk);
        #1 chk("out during reset", out, 8'hB9);
        rst = 0;
        repeat (4) @(posedge clk); #1;
        rd(7, v); chk("no phantom IP after power-up reset, pins high", v, 32'h0);
        rd(6, v); chk("IE after reset", v, 32'h0);
        chk("irq idle", in_irq, 0);
        rd(0, v); chk("OUT after reset", v, 32'hB9);
        rd(3, v); chk("SPICTL after reset", v, 32'h0);
        // EN = 0: OUT bits follow writes
        wr(0, 4'hF, 32'hFFFF_FFFF); rd(0, v); chk("OUT 0xFF", v, 32'hFF);
        chk("pins 0xFF", out, 8'hFF);
        wr(0, 4'hF, 32'h0000_0000); rd(0, v); chk("OUT 0x00", v, 32'h00);
        wr(0, 4'hF, 32'h0000_0020); rd(0, v); chk("OUT bit 5 (SD CS#)", v, 32'h20);
        wr(0, 4'hF, 32'h0000_0010); rd(0, v); chk("OUT bit 4", v, 32'h10);
        chk("pins bit 4", out, 8'h10);
        wr(0, 4'hF, 32'h0000_0000);
        wr(0, 4'h1, 32'h0000_0042); rd(0, v); chk("OUT byte", v, 32'h42);
        wr(0, 4'h2, 32'h0000_7E00); rd(0, v); chk("OUT lane 1 ignored", v, 32'h42);
        wr(0, 4'hE, 32'hFFFF_FF00); rd(0, v); chk("OUT lanes 1-3 ignored", v, 32'h42);
        // EN = 1: bits 3 and 1 belong to the engine (idle: SCK high, MOSI low)
        wr(0, 4'hF, 32'h0000_0000);
        wr(3, 4'hF, 32'h1); rd(3, v); chk("EN set", v, 32'h1);
        chk("SCK idle high with EN", out[3], 1);
        wr(0, 4'hF, 32'h0000_00FF); rd(0, v); chk("OUT bits 3, 1 ignored with EN", v, 32'hF5 | 32'h08);
        chk("pins with EN", out, 8'hFD);
        wr(3, 4'hF, 32'h0); rd(3, v); chk("EN clear", v, 32'h0);
        wr(0, 4'hF, 32'h0000_0000); rd(0, v); chk("OUT follows again", v, 32'h0);
        // IN
        in = 8'hA5; repeat (3) @(posedge clk); #1;
        rd(1, v); chk("IN", v, 32'hA5);
        chk("in_sync", in_sync, 8'hA5);
        in = 8'h3C; @(negedge clk); sel = 1; we = 0; addr = 1; #1;
        chk("IN is two clocks behind", rdata, 32'hA5);
        @(posedge clk); #1 sel = 0; repeat (2) @(posedge clk); #1;
        rd(1, v); chk("IN settled", v, 32'h3C);
        wr(1, 4'hF, 32'hFF); rd(1, v); chk("IN ignores writes", v, 32'h3C);
        // reserved slots and aliasing
        for (i = 2; i < 16; i = i + 1)
            if (i != 3 && i != 6 && i != 7 && i != 8 && i != 9 && i != 10 && i != 11 && i != 12) begin
                wr(i[3:0], 4'hF, 32'hFFFF_FFFF);
                rd(i[3:0], v); chk("reserved slot reads 0", v, 32'h0);
            end
        rd(0, v); chk("OUT untouched by reserved writes", v, 32'h0);
        // reset restores everything
        wr(0, 4'hF, 32'h0000_0045); wr(3, 4'hF, 32'h1);
        rst = 1; repeat (2) @(posedge clk); #1 rst = 0;
        rd(0, v); chk("OUT after second reset", v, 32'hB9);
        rd(3, v); chk("EN after second reset", v, 32'h0);
        // ---- IN_IE / IN_IP, directed
        in = 8'h00; repeat (5) @(posedge clk); #1;
        wr(7, 4'hF, 32'hFF);                       // flush the edge of the line above
        rd(7, v); chk("IP clear", v, 0);
        wr(6, 4'hF, 32'hFFFF_FF5A); rd(6, v); chk("IE rw (lane 0 only)", v, 32'h5A);
        wr(6, 4'h2, 32'h0000_FF00); rd(6, v); chk("IE lane 1 ignored", v, 32'h5A);
        wr(6, 4'hF, 32'h0);
        // exact timing: the pin changes before a clock edge; IP sets 3 edges later
        @(negedge clk); in[3] = 1;
        @(posedge clk); #1 chk("IP not yet (1)", m_ip, 0); chk("IP dut (1)", dut.in_ip, 0);
        @(posedge clk); #1 chk("IP dut (2)", dut.in_ip, 0);
        @(posedge clk); #1 chk("IP dut (3) set", dut.in_ip, 8'h08);
        chk("irq masked by IE", in_irq, 0);
        wr(6, 4'hF, 32'h08); chk("irq level once IE set", in_irq, 1);
        wr(7, 4'hF, 32'h04); rd(7, v); chk("W1C of another bit", v, 32'h08);
        wr(7, 4'h2, 32'h08); rd(7, v); chk("W1C needs lane 0", v, 32'h08);
        wr(7, 4'hF, 32'h08); rd(7, v); chk("W1C clears", v, 0); chk("irq drops", in_irq, 0);
        // a W1C racing a new edge: the edge arrives in the same clock as the clear
        wr(6, 4'hF, 32'h0);
        @(negedge clk); in[5] = 1;                 // set lands at the 3rd edge
        @(negedge clk); @(negedge clk);            // now one edge before the set
        sel = 1; we = 1; be = 4'hF; addr = 7; wdata = 32'h20;
        @(posedge clk); #1 sel = 0; we = 0;        // clear and set in the same clock
        chk("set beats same-clock W1C", dut.in_ip, 8'h20);
        wr(7, 4'hF, 32'h20); rd(7, v); chk("then clears", v, 0);
        // falling edges count too
        @(negedge clk); in[5] = 0; repeat (4) @(posedge clk); #1;
        rd(7, v); chk("falling edge sets IP", v, 32'h20);
        wr(7, 4'hF, 32'hFF);
        // no stall on 6/7 while the SPI is busy
        wr(12, 4'hF, 32'h3);                       // slow clock
        wr(9, 4'hF, 32'hA5);
        repeat (3) @(posedge clk); #1;
        rd(3, v); chk("SPI busy", v[8], 1);
        sel = 1; we = 1; be = 4'hF; addr = 6; wdata = 32'h12; #1 chk("IE write never waits (busy)", ready, 1);
        @(posedge clk); #1 sel = 0; we = 0;
        sel = 1; we = 1; be = 4'hF; addr = 7; wdata = 32'h0; #1 chk("IP write never waits (busy)", ready, 1);
        @(posedge clk); #1 sel = 0; we = 0;
        rd(6, v); chk("IE after busy write", v, 32'h12);
        sel = 1; we = 1; be = 4'hF; addr = 0; wdata = 32'h0; #1 chk("OUT write still waits (busy)", ready, 0);
        sel = 0; we = 0;
        wr(6, 4'hF, 32'h0);
        i = 0; while (i < 3000) begin @(posedge clk); #1 if (dut.s_txe) i = 9999; else i = i + 1; end
        chk("SPI byte finished", i, 9999);
        // reboot with the pins high and a pending bit: IP/IE cleared, no phantom edge
        in = 8'hFF; repeat (6) @(posedge clk); #1;
        wr(7, 4'hF, 32'hFF); wr(6, 4'hF, 32'hFF);
        in = 8'h0F; repeat (5) @(posedge clk); #1;
        rd(7, v); chk("IP pending before reboot", v, 32'hF0);
        rst = 1; repeat (2) @(posedge clk); #1 rst = 0;
        rd(7, v); chk("IP zero after reboot", v, 0); rd(6, v); chk("IE zero after reboot", v, 0);
        repeat (6) @(posedge clk); #1;
        rd(7, v); chk("no phantom IP after reboot, pins held", v, 0);
        // random: model compares every clock
        model_on = 1;
        for (n = 0; n < 20000; n = n + 1) rnd_cycle;
        @(negedge clk); rst = 0; sel = 0; we = 0; model_on = 0;
        // STATUS writes never wait, even while a byte is in flight; the IRQ enables
        wr(9, 4'hF, 32'h5A);
        chk("irq off", spi_irq, 0);
        wr(10, 4'hF, 32'h2); chk("TXR irq", spi_irq, 1);
        wr(10, 4'hF, 32'h0); chk("irq enables clear", spi_irq, 0);
        wr(10, 4'hF, 32'h1); repeat (3) @(posedge clk); #1 chk("TXE busy, no irq", spi_irq, 0);
        sel = 1; we = 1; be = 4'hF; addr = 10; wdata = 32'h3; #1 chk("STATUS write never waits", ready, 1);
        @(posedge clk); #1 sel = 0; we = 0;
        wr(10, 4'hF, 32'h0);
        if (errors == 0) $display("PASS tb_gpio: %0d checks", checks);
        else $display("FAIL tb_gpio: %0d errors, %0d checks", errors, checks);
        $finish;
    end
endmodule
