//============================================================================
// RpEmitter
//
// Streams finished output rows from the RowWindow as the 3840-pixel panorama
// raster the M1 renderer produced, blending the 17-pixel camera seams.
//
// Row sy_out may be emitted once ROW_READY[sy_out] <= y0_done (every pixel of
// it has then been written this pass), or once the whole pass is done.
//
// Strips are read in order, one read per pixel (cam0 650 px, cam1..5 655).
// The last OVL pixels of strip k are held in a FIFO and blended with the first
// OVL pixels of strip k+1, which is exactly the M1 renderer's overlap:
//   pano_x = CAM(k+1)_START + j,  a = strip k pixel, b = strip k+1 pixel j,
//   out = !present[k] ? BLACK : present[k+1] ? blend(a, b, alpha[j]) : a
// Everything else is present[k] ? pixel : BLACK.  A row the walker had to drop
// pixels from (RowWindow overflow) is emitted black.
//============================================================================
`timescale 1ns/1ps
module RpEmitter #(
    parameter integer NUM_ROWS = 480,
    parameter [15:0]  BLACK = 16'h1080,
    parameter integer OVL = 17,
    parameter integer W0 = 650, parameter integer W1 = 655, parameter integer W2 = 655,
    parameter integer W3 = 655, parameter integer W4 = 655, parameter integer W5 = 655,
    parameter integer RW_RD_LAT = 2,
    parameter         ALPHA_Y_FILE = "../../assets/rowruns/eo_v19_alpha_y.mem",
    parameter         ALPHA_C_FILE = "../../assets/rowruns/eo_v19_alpha_c.mem"
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         start,
    input  wire [5:0]   cam_present,

    output reg  [8:0]   rr_raddr,
    input  wire [10:0]  rr_rdata,          // latency 1

    input  wire         y0_done_valid,
    input  wire [10:0]  y0_done,
    input  wire         all_done,

    input  wire         drop_valid,
    input  wire [8:0]   drop_sy,

    output reg  [17:0]  rw_raddr,
    input  wire [71:0]  rw_dout,           // latency RW_RD_LAT

    output wire         px_valid,
    input  wire         px_ready,
    output wire [15:0]  px_data,
    output reg          frame_done,
    output reg          done,

    output reg  [8:0]   sy_out,
    output wire         can_progress
);
    function integer strip_w;
        input integer k;
        begin
            case (k)
                0: strip_w = W0; 1: strip_w = W1; 2: strip_w = W2;
                3: strip_w = W3; 4: strip_w = W4; default: strip_w = W5;
            endcase
        end
    endfunction
    function [11:0] strip_base;
        input [2:0] k;
        begin
            case (k)
                3'd0: strip_base = 12'd0;
                3'd1: strip_base = W0;
                3'd2: strip_base = W0 + W1;
                3'd3: strip_base = W0 + W1 + W2;
                3'd4: strip_base = W0 + W1 + W2 + W3;
                default: strip_base = W0 + W1 + W2 + W3 + W4;
            endcase
        end
    endfunction

    reg [15:0] alpha_y [0:31];
    reg [15:0] alpha_c [0:15];
    initial begin
        $readmemh(ALPHA_Y_FILE, alpha_y);
        $readmemh(ALPHA_C_FILE, alpha_c);
    end

    //------------------------------------------------------------------------
    // Row sequencing
    //------------------------------------------------------------------------
    localparam [2:0] E_IDLE = 3'd0, E_RR = 3'd1, E_RR2 = 3'd2, E_RR3 = 3'd3,
                     E_WAIT = 3'd4, E_ROW = 3'd5, E_FLUSH = 3'd6, E_DONE = 3'd7;
    reg [2:0]  state;
    reg [10:0] rr_val;
    reg [479:0] row_bad;
    reg [5:0]  present;
    reg [2:0]  k;
    reg [9:0]  j;

    wire ready_now = all_done || (y0_done_valid && (rr_val <= y0_done));
    assign can_progress = !((state == E_WAIT) && !ready_now);

    // elastic output: issue a read only if the pixel can be absorbed
    localparam integer PIPE = RW_RD_LAT + 4;
    reg  [PIPE-1:0] pv;                     // pixel pipeline occupancy
    reg  [4:0]      ocount;                 // output FIFO level (0..16)
    wire [4:0]      pipe_n;
    assign pipe_n = count_ones(pv);
    function [4:0] count_ones;
        input [PIPE-1:0] v;
        integer n;
        begin
            count_ones = 0;
            for (n = 0; n < PIPE; n = n + 1) count_ones = count_ones + v[n];
        end
    endfunction
    wire room = (ocount + pipe_n) < 5'd14;
    wire issue = (state == E_ROW) && room;
    wire last_of_row = (k == 3'd5) && (j == strip_w(5) - 1);

    always @(posedge clk) begin
        if (rst) begin
            state <= E_IDLE; sy_out <= 9'd0; done <= 1'b0;
        end else begin
            case (state)
            E_IDLE: if (start) begin
                sy_out <= 9'd0; done <= 1'b0; row_bad <= 480'd0; present <= cam_present;
                state <= E_RR;
            end
            // rr_raddr is registered in E_RR, read by the table in E_RR2 and
            // its data is on rr_rdata in E_RR3.
            E_RR:   begin rr_raddr <= sy_out; state <= E_RR2; end
            E_RR2:  state <= E_RR3;
            E_RR3:  begin rr_val <= rr_rdata; state <= E_WAIT; end
            E_WAIT: if (ready_now) begin k <= 3'd0; j <= 10'd0; state <= E_ROW; end
            E_ROW: if (issue) begin
                if (last_of_row) begin
                    if (sy_out == NUM_ROWS - 1) state <= E_FLUSH;
                    else begin sy_out <= sy_out + 9'd1; state <= E_RR; end
                end else if (j == strip_w(k) - 1) begin
                    k <= k + 3'd1; j <= 10'd0;
                end else begin
                    j <= j + 10'd1;
                end
            end
            E_FLUSH: if (frame_done) begin done <= 1'b1; state <= E_DONE; end
            default: ;
            endcase
            if (drop_valid) row_bad[drop_sy] <= 1'b1;
        end
    end

    //------------------------------------------------------------------------
    // Pixel pipeline
    //   p0 issue: rw_raddr, side {k, j, sel, bad, last}
    //   p0+RW_RD_LAT: word arrives -> extract pixel
    //   +1 classify (tail -> seam FIFO, head -> blend with popped pixel)
    //   +2 products  +3 result -> output FIFO
    //------------------------------------------------------------------------
    reg [2:0] sk [0:7];
    reg [9:0] sj [0:7];
    reg [1:0] ssel [0:7];
    reg       sbad [0:7];
    reg       slast [0:7];
    integer   m;
    always @(posedge clk) begin
        if (rst) pv <= 0;
        else     pv <= {pv[PIPE-2:0], issue};
        if (issue) begin
            begin : addr
                reg [11:0] sx;
                sx = strip_base(k) + {2'd0, j};
                rw_raddr <= {sy_out[7:0], sx[11:2]};
                ssel[0] <= sx[1:0];
            end
        end
        sk[0] <= k; sj[0] <= j; sbad[0] <= row_bad[sy_out]; slast[0] <= last_of_row && (sy_out == NUM_ROWS - 1);
        for (m = 1; m < 8; m = m + 1) begin
            sk[m] <= sk[m-1]; sj[m] <= sj[m-1]; ssel[m] <= ssel[m-1]; sbad[m] <= sbad[m-1]; slast[m] <= slast[m-1];
        end
    end

    // Word valid at pipeline index RW_RD_LAT (pv bit RW_RD_LAT-1 marks it).
    wire        w_v    = pv[RW_RD_LAT];
    wire [2:0]  w_k    = sk[RW_RD_LAT];
    wire [9:0]  w_j    = sj[RW_RD_LAT];
    wire [1:0]  w_sel  = ssel[RW_RD_LAT];
    wire        w_bad  = sbad[RW_RD_LAT];
    wire        w_last = slast[RW_RD_LAT];
    wire [15:0] w_px   = rw_dout[w_sel*18 +: 16];

    // seam FIFO
    reg [15:0] seam [0:OVL-1];
    reg [4:0]  seam_wr, seam_rd;

    reg        c_v, c_out, c_blend, c_bad, c_last, c_pa, c_pb;
    reg [15:0] c_a, c_b;
    reg [15:0] c_fy, c_fc;
    wire       tail = (w_k != 3'd5) && (w_j >= strip_w(w_k) - OVL);
    wire       head = (w_k != 3'd0) && (w_j < OVL);
    always @(posedge clk) begin
        if (rst || (state == E_IDLE)) begin
            seam_wr <= 5'd0; seam_rd <= 5'd0; c_v <= 1'b0;
        end else begin
            c_v <= w_v;
            if (w_v && tail) begin
                seam[seam_wr] <= w_px;
                seam_wr <= (seam_wr == OVL - 1) ? 5'd0 : seam_wr + 5'd1;
            end
            if (w_v && head)
                seam_rd <= (seam_rd == OVL - 1) ? 5'd0 : seam_rd + 5'd1;
        end
        c_out   <= !tail;
        c_blend <= head;
        c_bad   <= w_bad;
        c_last  <= w_last;
        c_a     <= head ? seam[seam_rd] : w_px;
        c_b     <= w_px;
        c_pa    <= head ? present[w_k - 3'd1] : present[w_k];
        c_pb    <= present[w_k];
        c_fy    <= alpha_y[w_j[4:0]];
        c_fc    <= alpha_c[(w_j > 10'd15) ? 4'd7 : w_j[4:1]];
    end

    function [32:0] wacc;
        input [7:0] a, b;
        input [15:0] f;
        begin
            wacc = ({1'b0, a} * (17'd65536 - {1'b0, f})) + ({1'b0, b} * {1'b0, f}) + 33'd32768;
        end
    endfunction
    reg        d_v, d_out, d_blend, d_bad, d_last, d_pa, d_pb;
    reg [15:0] d_a;
    reg [32:0] d_y, d_c;
    always @(posedge clk) begin
        d_v <= rst ? 1'b0 : c_v;
        d_out <= c_out; d_blend <= c_blend; d_bad <= c_bad; d_last <= c_last;
        d_pa <= c_pa; d_pb <= c_pb; d_a <= c_a;
        d_y <= wacc(c_a[15:8], c_b[15:8], c_fy);
        d_c <= wacc(c_a[7:0],  c_b[7:0],  c_fc);
    end

    reg        e_v, e_last;
    reg [15:0] e_px;
    always @(posedge clk) begin
        e_v    <= !rst && d_v && d_out;
        e_last <= d_last;
        if (d_bad || !d_pa)          e_px <= BLACK;
        else if (d_blend && d_pb)    e_px <= {d_y[23:16], d_c[23:16]};
        else                         e_px <= d_a;
    end

    //------------------------------------------------------------------------
    // Output FIFO (16 entries)
    //------------------------------------------------------------------------
    reg [16:0] ofifo [0:15];
    reg [3:0]  o_wr, o_rd;
    wire       o_pop = (ocount != 0) && px_ready;
    assign px_valid = (ocount != 0);
    assign px_data  = ofifo[o_rd][15:0];
    always @(posedge clk) begin
        if (rst) begin
            o_wr <= 4'd0; o_rd <= 4'd0; ocount <= 5'd0; frame_done <= 1'b0;
        end else begin
            frame_done <= 1'b0;
            if (e_v) begin
                ofifo[o_wr] <= {e_last, e_px};
                o_wr <= o_wr + 4'd1;
            end
            if (o_pop) begin
                o_rd <= o_rd + 4'd1;
                if (ofifo[o_rd][16]) frame_done <= 1'b1;
            end
            ocount <= ocount + (e_v ? 5'd1 : 5'd0) - (o_pop ? 5'd1 : 5'd0);
        end
    end
endmodule
