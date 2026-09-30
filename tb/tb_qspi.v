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
// Plusargs: +QSPI_DELAY=<ns> device + pad delay; +RD_LATE drives the
// controller's rd_late strap; and the model's +PSRAM_WRAP, +PSRAM_QPI,
// +FLASH_CRM, +FLASH_QPI (see tb/qspi_pmod_model.v). With rd_late = 0 the
// controller samples two clocks after the launching edge, so any delay below
// one SCK period (20 ns here) must pass; with rd_late = 1, three clocks.

`timescale 1ns / 1ps

module tb_qspi;
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

    qspi_ctrl qspi (
        .clk(clk), .rst(rst), .rd_late(rd_late),
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

    // mem_ctrl's side of the QSPI engine's request (tb/req_hold_check.v).
    req_hold_check #(.W(61), .NAME("QSPI transaction"), .DONE_NEEDS_REQ(1)) chk_qspi (
        .clk(clk), .rst(rst), .take(q_idle && q_start), .hold(q_start), .done(q_done),
        .payload({q_cs, q_addr, q_we, q_nbytes_m1, q_we ? q_wdata : 32'h0}));

    integer errors = 0;
    integer k;

    // Byte at a system address, straight from the model's arrays.
    function [7:0] mem_byte(input [31:0] a);
        if (a[31]) mem_byte = pmod.ram[a[23:0]];
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

    // Any chip select low while flash_wr is set is a failure.
    reg        flash_wr = 0;
    always @(posedge clk)
        if (flash_wr && ctl_oe && cs_n != 3'b111) begin
            $display("FAIL flash store selected a chip (cs_n=%b)", cs_n);
            errors   = errors + 1;
            flash_wr = 0;
        end

    initial begin
        for (k = 0; k < 256; k = k + 1) pmod.flash[k] = k ^ 8'h5A;
        repeat (3) @(posedge clk);
        rst = 0;

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

        if (errors == 0) $display("PASS tb_qspi (QSPI_DELAY=%0d ns, rd_late=%0d)", pmod.delay_ns, rd_late);
        else             $display("FAIL tb_qspi: %0d errors", errors);
        $finish;
    end

    initial begin
        #2000000;
        $display("TIMEOUT tb_qspi");
        $finish;
    end

endmodule
