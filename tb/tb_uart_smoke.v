// Temporary directed smoke bench for the 16550A uart (WO-49); WO-50 replaces it with a spec-model bench.
// Divisor 1: a 16x tick every clock, so a bit is 16 clocks and a frame 160.
`timescale 1ns/1ps
module tb_uart_smoke;
    reg clk = 0, rst = 1;
    always #8 clk = ~clk;
    reg sel = 0, we = 0, addr2 = 0; reg [3:0] be = 0; reg [31:0] wdata = 0;
    wire [31:0] rdata; wire ready, tx, rts_n, irq;
    reg rx = 1;
    uart dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr2(addr2), .wdata(wdata),
              .rdata(rdata), .ready(ready), .rx(rx), .tx(tx), .rts_n(rts_n), .irq(irq));

    integer nchk = 0, nbad = 0, stall = 0;
    task chk; input [255:0] name; input [31:0] got; input [31:0] exp; begin
        nchk = nchk + 1;
        if (got !== exp) begin nbad = nbad + 1; $display("FAIL %0s: got %h expected %h (t=%0t)", name, got, exp, $time); end
    end endtask

    // one bus write/read per call; a write waits for ready
    task wreg; input [2:0] off; input [7:0] v; begin
        @(negedge clk); sel = 1; we = 1; addr2 = off[2]; be = 4'b1 << off[1:0]; wdata = {24'b0, v} << (8*off[1:0]);
        stall = 0; @(posedge clk); while (!ready) begin stall = stall + 1; @(posedge clk); end
        @(negedge clk); sel = 0; we = 0; be = 0;
    end endtask
    task wword; input a2; input [3:0] b; input [31:0] d; begin   // raw word store (be lanes)
        @(negedge clk); sel = 1; we = 1; addr2 = a2; be = b; wdata = d;
        stall = 0; @(posedge clk); while (!ready) begin stall = stall + 1; @(posedge clk); end
        @(negedge clk); sel = 0; we = 0; be = 0;
    end endtask
    reg [31:0] rw;
    task rreg; input [2:0] off; output [7:0] v; begin
        @(negedge clk); sel = 1; we = 0; addr2 = off[2]; be = 4'b1 << off[1:0];
        @(posedge clk); rw = rdata; v = rw >> (8*off[1:0]);
        @(negedge clk); sel = 0; be = 0;
    end endtask
    reg [7:0] r;
    task rd_chk; input [255:0] name; input [2:0] off; input [7:0] exp; begin rreg(off, r); chk(name, r, exp); end endtask
    task wait_clk; input integer n; begin repeat (n) @(posedge clk); end endtask
    task setdiv; begin wreg(3, 8'h80); wreg(0, 8'd1); wreg(1, 8'd0); wreg(3, 8'h00); end endtask
    task rxf; input [7:0] d; input stop; integer k; begin   // async frame on rx
        rx = 0; wait_clk(16);
        for (k = 0; k < 8; k = k + 1) begin rx = d[k]; wait_clk(16); end
        rx = stop; wait_clk(16); rx = 1;
    end endtask

    // tx pin monitor: decodes frames when not in loopback
    reg [7:0] txlog [0:63]; integer ntx = 0; reg [7:0] mb; integer mk;
    initial forever begin
        @(negedge tx); wait_clk(8);
        for (mk = 0; mk < 8; mk = mk + 1) begin wait_clk(16); mb[mk] = tx; end
        wait_clk(16); txlog[ntx] = mb; ntx = ntx + 1;
    end

    integer i, n; reg [7:0] exp8;
    initial begin
        repeat (4) @(posedge clk); rst = 0; @(negedge clk);
        // 1 reset values
        rd_chk("RBR", 0, 8'h00); rd_chk("IER", 1, 8'h00); rd_chk("IIR", 2, 8'h01); rd_chk("LCR", 3, 8'h00);
        rd_chk("MCR", 4, 8'h02); rd_chk("LSR", 5, 8'h60); rd_chk("MSR", 6, 8'hB0); rd_chk("SCR", 7, 8'h00);
        chk("irq0", irq, 0); chk("rts0", rts_n, 0);
        wreg(7, 8'hA7); rd_chk("SCR rw", 7, 8'hA7); wreg(7, 8'h00);
        setdiv;
        // 2 FCR / IIR / THRE level
        wreg(2, 8'h81); rd_chk("IIR fen", 2, 8'hC1);
        wreg(1, 8'h02); rd_chk("IIR thre", 2, 8'hC2); chk("irq thre", irq, 1);
        rd_chk("IIR thre again", 2, 8'hC2);                       // level: a read does not clear it
        wreg(1, 8'h00); rd_chk("IIR none", 2, 8'hC1); chk("irq none", irq, 0);
        // 3 tx pin
        wreg(0, 8'hA5); wreg(0, 8'h3C); wait_clk(500);
        chk("tx pin n", ntx, 2); chk("tx pin 0", txlog[0], 8'hA5); chk("tx pin 1", txlog[1], 8'h3C);
        // 4 loopback, trigger 8 (FCR 0x81): 8 bytes -> RDA
        wreg(4, 8'h1F); rd_chk("MSR loop", 6, 8'hF0);
        wreg(1, 8'h01);
        for (i = 0; i < 7; i = i + 1) wreg(0, 8'h10 + i);
        wait_clk(7*170 + 100);
        rd_chk("IIR 7 bytes", 2, 8'hC1); chk("irq 7", irq, 0);
        wreg(0, 8'h17); wait_clk(400);
        rd_chk("IIR RDA", 2, 8'hC4); chk("irq rda", irq, 1); rd_chk("LSR dr", 5, 8'h61);
        for (i = 0; i < 8; i = i + 1) rd_chk("rbr ordered", 0, 8'h10 + i);
        rd_chk("LSR empty", 5, 8'h60); rd_chk("RBR empty reads 0", 0, 8'h00); rd_chk("IIR after drain", 2, 8'hC1);
        chk("tx marks in loop", tx, 1); chk("rts_n in loop", rts_n, 1);
        // 5 trigger 14 (FCR 0xC1) and 32 bytes through as 2 x 16, RTS# at 15
        wreg(2, 8'hC1);
        for (i = 0; i < 13; i = i + 1) wreg(0, i);
        wait_clk(1000); rd_chk("IIR 13 < 14", 2, 8'hC1);
        wreg(0, 8'd13); wait_clk(400); rd_chk("IIR 14", 2, 8'hC4);
        for (i = 0; i < 14; i = i + 1) rd_chk("14 ordered", 0, i);
        wreg(2, 8'h81);
        wreg(4, 8'h02);                                   // leave loopback: RTS#
        wreg(4, 8'h1F);
        for (n = 0; n < 2; n = n + 1) begin
            for (i = 0; i < 16; i = i + 1) wreg(0, 8'h40 + 16*n + i);
            wait_clk(16*170 + 200);
            rd_chk("LSR 16 queued", 5, 8'h61);
            for (i = 0; i < 16; i = i + 1) rd_chk("32 ordered", 0, 8'h40 + 16*n + i);
        end
        // 6 overrun: 17 bytes without a read
        wreg(2, 8'h01);
        for (i = 0; i < 17; i = i + 1) wreg(0, 8'h80 + i);
        wait_clk(17*170 + 300);
        rd_chk("LSR OE", 5, 8'h63); rd_chk("LSR OE cleared", 5, 8'h61);
        for (i = 0; i < 16; i = i + 1) rd_chk("OE kept oldest", 0, 8'h80 + i);
        rd_chk("LSR drained", 5, 8'h60);
        // 7 character timeout: 3 bytes at trigger 8, then quiet
        wreg(2, 8'h81);
        wreg(0, 8'h21); wreg(0, 8'h22); wreg(0, 8'h23);
        wait_clk(3*170 + 300);
        rd_chk("IIR below trigger", 2, 8'hC1);
        wait_clk(700); rd_chk("IIR CTI", 2, 8'hCC); chk("irq cti", irq, 1);
        rd_chk("pop", 0, 8'h21); rd_chk("IIR after pop", 2, 8'hC1);
        wait_clk(700); rd_chk("IIR CTI again", 2, 8'hCC);
        rd_chk("pop", 0, 8'h22); rd_chk("pop", 0, 8'h23); rd_chk("IIR cti gone", 2, 8'hC1);
        // 8 THR back-pressure: shifter + 4 entries absorb 5 writes, the 6th waits
        wreg(2, 8'h01); wreg(1, 8'h00);
        for (i = 0; i < 4; i = i + 1) begin wreg(0, 8'h50 + i); chk("no stall", stall, 0); end
        wreg(0, 8'h54); wreg(0, 8'h55); chk("6th write waits", stall > 100, 1);
        wait_clk(7*170);
        for (i = 0; i < 6; i = i + 1) rd_chk("bp data", 0, 8'h50 + i);
        // 9 FCR clears
        wreg(2, 8'h01); wreg(0, 8'h61); wreg(0, 8'h62); wreg(0, 8'h63); wreg(0, 8'h64);
        wreg(2, 8'h05);                                   // clear TX: the shifter finishes its frame
        wait_clk(1000); rd_chk("LSR tx cleared", 5, 8'h61); rd_chk("one byte went", 0, 8'h61); rd_chk("no more", 5, 8'h60);
        wreg(0, 8'h71); wreg(0, 8'h72); wait_clk(400);
        rd_chk("LSR 2 queued", 5, 8'h61); wreg(2, 8'h03); rd_chk("LSR rx cleared", 5, 8'h60);
        wreg(2, 8'h01); wreg(0, 8'h73); wait_clk(300); wreg(2, 8'h00);      // FEN change clears both FIFOs
        rd_chk("FEN change clears", 5, 8'h60); rd_chk("IIR fen 0", 2, 8'h01);
        // 10 break in loopback (BI entry), FEN 1
        wreg(2, 8'h81); wreg(1, 8'h04);
        wreg(3, 8'h40); wait_clk(500); wreg(3, 8'h00); wait_clk(400);
        rd_chk("LSR BI", 5, 8'hF1); rd_chk("IIR RLS", 2, 8'hC6); chk("irq rls", irq, 1);
        rd_chk("LSR BI stays", 5, 8'hF1);                  // an LSR read does not clear BI
        rd_chk("break data 0", 0, 8'h00); rd_chk("LSR after pop", 5, 8'h60); rd_chk("IIR after pop", 2, 8'hC1);
        wreg(2, 8'h00); wreg(3, 8'h40); wait_clk(500); wreg(3, 8'h00); wait_clk(400);
        rd_chk("LSR BI fen0", 5, 8'h71); rd_chk("pop", 0, 8'h00);
        // 11 framing error from the pin (loopback off)
        wreg(4, 8'h02); wreg(2, 8'h81); wreg(1, 8'h04);
        rxf(8'h55, 1'b0); wait_clk(100);
        rd_chk("LSR FE", 5, 8'hE9); rd_chk("IIR RLS fe", 2, 8'hC6);
        rd_chk("FE data", 0, 8'h55); rd_chk("LSR clean", 5, 8'h60);
        rxf(8'h96, 1'b1); wait_clk(100); rd_chk("LSR good", 5, 8'h61); rd_chk("good data", 0, 8'h96);
        // 12 RTS# follows the FIFO fill (not in loopback)
        wreg(1, 8'h00); wreg(2, 8'h01);
        chk("rts asserted", rts_n, 0);
        for (i = 0; i < 14; i = i + 1) rxf(i, 1'b1);
        wait_clk(5); chk("rts 14 held", rts_n, 0);
        rxf(8'hEE, 1'b1); wait_clk(5); chk("rts off at 15", rts_n, 1);
        wreg(2, 8'h03); wait_clk(5); chk("rts back", rts_n, 0);
        if (nbad == 0) $display("PASS %0d checks", nchk); else $display("FAIL %0d of %0d checks", nbad, nchk);
        $finish;
    end
    initial begin #(60_000_000); $display("TIMEOUT tb_uart_smoke"); $finish; end
endmodule
