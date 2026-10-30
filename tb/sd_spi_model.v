// Behavioural model of an SD card in SPI mode (WO-29 6.1), for the SoC and
// wrapper benches. Written from the SD Physical Layer Simplified Specification
// chapter 7 and WO-29, not from the RTL. SPI mode 3 on the pins (SCK idles
// high): the card samples DI on a rising SCK edge while CS# is low and changes
// DO on a falling edge; at the CS# fall it presents bit 7.
//
// What it does:
//   * power-up: >= 74 rising SCK edges with CS# high and DI high before the
//     first command; an SCK edge with CS# low earlier is an error;
//   * CMD0 (CRC 0x95) -> idle, R1 0x01; CMD8 0x1AA -> R7; CMD55 + ACMD41 ->
//     0x01 for +SD_BUSY=<n> tries (default 3) then 0x00; CMD58 -> OCR with bits
//     31 and 30; CMD17 (R1, N_AC 0xFF bytes, 0xFE, 512 data bytes, CRC16);
//     CMD18 streaming until CMD12 (stuff byte, R1b with busy); CMD24 (R1,
//     wait for 0xFE, 512 bytes + 2 CRC, data response 0x05, busy, store).
//     CRC7 is checked on CMD0 and CMD8 (a wrong one gives R1 bit 3); an unknown
//     command gives R1 bit 2. N_CR (0xFF bytes before R1) is 1-8 and N_AC 1-16,
//     seeded by +SD_SEED.
//   * the data image is a formula, not a hex file: byte i of block L is
//     ((i & 255) ^ (L * 0x35) ^ ((i >> 8) * 0xA5)) & 255, L = block & 15.
//     Every byte value occurs, so a stuck bus cannot match it.
//   * DO: from +T_OH to +T_ODLY after the falling edge the model drives the
//     COMPLEMENT of the new bit, then the new bit (T_ODLY_ID until the card is
//     ready, T_ODLY after). Never X: in the SoC an X can turn a failed compare
//     into a branch not taken, which is a false pass. DO is Z while CS# is high;
//     the bench puts a pull-up (tri1) on the card side.
//   * +SD_STUCK_DO makes DO read 1 whenever it would be driven (a negative
//     control).
//
// Checks (errors, or n_expected while `expect_violations`): an SCK edge with
// CS# low before the power-up clocks; an SCK period < 2.5 us before the card
// is ready or < 40 ns after; a level < 10 ns; DI setup/hold around a rising SCK
// less than T_ISU/T_IH; SCK not at the idle level (1) at a CS# edge; CS# rising
// off a byte boundary; a command while busy; a bad start or end bit.
//
// Races: a CS# edge and an SCK edge at the same timestamp are counted in
// n_race, never as an SCK edge; the comparison is on time stamps, not event
// order (every edge is processed 1 ps late, after a simultaneous edge landed).
`timescale 1ns / 1ps

module sd_spi_model #(
    parameter real T_ODLY_ID = 50.0,
    parameter real T_ODLY    = 14.0,
    parameter real T_OH      = 0.0,
    parameter real T_ISU     = 5.0,
    parameter real T_IH      = 5.0
)(
    input  wire fitted,
    input  wire cs_n,
    input  wire sck,
    input  wire di,
    input  wire expect_violations,
    output wire do_o
);
    // ── Counters the benches read ───────────────────────────────────────────
    integer errors = 0, n_expected = 0, n_cmd = 0, n_rd_blk = 0, n_wr_blk = 0, n_race = 0;
    integer n_crc16_ok = 0;
    real    sck_min_id_ns = 1.0e9, sck_min_dt_ns = 1.0e9;
    reg     ready = 1'b0;                   // out of idle (ACMD41 returned 0x00)

    integer sd_busy_n = 3, stuck = 0;
    reg [31:0] rs = 32'h1;
    function [31:0] rnd(input integer d);
        begin rs = rs ^ (rs << 13); rs = rs ^ (rs >> 17); rs = rs ^ (rs << 5); rnd = rs; end
    endfunction
    function integer rn(input integer n);
        reg [31:0] v; begin v = rnd(0); rn = v % n; end
    endfunction
    initial begin : plusargs
        integer s;
        if ($value$plusargs("SD_BUSY=%d", sd_busy_n)) ;
        if ($value$plusargs("SD_SEED=%d", s)) rs = 32'h2545F491 ^ (s * 32'h9E3779B1);
        else rs = 32'h2545F491;
        if (rs == 0) rs = 1;
        stuck = $test$plusargs("SD_STUCK_DO");
    end

    task automatic err(input [8*48-1:0] m);
        begin
            if (expect_violations) n_expected = n_expected + 1;
            else begin
                errors = errors + 1;
                if (errors <= 20) $display("ERROR SD: %0s (%0.1f ns)", m, $realtime);
            end
        end
    endtask

    // ── Data image and CRCs ─────────────────────────────────────────────────
    function [7:0] img(input integer blk, input integer i);
        reg [7:0] l;
        begin
            l = blk & 15;
            img = ((i & 255) ^ (l * 8'h35) ^ ((i >> 8) * 8'hA5)) & 8'hFF;
        end
    endfunction
    function [15:0] crc16_up(input [15:0] c, input [7:0] b);
        integer k; reg [15:0] r;
        begin
            r = c ^ {b, 8'h00};
            for (k = 0; k < 8; k = k + 1) r = r[15] ? ((r << 1) ^ 16'h1021) : (r << 1);
            crc16_up = r;
        end
    endfunction
    function [6:0] crc7_up(input [6:0] c, input [7:0] b);
        integer k; reg [6:0] r;
        begin
            r = c;
            for (k = 7; k >= 0; k = k - 1) r = ((r[6] ^ b[k]) ? ((r << 1) ^ 7'h09) : (r << 1));
            crc7_up = r;
        end
    endfunction

    // Written blocks (up to 4): block number and data
    integer    wb_blk [0:3];
    reg [7:0]  wb_dat [0:2047];
    integer    wb_n = 0;
    function [7:0] blk_byte(input integer blk, input integer i);
        integer s, f;
        begin
            f = -1;
            for (s = 0; s < wb_n; s = s + 1) if (wb_blk[s] == blk) f = s;
            blk_byte = (f >= 0) ? wb_dat[f * 512 + i] : img(blk, i);
        end
    endfunction

    // ── TX queue ────────────────────────────────────────────────────────────
    reg [7:0] txq [0:4095];
    reg       txb [0:4095];                 // 1 = a busy byte
    integer   qh = 0, qt = 0, busy_cnt = 0;
    reg       stream = 1'b0;                // CMD18 running
    integer   stream_blk = 0, st_last = 0;  // st_last: the index of the last CRC byte pushed
    integer   crc_end_pos [0:7];            // queue positions that end a read block
    integer   n_ce = 0;
    task push(input [7:0] b, input busy);
        begin txq[qt % 4096] = b; txb[qt % 4096] = busy; qt = qt + 1; if (busy) busy_cnt = busy_cnt + 1; end
    endtask
    task push_block(input integer blk);
        integer i, g; reg [15:0] c;
        begin
            g = 1 + rn(16);
            for (i = 0; i < g; i = i + 1) push(8'hFF, 1'b0);
            push(8'hFE, 1'b0);
            c = 16'h0000;
            for (i = 0; i < 512; i = i + 1) begin push(blk_byte(blk, i), 1'b0); c = crc16_up(c, blk_byte(blk, i)); end
            push(c[15:8], 1'b0); push(c[7:0], 1'b0);
            crc_end_pos[n_ce % 8] = qt - 1; n_ce = n_ce + 1;
        end
    endtask
    reg [7:0] tx_cur = 8'hFF;
    integer   tb_idx = 7;
    integer   rd_done = 0;                  // read blocks fully clocked out
    task pop;
        begin
            if (qh == qt && stream) begin push_block(stream_blk); stream_blk = stream_blk + 1; end
            if (qh == qt) tx_cur = 8'hFF;
            else begin
                tx_cur = txq[qh % 4096];
                if (txb[qh % 4096]) busy_cnt = busy_cnt - 1;
                begin : cnt
                    integer s;
                    for (s = 0; s < 8; s = s + 1) if (crc_end_pos[s] == qh && qh >= 0) begin
                        n_rd_blk = n_rd_blk + 1; crc_end_pos[s] = -1;
                    end
                end
                qh = qh + 1;
            end
            tb_idx = 7;
        end
    endtask
    integer ci;
    initial for (ci = 0; ci < 8; ci = ci + 1) crc_end_pos[ci] = -1;

    // ── DO ──────────────────────────────────────────────────────────────────
    reg do_val = 1'b1;
    assign do_o = (fitted && !cs_n) ? (stuck ? 1'b1 : do_val) : 1'bz;
    task present_next;
        reg b; real od;
        begin
            b = tx_cur[tb_idx];
            if (tb_idx > 0) tb_idx = tb_idx - 1;
            od = ready ? T_ODLY : T_ODLY_ID;
            do_val <= #(T_OH) ~b;
            do_val <= #(od) b;
        end
    endtask

    // ── Command / data receive state ────────────────────────────────────────
    localparam [2:0] RX_IDLE = 0, RX_ARG = 1, W_TOKEN = 2, W_DATA = 3, W_CRC = 4;
    reg [2:0]  rxs = RX_IDLE;
    reg [7:0]  fr [0:5];
    integer    nfr = 0, wcnt = 0, wblk = 0, wbusy = 0;
    reg        idle_st = 1'b0, app = 1'b0, pwr = 1'b0;
    integer    acmd41_n = 0, pu_cnt = 0;
    reg [7:0]  wbuf [0:511];
    reg [15:0] wcrc;

    task exec_cmd;
        reg [5:0] c; reg [31:0] arg; reg [6:0] k7; reg [7:0] r1; integer i, ncr, na, tmp; reg crc_ok; reg was_app;
        begin
            c = fr[0][5:0]; arg = {fr[1], fr[2], fr[3], fr[4]};
            n_cmd = n_cmd + 1;
            k7 = 7'h00;
            for (i = 0; i < 5; i = i + 1) k7 = crc7_up(k7, fr[i]);
            crc_ok = (k7 == fr[5][7:1]);
            was_app = app; app = 1'b0;
            ncr = 1 + rn(8);
            if (busy_cnt > 0) err("command while busy");
            for (i = 0; i < ncr; i = i + 1) push(8'hFF, 1'b0);
            r1 = idle_st ? 8'h01 : 8'h00;
            if ((c == 0 || c == 8) && !crc_ok) r1 = r1 | 8'h08;
            if (stream && c != 12) begin stream = 1'b0; end
            case (c)
                6'd0:  begin if (crc_ok) begin idle_st = 1'b1; ready = 1'b0; acmd41_n = 0; r1 = 8'h01; end push(r1, 1'b0); end
                6'd8:  begin
                    push(r1, 1'b0);
                    if (crc_ok && arg[11:0] == 12'h1AA) begin push(8'h00, 1'b0); push(8'h00, 1'b0); push(8'h01, 1'b0); push(8'hAA, 1'b0); end
                    else r1 = r1 | 8'h04;
                end
                6'd55: begin app = 1'b1; push(r1, 1'b0); end
                6'd41: begin
                    if (!was_app) push(r1 | 8'h04, 1'b0);
                    else begin
                        acmd41_n = acmd41_n + 1;
                        if (acmd41_n > sd_busy_n) begin idle_st = 1'b0; ready = 1'b1; push(8'h00, 1'b0); end
                        else push(8'h01, 1'b0);
                    end
                end
                6'd58: begin
                    push(r1, 1'b0);
                    push(ready ? 8'hC0 : 8'h80, 1'b0); push(8'hFF, 1'b0); push(8'h80, 1'b0); push(8'h00, 1'b0);
                end
                6'd17: begin
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else begin push(8'h00, 1'b0); push_block(arg); end
                end
                6'd18: begin
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else begin push(8'h00, 1'b0); stream = 1'b1; stream_blk = arg; end
                end
                6'd12: begin
                    // abandon the stream; a stuff byte, R1b, busy
                    qh = qt; stream = 1'b0;
                    push(8'hFF, 1'b0); push(8'h00, 1'b0);
                    na = 1 + rn(8);
                    for (i = 0; i < na; i = i + 1) push(8'h00, 1'b1);
                end
                6'd24: begin
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else begin push(8'h00, 1'b0); rxs = W_TOKEN; wblk = arg; end
                end
                default: push(r1 | 8'h04, 1'b0);
            endcase
        end
    endtask

    task on_rx_byte(input [7:0] b);
        integer i;
        begin
            case (rxs)
                RX_IDLE: begin
                    if (b[7:6] == 2'b01) begin fr[0] = b; nfr = 1; rxs = RX_ARG; end
                    else if (b != 8'hFF) err("bad start byte");
                end
                RX_ARG: begin
                    fr[nfr] = b; nfr = nfr + 1;
                    if (nfr == 6) begin
                        if (fr[5][0] !== 1'b1) err("command end bit not 1");
                        rxs = RX_IDLE;
                        exec_cmd;
                    end
                end
                W_TOKEN: begin
                    if (b == 8'hFE) begin rxs = W_DATA; wcnt = 0; end
                    else if (b != 8'hFF) err("write: not 0xFE or 0xFF while waiting for the token");
                end
                W_DATA: begin wbuf[wcnt] = b; wcnt = wcnt + 1; if (wcnt == 512) begin rxs = W_CRC; wcnt = 0; end end
                W_CRC: begin
                    wcnt = wcnt + 1;
                    if (wcnt == 2) begin
                        // the data response, busy, then store
                        push(8'h05, 1'b0);
                        wbusy = 1 + rn(16);
                        for (i = 0; i < wbusy; i = i + 1) push(8'h00, 1'b1);
                        begin : store
                            integer s, f;
                            f = -1;
                            for (s = 0; s < wb_n; s = s + 1) if (wb_blk[s] == wblk) f = s;
                            if (f < 0) begin f = wb_n; if (wb_n < 3) wb_n = wb_n + 1; wb_blk[f] = wblk; end
                            for (s = 0; s < 512; s = s + 1) wb_dat[f * 512 + s] = wbuf[s];
                        end
                        n_wr_blk = n_wr_blk + 1;
                        rxs = RX_IDLE;
                    end
                end
            endcase
        end
    endtask

    // ── Pins: every edge is processed 1 ps late ─────────────────────────────
    real    t_sck_ev = -1.0, t_cs_ev = -1.0, t_di = -1.0e9, t_rise = -1.0e9, t_fall = -1.0e9;
    integer bcnt = 0;
    reg [7:0] rx_sh = 8'h00;

    always @(di) t_di = $realtime;
    always @(di) if (fitted && !cs_n && ($realtime - t_rise) < T_IH && t_rise > 0.0) err("DI hold violated");

    always @(sck) if (fitted) begin : sck_ev
        real tnow, dt, tdi; reg is_rise, di_s;
        tnow = $realtime; is_rise = (sck === 1'b1); di_s = di; tdi = t_di;
        t_sck_ev = tnow;
        #0.001;
        if (t_cs_ev == tnow) begin
            // a CS# edge at the same timestamp: counted by the CS# side, not an SCK edge
        end else if (cs_n === 1'b1) begin
            if (is_rise) begin
                if (di_s === 1'b1) pu_cnt = pu_cnt + 1;
                t_rise = tnow;
            end else t_fall = tnow;
        end else if (!pwr && !(pu_cnt >= 74)) begin
            err("SCK edge with CS# low before 74 power-up clocks");
            if (is_rise) t_rise = tnow; else t_fall = tnow;
        end else begin
            pwr = 1'b1;
            if (is_rise) begin
                dt = tnow - t_rise;
                if (t_rise > 0.0 && dt < (ready ? 40.0 : 2500.0) && dt < 1.0e8) err("SCK period too short");
                if (t_rise > 0.0 && dt < 1.0e8) begin
                    if (ready) begin if (dt < sck_min_dt_ns) sck_min_dt_ns = dt; end
                    else       begin if (dt < sck_min_id_ns) sck_min_id_ns = dt; end
                end
                if (t_fall > 0.0 && (tnow - t_fall) < 10.0) err("SCK low time < 10 ns");
                if ((tnow - tdi) < T_ISU) err("DI setup violated");
                t_rise = tnow;
                rx_sh = {rx_sh[6:0], di_s}; bcnt = bcnt + 1;
                if (bcnt == 8) begin
                    bcnt = 0;
                    on_rx_byte(rx_sh);
                    pop;
                end
            end else begin
                if (t_rise > 0.0 && (tnow - t_rise) < 10.0) err("SCK high time < 10 ns");
                t_fall = tnow;
                present_next;
            end
        end
    end

    always @(cs_n) if (fitted) begin : cs_ev
        real tnow; reg fell;
        tnow = $realtime; fell = (cs_n === 1'b0);
        t_cs_ev = tnow;
        #0.001;
        if (t_sck_ev == tnow) n_race = n_race + 1;
        else if (sck !== 1'b1) err("SCK not at the idle level at a CS# edge");
        if (fell) begin
            bcnt = 0; rxs = (rxs == W_TOKEN || rxs == W_DATA || rxs == W_CRC) ? rxs : RX_IDLE;
            pop;
            present_next;
        end else begin
            if (bcnt != 0) err("CS# rose off a byte boundary");
            bcnt = 0;
        end
    end
endmodule
