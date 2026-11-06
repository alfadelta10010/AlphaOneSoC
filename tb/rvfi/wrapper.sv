// riscv-formal wrapper for fyracore (WO-37). Environment, in one place:
//
//  D1 PMA: full-RAM parameterisation (riscv-formal's ISA model has no access
//     faults). PMA stays with the directed suite, core_req and tb_rivercore.
//  D2 Assumed on every cycle after reset: M-mode with no PMP lock able to deny
//     a fetch, no MPRV-to-U data privilege, misa.C = 1. A DUT bug that enters
//     U-mode, sets L or clears misa.C spuriously is invisible here (waiver
//     W-RVFI-2); the directed suite, tb_pmp and the csr formal keep those.
//  D3 Memories: no state. Read data are free on EVERY cycle (ready or not);
//     ready is free, also with no request. A wait is bounded at FYRA_MAX_WAIT
//     cycles (1 under RISCV_FORMAL_FAIRNESS). No data-memory model (W-RVFI-3).
//  D5 Reset: rvfi_testbench drives reset == $initstate (one cycle).
//  D6 Interrupts and mtime are free. Under RISCV_FORMAL_FAIRNESS a WFI is
//     woken at once (all three sources raised while it waits).
//  D7 FYRA_IMEM_CHECK (imem_top.sv): fetch consistency, as rvfi_imem_check.

`ifndef FYRA_MAX_WAIT
`define FYRA_MAX_WAIT 2
`endif
`ifdef RISCV_FORMAL_FAIRNESS
`define FYRA_WAIT_LIMIT 1
`else
`define FYRA_WAIT_LIMIT `FYRA_MAX_WAIT
`endif

module rvfi_wrapper (
	input         clock,
	input         reset,
	`RVFI_OUTPUTS
);
	(* keep *) `rvformal_rand_reg [31:0] imem_rdata_f;
	(* keep *) `rvformal_rand_reg [31:0] dmem_rdata;
	(* keep *) `rvformal_rand_reg        imem_ready;
	(* keep *) `rvformal_rand_reg        dmem_ready;
	(* keep *) `rvformal_rand_reg        timer_irq;
	(* keep *) `rvformal_rand_reg        external_irq;
	(* keep *) `rvformal_rand_reg        sw_irq;
	(* keep *) `rvformal_rand_reg [63:0] mtime_in;
	(* keep *) `rvformal_rand_const_reg [31:0] boot_addr;

	(* keep *) wire [31:0] imem_addr;
	(* keep *) wire        imem_req;
	(* keep *) wire        dmem_req;
	(* keep *) wire [31:0] dmem_addr;
	(* keep *) wire [31:0] dmem_wdata;
	(* keep *) wire [3:0]  dmem_be;
	(* keep *) wire        dmem_we;
	(* keep *) wire        fencei_flush;
	(* keep *) wire [31:0] dbg_pc;
	(* keep *) wire        dbg_retired;
	(* keep *) wire [31:0] dbg_instr;
	(* keep *) wire        dbg_compressed;
	(* keep *) wire        dbg_trap;
	(* keep *) wire        fv_fetch_can_deny;
	(* keep *) wire        fv_data_priv_m;
	(* keep *) wire        fv_misa_c;
	(* keep *) wire        fv_wfi_active;
	(* keep *) wire        fv_wb_hit;

`ifdef FYRA_IMEM_CHECK
	// D7: a random halfword-aligned address and a random halfword. Any fetch
	// that covers the address returns the halfword; the retired instruction
	// must carry it.
	`rvformal_rand_const_reg [31:0] im_a_raw;
	`rvformal_rand_const_reg [15:0] im_d;
	wire [31:0] im_a = {im_a_raw[31:1], 1'b0};
	reg  [31:0] imem_rdata_o;
	always @* begin
		imem_rdata_o = imem_rdata_f;
		if (imem_req && imem_ready) begin
			if (imem_addr == im_a)      imem_rdata_o[15:0]  = im_d;
			if (imem_addr + 32'd2 == im_a) imem_rdata_o[31:16] = im_d;
		end
	end
	wire [31:0] imem_rdata = imem_rdata_o;
	always @* begin
		if (!reset) begin
			if (rvfi_valid && rvfi_pc_rdata == im_a)
				assert (rvfi_insn[15:0] == im_d);
			if (rvfi_valid && rvfi_insn[1:0] == 2'b11 && rvfi_pc_rdata + 32'd2 == im_a)
				assert (rvfi_insn[31:16] == im_d);
		end
	end
`else
	wire [31:0] imem_rdata = imem_rdata_f;
`endif

	fyracore #(
		.PMA_ROM_BASE (32'hFFFF_FFFF), .PMA_ROM_TOP (32'h0000_0000),
		.PMA_RAM_BASE (32'h0000_0000), .PMA_RAM_TOP (32'hFFFF_FFFF),
		.PMA_IO0_BASE (32'hFFFF_FFFF), .PMA_IO0_TOP (32'h0000_0000),
		.PMA_IO1_BASE (32'hFFFF_FFFF), .PMA_IO1_TOP (32'h0000_0000)
	) uut (
		.clk          (clock),
		.rst          (reset),
		.boot_addr    (boot_addr),
		.imem_addr    (imem_addr),
		.imem_req     (imem_req),
		.imem_rdata   (imem_rdata),
		.imem_ready   (imem_ready),
		.dmem_req     (dmem_req),
		.dmem_addr    (dmem_addr),
		.dmem_wdata   (dmem_wdata),
		.dmem_be      (dmem_be),
		.dmem_we      (dmem_we),
		.dmem_rdata   (dmem_rdata),
		.dmem_ready   (dmem_ready),
		.timer_irq    (timer_irq),
		.external_irq (external_irq),
		.sw_irq       (sw_irq),
		.mtime_in     (mtime_in),
		.fencei_flush (fencei_flush),
		.dbg_pc       (dbg_pc),
		.dbg_retired  (dbg_retired),
		.dbg_instr    (dbg_instr),
		.dbg_compressed(dbg_compressed),
		.dbg_trap     (dbg_trap),
		`RVFI_CONN,
		.fv_fetch_can_deny (fv_fetch_can_deny),
		.fv_data_priv_m    (fv_data_priv_m),
		.fv_misa_c         (fv_misa_c),
		.fv_wfi_active     (fv_wfi_active),
		.fv_wb_hit         (fv_wb_hit)
	);

	// D3: bounded waits. Consecutive cycles of req && !ready, per port.
	reg [3:0] iwait = 4'd0;
	reg [3:0] dwait = 4'd0;
	always @(posedge clock) begin
		iwait <= (reset || !imem_req || imem_ready) ? 4'd0 : iwait + 4'd1;
		dwait <= (reset || !dmem_req || dmem_ready) ? 4'd0 : dwait + 4'd1;
	end
	always @* begin
		if (iwait == `FYRA_WAIT_LIMIT) assume (imem_ready);
		if (dwait == `FYRA_WAIT_LIMIT) assume (dmem_ready);
	end

	// D2: the environment restriction
	always @* begin
		if (!reset) begin
			assume (!fv_fetch_can_deny);
			assume (fv_data_priv_m);
			assume (fv_misa_c);
		end
	end

`ifdef RISCV_FORMAL_FAIRNESS
	// D6: a WFI waits only for an mie-enabled source; raising all three wakes it
	always @* assume (!fv_wfi_active || (timer_irq && external_irq && sw_irq));
`endif

`ifdef FYRA_WRAPPER_COVERS
	// D9 covers on the formal taps (cover check only)
	reg load_waited = 1'b0;
	always @(posedge clock) begin
		if (reset || rvfi_valid) load_waited <= 1'b0;
		else if (dmem_req && !dmem_we && !dmem_ready) load_waited <= 1'b1;
	end
	always @* begin
		if (!reset) begin
			cover (rvfi_valid && load_waited && |rvfi_mem_rmask);
			cover (fv_wb_hit);
			cover (rvfi_valid && rvfi_mode == 2'b11);
		end
	end
`endif
endmodule
