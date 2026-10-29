// Fetch integrity of fyracore with word reuse (WO-27), proved by k-induction
// (tb/formal/run.sh core_fetch) against a symbolic code memory.
//
// The code memory is a constant but arbitrary table of 16 halfwords,
// h(a) = tab[a[4:1]], and the instruction port answers every request from it:
// imem_rdata = {h(imem_addr + 2), h(imem_addr)}. Everything else is free
// (imem_ready, dmem_ready, dmem_rdata, the interrupts, boot_addr, the
// register file). Stores never change the table: this is the no-self-modifying
// code case, which is the only one in which the kept halfword must equal the
// memory (fr_smc pins the other).
//
// run.sh instruments a copy of fyracore.v with the observation ports f_* (a
// formal tool reads no hierarchical names), so these are internal signals:
//   F1  on every cycle IF/EX loads (f_load) from an executable pc, the
//       halfword it takes is h(pc), and for a 32-bit instruction its upper
//       halfword is h(pc + 2): what is in hand is what the memory holds at pc
//       whether it came from the fetch or from the kept halfword
//   F2  lemma: if_kv implies if_kbuf == h(pc) (the kept halfword is the one at
//       pc; this is what makes F1 inductive)
//   F3  lemma: if_kv implies imem_req is low (no fetch with the instruction
//       in hand)
module core_fetch_props (
    input  wire        clk, rst_in,
    input  wire [31:0] boot_addr,
    input  wire [255:0] tab,
    input  wire        imem_ready, dmem_ready,
    input  wire [31:0] dmem_rdata,
    input  wire        timer_irq, external_irq, sw_irq,
    input  wire [63:0] mtime_in
);
    wire rst = rst_in;
    wire [31:0] imem_addr, dmem_addr, dmem_wdata, dbg_pc, dbg_instr;
    wire [3:0]  dmem_be;
    wire        imem_req, dmem_req, dmem_we, fencei_flush, dbg_retired, dbg_compressed, dbg_trap;
    wire [31:0] f_pc, f_fetched;
    wire [15:0] f_kbuf;
    wire        f_kv, f_exec, f_load;

    function [15:0] h(input [31:0] a);
        h = tab[16*a[4:1] +: 16];
    endfunction
    wire [31:0] imem_rdata = {h(imem_addr + 32'd2), h(imem_addr)};

    fyracore dut (.clk(clk), .rst(rst), .boot_addr(boot_addr),
        .imem_addr(imem_addr), .imem_req(imem_req), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
        .dmem_req(dmem_req), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
        .dmem_we(dmem_we), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
        .timer_irq(timer_irq), .external_irq(external_irq), .sw_irq(sw_irq), .mtime_in(mtime_in),
        .fencei_flush(fencei_flush), .dbg_pc(dbg_pc), .dbg_retired(dbg_retired),
        .dbg_instr(dbg_instr), .dbg_compressed(dbg_compressed), .dbg_trap(dbg_trap),
        .f_pc(f_pc), .f_kv(f_kv), .f_kbuf(f_kbuf), .f_exec(f_exec), .f_fetched(f_fetched),
        .f_load(f_load));

    reg armed = 1'b0;               // a reset has been applied
    always @(posedge clk) if (rst) armed <= 1'b1;
    wire chk = armed && !rst;

    // the table does not change (checked from the second cycle on)
    reg [255:0] tab_q = 256'd0;
    reg         tab_ok = 1'b0;
    always @(posedge clk) begin tab_q <= tab; tab_ok <= 1'b1; end

    always @(*) begin
        assume (!tab_ok || tab == tab_q);
        if (chk) begin
            assert (!f_kv || f_kbuf == h(f_pc));                                  // F2
            assert (!f_kv || !imem_req);                                          // F3
            if (f_load && f_exec) begin
                assert (f_fetched[15:0] == h(f_pc));                              // F1
                assert (f_fetched[1:0] != 2'b11 || f_fetched[31:16] == h(f_pc + 32'd2));
            end
        end
    end
endmodule
