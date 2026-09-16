//============================================================================
// RpOffsetSync
//
// Brings the I2C register file's per-camera roll/pitch bytes into ui_clk.
//
// The firmware (fpga_push_bank) writes the bank one byte at a time with a
// read-back verify, so for tens of milliseconds the register file holds a mix
// of old and new bytes -- a torn int16 can be several degrees wrong.  Every
// new value therefore has to be unchanged for STABLE_CYCLES (default 2^25,
// ~144 ms at 233 MHz) before it is passed on, and only then does the
// renderer rebuild its tables.
//
// Values are clamped to +-ANGLE_MAX centi-degrees here as well as in the
// table builder.
//============================================================================
`timescale 1ns/1ps
module RpOffsetSync #(
    parameter integer STABLE_LOG2 = 25,
    parameter integer ANGLE_MAX   = 1000
) (
    input  wire         clk,
    input  wire         rst,
    input  wire [95:0]  roll_raw,      // asynchronous, cam0 in [15:0]
    input  wire [95:0]  pitch_raw,
    output reg  [95:0]  roll_cd,
    output reg  [95:0]  pitch_cd,
    output reg  [15:0]  update_count
);
    (* ASYNC_REG = "TRUE" *) reg [191:0] meta;
    (* ASYNC_REG = "TRUE" *) reg [191:0] sync;
    reg [191:0] cand;
    reg [STABLE_LOG2:0] stable;

    function [15:0] clamp;
        input signed [15:0] v;
        begin
            if (v > ANGLE_MAX)       clamp = ANGLE_MAX;
            else if (v < -ANGLE_MAX) clamp = -ANGLE_MAX;
            else                     clamp = v;
        end
    endfunction

    reg [191:0] cand_clamped;
    integer i;
    always @* begin
        for (i = 0; i < 12; i = i + 1)
            cand_clamped[i*16 +: 16] = clamp(cand[i*16 +: 16]);
    end

    always @(posedge clk) begin
        meta <= {pitch_raw, roll_raw};
        sync <= meta;
        if (rst) begin
            cand <= 192'd0; stable <= 0;
            roll_cd <= 96'd0; pitch_cd <= 96'd0; update_count <= 16'd0;
        end else begin
            if (sync != cand) begin
                cand   <= sync;
                stable <= 0;
            end else if (!stable[STABLE_LOG2]) begin
                stable <= stable + 1'b1;
            end else if (cand_clamped != {pitch_cd, roll_cd}) begin
                {pitch_cd, roll_cd} <= cand_clamped;
                update_count <= update_count + 16'd1;
            end
        end
    end
endmodule
