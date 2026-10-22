// Stand-in for src/rf_top.v in the formal harnesses. The real model calls
// $test$plusargs outside SYNTHESIS and is an empty blackbox under it, and
// yosys's SAT engine reads neither. The read data are undriven wires, which
// run.sh's `setundef -undriven -expose` turns into free inputs: the core is
// checked against every possible register-file content, not one a program
// produces.
//
// The one thing the register file itself promises is checked here: x0 is
// never written (regFile header; REQ-RF-003).
module rf_top (
    input  wire [31:0] w_data,
    input  wire [4:0]  w_addr,
    input  wire        w_ena,
    input  wire [4:0]  ra_addr,
    input  wire [4:0]  rb_addr,
    output wire [31:0] ra_data,
    output wire [31:0] rb_data,
    input  wire        clk
);
    wire [31:0] free_a, free_b;     // undriven: free inputs after setundef
    assign ra_data = free_a;
    assign rb_data = free_b;
    always @* if (w_ena) assert (w_addr != 5'd0);
endmodule
