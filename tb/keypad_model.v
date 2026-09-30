// Behavioural model of the Digilent PmodKYPD 4x4 keypad, wired as
// docs/pins-and-peripherals.md sets it up: the top-row plug (COL4..COL1) on
// out[0..3], the bottom-row plug (ROW4..ROW1) on in[4..7].
//
//   col[3:0] = out[3:0]: out[3] COL1, out[2] COL2, out[1] COL3, out[0] COL4
//   row[3:0] = in[7:4]:  in[7] ROW1,  in[6] ROW2,  in[5] ROW3,  in[4] ROW4
//
// Key k = 4 x r + c for row r (0 = ROW1) and column c (0 = COL1), with the
// PmodKYPD's legend:
//            COL1 COL2 COL3 COL4
//     ROW1    1    2    3    A
//     ROW2    4    5    6    B
//     ROW3    7    8    9    C
//     ROW4    0    F    E    D
//
// Electrically: each row has a 10 k pull-up, each column a 470 R series
// resistor to a GPIO output that always drives. A pressed key joins its row
// to its column. A row with no key pressed reads 1; a row joined to columns
// that all drive the same level reads that level (470 R beats 10 k); a row
// joined to columns driving different levels sits near mid-rail (two 470 R
// in a divider) and reads X -- software must not rely on it, so a test that
// scans such a pattern gets X into the core, not a plausible answer.

`timescale 1ns / 1ps

module keypad_model (
    input  wire [3:0]  col,
    input  wire [15:0] pressed,
    output wire [3:0]  row
);
    function automatic lvl(input integer r, input [3:0] c_pins, input [15:0] keys);
        integer c;
        reg     any, v, clash;
        begin
            any = 1'b0; v = 1'b1; clash = 1'b0;
            for (c = 0; c < 4; c = c + 1)
                if (keys[4*r + c]) begin
                    if (any && c_pins[3-c] !== v) clash = 1'b1;
                    v = c_pins[3-c];
                    any = 1'b1;
                end
            lvl = !any ? 1'b1 : clash ? 1'bx : v;
        end
    endfunction

    assign row[3] = lvl(0, col, pressed);     // ROW1 -> in[7]
    assign row[2] = lvl(1, col, pressed);     // ROW2 -> in[6]
    assign row[1] = lvl(2, col, pressed);     // ROW3 -> in[5]
    assign row[0] = lvl(3, col, pressed);     // ROW4 -> in[4]
endmodule
