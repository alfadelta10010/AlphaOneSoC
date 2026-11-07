// SoC bus rules (WO-31 part A, REQ-BUS-001): soc_bus with the real uart and gpio
// behind it, port maps as in src/alphaone_soc.v (address, we, be and wdata fan
// out unchanged). Every other input is free. Proved by k-induction at length 1;
// all the properties are combinational, so no start state matters, and each is
// gated on `armed` (set only by rst) anyway.
//   BA1 uart_ready low only while uart_sel      BA2 the same for gpio_ready
//   BA3 d_ready is the addressed target's ready (mem_ready for flash/PSRAM)
//   BA4 every select is d_req && its window; at most one select high
//   BA5 d_rdata is the addressed target's rdata
// One assumption, PMA: d_req implies d_addr is in one of the six windows of
// docs/soc-architecture.md (flash 0x2000_0000 +16 MB, PSRAM 0x8000_0000 +16 MB,
// CLINT 0x0200_0000, UART 0x1000_0000, GPIO 0x1001_0000, syscon 0x1002_0000,
// +64 KB each): the core refuses every other address, soc_bus's decode relies on it.
module bus_props (
    input  wire        clk, rst,
    input  wire        d_req, d_we,
    input  wire [31:0] d_addr, d_wdata,
    input  wire [3:0]  d_be,
    input  wire        mem_ready,
    input  wire [31:0] mem_rdata, clint_rdata, syscon_rdata,
    input  wire        uart_rx,
    input  wire [7:0]  gpio_in
);
    wire        d_ready, mem_req, clint_sel, uart_sel, gpio_sel, syscon_sel, uart_ready, gpio_ready;
    wire [31:0] d_rdata, uart_rdata, gpio_rdata;
    wire        uart_tx, uart_rts_n;
    wire [7:0]  gpio_out;

    soc_bus bus (.d_req(d_req), .d_addr(d_addr), .d_rdata(d_rdata), .d_ready(d_ready),
        .mem_req(mem_req), .mem_rdata(mem_rdata), .mem_ready(mem_ready),
        .clint_sel(clint_sel), .clint_rdata(clint_rdata),
        .uart_sel(uart_sel), .uart_rdata(uart_rdata), .uart_ready(uart_ready),
        .gpio_sel(gpio_sel), .gpio_rdata(gpio_rdata), .gpio_ready(gpio_ready),
        .syscon_sel(syscon_sel), .syscon_rdata(syscon_rdata));
    uart uart_inst (.clk(clk), .rst(rst), .sel(uart_sel), .we(d_we), .be(d_be), .addr2(d_addr[2]),
        .wdata(d_wdata), .rdata(uart_rdata), .ready(uart_ready), .rx(uart_rx), .tx(uart_tx), .rts_n(uart_rts_n));
    gpio gpio_inst (.clk(clk), .rst(rst), .sel(gpio_sel), .we(d_we), .be(d_be), .addr(d_addr[5:2]),
        .wdata(d_wdata), .rdata(gpio_rdata), .ready(gpio_ready), .in(gpio_in), .out(gpio_out));

    reg armed = 1'b0;               // a reset has been applied; every assert is gated on it
    always @(posedge clk) if (rst) armed <= 1'b1;

    wire w_flash  = d_addr[31:24] == 8'h20;
    wire w_psram  = d_addr[31:24] == 8'h80;
    wire w_clint  = d_addr[31:16] == 16'h0200;
    wire w_uart   = d_addr[31:16] == 16'h1000;
    wire w_gpio   = d_addr[31:16] == 16'h1001;
    wire w_syscon = d_addr[31:16] == 16'h1002;
    wire w_mem    = w_flash || w_psram;

    always @(*) begin
        assume (!d_req || w_mem || w_clint || w_uart || w_gpio || w_syscon);        // PMA
        if (armed) begin
            assert (uart_ready || uart_sel);                                        // BA1
            assert (gpio_ready || gpio_sel);                                        // BA2
            if (d_req && w_uart)   assert (d_ready == uart_ready);                  // BA3
            if (d_req && w_gpio)   assert (d_ready == gpio_ready);
            if (d_req && w_syscon) assert (d_ready);
            if (d_req && w_clint)  assert (d_ready);
            if (d_req && w_mem)    assert (d_ready == mem_ready);
            assert (mem_req    == (d_req && w_mem));                                // BA4
            assert (clint_sel  == (d_req && w_clint));
            assert (uart_sel   == (d_req && w_uart));
            assert (gpio_sel   == (d_req && w_gpio));
            assert (syscon_sel == (d_req && w_syscon));
            assert (({3'b0, mem_req} + clint_sel + uart_sel + gpio_sel + syscon_sel) <= 6'd1);
            if (d_req && w_mem)    assert (d_rdata == mem_rdata);                   // BA5
            if (d_req && w_clint)  assert (d_rdata == clint_rdata);
            if (d_req && w_uart)   assert (d_rdata == uart_rdata);
            if (d_req && w_gpio)   assert (d_rdata == gpio_rdata);
            if (d_req && w_syscon) assert (d_rdata == syscon_rdata);
        end
    end

`ifdef SBY_COVER
    // the antecedents of BA1/BA2: back-pressure is reachable
    always @(*) begin
        cover (armed && !uart_ready && uart_sel); cover (armed && !gpio_ready && gpio_sel);
    end
`endif
endmodule
