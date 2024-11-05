module tb_regFile();
  reg clk_tb, wrEn_tb, rst_tb;
  reg [4:0] rd_tb;
  reg [4:0] rs1_tb;
  reg [4:0] rs2_tb;
  reg [31:0] dIn_tb;
  wire [31:0] r1_tb;
  wire [31:0] r2_tb;
  
  regFile dut (.clk(clk_tb), 
               .wrEn(wrEn_tb), 
               .rd(rd_tb), 
               .rs1(rs1_tb), 
               .rs2(rs2_tb), 
               .r1(r1_tb),
               .r2(r2_tb),
               .dIn(dIn_tb),
               .rst(rst_tb)
              );
  
  always begin
    clk_tb = 0;
    #5;
    clk_tb = 1;
    #5;
  end
  
  initial begin
    $dumpfile("regFile.vcd");
    $dumpvars(0, tb_regFile);
    wrEn_tb = 1'b0;
    rst_tb = 1'b1;
    rs1_tb = 5'd8;
    rs2_tb = 5'd23;
    #1 rst_tb = 1'b0;
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd0; dIn_tb = 32'hFAFAFA00; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd1; dIn_tb = 32'hFAFAFA01; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd2; dIn_tb = 32'hFAFAFA02; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd3; dIn_tb = 32'hFAFAFA03; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd4; dIn_tb = 32'hFAFAFA04; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd5; dIn_tb = 32'hFAFAFA05; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd6; dIn_tb = 32'hFAFAFA06; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd7; dIn_tb = 32'hFAFAFA07; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd8; dIn_tb = 32'hFAFAFA08; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd9; dIn_tb = 32'hFAFAFA09; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd10; dIn_tb = 32'hFAFAFA0A; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd11; dIn_tb = 32'hFAFAFA0B; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd12; dIn_tb = 32'hFAFAFA0C; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd13; dIn_tb = 32'hFAFAFA0D; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd14; dIn_tb = 32'hFAFAFA0E; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd15; dIn_tb = 32'hFAFAFA0F; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd16; dIn_tb = 32'hFAFAFA10; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd17; dIn_tb = 32'hFAFAFA11; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd18; dIn_tb = 32'hFAFAFA12; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd19; dIn_tb = 32'hFAFAFA13; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd20; dIn_tb = 32'hFAFAFA14; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd21; dIn_tb = 32'hFAFAFA15; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd22; dIn_tb = 32'hFAFAFA16; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd23; dIn_tb = 32'hFAFAFA17; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd24; dIn_tb = 32'hFAFAFA18; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd25; dIn_tb = 32'hFAFAFA19; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd26; dIn_tb = 32'hFAFAFA1A; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd27; dIn_tb = 32'hFAFAFA1B; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd28; dIn_tb = 32'hFAFAFA1C; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd29; dIn_tb = 32'hFAFAFA1D; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd30; dIn_tb = 32'hFAFAFA1E; 
    @(posedge clk_tb);
    wrEn_tb = 1'b1; rd_tb = 5'd31; dIn_tb = 32'hFAFAFA1F; 
    @(posedge clk_tb);
    wrEn_tb = 1'b0;
    dIn_tb = 32'b0;
    rd_tb = 5'b0;
    #10;
    rs1_tb = 5'b00001;
    rs2_tb = 5'b00010;
    #10;
    rs1_tb = 5'b00011;
    rs2_tb = 5'b00100;
    #10;
    rs1_tb = 5'b00101;
    rs2_tb = 5'b00110;
    #10;
    rs1_tb = 5'b00111;
    rs2_tb = 5'b01000;
    #10;
    rs1_tb = 5'b01001;
    rs2_tb = 5'b01010;
    #10;
    rs1_tb = 5'b01011;
    rs2_tb = 5'b01100;
    #10;
    rs1_tb = 5'b01101;
    rs2_tb = 5'b01110;
    #10;
    rs1_tb = 5'b01111;
    rs2_tb = 5'b10000;
    #10;
    rs1_tb = 5'b10001;
    rs2_tb = 5'b10010;
    #10;
    rs1_tb = 5'b10011;
    rs2_tb = 5'b10100;
    #10;
    rs1_tb = 5'b10101;
    rs2_tb = 5'b10110;
    #10;
    rs1_tb = 5'b10111;
    rs2_tb = 5'b11000;
    #10;
    rs1_tb = 5'b11001;
    rs2_tb = 5'b11010;
    #10;
    rs1_tb = 5'b11011;
    rs2_tb = 5'b11100;
    #10;
    rs1_tb = 5'b11101;
    rs2_tb = 5'b11110;
    #10;
    rs1_tb = 5'b11111;
    rs2_tb = 5'b00000;
    #10;
    rst_tb = 1'b1;
    #1;
    rst_tb = 1'b0;
    #9;
    $finish;
  end
endmodule
