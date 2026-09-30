// Stress testbench for the memory path: mem_ctrl + qspi_ctrl against the
// QSPI Pmod model, driven with request streams shaped like the core's.
//
// tb_qspi drops i_req between transfers; the core does not. Here the fetch
// request stays high, the next pc appears right after each ready edge, and a
// data request arrives only on the cycle after a fetch completes, as the
// pipeline issues them. It runs:
//   * a directed stream through the corners: 1 KB page ends (0x...3FE),
//     PSRAM A -> B (0x807F_FFFE), the top of PSRAM (0x80FF_FFFE, whose upper
//     half is past the window and not checked), flash;
//   * a split fetch with a data request raised during its first half -- the
//     second half must finish before the load starts;
//   * 400k clocks of random fetches and loads/stores, every result checked
//     against a shadow copy of memory, and the whole PSRAM compared at the end.
//   * with +RESETS, resets of 1-4 clocks dropped into the random traffic
//     (about one per 4,096 clocks), wherever they land -- mid-command,
//     mid-data -- and, after one reset in four, a second one within the
//     next 120 clocks, which lands in the start-up sequence. The run counts
//     resets that hit the start-up sequence, and its 16-clock step 4, and
//     fails if there are too few. After each the engine must run its start-up
//     sequence again, from whatever state the cut-off transaction left the
//     devices in, and carry on. A store the reset cut off may or may not have
//     written its bytes; the shadow takes the model's word for those. The
//     model keeps the PSRAMs' contents across their reset (99h), which the
//     datasheet does not promise; this checks the engine, not that.
// Plusargs as tb_qspi (+QSPI_DELAY, +RD_LATE, the model's), plus +SEED=n and
// +RESETS.
// Written by the 2026-09-26 RTL review; it caught both deliberate breakages
// tried on mem_ctrl (arbitration ignoring a pending split, and splitting only
// at the A/B boundary).
`timescale 1ns / 1ps
module tb_qspi_stress;
    reg clk = 0, rst = 1;
    always #5 clk = ~clk;

    reg         i_req = 0;
    reg  [31:0] i_addr = 0;
    wire [31:0] i_rdata;
    wire        i_ready;
    reg         d_req = 0;
    reg  [31:0] d_addr = 0, d_wdata = 0;
    reg  [3:0]  d_be = 0;
    reg         d_we = 0;
    wire [31:0] d_rdata;
    wire        d_ready;
    wire        q_start, q_we, q_idle, q_done;
    wire [1:0]  q_cs, q_nbytes_m1;
    wire [23:0] q_addr;
    wire [31:0] q_wdata, q_rdata;

    mem_ctrl memc (.clk(clk), .rst(rst),
        .i_req(i_req), .i_addr(i_addr), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be), .d_we(d_we),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .q_start(q_start), .q_cs(q_cs), .q_addr(q_addr), .q_we(q_we),
        .q_nbytes_m1(q_nbytes_m1), .q_wdata(q_wdata),
        .q_idle(q_idle), .q_done(q_done), .q_rdata(q_rdata));

    wire       sck, ctl_oe, io_oe;
    wire [2:0] cs_n;
    wire [3:0] io_out, dev_io;
    wire       dev_oe;
    wire [3:0] io_in = dev_oe ? dev_io : (io_oe ? io_out : 4'bxxxx);
    reg        rd_late;
    initial    rd_late = $test$plusargs("RD_LATE");

    qspi_ctrl qspi (.clk(clk), .rst(rst), .rd_late(rd_late),
        .start(q_start), .cs_sel(q_cs), .addr(q_addr), .we(q_we),
        .nbytes_m1(q_nbytes_m1), .wdata(q_wdata),
        .idle(q_idle), .done(q_done), .rdata(q_rdata),
        .sck(sck), .cs_n(cs_n), .ctl_oe(ctl_oe), .io_out(io_out), .io_oe(io_oe), .io_in(io_in));

    qspi_pmod_model pmod (.host_sck(sck), .host_cs_n(cs_n), .host_ctl_oe(ctl_oe),
        .host_io(io_out), .host_oe(io_oe), .dev_io(dev_io), .dev_oe(dev_oe));

    // mem_ctrl's side of the QSPI engine's request (tb/req_hold_check.v).
    req_hold_check #(.W(61), .NAME("QSPI transaction"), .DONE_NEEDS_REQ(1)) chk_qspi (
        .clk(clk), .rst(rst), .take(q_idle && q_start), .hold(q_start), .done(q_done),
        .payload({q_cs, q_addr, q_we, q_nbytes_m1, q_we ? q_wdata : 32'h0}));

    integer errors = 0, k, n_i = 0, n_d = 0;
    reg dbg_order = 0;
    reg [7:0] shadow [0:16777215];
    function [7:0] sb(input [31:0] a);
        if (a[31]) sb = shadow[a[23:0]];
        else       sb = (a[23:0] < 65536) ? pmod.flash[a[23:0]] : 8'h00;
    endfunction
    function [31:0] sw(input [31:0] a);
        sw = {sb(a+3), sb(a+2), sb(a+1), sb(a)};
    endfunction

    // ---- core-like fetch stream: i_req held high; next pc applied right after the ready edge ----
    reg [31:0] seq [0:63];
    integer    nseq, si;
    reg        stream_on = 0;
    reg        inject_d_mid_split = 0;
    integer    seed;
    reg        rand_mode = 0;

    // data-request generator (core-like: only the cycle after a fetch completes)
    reg        want_d = 0;
    reg [31:0] pend_d_addr; reg pend_d_we; reg [3:0] pend_d_be; reg [31:0] pend_d_wdata;

    task pick_d;
        reg [1:0] sz; reg [1:0] off; reg [7:0] b; reg [15:0] h; reg [31:0] w;
        begin
            pend_d_addr = 32'h8000_0000 | ($random(seed) & 32'h00FF_FFFC);
            if (($random(seed) & 7) == 0) pend_d_addr = 32'h2000_0000 | ($random(seed) & 32'h0000_FFFC);
            pend_d_we = pend_d_addr[31] && ($random(seed) & 1);
            sz = $random(seed) % 3; if (sz == 3) sz = 2;
            off = $random(seed);
            if (sz == 0) begin pend_d_be = 4'b0001 << off; b = $random(seed); pend_d_wdata = {4{b}}; end
            else if (sz == 1) begin pend_d_be = off[1] ? 4'b1100 : 4'b0011; h = $random(seed); pend_d_wdata = {2{h}}; end
            else begin pend_d_be = 4'b1111; w = $random(seed); pend_d_wdata = w; end
            if (!pend_d_we) pend_d_be = 4'b1111;
        end
    endtask

    reg [31:0] exp_i, exp_d;
    integer lanes, fl;
    always @(posedge clk) if (!rst) begin
        if (stream_on && i_ready && i_req) begin
            exp_i = sw(i_addr);
            if (i_addr == 32'h80FF_FFFE) begin
                // upper half is past the window: only the lower half matters
                if (i_rdata[15:0] !== exp_i[15:0]) begin
                    $display("FAIL fetch lo @%08h got %08h want %08h", i_addr, i_rdata, exp_i); errors = errors + 1; end
            end else if (i_rdata !== exp_i) begin
                $display("FAIL fetch @%08h got %08h want %08h t=%0t", i_addr, i_rdata, exp_i, $time); errors = errors + 1;
            end
            n_i = n_i + 1;
            // core: pc advances on the ready edge; maybe a data request the cycle after
            si = si + 1;
            if (rand_mode) begin
                i_addr <= #1 ((($random(seed) & 7) == 0) ? (32'h2000_0000 | ($random(seed) & 32'hFFFE))
                            : (32'h8000_0000 | ($random(seed) & 32'h00FF_FFFE) | ((($random(seed) & 3) == 0) ? 32'h3FE : 0)));
                if (($random(seed) & 1) && !d_req) begin
                    pick_d;
                    d_addr <= #1 pend_d_addr; d_we <= #1 pend_d_we; d_be <= #1 pend_d_be; d_wdata <= #1 pend_d_wdata;
                    d_req  <= #1 1'b1;
                end
            end else begin
                if (si < nseq) i_addr <= #1 seq[si];
                else begin i_req <= #1 0; stream_on <= #1 0; end
            end
        end
        if (d_ready && d_req) begin
            if (d_we) begin
                for (lanes = 0; lanes < 4; lanes = lanes + 1)
                    if (d_be[lanes]) shadow[d_addr[23:0] + lanes] = d_wdata[8*(lanes - 0) +: 8] ;
            end else begin
                exp_d = sw(d_addr);
                if (d_rdata !== exp_d) begin
                    $display("FAIL load @%08h got %08h want %08h t=%0t", d_addr, d_rdata, exp_d, $time); errors = errors + 1; end
            end
            n_d = n_d + 1;
            d_req <= #1 0;
            if (dbg_order) $display("INFO data served t=%0t (fetch count %0d)", $time, n_i);
        end
        if (dbg_order && i_ready) $display("INFO fetch served t=%0t", $time);
    end


    // store data: the core replicates data so lane k carries the byte for lane k already
    // (d_wdata is the replicated value; lane k byte = d_wdata[8k+7:8k])

    // inject a data request during the first half of a split fetch
    always @(posedge clk) if (inject_d_mid_split && memc.q_done == 0 && qspi.state == 3'd4 && memc.split && !memc.second && !d_req) begin
        d_addr <= #1 32'h8000_0200; d_we <= #1 0; d_be <= #1 4'b1111; d_req <= #1 1;
        inject_d_mid_split <= #1 0;
        $display("INFO injected d_req during the first half of a split fetch at t=%0t", $time);
    end

    integer i, nrst = 0, rlen, rst_again = 0, nrst_init = 0, nrst_step4 = 0;
    reg     resets_on;
    initial resets_on = $test$plusargs("RESETS");
    always @(negedge clk) if (resets_on && rand_mode && stream_on && !rst) begin
      if (rst_again > 0) rst_again = rst_again - 1;
      if (rst_again == 1 || (($random(seed) & 4095) == 0)) begin
        if (qspi.init) nrst_init = nrst_init + 1;
        if (qspi.init && qspi.step == 3'd4) nrst_step4 = nrst_step4 + 1;
        rlen = 1 + ($random(seed) & 3);
        if (d_req && d_we) for (lanes = 0; lanes < 4; lanes = lanes + 1) shadow[d_addr[23:0] + lanes] = 8'hxx;
        rst = 1; nrst = nrst + 1;
        repeat (rlen) @(negedge clk);
        // A store the reset cut short may or may not have written each byte.
        for (lanes = 0; lanes < 4; lanes = lanes + 1)
            if (shadow[d_addr[23:0] + lanes] === 8'hxx) shadow[d_addr[23:0] + lanes] = pmod.ram[d_addr[23:0] + lanes];
        d_req = 0; i_addr = 32'h8000_0000 | ($random(seed) & 32'h00FF_FFFE);
        rst = 0;
        rst_again = (($random(seed) & 3) == 0) ? 2 + ($unsigned($random(seed)) % 120) : 0;
      end
    end
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        for (k = 0; k < 256; k = k + 1) pmod.flash[k] = k ^ 8'h5A;
        for (k = 0; k < 65536; k = k + 1) pmod.flash[k] = k[7:0] ^ k[15:8] ^ 8'h5A;
        for (k = 0; k < 16777216; k = k + 1) begin shadow[k] = k[7:0] ^ k[15:8] ^ k[23:16]; pmod.ram[k] = shadow[k]; end
        repeat (3) @(posedge clk);
        rst = 0;

        // directed: core-like continuous fetch through the corners
        seq[0] = 32'h8000_03FC; seq[1] = 32'h8000_03FE; seq[2] = 32'h8000_0400;
        seq[3] = 32'h807F_FFFE; seq[4] = 32'h8080_0000; seq[5] = 32'h80FF_FFFE;
        seq[6] = 32'h8000_0000; seq[7] = 32'h2000_00FE; seq[8] = 32'h80FF_FBFE;
        seq[9] = 32'h8000_07FE; seq[10] = 32'h2000_0002;
        nseq = 11; si = 0;
        @(negedge clk); i_addr = seq[0]; i_req = 1; stream_on = 1;
        wait (!stream_on);
        $display("INFO directed stream done: %0d fetches", n_i);

        // split fetch with a data request injected mid-first-half
        @(negedge clk); nseq = 1; seq[0] = 32'h8000_07FE; si = 0; inject_d_mid_split = 1; dbg_order = 1;
        i_addr = 32'h8000_07FE; i_req = 1; stream_on = 1;
        wait (!stream_on); wait (!d_req);
        $display("INFO mid-split injection done"); dbg_order = 0;

        // random core-like traffic
        rand_mode = 1;
        @(negedge clk); i_addr = 32'h8000_0000; i_req = 1; stream_on = 1;
        repeat (400000) @(posedge clk);
        stream_on = 0;
        // final memory compare
        for (k = 0; k < 16777216; k = k + 1)
            if (pmod.ram[k] !== shadow[k]) begin
                if (errors < 20) $display("FAIL ram[%06h] model %02h shadow %02h", k, pmod.ram[k], shadow[k]);
                errors = errors + 1;
            end
        if (resets_on && (nrst < 20 || nrst_init < 5 || nrst_step4 < 1)) begin
            $display("FAIL tb_qspi_stress: %0d resets injected, %0d in start-up, %0d in its step 4",
                     nrst, nrst_init, nrst_step4);
            errors = errors + 1;
        end
        if (errors == 0) $display("PASS tb_qspi_stress fetches=%0d data=%0d resets=%0d (%0d in start-up, %0d in step 4) (rd_late=%0d delay=%0d)",
                                  n_i, n_d, nrst, nrst_init, nrst_step4, rd_late, pmod.delay_ns);
        else $display("FAIL tb_qspi_stress: %0d errors", errors);
        $finish;
    end
    initial begin #60000000; $display("TIMEOUT"); $finish; end
endmodule
