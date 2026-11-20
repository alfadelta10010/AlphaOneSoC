// WO-55/WO-63: audio (src/audio.v, one square voice), k-induction at length 1. Every property relates one
// non-reset step to the previous one (state and inputs copied in *_q). White-box ports exposed by run.sh PRE
// (audio.conf).
//   R   reset values, read-back layout (TONE0 = {O, P}, CTRL = EN, every other word and bit reads 0)
//   P1  !EN -> audio_o low and counters cleared one clock later
//   P2  audio_o toggles iff the voice ticks with c == 0; c reloads P / counts down / holds 0 with EN low
//   P3  pre counts while EN, cleared with EN low; config registers take byte-lane writes
module audio_props (
    input  wire        clk, rst,
    input  wire        sel, we,
    input  wire [3:0]  be,
    input  wire [4:2]  addr,
    input  wire [31:0] wdata
);
    wire [31:0] rdata;
    wire        audio_o, en;
    wire [11:0] per, c;
    wire [2:0]  oct;
    wire [10:0] pre;
    audio dut (.clk(clk), .rst(rst), .sel(sel), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata),
               .audio_o(audio_o), .per(per), .c(c), .oct(oct), .en(en), .pre(pre));

    reg armed = 1'b0, rst_q = 1'b0, armed_q = 1'b0;
    reg sel_q = 0, we_q = 0, en_q = 0, ao_q = 0;
    reg [3:0] be_q = 0; reg [4:2] addr_q = 0; reg [31:0] wdata_q = 0;
    reg [11:0] per_q = 0, c_q = 0; reg [2:0] oct_q = 0; reg [10:0] pre_q = 0;
    always @(posedge clk) begin
        if (rst) armed <= 1'b1;
        rst_q <= rst; armed_q <= armed;
        sel_q <= sel; we_q <= we; be_q <= be; addr_q <= addr; wdata_q <= wdata;
        en_q <= en; ao_q <= audio_o; per_q <= per; c_q <= c; oct_q <= oct; pre_q <= pre;
    end

    wire step = armed_q && !rst_q;
    wire w_q  = sel_q && we_q;
    wire b_q  = pre_q[3:0] == 4'hF;
    wire [6:0] m_q = (7'd1 << oct_q) - 7'd1;
    wire tk_q = en_q && b_q && ((pre_q[10:4] & m_q) == m_q);

    reg [11:0] pe; reg [2:0] oe;
    always @(*) begin
        if (armed_q && rst_q) assert (per == 0 && oct == 0 && c == 0 && !en && pre == 0 && !audio_o);  // R
        if (armed) begin
            case (addr)
                3'd0: assert (rdata == {17'b0, oct, per});
                3'd4: assert (rdata == {31'b0, en});
                default: assert (rdata == 32'b0);
            endcase
        end
        if (step) begin
            if (!en_q) assert (!audio_o && c == 12'd0);                                               // P1
            assert (audio_o == (en_q && (ao_q ^ (tk_q && c_q == 12'd0))));                           // P2
            assert (c == (!en_q ? 12'd0 : !tk_q ? c_q : c_q == 12'd0 ? per_q : c_q - 12'd1));
            assert (pre == (en_q ? pre_q + 11'd1 : 11'd0));                                           // P3
            pe = per_q; oe = oct_q;
            if (w_q && addr_q == 3'd0 && be_q[0]) pe[7:0] = wdata_q[7:0];
            if (w_q && addr_q == 3'd0 && be_q[1]) begin pe[11:8] = wdata_q[11:8]; oe = wdata_q[14:12]; end
            assert (per == pe && oct == oe);
            assert (en == ((w_q && addr_q == 3'd4 && be_q[0]) ? wdata_q[0] : en_q));
        end
    end

`ifdef SBY_COVER
    always @(*) begin
        cover (step && audio_o != ao_q);                               // the voice toggles
        cover (step && en_q && !en && pre_q != 0);                     // EN off mid-count
        cover (step && tk_q && c_q != 0 && oct_q == 1);                // octave 1 tick, counting down
    end
`endif
endmodule
