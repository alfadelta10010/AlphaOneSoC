// Output pinmux, a feature overlay: every uo_out pin keeps its default function (dflt, assembled in
// alphaone_soc) until software selects another one; one flop per pin after the mux (F12). PINMUX word at
// 0x1002_0020 (carved out of the syscon window by soc_bus): pin i's code in bits [4i+2:4i], bit 4i+3 reads 0.
//   code 0 DEFAULT dflt[i]   1 GPIO gpio[i]   2 RTS# rts_n   3 AUDIO audio   4..7 PWM0..PWM3 pwm[code-4]
// Reset: codes 0 and uo = UO_RESET (0x39, the wrapper's in-reset value). Never stalls.
module pinmux #(parameter [7:0] UO_RESET = 8'h39) (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [31:0] wdata,
    output wire [31:0] rdata,
    input  wire [7:0]  dflt,
    input  wire [7:0]  gpio,
    input  wire        rts_n,
    input  wire        audio,
    input  wire [3:0]  pwm,
    output reg  [7:0]  uo
);
    reg [23:0] codes;                       // 3 bits per pin (bit 3 of each nibble is not stored)

    genvar i;
    generate for (i = 0; i < 8; i = i + 1) begin : g_rd
        assign rdata[4*i +: 4] = {1'b0, codes[3*i +: 3]};
    end endgenerate

    reg [7:0] mux;
    integer j;
    always @(*) begin
        for (j = 0; j < 8; j = j + 1) begin
            case (codes[3*j +: 3])
                3'd0:    mux[j] = dflt[j];
                3'd1:    mux[j] = gpio[j];
                3'd2:    mux[j] = rts_n;
                3'd3:    mux[j] = audio;
                default: mux[j] = pwm[codes[3*j +: 3] - 3'd4];
            endcase
        end
    end

    wire w = sel & we;
    integer k;
    always @(posedge clk) begin
        if (rst) begin
            codes <= 24'd0;
            uo    <= UO_RESET;
        end else begin
            for (k = 0; k < 8; k = k + 1)
                if (w && be[k/2]) codes[3*k +: 3] <= wdata[4*k +: 3];
            uo <= mux;
        end
    end
endmodule
