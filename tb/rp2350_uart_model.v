// Behavioural model of the demo board's RP2350 UART1 (a PL011) on the chip's
// UART pins (docs/pins-and-peripherals.md): GPIO37 receives the chip's TX,
// GPIO20 drives the chip's RX, and GPIO38 is CTS, wired to the chip's RTS#.
//
// Receive: it decodes every frame on `tx` at its configured bit time --
// falling edge, start bit re-checked at mid-bit, each bit sampled at its
// middle, stop bit checked -- and keeps the bytes. It also checks the
// line's timing: every edge inside a frame must lie within TOL_NS of a
// whole number of bit times from the start edge, so a short or long bit
// is caught, not just a wrong byte.
//
// Transmit: bytes queued with send_byte / send_str go out 8N1. With flow
// control on (the board's setup) it checks CTS before each character, as
// the PL011 does, and starts only while CTS (= RTS#) is asserted low; a
// character already started always completes. With flow control off it
// sends regardless, which is how an overrun is made on purpose.
//
// Errors are counted in `errors` and printed as ERROR lines.

`timescale 1ns / 1ps

module rp2350_uart_model #(
    parameter real BIT_NS = 1280.0,   // 16 x divisor x clock period
    parameter real TOL_NS = 1.0
)(
    input  wire tx,       // the chip's TX
    output reg  rx,       // the chip's RX
    input  wire cts_n     // the chip's RTS#
);
    real    bit_ns;
    reg     flow;
    real    gap_ns;       // idle time added after each character sent
    integer errors;

    reg [7:0] rx_buf [0:16383];
    integer   rx_n;
    integer   rx_frames_bad;

    reg [7:0] tx_q [0:16383];
    integer   tx_head, tx_tail;
    integer   tx_sent, tx_sent_cts_off;
    integer   tx_stops;               // stop bits begun: the DUT samples within this one
    reg       tx_busy;

    initial begin
        bit_ns = BIT_NS; flow = 1'b1; gap_ns = 0.0; errors = 0;
        rx_n = 0; rx_frames_bad = 0;
        tx_head = 0; tx_tail = 0; tx_sent = 0; tx_sent_cts_off = 0; tx_stops = 0; tx_busy = 1'b0;
        rx = 1'b1;
    end

    task automatic error(input string m);
        begin
            errors = errors + 1;
            if (errors <= 20) $display("ERROR rp2350 UART: %s (%0.1f ns)", m, $realtime);
        end
    endtask

    // ── API ─────────────────────────────────────────────────────────────────
    task automatic set_baud(input real ns);  bit_ns = ns;  endtask
    task automatic set_flow(input f);        flow = f;     endtask
    task automatic send_byte(input [7:0] b);
        begin tx_q[tx_tail % 16384] = b; tx_tail = tx_tail + 1; end
    endtask
    task automatic send_str(input string s);
        integer i;
        for (i = 0; i < s.len(); i = i + 1) send_byte(s[i]);
    endtask
    function automatic string rx_str;
        integer i;
        string  s;
        begin
            s = "";
            for (i = 0; i < rx_n; i = i + 1) s = $sformatf("%s%c", s, rx_buf[i % 16384]);
            rx_str = s;
        end
    endfunction
    function automatic integer tx_pending;
        tx_pending = tx_tail - tx_head + (tx_busy ? 1 : 0);
    endfunction

    // ── Receiver ────────────────────────────────────────────────────────────
    real    f_t0 = -1.0e9;
    reg     in_frame = 1'b0;
    real    k;
    always @(tx)
        if (in_frame) begin
            k = ($realtime - f_t0) / bit_ns;
            if (k - $floor(k + 0.5) > TOL_NS / bit_ns || $floor(k + 0.5) - k > TOL_NS / bit_ns)
                error($sformatf("TX edge %0.1f ns into a frame, %0.3f bit times: not on a bit boundary",
                                $realtime - f_t0, k));
        end

    always begin : receiver
        integer   i;
        reg [7:0] b;
        @(negedge tx);
        if (tx === 1'b0) begin
            f_t0 = $realtime;
            in_frame = 1'b1;
            #(bit_ns / 2.0);
            if (tx !== 1'b0) begin
                error("start bit not low at its middle");
                in_frame = 1'b0;
            end else begin
                for (i = 0; i < 8; i = i + 1) begin #(bit_ns); b[i] = tx; end
                #(bit_ns);
                if (tx !== 1'b1) begin
                    error($sformatf("framing error (stop bit %b) after byte %02h", tx, b));
                    rx_frames_bad = rx_frames_bad + 1;
                end
                if (b === 8'bx) error("X data bits");
                rx_buf[rx_n % 16384] = b;
                rx_n = rx_n + 1;
                // The stop bit's second half: still on the grid.
                #(bit_ns / 2.0 - TOL_NS);
                in_frame = 1'b0;
            end
        end
    end

    // ── Transmitter ─────────────────────────────────────────────────────────
    always begin : transmitter
        integer   i;
        reg [7:0] b;
        wait (tx_head != tx_tail);
        if (flow) begin
            // The PL011 looks at CTS before each character, through a
            // synchroniser: a few ns later, and it looks again if CTS has
            // gone away in the meantime.
            while (cts_n !== 1'b0) @(cts_n);
            #(5.0);
        end
        if (!flow || cts_n === 1'b0) begin
            b = tx_q[tx_head % 16384];
            tx_head = tx_head + 1;
            tx_busy = 1'b1;
            if (cts_n !== 1'b0) tx_sent_cts_off = tx_sent_cts_off + 1;
            rx = 1'b0;
            #(bit_ns);
            for (i = 0; i < 8; i = i + 1) begin rx = b[i]; #(bit_ns); end
            rx = 1'b1;
            tx_stops = tx_stops + 1;
            #(bit_ns);
            tx_sent = tx_sent + 1;
            tx_busy = 1'b0;
            if (gap_ns > 0.0) #(gap_ns);
        end
    end
endmodule
