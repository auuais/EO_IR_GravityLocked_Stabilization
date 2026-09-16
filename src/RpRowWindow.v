//============================================================================
// RpRowWindow
//
// Partly built output rows: 256 row slots x 1024 words x 72 bits, 4 pixels
// per word at [k*18 +: 16].  Port A writes single pixels through byte-wide
// write enables (2 of the 8 nine-bit bytes), so the renderer never has to read
// a word back to change one pixel.  Port B is the emitter's read port.
//
// UltraRAM: Vivado cannot pack several narrow addresses into one URAM
// address, so a 16-bit x 1M-word memory would take 256 blocks.  Packing 4
// pixels per 72-bit word makes it 64.
//============================================================================
`timescale 1ns/1ps
module RpRowWindow #(
    parameter integer ADDR_W = 18,
    parameter integer RD_LAT = 3          // 2 or 3
) (
    input  wire              clk,
    input  wire [7:0]        we,
    input  wire [ADDR_W-1:0] waddr,
    input  wire [71:0]       din,
    input  wire [ADDR_W-1:0] raddr,
    output wire [71:0]       dout
);
    (* ram_style = "ultra" *) reg [71:0] mem [0:(1<<ADDR_W)-1];
    // One register between the renderer and a 64-block cascade's address,
    // data and enable fan-out.  Write latency is irrelevant to the renderer:
    // rows are only read after the y0 drain.
    reg [7:0]        we_q;
    reg [ADDR_W-1:0] waddr_q;
    reg [71:0]       din_q;
    always @(posedge clk) begin
        we_q <= we; waddr_q <= waddr; din_q <= din;
    end
    integer b;
    always @(posedge clk) begin
        for (b = 0; b < 8; b = b + 1)
            if (we_q[b]) mem[waddr_q][b*9 +: 9] <= din_q[b*9 +: 9];
    end
    reg [71:0] q1, q2, q3;
    always @(posedge clk) begin
        q1 <= mem[raddr];
        q2 <= q1;
        q3 <= q2;
    end
    assign dout = (RD_LAT == 3) ? q3 : q2;
endmodule
