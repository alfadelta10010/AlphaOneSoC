module regFile #(parameter DATA_WIDTH = 32) (
    input  wire                  clk,
    input  wire                  rst,   // unused: the registers are not reset
    input  wire                  wrEn,
    input  wire [4:0]            rs1,
    input  wire [4:0]            rs2,
    input  wire [4:0]            rd,
    input  wire [DATA_WIDTH-1:0] dIn,
    output wire [DATA_WIDTH-1:0] r1,
    output wire [DATA_WIDTH-1:0] r2
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
    // still trace-compare. +RF_X leaves them X instead, which makes any read
    // of a register a program never wrote visible in its trace.
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
    assign r1 = (rs1 != 5'b0) ? reg_file[rs1] : {DATA_WIDTH{1'b0}};
    assign r2 = (rs2 != 5'b0) ? reg_file[rs2] : {DATA_WIDTH{1'b0}};
endmodule
