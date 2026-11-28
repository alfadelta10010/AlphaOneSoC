// Simulation model of the one SB_IO configuration fpga_top uses: PIN_TYPE 6'b1010_01 =
// tristate output (OUTPUT_ENABLE), plain input. Nothing else of the cell is modelled.
module SB_IO #(parameter [5:0] PIN_TYPE = 6'b0) (
    inout  wire PACKAGE_PIN,
    input  wire OUTPUT_ENABLE,
    input  wire D_OUT_0,
    output wire D_IN_0
);
    assign PACKAGE_PIN = OUTPUT_ENABLE ? D_OUT_0 : 1'bz;
    assign D_IN_0 = PACKAGE_PIN;
endmodule
