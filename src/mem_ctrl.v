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
// Arbitration: data first. The pipeline only issues a new data request on
// the cycle after a fetch completes, so the fetch port cannot be starved; and
// serving the data request first means the fetch that follows a load is not
// read before the load and then thrown away while the load stalls the
// pipeline (fetch-first would do that on every load, forever, on a pipeline
// that refetches while stalled). The grant is latched rather than inferred
// from which request is high, so a request that appears mid-transaction
// cannot redirect its reply.
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

    assign i_rdata = q_rdata;
    assign d_rdata = q_rdata;
    assign i_ready = q_done && !gnt_d && (second || !split);
    assign d_ready = q_done && gnt_d;

endmodule
