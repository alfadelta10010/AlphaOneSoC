// Memory-port hold rule of fyracore (CPU ref 5.1 Handshake), proved by
// k-induction (tb/formal/run.sh) for every input sequence with arbitrary
// register-file contents (rf_top_stub.v). Inputs are all free: "nothing
// transfers while *_req is low, whatever *_ready is" makes a free ready a
// legal environment, and boot_addr is any value.
//   H1 a fetch request not answered by imem_ready is still up on the next
//      cycle with the same imem_addr
//   H2 likewise for a data request: dmem_req, dmem_addr, dmem_we, dmem_be
//      (and dmem_wdata for a write) are unchanged
// plus the stub's assertion that x0 is never written (REQ-RF-003).
module core_hold_props (
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
    wire chk = armed && !rst;

    // previous cycle's request, valid only if the cycle was checked too
    reg         p_chk = 1'b0, p_ipend = 1'b0, p_dpend = 1'b0, p_we = 1'b0;
    reg  [31:0] p_iaddr = 32'd0, p_daddr = 32'd0, p_wdata = 32'd0;
    reg  [3:0]  p_be = 4'd0;
    always @(posedge clk) begin
        p_chk   <= chk;
        p_ipend <= imem_req && !imem_ready;
        p_dpend <= dmem_req && !dmem_ready;
        p_iaddr <= imem_addr;
        p_daddr <= dmem_addr;
        p_we    <= dmem_we;
        p_be    <= dmem_be;
        p_wdata <= dmem_wdata;
    end

    always @(*) begin
        if (chk && p_chk) begin
            if (p_ipend) begin
                assert (imem_req);                                  // H1
                assert (imem_addr == p_iaddr);
            end
            if (p_dpend) begin
                assert (dmem_req);                                  // H2
                assert (dmem_addr == p_daddr);
                assert (dmem_we == p_we);
                assert (dmem_be == p_be);
                if (p_we) assert (dmem_wdata == p_wdata);
            end
        end
    end
endmodule
