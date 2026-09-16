//============================================================================
// RpLineRing
//
// The source-driven renderer's line cache: three source rows per camera,
// slot = row mod 3.  While output pixels for source row y0 are rendered, rows
// y0 and y0+1 are read and row y0+2 is written into the third slot, so the
// DDR replay and the renderer run concurrently without ever touching the same
// slot.  The renderer only moves to y0+1 after its pipeline has drained,
// which is what frees the y0 slot for row y0+3.
//
// Write side: EoV19DdrReplay in BEAT_OUT mode presents one 256-bit beat
// (16 pixels, pixel p in [p*16 +: 16]) per camera with its row and beat
// index, then holds for BEAT_HOLD cycles while this module writes the beat as
// four 64-bit words (4 pixels each) into a 480-word row.  Beats outside the
// replay's fetch window are never presented; their words keep old contents,
// which the renderer never addresses because the fetch window is derived from
// the same tables that bound every sampled column.
//
// Read side: one shared word address, two slots (rows y0 and y0+1), one
// camera.  Latency RD_LAT = 4 from rd_* to rd_pa/rd_pb.
//============================================================================
`timescale 1ns/1ps
module RpLineRing (
    input  wire          clk,
    input  wire          rst,
    input  wire          frame_start,      // replay frame_edge: forget all rows

    input  wire          beat_valid,
    input  wire [10:0]   beat_row,
    input  wire [6:0]    beat_idx,
    input  wire [1535:0] beat_data,        // cam k in [k*256 +: 256]
    input  wire          row_done,         // replay finished row_done_row
    input  wire [10:0]   row_done_row,
    output reg  [11:0]   rows_done,        // last completed row + 1 (0 = none)
    output wire          writer_idle,

    input  wire [8:0]    rd_word,
    input  wire [1:0]    rd_sel,
    input  wire [2:0]    rd_cam,
    input  wire [1:0]    rd_slot_a,
    input  wire [1:0]    rd_slot_b,
    output reg  [15:0]   rd_pa,
    output reg  [15:0]   rd_pb
);
    localparam integer WORDS = 480;

    //------------------------------------------------------------------------
    // Writer: one beat -> four words, all six cameras in parallel
    //------------------------------------------------------------------------
    reg [1535:0] wbeat;
    reg [8:0]    wbase;          // beat_idx * 4
    reg [1:0]    wslot;
    reg [2:0]    wleft;          // words still to write for the latched beat
    reg [1:0]    wk;             // word within the beat
    reg          row_done_pend;
    reg [10:0]   row_done_pend_row;
    assign writer_idle = (wleft == 3'd0);

    function [1:0] mod3;
        input [10:0] v;
        begin
            mod3 = v % 3;
        end
    endfunction

    always @(posedge clk) begin
        if (rst || frame_start) begin
            wleft <= 3'd0; wk <= 2'd0;
            rows_done <= 12'd0;
            row_done_pend <= 1'b0;
        end else begin
            if (beat_valid) begin
                wbeat <= beat_data;
                wbase <= {beat_idx, 2'b00};
                wslot <= mod3(beat_row);
                wleft <= 3'd4;
                wk    <= 2'd0;
            end else if (wleft != 3'd0) begin
                wleft <= wleft - 3'd1;
                wk    <= wk + 2'd1;
            end
            if (row_done) begin
                row_done_pend     <= 1'b1;
                row_done_pend_row <= row_done_row;
            end else if (row_done_pend && writer_idle && !beat_valid) begin
                row_done_pend <= 1'b0;
                rows_done     <= {1'b0, row_done_pend_row} + 12'd1;
            end
        end
    end

    wire        we_any = (wleft != 3'd0);
    wire [8:0]  waddr  = wbase + {7'd0, wk};

    //------------------------------------------------------------------------
    // 18 row memories (6 cams x 3 slots), 480 x 64 bits each
    //------------------------------------------------------------------------
    reg  [8:0]  rd_word_q;
    reg  [1:0]  sel_d1, sel_d2;
    reg  [2:0]  cam_d1, cam_d2;
    reg  [1:0]  sa_d1, sa_d2, sb_d1, sb_d2;
    wire [63:0] q [0:17];

    genvar gc, gs;
    generate
        for (gc = 0; gc < 6; gc = gc + 1) begin : g_cam
            for (gs = 0; gs < 3; gs = gs + 1) begin : g_slot
                (* ram_style = "block" *) reg [63:0] mem [0:511];
                reg [63:0] q1, q2;
                always @(posedge clk) begin
                    if (we_any && (wslot == gs))
                        mem[waddr] <= wbeat[gc*256 + wk*64 +: 64];
                end
                always @(posedge clk) begin
                    q1 <= mem[rd_word_q];
                    q2 <= q1;
                end
                assign q[gc*3 + gs] = q2;
            end
        end
    endgenerate

    // latency: rd_* -> rd_word_q (1) -> q1 (2) -> q2 (3) -> rd_pa/rd_pb (4)
    reg [63:0] wa, wb;
    always @(posedge clk) begin
        rd_word_q <= rd_word;
        sel_d1 <= rd_sel;    sel_d2 <= sel_d1;
        cam_d1 <= rd_cam;    cam_d2 <= cam_d1;
        sa_d1  <= rd_slot_a; sa_d2  <= sa_d1;
        sb_d1  <= rd_slot_b; sb_d2  <= sb_d1;
    end
    // q2 is valid for the address issued three cycles earlier; cam/slot/sel
    // are delayed to match and the mux+select is the fourth register.
    reg [1:0] sel_d3; reg [2:0] cam_d3; reg [1:0] sa_d3, sb_d3;
    always @(posedge clk) begin
        sel_d3 <= sel_d2; cam_d3 <= cam_d2; sa_d3 <= sa_d2; sb_d3 <= sb_d2;
    end
    wire [63:0] word_a = q[cam_d3*3 + sa_d3];
    wire [63:0] word_b = q[cam_d3*3 + sb_d3];
    always @(posedge clk) begin
        rd_pa <= word_a[sel_d3*16 +: 16];
        rd_pb <= word_b[sel_d3*16 +: 16];
    end
endmodule
