// Checker for one side of a hold-until-done handshake, for testbenches.
//
// A request is taken on a cycle `take` is high. From the next cycle until
// the cycle `done` is high it is pending, and on every pending cycle `hold`
// must still be high and `payload` must still be what it was when the
// request was taken. A requester that withdraws or changes a request
// mid-wait loses or corrupts the transfer on a real bus, even where the
// responder happens to hide it. With DONE_NEEDS_REQ = 1, `done` with no
// request taken or pending -- a reply nobody asked for -- is an error too.
// Any violation prints an ERROR line and stops the run.
//
// Hooked up as:
//   the core's request/ready ports (src/fyracore.v)
//       take = hold = req, done = ready; payload = the address, plus we, be
//       and (for a write) wdata on the data port. DONE_NEEDS_REQ = 0: the
//       core ignores ready while req is low, and the bus fabric drives it
//       high then. tb/memory_model.v has the same check built in for the
//       core-level testbench.
//   qspi_ctrl's request, from mem_ctrl (src/qspi_ctrl.v)
//       take = idle && start, hold = start, done = done; payload = cs_sel,
//       addr, we, nbytes_m1 and (for a write) wdata, all of which qspi_ctrl
//       reads combinationally for the whole transaction. DONE_NEEDS_REQ = 1.

module req_hold_check #(
    parameter            W              = 32,
    parameter [8*24-1:0] NAME           = "request",
    parameter            DONE_NEEDS_REQ = 0
)(
    input  wire         clk,
    input  wire         rst,
    input  wire         take,
    input  wire         hold,
    input  wire         done,
    input  wire [W-1:0] payload
);
    reg         pend;
    reg [W-1:0] held;

    always @(posedge clk) begin
        if (rst)
            pend <= 1'b0;
        else begin
            if (pend && (!hold || payload !== held)) begin
                $display("ERROR: %0s changed before done (%h -> %h, hold %b, t=%0t)",
                         NAME, held, payload, hold, $time);
                $fatal(1);
            end
            if (DONE_NEEDS_REQ && done && !pend && !take) begin
                $display("ERROR: %0s done with no request (t=%0t)", NAME, $time);
                $fatal(1);
            end
            if (!pend)
                held <= payload;
            pend <= (pend || take) && !done;
        end
    end

endmodule
