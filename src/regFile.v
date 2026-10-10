// One write port, one read port. fyracore time-shares the read port between
// rs1 and rs2 (see rs2_phase there): a second 32:1 read mux of 32-bit words
// is most of a register file's logic, and the cycle it saves is spent
// waiting for the next instruction fetch anyway.
module regFile #(parameter DATA_WIDTH = 32) (
    input  wire                  clk,
    input  wire                  rst,   // unused: the registers are not reset
    input  wire                  wrEn,
    input  wire [4:0]            rs,
    input  wire [4:0]            rd,
    input  wire [DATA_WIDTH-1:0] dIn,
    output wire [DATA_WIDTH-1:0] r
);
    reg [DATA_WIDTH-1:0] reg_file [0:31];
    integer i;

    // No reset. x1-x31 are UNSPECIFIED after reset (Priv spec, "Reset":
    // only the privilege mode, mstatus.MIE/MPRV, pc, mcause and the PMP
    // A/L fields are defined), so resetting 992 flops bought nothing but a
    // mux in front of each. Boot code that relies on a register being 0
    // clears it itself; plugins/helpers/boot_flash.S zeroes x1-x31 first
    // thing.
    //
    // Simulation starts them at 0 anyway, the way Spike does, so programs
    // that bypass the boot stub (the directed tests start straight in PSRAM)
    // still trace-compare. +RF_X leaves them X instead: a read of a register
    // a program never wrote then puts an X in its trace (written to a
    // register, a CSR or memory, or used as an address), which run.sh fails.
    // An X that only decides a branch is not caught: the simulator takes the
    // not-taken arm, and when Spike (registers at 0) also falls through, the
    // traces agree.
`ifndef SYNTHESIS
    initial begin
        if (!$test$plusargs("RF_X"))
            for (i = 0; i < 32; i = i + 1)
                reg_file[i] = 0;
    end
`endif

    // Write on rising edge (x0 is hardwired to 0)
    always @(posedge clk) begin
        if (wrEn && rd != 5'b0)
            reg_file[rd] <= dIn;
    end

    // Combinational read (x0 always returns 0)
    assign r = (rs != 5'b0) ? reg_file[rs] : {DATA_WIDTH{1'b0}};
endmodule
