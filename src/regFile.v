module regFile #(parameter DATA_WIDTH = 32) (
    input  wire                  clk,
    input  wire                  rst,
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

    initial begin
        for (i = 0; i < 32; i = i + 1)
            reg_file[i] = 0;
    end

    // Write on rising edge (x0 is hardwired to 0)
    always @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < 32; i = i + 1)
                reg_file[i] <= 0;
        end else if (wrEn && rd != 5'b0) begin
            reg_file[rd] <= dIn;
        end
    end

    // Combinational read (x0 always returns 0)
    assign r1 = (rs1 != 5'b0) ? reg_file[rs1] : {DATA_WIDTH{1'b0}};
    assign r2 = (rs2 != 5'b0) ? reg_file[rs2] : {DATA_WIDTH{1'b0}};
endmodule
