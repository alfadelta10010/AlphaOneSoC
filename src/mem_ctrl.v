// Memory controller: joins the core's instruction port and the memory half of
// its data port onto the one QSPI engine (qspi_ctrl).
//
// Both ports follow the core's request/ready contract (src/fyracore.v): a
// request is held, address and data unchanged, until the cycle ready is
// returned with it. The QSPI engine reads its transaction parameters
// combinationally for the whole transaction, so they are derived here from
// the held request and two bits of state, and nothing is copied.
//
// Arbitration: data first. The pipeline only issues a new data request on a
// cycle a fetch completes, so the fetch port cannot be starved; and serving
// the data request first means the fetch that follows a load is not read
// before the load and then thrown away while the load stalls the pipeline.
// The grant is still latched rather than inferred from which request is
// high, so a request that appears mid-transaction cannot redirect its reply.
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
//           costs nothing extra. The one case that needs care is a fetch
//           whose 4 bytes run off the end of PSRAM A into PSRAM B
//           (pc = 0x807F_FFFE): it is split into two 2-byte reads, one per
//           chip. qspi_ctrl's read register carries over between them, so
//           the split needs no storage of its own. (The same test also fires
//           at 0x80FF_FFFE, the top of B, where the upper half is past the
//           window and the core faults it whatever is returned.)
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

    // A fetch that crosses from one PSRAM chip into the next.
    wire split = i_addr[31] && (&i_addr[22:1]);

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
    // transaction runs, the one about to be granted while idle.
    wire use_d = q_idle ? pick_d : gnt_d;

    wire [31:0] a = use_d ? d_addr : i_addr;

    // Chip select and chip address. The second half of a split fetch starts
    // at byte 0 of the other chip.
    wire psram  = a[31];
    wire chip_b = second ? !i_addr[23] : a[23];
    assign q_cs = !psram ? 2'd0 : (chip_b ? 2'd2 : 2'd1);

    // Store: first enabled lane, and the number of enabled lanes.
    wire [1:0] st_lane  = d_be[0] ? 2'd0 : d_be[1] ? 2'd1 : d_be[2] ? 2'd2 : 2'd3;
    wire [1:0] st_n_m1  = {d_be[0] & d_be[3], (d_be[0] & d_be[1]) | (d_be[2] & d_be[3])};

    wire [23:0] chip_addr = {a[23] & !psram, a[22:0]};
    assign q_addr = second      ? 24'd0 :
                    !use_d      ? chip_addr :                        // fetch: the halfword
                    d_we        ? {chip_addr[23:2], st_lane} :       // store: first lane
                                  {chip_addr[23:2], 2'b00};          // load: the word
    assign q_we        = use_d && d_we;
    assign q_nbytes_m1 = (use_d && d_we) ? st_n_m1 :
                         (!use_d && (split || second)) ? 2'd1 : 2'd3;
    assign q_wdata     = d_wdata;

    assign i_rdata = q_rdata;
    assign d_rdata = q_rdata;
    assign i_ready = q_done && !gnt_d && (second || !split);
    assign d_ready = q_done && gnt_d;

endmodule
