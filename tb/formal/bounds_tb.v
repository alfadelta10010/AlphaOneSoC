// Random simulation of mem_ctrl + qspi_ctrl under the WO-31 assumptions (M-A1..M-A4):
// measures LP LF S LD LI (LF = longest CS0-low run without the engine idle). Not a proof; the pdr proofs in tb/formal/mem_*.sv carry the bounds.
// +SE=1 (default) streaming on, +SE=0 off (stream_en tied 0); the output line names it.
// Build: make BUILD_DIR=build/x bounds-qspi [DF_N=4]  (DFN = the data-fetch count assumption M-A4).
`timescale 1ns/1ps
`ifndef DFN
`define DFN 4
`endif
module bounds_tb;
    reg clk = 0, rst = 1, rd_late = 0, stream_en = 1;
    integer se_arg;
    reg i_req = 0, d_req = 0, d_we = 0;
    reg [31:0] i_addr = 0, d_addr = 0, d_wdata = 0;
    reg [3:0] d_be = 4'hF;
    wire [31:0] i_rdata, d_rdata, q_wdata, q_rdata;
    wire i_ready, d_ready, q_start, q_we, q_idle, q_done, sck, ctl_oe, io_oe;
    wire [1:0] q_cs, q_nbytes_m1; wire [23:0] q_addr; wire [2:0] cs_n; wire [3:0] io_out;
    reg [3:0] io_in = 0;
    mem_ctrl m (.clk(clk), .rst(rst), .i_req(i_req), .i_addr(i_addr), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be), .d_we(d_we), .d_rdata(d_rdata), .d_ready(d_ready),
        .q_start(q_start), .q_cs(q_cs), .q_addr(q_addr), .q_we(q_we), .q_nbytes_m1(q_nbytes_m1), .q_wdata(q_wdata),
        .q_idle(q_idle), .q_done(q_done), .q_rdata(q_rdata));
    qspi_ctrl q (.clk(clk), .rst(rst), .rd_late(rd_late), .start(q_start), .cs_sel(q_cs), .addr(q_addr), .we(q_we),
        .nbytes_m1(q_nbytes_m1), .wdata(q_wdata), .idle(q_idle), .done(q_done), .rdata(q_rdata),
        .sck(sck), .cs_n(cs_n), .ctl_oe(ctl_oe), .io_out(io_out), .io_oe(io_oe), .io_in(io_in), .stream_en(stream_en));
    always #5 clk = ~clk;
    integer seed, cyc, pl, fl, dw, iw, nd, sc, seen_idle;
    integer mLP[0:1], mLF[0:1], mS[0:1], mLD[0:1], mLI[0:1];
    integer run, p_new_i, p_new_d, p_rst, mode;
    reg i_q, d_q, idl_q;
    function [31:0] rnd_addr(input integer dummy);
        reg [31:0] a; integer r;
        begin
            r = $urandom(seed) % 8; seed = seed + 1;
            case (r)
                0: a = 32'h807F_FFFE; 1: a = 32'h8000_03FE; 2: a = 32'h8000_07FE;
                3: a = 32'h2000_0000 + ($urandom % 24'hFFFFFF);
                default: a = 32'h8000_0000 + ($urandom % 24'hFFFFFF);
            endcase
            rnd_addr = a;
        end
    endfunction
    always @(posedge clk) begin
        if (rst) begin pl = 0; fl = 0; dw = 0; iw = 0; nd = 0; sc = 0; seen_idle = 0; end
        else begin
            pl = (!cs_n[1] || !cs_n[2]) ? pl + 1 : 0; fl = (!cs_n[0] && !q_idle) ? fl + 1 : 0;   // an idle open stream (CS0 low, engine idle) is not a run: it has no bound
            dw = (d_req && !d_ready) ? dw + 1 : 0;  iw = (i_req && !i_ready) ? iw + 1 : 0;
            sc = sc + 1; if (q_idle && !seen_idle) begin seen_idle = 1; if (sc > mS[rd_late]) mS[rd_late] = sc; end
            if (pl > mLP[rd_late]) mLP[rd_late] = pl;  if (fl > mLF[rd_late]) mLF[rd_late] = fl;
            if (d_req && dw > mLD[rd_late]) mLD[rd_late] = dw;
            if (i_req && iw > mLI[rd_late]) mLI[rd_late] = iw;
            if (i_ready) nd = 0; else if (d_ready) nd = nd + 1;
        end
    end
    // requests: held until ready; new data request only while nd < `DFN (M-A4)
    always @(negedge clk) begin
        if (!rst) begin
            if (i_req && i_ready) i_req = 0;
            if (d_req && d_ready) d_req = 0;
            if (!i_req && ($urandom % 100) < p_new_i) begin i_req = 1; i_addr = rnd_addr(0) & ~32'd1; end
            if (!d_req && nd < `DFN && ($urandom % 100) < p_new_d) begin
                d_req = 1; d_addr = rnd_addr(0) & ~32'd3; d_we = $urandom % 2;
                case ($urandom % 4) 0: d_be = 4'hF; 1: d_be = 4'h3; 2: d_be = 4'hC; 3: d_be = 4'h1; endcase
                d_wdata = $urandom;
            end
        end
        io_in = $urandom;
    end
    integer k;
    initial begin
        for (k = 0; k < 2; k = k + 1) begin mLP[k] = 0; mLF[k] = 0; mS[k] = 0; mLD[k] = 0; mLI[k] = 0; end
        seed = 1;
        if (!$value$plusargs("SE=%d", se_arg)) se_arg = 1;
        stream_en = (se_arg != 0);
        for (run = 0; run < 3000; run = run + 1) begin
            rd_late = run % 2; rst = 1; i_req = 0; d_req = 0;
            p_new_i = 1 + $urandom % 100; p_new_d = 1 + $urandom % 100;
            repeat (3) @(negedge clk);
            // some runs start with both requests pending at reset release
            if (run % 3 == 0) begin i_req = 1; i_addr = rnd_addr(0) & ~32'd1; end
            if (run % 5 == 0) begin d_req = 1; d_addr = rnd_addr(0) & ~32'd3; d_we = $urandom % 2; d_be = 4'hF; end
            rst = 0;
            repeat (1500 + $urandom % 1000) @(negedge clk);
        end
        for (k = 0; k < 2; k = k + 1)
            $display("stream_en=%0d rd_late=%0d LP=%0d LF=%0d S=%0d LD=%0d LI=%0d", stream_en, k, mLP[k], mLF[k], mS[k], mLD[k], mLI[k]);
        $finish;
    end
endmodule
