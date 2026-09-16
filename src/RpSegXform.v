//============================================================================
// RpSegXform
//
// Applies one camera's static roll/pitch offset to one RowRun segment and
// derives everything the source-driven renderer needs to walk it.  Six
// registered stages, no back-pressure: in_valid is carried as out_valid.
//
//   dx = ax0 - CX                dy = ay0 + (ysh<<16) - CY
//   A_x = ((c*dx + s*dy) >>> 15) + CX
//   A_y = ((-s*dx + c*dy) >>> 15) + CY
//   D_x = (c*(dax<<11) + s*(day<<11)) >>> 15
//   D_y = (-s*(dax<<11) + c*(day<<11)) >>> 15
//
// The segment is walked in the direction of increasing source y
// (dir = D_y >= 0), so sched_y = clamp(floor(ay)) is monotone along the walk:
//   i0     = dir ? 0 : last          start pixel index
//   (ax,ay)= A + i0*D                start accumulators
//   step   = dir ? D : -D
//   st, en = clamp(floor(ay)) at the first and last walked pixel, 0..YMAX
//   xa, xb = clamp(floor(ax)) at pixel 0 and pixel last, 0..XMAX
//
// model/golden.py build_tables() is the reference; the table-builder bench
// compares the result entry by entry.
//============================================================================
`timescale 1ns/1ps
module RpSegXform #(
    parameter integer SRC_W = 1920,
    parameter integer SRC_H = 1080,
    parameter integer DRUN_TO_Q16 = 11
) (
    input  wire               clk,
    input  wire               in_valid,
    input  wire signed [31:0] in_ax0,
    input  wire signed [31:0] in_ay0,
    input  wire signed [15:0] in_dax,
    input  wire signed [15:0] in_day,
    input  wire [5:0]         in_last,     // segment length - 1
    input  wire signed [17:0] in_c,        // 0..32768
    input  wire signed [16:0] in_s,        // -32767..32767
    input  wire signed [7:0]  in_ysh,      // rows
    input  wire [22:0]        in_tag,      // carried untouched (sy, cam, seg ...)

    output reg                out_valid,
    output reg  [22:0]        out_tag,
    output reg  [5:0]         out_i0,
    output reg                out_dir,
    output reg  [5:0]         out_last,
    output reg  signed [31:0] out_ax,
    output reg  signed [31:0] out_ay,
    output reg  signed [23:0] out_stx,
    output reg  signed [23:0] out_sty,
    output reg  [10:0]        out_st,
    output reg  [10:0]        out_en,
    output reg  [10:0]        out_xa,
    output reg  [10:0]        out_xb,
    output reg                out_sat      // a step or accumulator did not fit
);
    localparam signed [31:0] CX = SRC_W <<< 15;
    localparam signed [31:0] CY = SRC_H <<< 15;
    localparam integer XMAX = SRC_W - 2;
    localparam integer YMAX = SRC_H - 2;

    function [10:0] clamp_floor;
        input signed [47:0] v;
        input integer       vmax;
        reg signed [47:0]   f;
        begin
            f = v >>> 16;
            if (v < 0)          clamp_floor = 11'd0;
            else if (f > vmax)  clamp_floor = vmax[10:0];
            else                clamp_floor = f[10:0];
        end
    endfunction

    // ---- stage 1: centre and widen --------------------------------------
    reg               v1;
    reg [22:0]        tag1;
    reg [5:0]         last1;
    reg signed [26:0] dx1, dy1, dax1, day1;
    reg signed [17:0] c1;
    reg signed [16:0] s1;
    always @(posedge clk) begin
        v1    <= in_valid;
        tag1  <= in_tag;
        last1 <= in_last;
        dx1   <= in_ax0 - CX;
        dy1   <= in_ay0 + ($signed({{8{in_ysh[7]}}, in_ysh}) <<< 16) - CY;
        dax1  <= $signed(in_dax) <<< DRUN_TO_Q16;
        day1  <= $signed(in_day) <<< DRUN_TO_Q16;
        c1    <= in_c;
        s1    <= in_s;
    end

    // ---- stage 2: eight products (DSP) ------------------------------------
    reg               v2;
    reg [22:0]        tag2;
    reg [5:0]         last2;
    reg signed [44:0] p_cdx, p_sdy, p_sdx, p_cdy, p_cdax, p_sday, p_sdax, p_cday;
    always @(posedge clk) begin
        v2     <= v1;
        tag2   <= tag1;
        last2  <= last1;
        p_cdx  <= c1 * dx1;
        p_sdy  <= s1 * dy1;
        p_sdx  <= s1 * dx1;
        p_cdy  <= c1 * dy1;
        p_cdax <= c1 * dax1;
        p_sday <= s1 * day1;
        p_sdax <= s1 * dax1;
        p_cday <= c1 * day1;
    end

    // ---- stage 3: rotate --------------------------------------------------
    reg               v3;
    reg [22:0]        tag3;
    reg [5:0]         last3;
    reg signed [45:0] sum_ax, sum_ay, sum_dx, sum_dy;
    always @(posedge clk) begin
        v3     <= v2;
        tag3   <= tag2;
        last3  <= last2;
        sum_ax <= p_cdx + p_sdy;
        sum_ay <= p_cdy - p_sdx;
        sum_dx <= p_cdax + p_sday;
        sum_dy <= p_cday - p_sdax;
    end

    reg               v4;
    reg [22:0]        tag4;
    reg [5:0]         last4;
    reg signed [47:0] Ax4, Ay4, Dx4, Dy4;
    always @(posedge clk) begin
        v4    <= v3;
        tag4  <= tag3;
        last4 <= last3;
        Ax4   <= (sum_ax >>> 15) + CX;
        Ay4   <= (sum_ay >>> 15) + CY;
        Dx4   <= sum_dx >>> 15;
        Dy4   <= sum_dy >>> 15;
    end

    // ---- stage 5: end point = A + last*D ---------------------------------
    reg               v5;
    reg [22:0]        tag5;
    reg [5:0]         last5;
    reg signed [47:0] Ax5, Ay5, Dx5, Dy5, Ex5, Ey5;
    always @(posedge clk) begin
        v5    <= v4;
        tag5  <= tag4;
        last5 <= last4;
        Ax5   <= Ax4;
        Ay5   <= Ay4;
        Dx5   <= Dx4;
        Dy5   <= Dy4;
        Ex5   <= Ax4 + $signed({1'b0, last4}) * Dx4;
        Ey5   <= Ay4 + $signed({1'b0, last4}) * Dy4;
    end

    // ---- stage 6: orient the walk and clamp ------------------------------
    wire               dir5  = !Dy5[47];
    wire signed [47:0] sax5  = dir5 ? Ax5 : Ex5;
    wire signed [47:0] say5  = dir5 ? Ay5 : Ey5;
    wire signed [47:0] eay5  = dir5 ? Ey5 : Ay5;
    wire signed [47:0] stx5  = dir5 ? Dx5 : -Dx5;
    wire signed [47:0] sty5  = dir5 ? Dy5 : -Dy5;
    wire sat5 = (sax5 < -48'sd2147483648) || (sax5 > 48'sd2147483647) ||
                (say5 < -48'sd2147483648) || (say5 > 48'sd2147483647) ||
                (stx5 < -48'sd8388608)    || (stx5 > 48'sd8388607) ||
                (sty5 < -48'sd8388608)    || (sty5 > 48'sd8388607);
    always @(posedge clk) begin
        out_valid <= v5;
        out_tag   <= tag5;
        out_last  <= last5;
        out_dir   <= dir5;
        out_i0    <= dir5 ? 6'd0 : last5;
        out_ax    <= sax5[31:0];
        out_ay    <= say5[31:0];
        out_stx   <= stx5[23:0];
        out_sty   <= sty5[23:0];
        out_st    <= clamp_floor(say5, YMAX);
        out_en    <= clamp_floor(eay5, YMAX);
        out_xa    <= clamp_floor(Ax5, XMAX);
        out_xb    <= clamp_floor(Ex5, XMAX);
        out_sat   <= sat5;
    end
endmodule
