// SPI controller with the register semantics of OpenCores tiny_spi, so the
// Linux driver drivers/spi/spi-oc-tiny.c runs it unchanged. It is a sub-block
// of gpio.v, which decodes the bus and owns EN, OUT and IN; this module owns
// the two shared pin flops, so MOSI and SCK always leave from a flop (F12).
//
// The engine moves a byte as 8 bits, each an A phase and a B phase of
// BAUD + 1 clocks. A_LVL = cpol ^ cpha is SCK's level in A, ~A_LVL in B, and
// cpol when idle. In every mode the edge into A launches a bit (MOSI changes,
// the device changes MISO), the edge A -> B is where the device samples MOSI,
// and the clock that ends B is the next launch. A byte takes 16 x (BAUD + 1)
// clocks and bytes run back to back with no gap.
//
// MISO is sampled one core clock before the edge that ends each bit: miso is
// gpio's first synchroniser flop (in_m[1]), which captures it every clock.
//
// bb is both the TX holding register (bba = it holds a byte not yet loaded)
// and, after a load, the byte received with the byte before; sr is the shift
// register (TX leaves at the top, RX enters at the bottom) and RXDATA.
//
// While en = 0 the engine runs and times bytes normally but the pins follow
// OUT writes of bits 1 and 3 (wr_out); while en = 1 those writes are ignored
// and the engine drives p_mosi and p_sck. A write of EN or CONTROL with
// en = 1 puts SCK at the (new) idle level cpol; gpio only lets such a write
// through while the engine is idle (it waits for txe).

module spi (
    input  wire       clk,
    input  wire       rst,
    input  wire       en,         // 1 = the engine owns the MOSI and SCK pins
    input  wire       miso,       // synchronised (gpio's in_m[1])
    // Register writes, one-clock strobes; wdata is the bus write data
    input  wire [7:0] wdata,
    input  wire       wr_tx,      // TXDATA
    input  wire       wr_ctl,     // CONTROL: wdata[1:0] = {CPOL, CPHA}
    input  wire       wr_baud,    // BAUD
    input  wire       wr_en,      // a write of SPICTL that sets EN = 1
    input  wire       wr_out,     // OUT: wdata[3] and wdata[1] reach the pins when en = 0
    // Register reads
    output wire [7:0] rxdata,     // sr
    output wire [7:0] txdata,     // bb
    output wire       txe,        // engine idle and bb empty
    output wire       txr,        // bb empty
    output wire [1:0] control,    // {CPOL, CPHA}
    output wire [7:0] baud_o,
    // Pins
    output wire       p_mosi,
    output wire       p_sck
);

    localparam [1:0] IDLE = 2'd0, A = 2'd1, B = 2'd2;

    reg [1:0] st;
    reg [7:0] sr, bb;
    reg       bba;
    reg [7:0] cc;                 // clocks left in the half-period (no reset: loaded at every LOAD)
    reg [2:0] bc;                 // bits left in the byte (no reset: loaded at every LOAD)
    reg       cpol, cpha;
    reg [7:0] baud;
    reg       mosi_r, sck_r;

    wire a_lvl   = cpol ^ cpha;
    wire cc_end  = (cc == 8'd0);
    wire [7:0] rx_in = {sr[6:0], miso};

    assign txe     = (st == IDLE) && !bba;
    assign txr     = !bba;
    assign rxdata  = sr;
    assign txdata  = bb;
    assign control = {cpol, cpha};
    assign baud_o  = baud;
    assign p_mosi  = mosi_r;
    assign p_sck   = sck_r;

    always @(posedge clk) begin
        if (rst) begin
            st     <= IDLE;
            sr     <= 8'h00;
            bb     <= 8'h00;
            bba    <= 1'b0;
            cpol   <= 1'b1;       // mode 3: SCK idles high, the level it resets to
            cpha   <= 1'b1;
            baud   <= 8'hFF;
            mosi_r <= 1'b0;
            sck_r  <= 1'b1;
        end else begin
            // ---- register writes (gpio has already made them wait as needed)
            if (wr_ctl) begin
                cpol <= wdata[1];
                cpha <= wdata[0];
                if (en) sck_r <= wdata[1];
            end
            if (wr_baud) baud <= wdata;
            if (wr_en) sck_r <= cpol;
            if (wr_out && !en) begin
                sck_r  <= wdata[3];
                mosi_r <= wdata[1];
            end
            if (wr_tx) begin
                bb  <= wdata;
                bba <= 1'b1;
            end

            // ---- the engine
            case (st)
            IDLE: if (bba) begin
                bb <= sr;                         // TXDATA then reads the last RX byte
                sr <= bb;
                if (en) begin mosi_r <= bb[7]; sck_r <= a_lvl; end
                bba <= 1'b0;
                bc  <= 3'd7;
                cc  <= baud;
                st  <= A;
            end
            A: if (cc_end) begin                  // the device samples MOSI
                if (en) sck_r <= ~a_lvl;
                cc <= baud;
                st <= B;
            end else cc <= cc - 8'd1;
            B: if (!cc_end) cc <= cc - 8'd1;
               else if (bc != 3'd0) begin         // next bit
                sr <= rx_in;
                if (en) begin mosi_r <= sr[6]; sck_r <= a_lvl; end
                bc <= bc - 3'd1;
                cc <= baud;
                st <= A;
               end else if (bba) begin            // next byte, no gap
                bb <= rx_in;
                sr <= bb;
                if (en) begin mosi_r <= bb[7]; sck_r <= a_lvl; end
                bba <= 1'b0;
                bc  <= 3'd7;
                cc  <= baud;
                st  <= A;
               end else begin
                sr <= rx_in;
                if (en) sck_r <= cpol;
                st <= IDLE;
               end
            default: st <= IDLE;
            endcase
        end
    end

endmodule
