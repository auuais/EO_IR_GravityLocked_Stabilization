//============================================================================
// RpRowWindow
//
// Partly built output rows in UltraRAM: 2^18 x 72-bit words.
//   EO: 256 rows x 1024 words, 4 pixels per word at [k*18 +: 16], each pixel
//       written through two of the eight nine-bit byte enables
//   IR: 512 rows x  512 words, 8 luma pixels per word at [k*9 +: 8], one byte
//       enable each
// Port A writes single pixels through byte-wide write enables, so the renderer
// never has to read a word back to change one pixel.  Port B is the emitter's
// read port.
//
// Vivado cannot pack several narrow addresses into one URAM address, so a
// 16-bit x 1M-word memory would take 256 blocks.  Packing makes it 64.
//
// Synthesis recommends five read pipeline stages for this 8x8 URAM matrix and
// absorbs registers only from a plain chain after the memory, so RD_LAT is a
// straight register chain.
//============================================================================
`timescale 1ns/1ps
module RpRowWindow #(
    parameter integer ADDR_W = 18,
    parameter integer RD_LAT = 5          // 2..7
) (
    input  wire              clk,
    input  wire [7:0]        we,
    input  wire [ADDR_W-1:0] waddr,
    input  wire [71:0]       din,
    input  wire [ADDR_W-1:0] raddr,
    output wire [71:0]       dout
);
    (* ram_style = "ultra" *) reg [71:0] mem [0:(1<<ADDR_W)-1];
    // One register between the renderer and the cascade's address, data and
    // enable fan-out.  Write latency is irrelevant to the renderer: rows are
    // only read after the y0 drain.
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
    reg [71:0] q [1:7];
    integer i;
    always @(posedge clk) begin
        q[1] <= mem[raddr];
        for (i = 2; i <= 7; i = i + 1) q[i] <= q[i-1];
    end
    assign dout = q[RD_LAT];
endmodule
