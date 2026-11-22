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
//     wait for 0xFE, 512 bytes + 2 CRC, data response 0x05, busy, store); CMD25 the same with 0xFC
//     before each block, the next block's address following, and 0xFD (stuff byte, busy) to end.
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
//   * card kinds: +SD_SDSC makes it a standard-capacity v2 card (OCR bit 30 = 0, so READ and
//     WRITE take a byte address, a multiple of 512; CMD16 sets the block length, which must
//     be 512), +SD_V1 a v1 card as well (CMD8 is an illegal command, R1 0x05). Default: SDHC.
//     CMD13 (SEND_STATUS) answers an R2 of 0x0000 (R1, then no error bits).
//   * faults, for the driver's error paths: +SD_RDERR=<blk> makes a read of that block answer with a data error
//     token (0x04, "ECC failed") instead of data; +SD_RDCRC=<blk> a wrong CRC16 after that block's data; +SD_WRRESP=<hex> the data response token of a write (0b CRC
//     error, 0d write error; 05 default) and the block is then not stored; +SD_STATUS=<hex> the second byte
//     of CMD13's R2; +SD_CMD8BAD an R7 that does not echo the check pattern; +SD_NO16 a CMD16 the card refuses.
//     +SD_BUSY=<n> (above) keeps ACMD41 returning idle for n tries.
//   * capacity: +SD_BLKS=<n> sets the card's size in blocks (default: DISK_BLKS with a disk, else unbounded);
//     CMD9 (SDHC/SDXC only) answers a CSD version 2 with C_SIZE = n / 1024 - 1, so 67108864 blocks is a 32 GB card;
//     a read or write at or beyond n is refused (R1 0x40, an error unless +SD_EXPECT). +SD_SPARSE: the blocks
//     from DISK_BLKS up to n are the formula image (above) with up to 16 written blocks remembered, so block
//     numbers up to 2^32 - 1 can be read and written without a disk that big.
//   * a real disk: with DISK_BLKS > 1 and `use_disk` set by the bench (tb_sw does it for
//     +SD_IMAGE=<byte-hex>), reads and writes go to the `disk` array, so a FAT image
//     can be mounted, written to and read back (+SD_DUMP in tb_sw writes it out).
//     DISK_BLKS = 1 (the default) keeps the formula image and the three-block write
//     store above; no other bench sets it.
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
    parameter real T_IH      = 5.0,
    parameter integer DISK_BLKS = 1
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
    real    sck_min_id_ns = 1.0e9, sck_min_dt_ns = 1.0e9;
    reg     ready = 1'b0;                   // out of idle (ACMD41 returned 0x00)

    integer sd_busy_n = 3, stuck = 0;
    reg     sdsc = 1'b0, v1 = 1'b0;         // +SD_SDSC, +SD_V1
    integer rderr_blk = -1;                 // +SD_RDERR
    integer rdcrc_blk = -1;                 // +SD_RDCRC
    reg [7:0] wr_resp = 8'h05, sd_status = 8'h00;   // +SD_WRRESP, +SD_STATUS
    reg     cmd8bad = 1'b0, no16 = 1'b0;    // +SD_CMD8BAD, +SD_NO16
    reg [31:0] cap_blks = 32'hFFFFFFFF, cap_tmp = 32'h0;   // +SD_BLKS
    reg     cap_set = 1'b0, sparse = 1'b0;           // +SD_BLKS given, +SD_SPARSE
    reg     wr_once = 1'b0;                 // +SD_WRONCE: +SD_WRRESP applies to the first write only
    reg [7:0] st_pend = 8'h00;              // status bits a refused write left, cleared by CMD13
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
        v1   = $test$plusargs("SD_V1");
        if ($value$plusargs("SD_RDERR=%d", rderr_blk)) ;
        if ($value$plusargs("SD_RDCRC=%d", rdcrc_blk)) ;
        if ($value$plusargs("SD_BLKS=%d", cap_tmp)) begin cap_blks = cap_tmp; cap_set = 1'b1; end
        sparse = $test$plusargs("SD_SPARSE");
        if ($value$plusargs("SD_WRRESP=%h", wr_resp)) ;
        if ($value$plusargs("SD_STATUS=%h", sd_status)) ;
        cmd8bad = $test$plusargs("SD_CMD8BAD");
        wr_once = $test$plusargs("SD_WRONCE");
        no16    = $test$plusargs("SD_NO16");
        sdsc = $test$plusargs("SD_SDSC") || v1;
        if ($value$plusargs("SD_SEED=%d", s)) rs = 32'h2545F491 ^ (s * 32'h9E3779B1);
        else rs = 32'h2545F491;
        if (rs == 0) rs = 1;
        stuck = $test$plusargs("SD_STUCK_DO");
    end

    initial begin : cap_check                // the bench sets use_disk at time 0
        #1;
        if (use_disk && cap_set && cap_blks > DISK_BLKS && !sparse) err("+SD_BLKS beyond the disk needs +SD_SPARSE");
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

    // A real disk, when the bench loads one
    reg        use_disk = 1'b0;
    reg [7:0]  disk [0:DISK_BLKS * 512 - 1];

    // Written blocks (up to 4): block number and data
    reg [31:0] wb_blk [0:15];
    reg [7:0]  wb_dat [0:8191];
    integer    wb_n = 0;
    wire [31:0] cap_now = cap_set ? cap_blks : (use_disk ? DISK_BLKS : 32'hFFFFFFFF);
    function on_disk(input [31:0] blk);      // this block is in the `disk` array
        on_disk = use_disk && (!sparse || blk < DISK_BLKS);
    endfunction
    function [7:0] blk_byte(input [31:0] blk, input integer i);
        integer s, f;
        begin
            f = -1;
            for (s = 0; s < wb_n; s = s + 1) if (wb_blk[s] == blk) f = s;
            blk_byte = on_disk(blk) ? disk[blk * 512 + i] : (f >= 0) ? wb_dat[f * 512 + i] : img(blk, i);
        end
    endfunction

    // ── TX queue ────────────────────────────────────────────────────────────
    reg [7:0] txq [0:4095];
    reg       txb [0:4095];                 // 1 = a busy byte
    integer   qh = 0, qt = 0, busy_cnt = 0;
    reg       stream = 1'b0;                // CMD18 running
    integer   oor_pos = -1;                 // queue position of the out-of-range token of a stream
    reg [31:0] stream_blk = 0;
    integer   st_last = 0;  // st_last: the index of the last CRC byte pushed
    integer   crc_end_pos [0:7];            // queue positions that end a read block
    integer   n_ce = 0;
    task push(input [7:0] b, input busy);
        begin txq[qt % 4096] = b; txb[qt % 4096] = busy; qt = qt + 1; if (busy) busy_cnt = busy_cnt + 1; end
    endtask
    task push_block(input [31:0] blk);
        integer i, g; reg [15:0] c;
        begin
            g = 1 + rn(16);
            for (i = 0; i < g; i = i + 1) push(8'hFF, 1'b0);
            if (rderr_blk >= 0 && blk == rderr_blk) begin       // +SD_RDERR: a data error token, no data; a stream stops
                push(8'h04, 1'b0); stream = 1'b0;
            end else begin
            push(8'hFE, 1'b0);
            c = 16'h0000;
            for (i = 0; i < 512; i = i + 1) begin push(blk_byte(blk, i), 1'b0); c = crc16_up(c, blk_byte(blk, i)); end
            if (rdcrc_blk >= 0 && blk == rdcrc_blk) c = c ^ 16'h0101;      // +SD_RDCRC: a wrong CRC16 on this block (a bit wrong in each byte)
            push(c[15:8], 1'b0); push(c[7:0], 1'b0);
            crc_end_pos[n_ce % 8] = qt - 1; n_ce = n_ce + 1;
            end
        end
    endtask
    task csd_push;                          // the 16 CSD bytes (v2) and their CRC16
        integer i; reg [15:0] c; reg [21:0] cs; reg [7:0] b [0:15];
        begin
            cs = (cap_now >> 10) - 1;
            b[0] = 8'h40; b[1] = 8'h0E; b[2] = 8'h00; b[3] = 8'h32; b[4] = 8'h5B; b[5] = 8'h59; b[6] = 8'h00;
            b[7] = {2'b00, cs[21:16]}; b[8] = cs[15:8]; b[9] = cs[7:0];
            b[10] = 8'h7F; b[11] = 8'h80; b[12] = 8'h0A; b[13] = 8'h40; b[14] = 8'h00; b[15] = 8'h01;
            c = 16'h0000;
            for (i = 0; i < 16; i = i + 1) begin push(b[i], 1'b0); c = crc16_up(c, b[i]); end
            push(c[15:8], 1'b0); push(c[7:0], 1'b0);
        end
    endtask
    reg [7:0] tx_cur = 8'hFF;
    integer   tb_idx = 7;
    integer   rd_done = 0;                  // read blocks fully clocked out
    integer   oi;
    task pop;
        begin
            if (qh == qt && stream) begin
                if ((use_disk || cap_set) && stream_blk >= cap_now) begin   // past the card: the out-of-range error token, an error only once clocked out
                    for (oi = 0; oi < 20; oi = oi + 1) push(8'hFF, 1'b0);     // more than the 7 bytes of a CMD12 frame: a host that stops at the last block never sees it
                    oor_pos = qt; push(8'h08, 1'b0); stream = 1'b0;
                end else begin push_block(stream_blk); stream_blk = stream_blk + 1; end
            end
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
                if (oor_pos == qh) begin err("CMD18 stream ran past the end of the card"); oor_pos = -1; end
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
    integer    nfr = 0, wcnt = 0, wbusy = 0;
    reg [31:0] wblk = 0;
    reg        wmulti = 1'b0;                // CMD25 running: blocks follow tokens 0xFC until 0xFD
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
                    if (v1) push(r1 | 8'h04, 1'b0);
                    else push(r1, 1'b0);
                    if (v1) ;
                    else if (crc_ok && arg[11:0] == 12'h1AA) begin push(8'h00, 1'b0); push(8'h00, 1'b0); push(8'h01, 1'b0); push(cmd8bad ? 8'hAB : 8'hAA, 1'b0); end
                    else r1 = r1 | 8'h04;
                end
                6'd55: begin app = 1'b1; push(r1, 1'b0); end
                6'd41: begin
                    if (!was_app) push(r1 | 8'h04, 1'b0);
                    else begin
                        acmd41_n = acmd41_n + 1;
                        // HCS (arg[30]): a v1 card is not told it (the host must send 0); an SDHC card
                        // never leaves idle for HCS = 0 (SD Physical Layer 7.2.1, 4.2.3.1)
                        if (v1 && arg[30]) err("ACMD41 with HCS set sent to a v1 card");
                        if (!sdsc && !arg[30]) push(8'h01, 1'b0);
                        else if (acmd41_n > sd_busy_n) begin idle_st = 1'b0; ready = 1'b1; push(8'h00, 1'b0); end
                        else push(8'h01, 1'b0);
                    end
                end
                6'd58: begin
                    push(r1, 1'b0);
                    push(ready ? (sdsc ? 8'h80 : 8'hC0) : 8'h80, 1'b0); push(8'hFF, 1'b0); push(8'h80, 1'b0); push(8'h00, 1'b0);
                end
                6'd9: begin             // SEND_CSD, a CSD version 2 (SDHC/SDXC only)
                    if (!ready || sdsc) push(r1 | 8'h04, 1'b0);
                    else begin
                        push(8'h00, 1'b0);
                        na = 1 + rn(8);
                        for (i = 0; i < na; i = i + 1) push(8'hFF, 1'b0);
                        push(8'hFE, 1'b0);
                        csd_push;
                    end
                end
                6'd13: begin
                    push(r1, 1'b0); push(sd_status | st_pend, 1'b0);
                    st_pend = 8'h00;                        // the error bits clear on read
                end
                6'd16: begin
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else if (arg != 32'd512 || no16) push(r1 | 8'h40, 1'b0);
                    else push(8'h00, 1'b0);
                end
                6'd17: begin
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else if (sdsc && arg[8:0] != 9'd0) begin err("CMD17 byte address not a multiple of 512"); push(8'h40, 1'b0); end
                    else if ((use_disk || cap_set) && (sdsc ? arg >> 9 : arg) >= cap_now) begin err("CMD17 beyond the disk"); push(8'h40, 1'b0); end
                    else if (rderr_blk >= 0 && (sdsc ? arg >> 9 : arg) == rderr_blk) begin
                        push(8'h00, 1'b0);
                        na = 1 + rn(8);
                        for (i = 0; i < na; i = i + 1) push(8'hFF, 1'b0);
                        push(8'h04, 1'b0);                      // a data error token, no data
                    end
                    else begin push(8'h00, 1'b0); push_block(sdsc ? arg >> 9 : arg); end
                end
                6'd18: begin
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else if (sdsc && arg[8:0] != 9'd0) begin err("CMD18 byte address not a multiple of 512"); push(8'h40, 1'b0); end
                    else if ((use_disk || cap_set) && (sdsc ? arg >> 9 : arg) >= cap_now) begin err("CMD18 beyond the disk"); push(8'h40, 1'b0); end
                    else begin push(8'h00, 1'b0); stream = 1'b1; stream_blk = sdsc ? arg >> 9 : arg; end
                end
                6'd12: begin
                    // abandon the stream; a stuff byte, R1b, busy
                    qh = qt; stream = 1'b0; oor_pos = -1;
                    push(8'h3C, 1'b0); push(8'h00, 1'b0);     // the stuff byte is not 0xFF, nor an R1: the host must discard it
                    na = 1 + rn(8);
                    for (i = 0; i < na; i = i + 1) push(8'h00, 1'b1);
                end
                6'd24: begin
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else if (sdsc && arg[8:0] != 9'd0) begin err("CMD24 byte address not a multiple of 512"); push(8'h40, 1'b0); end
                    else if ((use_disk || cap_set) && (sdsc ? arg >> 9 : arg) >= cap_now) begin err("CMD24 beyond the disk"); push(8'h40, 1'b0); end
                    else begin push(8'h00, 1'b0); rxs = W_TOKEN; wmulti = 1'b0; wblk = sdsc ? arg >> 9 : arg; end
                end
                6'd25: begin            // WRITE_MULTIPLE_BLOCK: tokens 0xFC, one block each, ended by the stop token 0xFD
                    if (!ready) push(r1 | 8'h04, 1'b0);
                    else if (sdsc && arg[8:0] != 9'd0) begin err("CMD25 byte address not a multiple of 512"); push(8'h40, 1'b0); end
                    else if ((use_disk || cap_set) && (sdsc ? arg >> 9 : arg) >= cap_now) begin err("CMD25 beyond the disk"); push(8'h40, 1'b0); end
                    else begin push(8'h00, 1'b0); rxs = W_TOKEN; wmulti = 1'b1; wblk = sdsc ? arg >> 9 : arg; end
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
                    if (b == (wmulti ? 8'hFC : 8'hFE)) begin
                        rxs = W_DATA; wcnt = 0;
                        if ((use_disk || cap_set) && wblk >= cap_now) err("write beyond the card (OUT_OF_RANGE)");
                    end
                    else if (wmulti && b == 8'hFD) begin     // stop tran: a stuff byte, then busy
                        push(8'hFF, 1'b0);
                        wbusy = 1 + rn(16);
                        for (i = 0; i < wbusy; i = i + 1) push(8'h00, 1'b1);
                        wmulti = 1'b0; rxs = RX_IDLE;
                    end
                    else if (b != 8'hFF) err(wmulti ? "write: not 0xFC, 0xFD or 0xFF while waiting for the token" : "write: not 0xFE or 0xFF while waiting for the token");
                end
                W_DATA: begin wbuf[wcnt] = b; wcnt = wcnt + 1; if (wcnt == 512) begin rxs = W_CRC; wcnt = 0; end end
                W_CRC: begin
                    wcnt = wcnt + 1;
                    if (wcnt == 2) begin
                        // the data response, busy, then store
                        push(wr_resp, 1'b0);
                        if (wr_resp != 8'h05) st_pend = st_pend | 8'h04;   // a refused write: the status keeps "error" (R2 byte 2, bit 2; SD spec 7.3.2.3)
                        wbusy = 1 + rn(16);
                        for (i = 0; i < wbusy; i = i + 1) push(8'h00, 1'b1);
                        begin : store
                            integer s, f;
                            if (wr_resp != 8'h05) ;                 // refused: nothing is stored
                            else if ((use_disk || cap_set) && wblk >= cap_now) ;   // beyond the card: nothing is stored
                            else if (on_disk(wblk)) for (s = 0; s < 512; s = s + 1) disk[wblk * 512 + s] = wbuf[s];
                            else begin                              // the written-block table: only blocks that are not on the disk
                                f = -1;
                                for (s = 0; s < wb_n; s = s + 1) if (wb_blk[s] == wblk) f = s;
                                if (f < 0 && wb_n == 16) err("written-block table full (16)");   // nothing is stored
                                else begin
                                    if (f < 0) begin f = wb_n; wb_n = wb_n + 1; wb_blk[f] = wblk; end
                                    for (s = 0; s < 512; s = s + 1) wb_dat[f * 512 + s] = wbuf[s];
                                end
                            end
                        end
                        n_wr_blk = n_wr_blk + 1;
                        if (wr_once) wr_resp = 8'h05;
                        if (wmulti) begin wblk = wblk + 1; rxs = W_TOKEN; end   // the next block, or the stop token
                        else rxs = RX_IDLE;
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
