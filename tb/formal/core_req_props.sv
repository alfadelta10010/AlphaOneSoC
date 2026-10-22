// Legality of every memory request fyracore can make, checked boundedly
// from reset (tb/formal/run.sh, BMC depth 10): not k-inductive, because the
// outputs are combinational from EX/WB registers and an arbitrary start
// state pairs them inconsistently, and a yosys harness cannot name internal
// invariants. All inputs are free (instruction words, register-file data via
// rf_top_stub.v, boot_addr, ready, interrupts), so depth 10 covers every
// possible first instruction with every operand value. Default PMA windows:
// ROM 0x20000000-0x20FFFFFF, RAM 0x80000000-0x80FFFFFF, IO0
// 0x02000000-0x0200FFFF, IO1 0x10000000-0x1002FFFF (CPU ref 4, 5.1).
//   R1 imem_addr[0] = 0            R2 imem_addr in ROM or RAM
//   R3 dmem_addr[1:0] = 0          R4 dmem_be is a legal byte/half/word lane set
//   R5 store data replicated across the lanes in use
//   R6 dmem_addr in ROM, RAM, IO0 or IO1     R7 no store to ROM
module core_req_props (
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

    function in_win(input [31:0] a, input [31:0] lo, input [31:0] hi);
        in_win = (a >= lo) && (a <= hi);
    endfunction
    wire i_rom = in_win(imem_addr, 32'h2000_0000, 32'h20FF_FFFF);
    wire i_ram = in_win(imem_addr, 32'h8000_0000, 32'h80FF_FFFF);
    wire d_rom = in_win(dmem_addr, 32'h2000_0000, 32'h20FF_FFFF);
    wire d_ram = in_win(dmem_addr, 32'h8000_0000, 32'h80FF_FFFF);
    wire d_io0 = in_win(dmem_addr, 32'h0200_0000, 32'h0200_FFFF);
    wire d_io1 = in_win(dmem_addr, 32'h1000_0000, 32'h1002_FFFF);

    always @(*) begin
        if (chk) begin
            if (imem_req) begin
                assert (imem_addr[0] == 1'b0);                              // R1
                assert (i_rom || i_ram);                                    // R2
            end
            if (dmem_req) begin
                assert (dmem_addr[1:0] == 2'b00);                           // R3
                assert (dmem_be == 4'b0001 || dmem_be == 4'b0010 || dmem_be == 4'b0100 ||
                        dmem_be == 4'b1000 || dmem_be == 4'b0011 || dmem_be == 4'b1100 ||
                        dmem_be == 4'b1111);                                // R4
                assert (d_rom || d_ram || d_io0 || d_io1);                  // R6
                if (dmem_we) begin
                    if (dmem_be == 4'b0011 || dmem_be == 4'b1100)           // R5
                        assert (dmem_wdata[31:16] == dmem_wdata[15:0]);
                    if (dmem_be == 4'b0001 || dmem_be == 4'b0010 || dmem_be == 4'b0100 || dmem_be == 4'b1000)
                        assert (dmem_wdata[31:24] == dmem_wdata[23:16] &&
                                dmem_wdata[23:16] == dmem_wdata[15:8] &&
                                dmem_wdata[15:8]  == dmem_wdata[7:0]);
                    assert (!d_rom);                                        // R7
                end
            end
        end
    end
endmodule
