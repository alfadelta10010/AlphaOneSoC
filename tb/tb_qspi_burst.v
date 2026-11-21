// WO-68: PSRAM line bursts. mem_ctrl + qspi_ctrl against the QSPI Pmod model, the instruction port driven like the cache
// drives it in a line fill (four aligned word requests in line order, i_burst high) and the data port used to break
// bursts. Checks, from the model's own counters and its tCEM / 1 KB page checks (which end the run on a failure):
//   * a four-word fill of a PSRAM line is ONE read command (n_pr) with streaming on, four with +NOSTREAM;
//   * the burst ends with chip select high after the line's last word, never crosses the page (a line at the
//     page's end), and works on both chips, on the last line of PSRAM A and with rd_late;
//   * anything but the next word closes it at once: a data load or store (same chip, other chip, flash), a
//     fetch that is not the next word, the other chip at the same offset, a request without i_burst, a request
//     that never comes (chip select must be high four clocks after a word's ready);
//   * no qualifier, no burst: ordinary PSRAM fetches and loads cost one command each;
//   * a reset at every clock of a continuing word;
//   * the longest PSRAM chip-select-low time seen (the model's tcem_max) stays far below tCEM.
// Plusargs: +RD_LATE, +NOSTREAM, +DDR (flash DDR on), +QSPI_DELAY=<ns> and +CLK_HALF_PS=<ps> as tb_qspi.
`timescale 1ns / 1ps
module tb_qspi_burst;
    reg clk = 0, rst = 1;
    real half = 5.0;
    integer half_ps;
    initial begin
        if ($value$plusargs("CLK_HALF_PS=%d", half_ps)) half = half_ps / 1000.0;
        forever #(half) clk = ~clk;
    end
    reg         i_req = 0, i_burst = 0;
    reg  [31:0] i_addr = 0;
    wire [31:0] i_rdata;
    wire        i_ready;
    reg         d_req = 0, d_we = 0;
    reg  [31:0] d_addr = 0, d_wdata = 0;
    reg  [3:0]  d_be = 0;
    wire [31:0] d_rdata;
    wire        d_ready;
    wire        q_start, q_we, q_idle, q_done, q_burst;
    wire [1:0]  q_cs, q_nbytes_m1;
    wire [23:0] q_addr;
    wire [31:0] q_wdata, q_rdata;

    mem_ctrl memc (.clk(clk), .rst(rst),
        .i_req(i_req), .i_addr(i_addr), .i_burst(i_burst), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be), .d_we(d_we),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .q_start(q_start), .q_cs(q_cs), .q_addr(q_addr), .q_we(q_we),
        .q_nbytes_m1(q_nbytes_m1), .q_wdata(q_wdata), .q_burst(q_burst),
        .q_idle(q_idle), .q_done(q_done), .q_rdata(q_rdata));

    wire       sck, ctl_oe, io_oe;
    wire [2:0] cs_n;
    wire [3:0] io_out, dev_io;
    wire       dev_oe;
    wire [3:0] io_in = dev_oe ? dev_io : (io_oe ? io_out : 4'bxxxx);
    reg        rd_late, stream_en, ddr_v;
    initial begin
        rd_late = $test$plusargs("RD_LATE");
        stream_en = !$test$plusargs("NOSTREAM");
        ddr_v = $test$plusargs("DDR");
    end
    qspi_ctrl qspi (.clk(clk), .rst(rst), .rd_late(rd_late), .stream_en(stream_en),
        .ddr(ddr_v), .ddr_cap(3'd1), .burst(q_burst),
        .start(q_start), .cs_sel(q_cs), .addr(q_addr), .we(q_we),
        .nbytes_m1(q_nbytes_m1), .wdata(q_wdata),
        .idle(q_idle), .done(q_done), .rdata(q_rdata),
        .sck(sck), .cs_n(cs_n), .ctl_oe(ctl_oe), .io_out(io_out), .io_oe(io_oe), .io_in(io_in));
    qspi_pmod_model pmod (.host_sck(sck), .host_cs_n(cs_n), .host_ctl_oe(ctl_oe),
        .host_io(io_out), .host_oe(io_oe), .dev_io(dev_io), .dev_oe(dev_oe));
    qspi_pin_inv pins (.clk(clk), .ctl_oe(ctl_oe), .cs_n(cs_n), .sck(sck), .io_oe(io_oe), .quiet(1'b0));

    integer errors = 0;
    function [31:0] mem_word(input [31:0] a);
        mem_word = {pmod.ram_rd(a[23:0] + 3), pmod.ram_rd(a[23:0] + 2), pmod.ram_rd(a[23:0] + 1), pmod.ram_rd(a[23:0])};
    endfunction
    function [31:0] fl_word(input [31:0] a);
        fl_word = {pmod.flash_rd(a[23:0] + 3), pmod.flash_rd(a[23:0] + 2), pmod.flash_rd(a[23:0] + 1), pmod.flash_rd(a[23:0])};
    endfunction
    task err(input [8*40-1:0] what);
        begin $display("FAIL %0s t=%0t", what, $time); errors = errors + 1; end
    endtask

    // One word request on the i-port, held until ready; wait_k clocks of delay before the request.
    // Like the cache, the next word follows with no idle clock: the request is NOT dropped after ready, the next
    // fword (or a task that needs the port idle: dload, dstore, fend) changes or drops it within the same clock.
    task fword(input [31:0] a, input b, input integer wait_k);
        begin
            if (wait_k > 0) begin
                @(negedge clk); i_req = 0; i_burst = 0;
                repeat (wait_k) @(negedge clk);
            end
            if (!i_req) @(negedge clk);
            i_req = 1; i_addr = a; i_burst = b;
            if ($test$plusargs("TRACE")) $display("%0t fword %08h burst %0d", $time, a, b);
            @(posedge clk); while (!i_ready) @(posedge clk);
            if (i_rdata !== (a[31] ? mem_word(a) : fl_word(a))) begin
                $display("FAIL fetch @%08h got %08h", a, i_rdata); errors = errors + 1;
            end
            #1;
        end
    endtask
    task fend;                                   // release the fetch port (within the half clock after a ready)
        begin @(negedge clk); i_req = 0; i_burst = 0; end
    endtask
    task dload(input [31:0] a);
        begin
            @(negedge clk); i_req = 0; i_burst = 0; d_req = 1; d_we = 0; d_addr = a; d_be = 4'hF;
            @(posedge clk); while (!d_ready) @(posedge clk);
            if (d_rdata !== (a[31] ? mem_word(a) : fl_word(a))) begin
                $display("FAIL load @%08h got %08h want %08h", a, d_rdata, a[31] ? mem_word(a) : fl_word(a)); errors = errors + 1;
            end
            @(negedge clk); d_req = 0;
        end
    endtask
    task dstore(input [31:0] a, input [31:0] v);
        begin
            @(negedge clk); i_req = 0; i_burst = 0; d_req = 1; d_we = 1; d_addr = a; d_be = 4'hF; d_wdata = v;
            @(posedge clk); while (!d_ready) @(posedge clk);
            @(negedge clk); d_req = 0; d_we = 0;
        end
    endtask
    // The four words of a line; hook: after word k (0..3) do something (op 0 none, 1 load same chip,
    // 2 load other chip, 3 load flash, 4 store same chip, 5 idle gap, 6 next fetch without i_burst)
    task line(input [31:0] base, input integer op, input integer after_k);
        integer w;
        begin
            for (w = 0; w < 4; w = w + 1) begin
                fword(base + 4 * w, (op == 6 && w == after_k + 1) ? 1'b0 : 1'b1, (op == 5 && w == after_k + 1) ? 40 : 0);
                if (w == after_k) case (op)
                    1: dload(base ^ 32'h0000_0400);
                    2: dload(base ^ 32'h0080_0000);
                    3: dload(32'h2000_0040);
                    4: dstore(base ^ 32'h0000_0400, 32'hA5A5_5A5A);
                    default: ;
                endcase
            end
            fend;
        end
    endtask
    integer n0, nb0;
    task cmds(input [8*40-1:0] what, input integer want_stream, input integer want_plain);
      begin
        fend;
        if ((pmod.n_pr - n0) != (stream_en ? want_stream : want_plain)) begin
            $display("FAIL %0s: %0d PSRAM read commands, want %0d", what, pmod.n_pr - n0, stream_en ? want_stream : want_plain);
            errors = errors + 1;
        end
      end
    endtask
    // CS high four clocks after a ready with no request following (a burst must not wait)
    integer cs_wait_fail = 0;
    task idle_closes;
        begin
            fword(32'h8000_0500, 1'b1, 0);               // word 0 of a line, then nothing
            fend;
            repeat (4) @(posedge clk);
            if (cs_n !== 3'b111) begin $display("FAIL idle burst left CS low (cs_n=%b)", cs_n); errors = errors + 1; end
        end
    endtask
    integer k, w;
    initial begin
        repeat (4) @(negedge clk); rst = 0;
        // 1. plain burst, chip A, chip B
        n0 = pmod.n_pr; line(32'h8000_0100, 0, 9); cmds("line A", 1, 4);
        n0 = pmod.n_pr; line(32'h8080_0200, 0, 9); cmds("line B", 1, 4);
        // the last line of a page, and of PSRAM A
        n0 = pmod.n_pr; line(32'h8000_03F0, 0, 9); cmds("last line of a page", 1, 4);
        n0 = pmod.n_pr; line(32'h807F_FFF0, 0, 9); cmds("last line of A", 1, 4);
        // 2. no qualifier: one command per word
        n0 = pmod.n_pr; for (w = 0; w < 4; w = w + 1) fword(32'h8000_0600 + 4 * w, 1'b0, 0); cmds("no qualifier", 4, 4);
        // 3. breakers after each word
        for (k = 0; k < 3; k = k + 1) begin
            n0 = pmod.n_pr; line(32'h8000_0700, 1, k); cmds("load same chip", 3, 5);
            n0 = pmod.n_pr; line(32'h8000_0710, 2, k); cmds("load other chip", 3, 5);
            n0 = pmod.n_pr; line(32'h8000_0720, 3, k); cmds("load flash", 2, 4);
            n0 = pmod.n_pr; line(32'h8000_0730, 4, k); cmds("store same chip", 2, 4);
            n0 = pmod.n_pr; line(32'h8000_0740, 5, k); cmds("idle gap", 2, 4);
            n0 = pmod.n_pr; line(32'h8000_0750, 6, k); cmds("no qualifier mid-line", k < 2 ? 3 : 2, 4);
        end
        // 4. not the next word: skip a word, repeat a word, go back; the other chip at the next offset
        n0 = pmod.n_pr; fword(32'h8000_0800, 1, 0); fword(32'h8000_0808, 1, 0); fword(32'h8000_080C, 1, 0); cmds("skip a word", 2, 3);
        n0 = pmod.n_pr; fword(32'h8000_0810, 1, 0); fword(32'h8000_0810, 1, 0); cmds("same word twice", 2, 2);
        n0 = pmod.n_pr; fword(32'h8000_0824, 1, 0); fword(32'h8000_0820, 1, 0); cmds("back", 2, 2);
        n0 = pmod.n_pr; fword(32'h8000_0830, 1, 0); fword(32'h8080_0834, 1, 0); fword(32'h8080_0838, 1, 0); cmds("other chip", 2, 3);
        n0 = pmod.n_pr; fword(32'h8000_0840, 1, 0); fword(32'h2000_0100, 1, 0); fword(32'h8000_0844, 1, 0); cmds("flash fetch between", 2, 2);
        // a burst opened at word 1, 2 (not only word 0) and at the last word
        n0 = pmod.n_pr; fword(32'h8000_0854, 1, 0); fword(32'h8000_0858, 1, 0); fword(32'h8000_085C, 1, 0); cmds("open at word 1", 1, 3);
        n0 = pmod.n_pr; fword(32'h8000_086C, 1, 0); fword(32'h8000_0870, 1, 0); cmds("last word opens none", 2, 2);
        // a burst does not carry into the next line even when asked
        n0 = pmod.n_pr; fword(32'h8000_087C, 1, 0); fword(32'h8000_0880, 1, 0); cmds("line end", 2, 2);
        // 5. the request that never comes
        idle_closes;
        // 6. flash fetches around a burst, flash stream open into a PSRAM burst
        fword(32'h2000_0200, 0, 0); fword(32'h2000_0204, 0, 0);
        n0 = pmod.n_pr; line(32'h8000_0900, 0, 9); cmds("line after a flash stream", 1, 4);
        fword(32'h2000_0208, 0, 0);
        // 7. a reset at every clock of a continuing word
        for (k = 0; k < 40; k = k + 1) begin
            fword(32'h8000_0A00, 1, 0);
            @(negedge clk); i_req = 1; i_addr = 32'h8000_0A04; i_burst = 1;
            repeat (k) @(posedge clk);
            @(negedge clk); rst = 1; i_req = 0; i_burst = 0;
            repeat (2) @(negedge clk);
            rst = 0;
            line(32'h8000_0B00, 0, 9);
        end
        // 8. mixed random traffic
        for (k = 0; k < 400; k = k + 1) begin
            w = $urandom % 8;
            case (w)
                0, 1, 2: line(32'h8000_0000 | (($urandom % 8) << 4) | (($urandom % 2) << 23) | (($urandom % 64) << 10), 0, 9);
                3: line(32'h8000_0C00 | (($urandom % 4) << 4), 1 + ($urandom % 6), $urandom % 3);
                4: fword(32'h8000_0000 | (($urandom % 256) << 2), $urandom % 2, 0);
                5: dload(32'h8000_0000 | (($urandom % 256) << 2));
                6: fword(32'h2000_0000 | (($urandom % 256) << 2), 0, $urandom % 3);
                default: begin fword(32'h8000_0D00, 1, 0); fword(32'h8000_0D04, 1, $urandom % 6); end
            endcase
        end
        if (pmod.tcem_max > 2000.0) begin $display("FAIL longest PSRAM CS low %0f ns", pmod.tcem_max); errors = errors + 1; end
        if (errors == 0)
            $display("PASS tb_qspi_burst (rd_late=%0d, stream=%0d, ddr=%0d; longest CS low %0.0f ns, %0d PSRAM reads, %0d bytes)",
                     rd_late, stream_en, ddr_v, pmod.tcem_max, pmod.n_pr, pmod.n_prb);
        else $display("FAIL tb_qspi_burst: %0d errors", errors);
        $finish;
    end
    initial begin #200000000; $display("TIMEOUT tb_qspi_burst"); $finish; end
endmodule
