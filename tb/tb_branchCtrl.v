module tb_branchCtrl(bCtrl_tb, r1_tb, r2_tb, bSel_tb);
  output reg [2:0] bCtrl_tb;
  output reg [31:0] r1_tb;
  output reg [31:0] r2_tb;
  input wire [0:0] bSel_tb;
  
  branchCtrl dut (.bCtrl(bCtrl_tb),
                  .r1(r1_tb),
                  .r2(r2_tb), 
                  .bSel(bSel_tb)
                 );
  
  initial begin
    $dumpfile("branchCtrl.vcd");
    $dumpvars(0, tb_branchCtrl);
    bCtrl_tb = 3'b000;
    r1_tb = 32'hF0000000;
    r2_tb = 32'hF0000000;
    #1 bCtrl_tb = 3'b001;
    #1 bCtrl_tb = 3'b010;
    #1 r2_tb = 32'hF0000001;
    #1 bCtrl_tb = 3'b011;
    #1 bCtrl_tb = 3'b111;
    #1 bCtrl_tb = 3'b100;
    #1 r2_tb = 32'hFFFFFFFF;
    #1 bCtrl_tb = 3'b101;
    #1 $finish;
    end
endmodule
