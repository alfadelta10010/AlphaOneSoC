// Memory controller: joins the core's instruction port and the memory half of
// its data port onto the one QSPI engine (qspi_ctrl).
//
// Both ports follow the core's request/ready contract (src/fyracore.v): a
// request is held, address and data unchanged, until the cycle ready is
// returned with it. The QSPI engine takes the chip and the direction with
// the start of a transaction and reads the rest combinationally from the
// cycle after, so the parameters are derived here from the held request and
// two bits of state, and nothing is copied.
//
// Arbitration: data first. With the instruction cache off (CACHE_CTL.EN = 0, the reset
// state) the i-port is the core's fetch port and the pipeline only issues a new data
// request on the cycle after a fetch completes or after a fetch-word-reuse hit (an
// instruction taken from the kept halfword with no fetch). At most every other
// IF/EX load is a hit, so few data accesses run between consecutive fetches (up to
// four: two back-to-back AMOs, a read and a write each, behind fetches that already
// completed; bounded by tb/formal core_df) and a fetch waits a bounded time (449/482
// clocks at most with streaming, 442/456 without; rd_late 0/1, measured by
// simulation, not proved). That statement, M-A4 and P_LI in tb/formal/mem_props.sv are
// EN = 0 statements. Serving the data request first means the fetch that follows a
// load is not read before the load and then thrown away while the load stalls the
// pipeline (fetch-first would do that on every load, forever, on a pipeline that
// refetches while stalled). The grant is latched rather than inferred from which
// request is high, so a request that appears mid-transaction cannot redirect its
// reply.
//
// With the cache on (EN = 1, src/cache.v) the i-port requester is the cache: one
// aligned 4-byte word per request (never split: a word address has pc[1] = 0), four
// words per line fill, one fill at a time. Two things differ from EN = 0:
//   * A fill word can be starved. The core runs from cache hits and keeps issuing
//     data requests, which win the arbitration, so the word may wait behind any
//     number of them. That is not a deadlock: the core is not waiting for that
//     fill, and as soon as it misses it stalls, its data traffic stops (core_df
//     still bounds it) and the fill drains.
//   * A data request can wait behind one fill word (the transaction in flight when
//     it appears; data first applies from the next grant on). That is one memory
//     transaction, shorter than the split fetch behind which ML1's 182/183 is
//     already measured, so ML1 (which assumes nothing about the i-port beyond
//     M-A1/M-A2) is unchanged.
//   The wait the core sees on a fetch miss, derived from the RTL (not proved): at
//   most DF_N = 4 data transactions between its fetch handshakes (core_df, it
//   issues no more once stalled), plus up to 3 words left in the fill that was
//   running when it missed (a fill's first word has arrived before the core can
//   miss elsewhere), plus up to 4 words of its own fill, plus 3 clocks (hit
//   latency after the word is written), each transaction at most T clocks (PSRAM
//   word 42/43 for rd_late 0/1: the 40/41-clock CS run + start/done; flash
//   57/58, the CS0-low run, a streamed follow-up word is 18):
//     (4 + 3 + 4) * T + 3:  PSRAM code and data  11 * 43 + 3 = 476 clocks
//                           flash code, PSRAM data  4 * 43 + 7 * 58 + 3 = 581 clocks
//                           PSRAM code, flash data  4 * 58 + 7 * 43 + 3 = 536 clocks
//   A data transaction between two fill words breaks the flash stream, which is why
//   every word is priced at the full 58. With no data traffic a flash line fill
//   is about 57 + 3 * 18 = 111 clocks and a PSRAM fill 4 * 42 = 168.
//
// PSRAM line burst (i_burst -> q_burst): with the cache on, the four words of a line in PSRAM may
// share one chip select period (qspi_ctrl keeps CE# low after words 0-2 and continues with the next
// word if the next request is that word, at most one 16-byte line, so no page crossing). A data
// access or anything else closes it. i_burst low (cache off, the reset state) leaves every pin as
// without it. A burst word costs 8 SCK instead of 20 and the data port waits for at most one word
// as before (a data request closes the burst at the next grant).
//
// Requests are sampled only while qspi_ctrl is idle, and it is never idle on
// the cycle it reports done. That matters: on its ready cycle the core still
// shows the request being completed (a fetch's old pc, say), and starting a
// new transaction from it would read the stale address.
//
// Chips, by address. The PMA check in the core has already refused anything
// outside the two windows, so one bit tells them apart:
//
//   addr[31] = 0   flash, 0x2000_0000 + 16 MB   CS0, chip address addr[23:0]
//   addr[31] = 1   PSRAM, 0x8000_0000 + 16 MB   CS1 when addr[23] = 0 (A),
//                                               CS2 when addr[23] = 1 (B),
//                                               chip address addr[22:0]
//
// Transfers:
//
//   fetch   4 bytes from the halfword-aligned pc. A QSPI read streams from
//           any byte address, so a 32-bit instruction straddling a word
//           costs nothing extra -- within a PSRAM page. A PSRAM read may not
//           run on across a 1 KB page: parts with row-boundary crossing
//           (APS6404L-3SQR) allow it, but "compatible" parts without it wrap
//           to the start of the page, and the Pmod may carry either. So a
//           PSRAM fetch at the last halfword of a page (pc[9:1] all ones) is
//           split into two 2-byte reads, the second at the next page. That
//           also covers running off the end of PSRAM A into PSRAM B
//           (0x807F_FFFE), where the next page is on the other chip; at the
//           top of B (0x80FF_FFFE) the upper half is past the window and the
//           core faults it whatever is returned. qspi_ctrl's read register
//           carries over between the two reads, so the split needs no
//           storage of its own. Flash reads run on across any boundary.
//   load    always the whole aligned word, whatever the byte enables: a
//           memory read has no side effects, and a whole word needs no lane
//           steering because byte k of the transfer is lane k.
//   store   only the enabled bytes, from the first enabled lane. RISC-V
//           stores are naturally aligned, so the enables are contiguous; and
//           the core replicates store data across the lanes ({4{byte}},
//           {2{half}}), so the first byte to send is always in wdata[7:0]
//           and no shifter is needed.
//
// Flash is never written: the core's PMA check faults every store, AMO and
// SC aimed at it before the request exists.

module mem_ctrl (
    input  wire        clk,
    input  wire        rst,
    // Instruction port (from the core)
    input  wire        i_req,
    input  wire [31:0] i_addr,
    input  wire        i_burst,       // the request is a word of a cache line fill (src/cache.v m_burst); 0 with no cache
    output wire [31:0] i_rdata,
    output wire        i_ready,
    // Data port (from soc_bus, memory windows only)
    input  wire        d_req,
    input  wire [31:0] d_addr,
    input  wire [31:0] d_wdata,
    input  wire [3:0]  d_be,
    input  wire        d_we,
    output wire [31:0] d_rdata,
    output wire        d_ready,
    // To the QSPI engine
    output wire        q_start,
    output wire [1:0]  q_cs,
    output wire [23:0] q_addr,
    output wire        q_we,
    output wire [1:0]  q_nbytes_m1,
    output wire [31:0] q_wdata,
    output wire        q_burst,
    input  wire        q_idle,
    input  wire        q_done,
    input  wire [31:0] q_rdata
);

    // A PSRAM fetch that crosses a 1 KB page, and the page it runs into.
    // Carrying out of bit 22 is the step from PSRAM A to B.
    wire        split     = i_addr[31] && (&i_addr[9:1]);
    wire [13:0] next_page = i_addr[23:10] + 14'd1;

    reg gnt_d;     // the transaction in flight serves the data port
    reg second;    // the second half of a split fetch is next / in flight

    // Which port a transaction starting now would serve. A split fetch keeps
    // the engine until both halves are done.
    wire pick_d = d_req && !second;
    assign q_start = second || d_req || i_req;

    always @(posedge clk) begin
        if (rst) begin
            gnt_d  <= 1'b0;
            second <= 1'b0;
        end else begin
            if (q_idle && q_start)
                gnt_d <= pick_d;
            if (q_done && !gnt_d)
                second <= split && !second;
        end
    end

    // The port the engine is working for: the latched grant while a
    // transaction runs, the one about to be granted while idle. Only the
    // chip select and the direction follow it, because only they are taken
    // on the start cycle; address, byte count and data follow the latched
    // grant alone, which is the same port on every cycle the engine reads
    // them. With use_d on them too, the choice of port -- the core's data
    // request, which waits for an SC's reservation compare -- was in front
    // of the address nibbles on the pins, on a cycle nothing is driven.
    wire use_d = q_idle ? pick_d : gnt_d;

    wire [31:0] a = gnt_d ? d_addr : i_addr;

    // Chip select and chip address. The second half of a split fetch starts
    // at byte 0 of the next page.
    wire psram  = use_d ? d_addr[31] : i_addr[31];
    wire a23    = use_d ? d_addr[23] : i_addr[23];
    wire chip_b = second ? next_page[13] : a23;
    assign q_cs = !psram ? 2'd0 : (chip_b ? 2'd2 : 2'd1);

    // Store: first enabled lane, and the number of enabled lanes.
    wire [1:0] st_lane  = d_be[0] ? 2'd0 : d_be[1] ? 2'd1 : d_be[2] ? 2'd2 : 2'd3;
    wire [1:0] st_n_m1  = {d_be[0] & d_be[3], (d_be[0] & d_be[1]) | (d_be[2] & d_be[3])};

    wire [23:0] chip_addr = {a[23] & !a[31], a[22:0]};
    assign q_addr = second      ? {1'b0, next_page[12:0], 10'b0} :
                    !gnt_d      ? chip_addr :                        // fetch: the halfword
                    d_we        ? {chip_addr[23:2], st_lane} :       // store: first lane
                                  {chip_addr[23:2], 2'b00};          // load: the word
    assign q_we        = use_d && d_we;
    assign q_nbytes_m1 = (gnt_d && d_we) ? st_n_m1 :
                         (!gnt_d && (split || second)) ? 2'd1 : 2'd3;
    assign q_wdata     = d_wdata;
    // PSRAM line burst: only a fetch-port request (never the data port, never the second half of
    // a split fetch, which a cache fill word never is) may keep CE# low (qspi_ctrl "PSRAM line burst")
    assign q_burst     = i_burst && !use_d && !second;

    assign i_rdata = q_rdata;
    assign d_rdata = q_rdata;
    assign i_ready = q_done && !gnt_d && (second || !split);
    assign d_ready = q_done && gnt_d;

endmodule
