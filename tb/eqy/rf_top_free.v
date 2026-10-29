// Stand-in for src/rf_top.v in the RTL lemma (tb/eqy/run.sh, stage lemma):
// yosys's SAT engine reads neither the real model (it calls $test$plusargs)
// nor an empty blackbox. The read data are undriven wires, which the lemma's
// `setundef -undriven -expose` turns into free inputs, so the lemma holds for
// every register-file content. Unlike tb/formal/rf_top_stub.v it asserts
// nothing: only the constant-bit lemmas are being asked here.
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
endmodule
