module tb_memController;
  reg [31:0] pcP, aluOut, r2, memDataIn;
  reg clk, memReady, aluReady, memClk, rst;
  reg [2:0] memCtrl, dataPosIn;
  wire [31:0] inst, dataR, memDataOut;
  wire [1:0] memType;
  wire [2:0] dataPosOut;
  wire dataSend;
  wire [23:0] spiAddrOut;
  wire [3:0] gpAddrOut;

  memController dut (
    .pcP(pcP), .aluOut(aluOut), .r2(r2),
    .clk(clk), .memReady(memReady), .aluReady(aluReady),
    .inst(inst), .dataR(dataR),
    .memCtrl(memCtrl), .memDataIn(memDataIn), .memDataOut(memDataOut),
    .memType(memType), .dataPosOut(dataPosOut),
    .dataPosIn(dataPosIn), .dataSend(dataSend),
    .spiAddrOut(spiAddrOut), .gpAddrOut(gpAddrOut),
    .memClk(memClk), .rst(rst)
  );
  
  always begin
    clk = 0;
    #10;
    clk = 1;
    #10;
  end
  
  always begin
    memClk = 0;
    #5;
    memClk = 1;
    #5;
  end

  initial begin
    $dumpfile("memController.vcd");
    $dumpvars(0, tb_memController);
    rst = 1'b1;
    #1 rst = 1'b0;
    // Initialize input signals
    #1;
    pcP = 32'h0000_0000;
    aluOut = 32'h0080_0000;
    r2 = 32'hA5A5_A5A5;
    memDataIn = 32'hF0F0_F0F0;
    memCtrl = 3'b000;
    dataPosIn = 3'b000;
    memReady = 0;
    aluReady = 0;
    #10;
    pcP = 32'h0000_0004; // Within IM range
    #10;
    
    // Load Byte
    memCtrl = 3'b000; // LB
    aluOut = 32'h0080_0004; // Within DM range
    aluReady = 1;
    #10 aluReady = 0; 
    #10;
    memReady = 1; 
    #10 memReady = 0; // Mimic memory ready signal

    // Load Halfword Unsigned
    memCtrl = 3'b100; // LHU
    aluOut = 32'h0080_0008;
    aluReady = 1;
    #10 aluReady = 0; 
    #10;
    memReady = 1; 
    #10 memReady = 0;

    // Load Word
    memCtrl = 3'b010; // LW
    aluOut = 32'h0080_000C;
    aluReady = 1;
    #10 aluReady = 0; #10;
    memReady = 1; #10 memReady = 0;

    // Store Byte
    memCtrl = 3'b101; // SB
    aluOut = 32'h0100_0000; // GPO range
    aluReady = 1;
    #10 aluReady = 0; #10;
    memReady = 1; #10 memReady = 0;

    // Store Word
    memCtrl = 3'b111; // SW
    aluOut = 32'h0080_000C;
    aluReady = 1;
    #10 aluReady = 0; #10;
    memReady = 1; #10 memReady = 0;
    
    // Finish simulation
    #20;
    $finish;
  end

endmodule
