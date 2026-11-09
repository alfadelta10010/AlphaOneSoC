// Testbench for the memory path: mem_ctrl + qspi_ctrl against the QSPI Pmod
// model, driven the way the core drives its ports (a request is held until
// ready).
//
// Checks every transfer shape the core can issue:
//   * word, halfword and byte stores in every lane, to PSRAM A and B, checked
//     against the model's array;
//   * whole-word loads from both chips and from flash;
//   * fetches at word and halfword addresses, including those that cross a
//     1 KB PSRAM page (split into two reads) -- one of which crosses from
//     PSRAM A into PSRAM B -- and flash fetches;
//   * a fetch and a load raised together: the load must be served first;
//   * a store aimed at flash, which the core's PMA check never lets out: it
//     must complete without selecting any chip -- qspi_ctrl's backstop, as
//     0x38 is Enter QPI on the W25Q128JV-DTR -- and change nothing.
//
//   * streaming flash reads (stream_en): sequential fetches and loads keep CS0
//     low and send data clocks only (the model counts the read commands: one
//     for a whole run); the 2-byte top-up; a non-sequential read; PSRAM reads
//     and writes while a stream is open; a reset while a stream is open and
//     at every point of a continuing read. Pin invariants every clock
//     (qspi_pin_inv in the model).
//
// DDR (EDh): +DDR sets qspi_ctrl's ddr input, +DDR_CAP=<n> its capture point (default
// 2). The default delays (2 ns, hold 1) suit DDR_CAP 0 and 1 at the 10 ns clock. +CLK_HALF_PS=<ps>
// sets the clock's half period (default 5000; 8000 is the SoC's 62.5 MHz). +MODESW adds a
// run of mode switches (ddr 0 -> 1 -> 0, ddr_cap changes) while a stream is open.
// +SWEEP runs only the flash-only suite in the selected mode and prints one
// "SWEEP PASS|FAIL" line (tests the capture point for the round trip the model's
// +QSPI_DELAY/+QSPI_HOLD stand for; see the test-qspi-ddr-sweep target).
//
// Plusargs: +NOSTREAM ties stream_en low, +STREAM_TOGGLE flips it at random
// clocks; +QSPI_DELAY=<ns> device + pad delay; +RD_LATE drives the
// controller's rd_late strap; and the model's +PSRAM_WRAP, +PSRAM_QPI,
// +FLASH_CRM, +FLASH_QPI (see tb/qspi_pmod_model.v). With rd_late = 0 the
// controller samples two clocks after the launching edge, so any delay below
// one SCK period (20 ns here) must pass; with rd_late = 1, three clocks.

`timescale 1ns / 1ps

module tb_qspi;
    reg clk = 0, rst = 1;
    real half = 5.0;
    integer half_ps;
    initial begin
        if ($value$plusargs("CLK_HALF_PS=%d", half_ps)) half = half_ps / 1000.0;
        forever #(half) clk = ~clk;
    end

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

    mem_ctrl memc (
        .clk(clk), .rst(rst),
        .i_req(i_req), .i_addr(i_addr), .i_rdata(i_rdata), .i_ready(i_ready),
        .d_req(d_req), .d_addr(d_addr), .d_wdata(d_wdata), .d_be(d_be), .d_we(d_we),
        .d_rdata(d_rdata), .d_ready(d_ready),
        .q_start(q_start), .q_cs(q_cs), .q_addr(q_addr), .q_we(q_we),
        .q_nbytes_m1(q_nbytes_m1), .q_wdata(q_wdata),
        .q_idle(q_idle), .q_done(q_done), .q_rdata(q_rdata)
    );

    wire       sck, ctl_oe, io_oe;
    wire [2:0] cs_n;
    wire [3:0] io_out, dev_io;
    wire       dev_oe;
    // The pins as the controller sees them. Nobody driving reads X, so
    // sampling an undriven bus shows up as a wrong result.
    wire [3:0] io_in = dev_oe ? dev_io : (io_oe ? io_out : 4'bxxxx);
    reg        rd_late;
    initial    rd_late = $test$plusargs("RD_LATE");
    reg        stream_en;
    reg        toggle;
    initial begin
        stream_en = !$test$plusargs("NOSTREAM");
        toggle    = $test$plusargs("STREAM_TOGGLE");
    end
    integer    tseed = 7;
    always @(negedge clk) if (toggle && ($random(tseed) & 15) == 0) stream_en <= ~stream_en;

    reg        ddr_v;
    reg [2:0]  cap_v;
    reg        sweep;
    initial begin
        ddr_v = $test$plusargs("DDR");
        cap_v = 3'd2;
        if ($value$plusargs("DDR_CAP=%d", cap_v)) ;
        sweep = $test$plusargs("SWEEP");
    end

    qspi_ctrl qspi (
        .clk(clk), .rst(rst), .rd_late(rd_late), .stream_en(stream_en),
        .ddr(ddr_v), .ddr_cap(cap_v),
        .start(q_start), .cs_sel(q_cs), .addr(q_addr), .we(q_we),
        .nbytes_m1(q_nbytes_m1), .wdata(q_wdata),
        .idle(q_idle), .done(q_done), .rdata(q_rdata),
        .sck(sck), .cs_n(cs_n), .ctl_oe(ctl_oe), .io_out(io_out), .io_oe(io_oe),
        .io_in(io_in)
    );

    qspi_pmod_model pmod (
        .host_sck(sck), .host_cs_n(cs_n), .host_ctl_oe(ctl_oe),
        .host_io(io_out), .host_oe(io_oe), .dev_io(dev_io), .dev_oe(dev_oe)
    );

    qspi_pin_inv pins (.clk(clk), .ctl_oe(ctl_oe), .cs_n(cs_n), .sck(sck), .io_oe(io_oe),
        .quiet(qspi.strm && qspi.state != qspi.S_CMD && qspi.state != qspi.S_ADDR &&
               qspi.state != qspi.S_DUMMY && qspi.state != qspi.S_DATA &&
               qspi.state != qspi.S_CLOSE && qspi.state != qspi.S_GO));

    // mem_ctrl's side of the QSPI engine's request (tb/req_hold_check.v).
    req_hold_check #(.W(61), .NAME("QSPI transaction"), .DONE_NEEDS_REQ(1), .LATE(1)) chk_qspi (
        .clk(clk), .rst(rst), .take(q_idle && q_start), .hold(q_start), .done(q_done),
        .payload({q_cs, q_addr, q_we, q_nbytes_m1, q_we ? q_wdata : 32'h0}));

    integer errors = 0;
    integer k;

    // Interface assertions (REVIEW-53 m-1, m-2).
    // Flash reads are 4 bytes: the DDR read ignores nbytes_m1.
    // nbytes_m1 is valid from the cycle after the start cycle (see qspi_ctrl.v, Interface).
    reg fl_rd_st = 0;
    always @(posedge clk) begin
        fl_rd_st <= !rst && q_idle && q_start && q_cs == 2'd0 && !q_we;
        if (fl_rd_st && q_nbytes_m1 != 2'd3) begin
            $display("FAIL flash read with nbytes_m1 = %0d (must be 3)", q_nbytes_m1);
            errors = errors + 1;
        end
    end
    // The command byte of every DDR open, rebuilt from IO0 at the SCK rises:
    // its first bit comes from the idle nibble, so it must equal cmd[7] of EDh.
    integer cmd_n = 8;
    reg [7:0] cmd_b = 8'h00;
    always @(negedge cs_n[0]) begin cmd_n = 0; cmd_b = 8'h00; end
    always @(posedge sck) if (ctl_oe && !cs_n[0] && cmd_n < 8) begin
        cmd_b = {cmd_b[6:0], io_out[0]};
        cmd_n = cmd_n + 1;
        if (cmd_n == 8 && qspi.t_ddr && cmd_b !== 8'hED) begin
            $display("FAIL DDR command byte on IO0 is %h, not ED (first bit %b)", cmd_b, cmd_b[7]);
            errors = errors + 1;
        end
    end

    // Byte at a system address, straight from the model's arrays.
    function [7:0] mem_byte(input [31:0] a);
        if (a[31]) mem_byte = pmod.ram_rd(a[23:0]);
        else       mem_byte = pmod.flash_rd(a[23:0]);
    endfunction

    function [31:0] mem_word(input [31:0] a);   // 4 bytes from a, little-endian
        mem_word = {mem_byte(a + 3), mem_byte(a + 2), mem_byte(a + 1), mem_byte(a)};
    endfunction

    task check(input [8*24-1:0] what, input [31:0] a, input [31:0] got, input [31:0] want);
        if (got !== want) begin
            $display("FAIL %0s @%08h: got %08h want %08h", what, a, got, want);
            errors = errors + 1;
        end
    endtask

    task store(input [31:0] a, input [3:0] be, input [31:0] data);
        begin
            @(negedge clk);
            d_req = 1; d_we = 1; d_addr = {a[31:2], 2'b00}; d_be = be; d_wdata = data;
            @(posedge clk); while (!d_ready) @(posedge clk);
            @(negedge clk); d_req = 0; d_we = 0;
        end
    endtask

    task load(input [31:0] a);
        begin
            @(negedge clk);
            d_req = 1; d_we = 0; d_addr = {a[31:2], 2'b00}; d_be = 4'b1111;
            @(posedge clk); while (!d_ready) @(posedge clk);
            check("load", a, d_rdata, mem_word({a[31:2], 2'b00}));
            @(negedge clk); d_req = 0;
        end
    endtask

    task fetch(input [31:0] a);
        begin
            @(negedge clk);
            i_req = 1; i_addr = a;
            @(posedge clk); while (!i_ready) @(posedge clk);
            check("fetch", a, i_rdata, mem_word(a));
            @(negedge clk); i_req = 0;
        end
    endtask

    // Store data the way the core presents it: replicated across the lanes.
    function [31:0] rep(input [1:0] size, input [31:0] v);
        rep = (size == 0) ? {4{v[7:0]}} : (size == 1) ? {2{v[15:0]}} : v;
    endfunction

    reg [31:0] base;
    integer    lane;
    time       t_d, t_i;

    // Any chip select falling while flash_wr is set is a failure (an open
    // stream's CS0 is already low, and rises to close it).
    reg        flash_wr = 0;
    reg [2:0]  cs_prev = 3'b111;
    always @(posedge clk) begin
        cs_prev <= cs_n;
        if (flash_wr && ctl_oe && (~cs_n & cs_prev) != 3'b000) begin
            $display("FAIL flash store selected a chip (cs_n=%b)", cs_n);
            errors   = errors + 1;
            flash_wr = 0;
        end
    end

    // Flash reads the model saw since `n0`; a run of sequential reads must be
    // one command with streaming (stream_en steady at 1), one each without.
    integer n0, nrun;
    task cmds_since(input [8*24-1:0] what, input integer want_stream, input integer want_plain);
        if (!toggle && ((pmod.n_eb + pmod.n_edh) - n0) != (stream_en ? want_stream : want_plain)) begin
            $display("FAIL %0s: %0d flash read commands, want %0d", what, (pmod.n_eb + pmod.n_edh) - n0,
                     stream_en ? want_stream : want_plain);
            errors = errors + 1;
        end
    endtask

    // A reset `k` clocks after a flash fetch is raised, with a stream open
    // beforehand (a hit at the next halfword/word): every k from the start
    // (S_IDLE, S_CHK) through the data phase and past it.
    integer rk;
    task reset_in_fetch(input [31:0] a, input integer k);
        begin
            @(negedge clk); i_req = 1; i_addr = a;
            repeat (k) @(posedge clk);
            @(negedge clk); rst = 1; i_req = 0;
            repeat (2) @(negedge clk);
            rst = 0;
        end
    endtask

    // The flash-only suite: every flash read shape (open, continue, top-up,
    // skip, back, a 6-byte open at addr[1] = 1, loads), no PSRAM traffic.
    task flash_suite;
        begin
            for (k = 0; k < 8; k = k + 1) fetch(32'h2000_0200 + 4 * k);
            fetch(32'h2000_0240); fetch(32'h2000_0242); fetch(32'h2000_0244);
            fetch(32'h2000_0248); fetch(32'h2000_024C); fetch(32'h2000_024E);
            fetch(32'h2000_0280); load(32'h2000_0284); fetch(32'h2000_0288);
            load(32'h2000_028C); load(32'h2000_0290);
            fetch(32'h2000_0302); fetch(32'h2000_0306); fetch(32'h2000_030A);
            fetch(32'h2000_0308); fetch(32'h2000_0300); fetch(32'h2000_02FC);
            fetch(32'h2000_0402); fetch(32'h2000_0406);
            load(32'h2000_0000); load(32'h2000_0010);
            fetch(32'h2000_0020); fetch(32'h2000_0022);
        end
    endtask

    // Mode switches with a stream open. Each fetch that cannot continue the
    // stream (a mode change) is a new command; one that can is not.
    integer ne0;
    task mode_switch_suite;
        begin
            ddr_v = 0; cap_v = 3'd1;
            fetch(32'h2000_0600); fetch(32'h2000_0604);          // an SDR stream is open
            ne0 = pmod.n_edh; n0 = (pmod.n_eb + pmod.n_edh);
            ddr_v = 1;
            fetch(32'h2000_0608);                                // mode change: close, EDh open
            fetch(32'h2000_060C);                                // DDR continuation
            fetch(32'h2000_060E);                                // DDR top-up
            if (!toggle && ((pmod.n_eb + pmod.n_edh) - n0 != (stream_en ? 1 : 3) || pmod.n_edh - ne0 != (stream_en ? 1 : 3))) begin
                $display("FAIL ddr switch 0->1: %0d commands, %0d EDh", (pmod.n_eb + pmod.n_edh) - n0, pmod.n_edh - ne0);
                errors = errors + 1;
            end
            n0 = (pmod.n_eb + pmod.n_edh);
            cap_v = 3'd0;                                        // capture point change
            fetch(32'h2000_0614); fetch(32'h2000_0618);
            if (!toggle && (pmod.n_eb + pmod.n_edh) - n0 != (stream_en ? 1 : 2)) begin
                $display("FAIL ddr_cap change: %0d commands", (pmod.n_eb + pmod.n_edh) - n0);
                errors = errors + 1;
            end
            n0 = (pmod.n_eb + pmod.n_edh); ne0 = pmod.n_edh;
            ddr_v = 0;                                           // back to SDR
            fetch(32'h2000_061C); fetch(32'h2000_0620);
            if (!toggle && ((pmod.n_eb + pmod.n_edh) - n0 != (stream_en ? 1 : 2) || pmod.n_edh != ne0)) begin
                $display("FAIL ddr switch 1->0: %0d commands, %0d EDh", (pmod.n_eb + pmod.n_edh) - n0, pmod.n_edh - ne0);
                errors = errors + 1;
            end
            // A mode change with nobody waiting closes the stream by itself.
            repeat (10) @(negedge clk);
            ddr_v = 1; cap_v = 3'd1;
            repeat (10) @(negedge clk);
            if (cs_n[0] !== 1'b1) begin
                $display("FAIL ddr change did not close the idle stream (cs_n=%b)", cs_n);
                errors = errors + 1;
            end
            fetch(32'h2000_0624); fetch(32'h2000_0628);          // DDR again
            cap_v = 3'd0; repeat (10) @(negedge clk);
            if (cs_n[0] !== 1'b1) begin
                $display("FAIL ddr_cap change did not close the idle stream (cs_n=%b)", cs_n);
                errors = errors + 1;
            end
            fetch(32'h2000_062C);
        end
    endtask

    initial begin
        for (k = 0; k < 256; k = k + 1) pmod.flash[k] = k ^ 8'h5A;
        for (k = 512; k < 2048; k = k + 1) pmod.flash[k] = (k * 37) ^ (k >> 3);
        repeat (3) @(posedge clk);
        rst = 0;

        if (sweep) begin
            // The init sequence is SDR whatever the round trip; wait for it.
            while (!q_idle) @(posedge clk);
            flash_suite;
            if (errors == 0) $display("SWEEP PASS (cap %0d, ddr %0d, delay %0d hold %0d)", cap_v, ddr_v, pmod.delay_ns, pmod.hold_ns);
            else             $display("SWEEP FAIL (cap %0d, ddr %0d, delay %0d hold %0d): %0d errors", cap_v, ddr_v, pmod.delay_ns, pmod.hold_ns, errors);
            $finish;
        end

        // Stores in every shape, both chips, then read back through loads.
        for (k = 0; k < 2; k = k + 1) begin
            base = k ? 32'h8080_0100 : 32'h8000_0100;
            store(base + 0, 4'b1111, 32'h1122_3344);
            for (lane = 0; lane < 4; lane = lane + 1)
                store(base + 4 + lane, 4'b0001 << lane, rep(0, 8'hA0 + lane));
            store(base + 8,  4'b0011, rep(1, 16'hBEEF));
            store(base + 10, 4'b1100, rep(1, 16'hCAFE));
            check("word",  base,     mem_word(base),     32'h1122_3344);
            check("bytes", base + 4, mem_word(base + 4), 32'hA3A2_A1A0);
            check("halfs", base + 8, mem_word(base + 8), 32'hCAFE_BEEF);
            load(base); load(base + 4); load(base + 8);
        end

        // The chip boundary: last word of A, first word of B.
        store(32'h807F_FFFC, 4'b1111, 32'hD4C3_B2A1);
        store(32'h8080_0000, 4'b1111, 32'h8877_6655);
        fetch(32'h807F_FFFC);
        fetch(32'h807F_FFFE);       // split: A 0x7FFFFE-F, then B 0x000000-1
        fetch(32'h8080_0000);
        fetch(32'h8000_0102);       // halfword-aligned, one chip
        fetch(32'h8080_0106);

        // Every other 1 KB page boundary: split too, or a part that wraps at
        // the page returns the page's first halfword.
        store(32'h8000_03FC, 4'b1111, 32'h4433_2211);
        store(32'h8000_0400, 4'b1111, 32'h8877_6655);
        fetch(32'h8000_03FE);
        store(32'h8080_07FC, 4'b1111, 32'hCCBB_AA99);
        store(32'h8080_0800, 4'b1111, 32'h00FF_EEDD);
        fetch(32'h8080_07FE);

        // Flash
        load(32'h2000_0000); load(32'h2000_0010);
        fetch(32'h2000_0020); fetch(32'h2000_0022);

        // Streaming. Sequential flash fetches in 4-byte steps and 2-byte
        // steps (the top-up, then the continue behind it), loads at the
        // stream address, a jump, and PSRAM accesses that close the stream.
        n0 = (pmod.n_eb + pmod.n_edh);
        for (k = 0; k < 6; k = k + 1) fetch(32'h2000_0200 + 4 * k);
        cmds_since("sequential fetches", 1, 6);
        n0 = (pmod.n_eb + pmod.n_edh);
        fetch(32'h2000_0240); fetch(32'h2000_0242); fetch(32'h2000_0244);   // two top-ups in a row
        fetch(32'h2000_0248); fetch(32'h2000_024C); fetch(32'h2000_024E);   // continues, then a top-up
        cmds_since("top-up run", 1, 6);
        n0 = (pmod.n_eb + pmod.n_edh);
        fetch(32'h2000_0280); load(32'h2000_0284); fetch(32'h2000_0288);    // loads at the stream address
        load(32'h2000_028C); load(32'h2000_0290);
        cmds_since("fetch and load run", 1, 5);
        n0 = (pmod.n_eb + pmod.n_edh);
        fetch(32'h2000_0300); fetch(32'h2000_0308);                         // a skip: close and reopen
        fetch(32'h2000_02FC); fetch(32'h2000_0300);                         // back (then a continue)
        fetch(32'h2000_02F0);                                               // well before p
        cmds_since("non-sequential", 4, 5);
        n0 = (pmod.n_eb + pmod.n_edh);
        fetch(32'h2000_0340); load(32'h8000_0100); fetch(32'h2000_0344);    // PSRAM read closes the stream
        store(32'h8000_0108, 4'b1111, 32'h0BAD_F00D); fetch(32'h2000_0348); // so does a PSRAM write
        fetch(32'h8080_0100); fetch(32'h2000_034C);
        check("write after stream", 32'h8000_0108, mem_word(32'h8000_0108), 32'h0BAD_F00D);
        cmds_since("psram between", 4, 4);
        n0 = (pmod.n_eb + pmod.n_edh);
        fetch(32'h2000_0380); fetch(32'h2000_0384);
        flash_wr = 1;
        store(32'h2000_0388, 4'b1111, 32'hDEAD_BEEF);                       // a flash store closes it too
        flash_wr = 0;
        fetch(32'h2000_0388); fetch(32'h2000_038C);
        cmds_since("flash store between", 2, 4);

        // Halfword-aligned opens: a jump to addr[1] = 1 opens (a DDR open reads 6 bytes
        // from the word below, the shift register keeping the last 4), then a continue.
        n0 = (pmod.n_eb + pmod.n_edh);
        fetch(32'h2000_0702); fetch(32'h2000_0706); fetch(32'h2000_0782); fetch(32'h2000_0786);
        cmds_since("halfword opens", 2, 4);

        // Reset with a stream open (the pins are released and the start-up
        // sequence runs again), and at every clock of a continuing read.
        for (rk = 0; rk < 14; rk = rk + 1) begin
            fetch(32'h2000_0500); fetch(32'h2000_0504);                     // the stream is open
            reset_in_fetch(32'h2000_0508, rk);                              // continue, cut at clock rk
            fetch(32'h2000_0508); fetch(32'h2000_050C);
        end
        for (rk = 0; rk < 14; rk = rk + 1) begin
            fetch(32'h2000_0500);
            reset_in_fetch(32'h2000_0502, rk);                              // top-up, cut at clock rk
            fetch(32'h2000_0504);
        end

        if ($test$plusargs("MODESW")) mode_switch_suite;

        // A store to flash. Flash 0x100 reads 0; PSRAM A 0x100, the same chip
        // address, holds the word stored above.
        flash_wr = 1;
        store(32'h2000_0100, 4'b1111, 32'hDEAD_BEEF);
        flash_wr = 0;
        check("flash store: flash", 32'h2000_0100, mem_word(32'h2000_0100), 32'h0);
        check("flash store: PSRAM", 32'h8000_0100, mem_word(32'h8000_0100), 32'h1122_3344);
        load(32'h2000_0000);        // the flash still answers reads

        // A load and a fetch raised on the same cycle: data first.
        @(negedge clk);
        i_req = 1; i_addr = 32'h8000_0100;
        d_req = 1; d_we = 0; d_addr = 32'h8000_0104; d_be = 4'b1111;
        t_d = 0; t_i = 0;
        while (!t_d || !t_i) begin
            @(posedge clk);
            if (d_ready && !t_d) begin
                t_d = $time; check("load+", 32'h8000_0104, d_rdata, mem_word(32'h8000_0104));
                @(negedge clk); d_req = 0;
            end
            if (i_ready && !t_i) begin
                t_i = $time; check("fetch+", 32'h8000_0100, i_rdata, mem_word(32'h8000_0100));
                @(negedge clk); i_req = 0;
            end
        end
        if (t_d > t_i) begin
            $display("FAIL arbitration: fetch served at %0t before load at %0t", t_i, t_d);
            errors = errors + 1;
        end

        errors = errors + pins.errs;
        if (errors == 0) $display("PASS tb_qspi (QSPI_DELAY=%0d ns, rd_late=%0d, ddr=%0d cap=%0d)", pmod.delay_ns, rd_late, ddr_v, cap_v);
        else             $display("FAIL tb_qspi: %0d errors", errors);
        $finish;
    end

    initial begin
        #8000000;
        $display("TIMEOUT tb_qspi");
        $finish;
    end

endmodule
