// Top for the custom fetch-consistency check (D7): rvfi_wrapper with
// FYRA_IMEM_CHECK defined, reset high only at the initial state, as in
// riscv-formal's rvfi_testbench. The asserts are in wrapper.sv.
module imem_top (
	input clock,
	input reset
);
	`RVFI_WIRES

	always_comb assume (reset == $initstate);

	rvfi_wrapper wrapper (
		.clock (clock),
		.reset (reset),
		`RVFI_CONN
	);
endmodule
