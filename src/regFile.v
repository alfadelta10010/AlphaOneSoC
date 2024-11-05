module regFile #(parameter DATA_WIDTH = 32) (clk, wrEn, rs1, rs2, rd, r1, r2, rst, dIn);
  input wire clk, wrEn, rst;
  input wire [4:0] rs1, rs2, rd;
  input wire [DATA_WIDTH-1:0] dIn;
  output wire [DATA_WIDTH-1:0] r1, r2;
  reg [DATA_WIDTH-1:0] reg_file [0:31];
  integer i = 0;
  initial begin
    for (i = 0; i < 32; i = i + 1) 
      begin
        reg_file[i] = 0;
      end
  end
  always @(posedge clk or posedge rst) begin
    if (rst) begin
      reg_file[0] <= 0;
      reg_file[1] <= 0;  // substitute with other values
      reg_file[2] <= 0;  // substitute with other values
      reg_file[3] <= 0;  // substitute with other values
      reg_file[4] <= 0;
      reg_file[5] <= 0;
      reg_file[6] <= 0;
      reg_file[7] <= 0;
      reg_file[8] <= 0;
      reg_file[9] <= 0;
      reg_file[10] <= 0;
      reg_file[11] <= 0;
      reg_file[12] <= 0;
      reg_file[13] <= 0;
      reg_file[14] <= 0;
      reg_file[15] <= 0;
      reg_file[16] <= 0;
      reg_file[17] <= 0;
      reg_file[18] <= 0;
      reg_file[19] <= 0;
      reg_file[20] <= 0;
      reg_file[21] <= 0;
      reg_file[22] <= 0;
      reg_file[23] <= 0;
      reg_file[24] <= 0;
      reg_file[25] <= 0;
      reg_file[26] <= 0;
      reg_file[27] <= 0;
      reg_file[28] <= 0;
      reg_file[29] <= 0;
      reg_file[30] <= 0;
      reg_file[31] <= 0;
    end else begin
      reg_file[rd] <= (wrEn && rd != 0) ? dIn : reg_file[rd];
    end
  end
/*
  always @(posedge clk) 
    reg_file[rd] <= (wrEn && rd != 0) ? dIn : reg_file[rd];
*/
  // register file read logic (combinational)
  assign r1 = (rs1 != 0 ) ? reg_file[rs1] : 0;
  assign r2 = (rs2 != 0 ) ? reg_file[rs2] : 0;
endmodule
