// FPGA stand-in for the sky130 RF macro: 32x32, two sync read ports, one write.
// regFile's bypass supplies the written word on a collision, so plain RAM
// read-during-write behaviour is fine.
module rf_top (
    input  wire [31:0] w_data,
    input  wire [4:0]  w_addr,
    input  wire        w_ena,
    input  wire [4:0]  ra_addr,
    input  wire [4:0]  rb_addr,
    output reg  [31:0] ra_data,
    output reg  [31:0] rb_data,
    input  wire        clk
);
    reg [31:0] mem_a [0:31];
    reg [31:0] mem_b [0:31];
    always @(posedge clk) begin
        if (w_ena) begin
            mem_a[w_addr] <= w_data;
            mem_b[w_addr] <= w_data;
        end
        ra_data <= mem_a[ra_addr];
        rb_data <= mem_b[rb_addr];
    end
endmodule
