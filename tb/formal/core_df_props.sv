// Data requests per fetch (WO-31 part D): discharges M-A4 of mem_props.sv. fyracore on
// its ports only (free instruction words, register-file data via rf_top_stub.v, free
// readies), all inputs as in core_req_props.sv. Counts data handshakes (dmem_req &&
// dmem_ready) since the last fetch handshake (imem_req && imem_ready) and asserts the
// count <= DF_N. BMC from reset finds counts of 3 and 4 (an AMO's read and write, then
// the next instruction's accesses, all behind fetches that completed earlier: two AMOs
// back to back give 4) and none of 5 within 32 steps, so DF_N is 4, not the 1 (docs)
// or 2 (mem_ctrl header) the documents claim: SPEC-AMBIGUITY, see WO-31 notes. Bounded
// from reset (BMC), not inductive without internal invariants.
// One assumption: the memory controller never completes a fetch and a data request in
// the same cycle (mem_ctrl: i_ready = q_done && !gnt_d, d_ready = q_done && gnt_d).
`ifndef DF_N
`define DF_N 4
`endif
module core_df_props (
    input  wire        clk, rst_in,
    input  wire [31:0] boot_addr,
    input  wire [31:0] imem_rdata, dmem_rdata,
    input  wire        imem_ready, dmem_ready,
    input  wire        timer_irq, external_irq, sw_irq,
    input  wire [63:0] mtime_in
);
    wire rst = rst_in;
    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dbg_pc, dbg_instr;
    wire [3:0]  dmem_be;
    wire        imem_req, dmem_req, dmem_we, fencei_flush, dbg_retired, dbg_compressed, dbg_trap;
    fyracore dut (.clk(clk), .rst(rst), .boot_addr(boot_addr),
        .imem_addr(imem_addr), .imem_req(imem_req), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
        .dmem_req(dmem_req), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_we(dmem_we), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
        .timer_irq(timer_irq), .external_irq(external_irq), .sw_irq(sw_irq), .mtime_in(mtime_in),
        .fencei_flush(fencei_flush), .dbg_pc(dbg_pc), .dbg_retired(dbg_retired),
        .dbg_instr(dbg_instr), .dbg_compressed(dbg_compressed), .dbg_trap(dbg_trap));

    reg armed = 1'b0;               // a reset has been applied
    always @(posedge clk) if (rst) armed <= 1'b1;
    wire f_hs = imem_req && imem_ready, d_hs = dmem_req && dmem_ready;
    reg [3:0] cnt = 4'd0;           // data handshakes since the last fetch handshake
    always @(posedge clk) begin
        if (rst || f_hs) cnt <= 4'd0; else if (d_hs && cnt != 4'd15) cnt <= cnt + 4'd1;
    end
    always @(*) begin
        assume (!(f_hs && d_hs));
        if (armed && !rst) assert (cnt <= `DF_N);
    end

`ifdef SBY_COVER
    reg amo_f = 1'b0;               // an AMO's data access since the last fetch handshake
    always @(posedge clk) if (rst || f_hs) amo_f <= 1'b0; else if (d_hs && dbg_instr[6:0] == 7'b0101111) amo_f <= 1'b1;
    always @(*) begin
        cover (armed && !rst && cnt == `DF_N);
        cover (armed && !rst && cnt == `DF_N && amo_f);
    end
`endif
endmodule
