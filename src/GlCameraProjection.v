`timescale 1ns/1ps
// Bit-exact integer port of convert_rpy_sensor_to_cam_centi in the extracted
// C++ oracle (reference/gravity_math/source_functions.inc).
//
// Accept start only while !busy, freezing all five signed centidegree inputs.
// Output R/P/Y are updated together with a one-cycle done pulse. A start while
// busy is ignored. Reset aborts work and clears outputs. This unit performs no
// global angle limiting, camera trim selection, freshness check, or pixel map.
//
// R = (Rx(sensor roll) * Ry(sensor pitch)) *
//     ((Rz(mount yaw) * Ry(mount pitch)) * Rx(mount roll)).
// Each of the FOUR matrix products rounds and saturates independently, using
// Q15 unity 32767 and (sum + 16384) >>> 15 even for negative sums.
//
// Integer angle normalization and atan ratios use one restoring-division bit
// per cycle; square root uses a three-cycle restoring step. No combinational
// divider/modulo or variable-length combinational loop is inferred. Products
// and accumulators are registered separately. Latency is at most 601 cycles
// from accepted start to done (about 2.58 us at 233 MHz), shorter for atan axes.
// This is an RTL cycle bound, not a claim of routed timing closure.
//
// ROM formats: trig[31:16] = signed cos, trig[15:0] = signed sin (36000 rows);
// atan = unsigned centidegrees for ratios 0..4096 inclusive (4097 rows).
module GlCameraProjection #(
    parameter ANGLE_ROM_FILE = "reference/gravity_math/angle_centi_q15.mem",
    parameter ATAN_ROM_FILE = "reference/gravity_math/atan_ratio_centi.mem"
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire signed [31:0] sensor_roll_cd,
    input  wire signed [31:0] sensor_pitch_cd,
    input  wire signed [31:0] mount_yaw_cd,
    input  wire signed [31:0] mount_pitch_cd,
    input  wire signed [31:0] mount_roll_cd,
    output reg                busy,
    output reg                done,
    output reg  signed [31:0] camera_roll_cd,
    output reg  signed [31:0] camera_pitch_cd,
    output reg  signed [31:0] camera_yaw_cd
);
    (* rom_style = "block" *) reg [31:0] angle_rom [0:35999];
    (* rom_style = "block" *) reg [15:0] atan_rom [0:4096];
    reg [15:0] angle_addr;
    reg [12:0] atan_addr;
    reg [31:0] angle_q;
    reg [15:0] atan_q;
    initial begin
        $readmemh(ANGLE_ROM_FILE, angle_rom);
        $readmemh(ATAN_ROM_FILE, atan_rom);
    end
    always @(posedge clk) begin
        angle_q <= angle_rom[angle_addr];
        atan_q <= atan_rom[atan_addr];
    end

    localparam [4:0]
        S_IDLE = 0, S_NORM_LOAD = 1, S_NORM_STEP = 2, S_NORM_ADDR = 3,
        S_NORM_WAIT = 4, S_NORM_CAP = 5, S_MAT_LOAD = 6, S_MAT_MUL = 7,
        S_MAT_ACC = 8, S_MAT_STORE = 9, S_ASIN_CLAMP = 10,
        S_ASIN_SQUARE = 11, S_ROOT_INIT = 12, S_ROOT_TRIAL = 13,
        S_ROOT_DIFF = 14, S_ROOT_UPDATE = 15, S_ROOT_DONE = 16,
        S_ATAN_INIT = 17, S_DIV_STEP = 18, S_ATAN_ADDR = 19,
        S_ATAN_WAIT = 20, S_ATAN_CAP = 21, S_ATAN_QUAD = 22,
        S_PITCH_WAIT = 23, S_PITCH_CAP = 24;
    reg [4:0] state;

    reg signed [31:0] angles [0:4];
    reg signed [15:0] cosine [0:4];
    reg signed [15:0] sine [0:4];
    reg [2:0] norm_index;
    reg [31:0] norm_shift;
    reg [15:0] norm_rem;
    reg norm_negative;
    reg [5:0] bit_count;
    wire [16:0] norm_trial = {norm_rem, norm_shift[31]};
    wire [16:0] norm_sub = norm_trial - 17'd36000;

    reg signed [15:0] mat_a [0:8];
    reg signed [15:0] mat_b [0:8];
    reg signed [15:0] mat_result [0:8];
    reg signed [15:0] mat_system [0:8];
    reg [1:0] mat_stage, mat_col, mat_k;
    reg [3:0] mat_row_base;
    reg signed [31:0] product;
    reg signed [35:0] accumulator;
    wire [3:0] mat_a_index = mat_row_base + {2'd0, mat_k};
    wire [3:0] mat_b_index = ({2'd0, mat_k} * 4'd3) + {2'd0, mat_col};
    wire [3:0] mat_out_index = mat_row_base + {2'd0, mat_col};

    function signed [15:0] round_clamp_q15;
        input signed [35:0] value;
        reg signed [35:0] rounded;
        begin
            rounded = (value + 36'sd16384) >>> 15;
            if (rounded > 36'sd32767) round_clamp_q15 = 16'sh7fff;
            else if (rounded < -36'sd32768) round_clamp_q15 = 16'sh8000;
            else round_clamp_q15 = rounded[15:0];
        end
    endfunction

    reg signed [15:0] asin_v;
    reg [31:0] asin_square;
    reg [31:0] root_rem, root_res, root_bit, root_trial;
    reg [32:0] root_diff;
    wire signed [16:0] neg_r20 = -$signed({mat_result[6][15], mat_result[6]});

    // atan arguments are bounded by the matrix/Q15 sqrt domain, [-32768,32768].
    reg signed [31:0] atan_x, atan_y;
    reg [1:0] atan_kind; // 0 pitch (asin), 1 roll, 2 yaw
    reg atan_swap;
    reg [15:0] divisor;
    reg [31:0] div_shift, quotient;
    reg [15:0] div_rem;
    reg signed [31:0] atan_base;
    reg signed [31:0] pending_roll, pending_pitch;
    wire [31:0] abs_x = atan_x[31] ? -atan_x : atan_x;
    wire [31:0] abs_y = atan_y[31] ? -atan_y : atan_y;
    wire [31:0] atan_min = (abs_y <= abs_x) ? abs_y : abs_x;
    wire [31:0] atan_max = (abs_y <= abs_x) ? abs_x : abs_y;
    wire [16:0] div_trial = {div_rem, div_shift[31]};
    wire [16:0] div_sub = div_trial - {1'b0, divisor};
    wire signed [31:0] atan_result = !atan_x[31]
        ? (atan_y[31] ? -atan_base : atan_base)
        : (atan_y[31] ? atan_base - 32'sd18000 : 32'sd18000 - atan_base);
    wire signed [15:0] pitch_cos = angle_q[31:16];

    integer i;
    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            busy <= 1'b0; done <= 1'b0;
            camera_roll_cd <= 32'sd0;
            camera_pitch_cd <= 32'sd0;
            camera_yaw_cd <= 32'sd0;
            angle_addr <= 16'd0; atan_addr <= 13'd0;
        end else begin
            done <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    angles[0] <= sensor_roll_cd;
                    angles[1] <= sensor_pitch_cd;
                    angles[2] <= mount_yaw_cd;
                    angles[3] <= mount_pitch_cd;
                    angles[4] <= mount_roll_cd;
                    busy <= 1'b1;
                    norm_index <= 3'd0;
                    state <= S_NORM_LOAD;
                end
                S_NORM_LOAD: begin
                    // 32-bit unsigned magnitude also represents abs(INT32_MIN).
                    norm_shift <= angles[norm_index][31] ? -angles[norm_index] : angles[norm_index];
                    norm_negative <= angles[norm_index][31];
                    norm_rem <= 16'd0;
                    bit_count <= 6'd31;
                    state <= S_NORM_STEP;
                end
                S_NORM_STEP: begin
                    norm_shift <= {norm_shift[30:0], 1'b0};
                    norm_rem <= (norm_trial >= 17'd36000) ? norm_sub[15:0] : norm_trial[15:0];
                    bit_count <= bit_count - 6'd1;
                    if (bit_count == 0) state <= S_NORM_ADDR;
                end
                S_NORM_ADDR: begin
                    angle_addr <= (norm_negative && norm_rem != 0) ? 16'd36000 - norm_rem : norm_rem;
                    state <= S_NORM_WAIT;
                end
                S_NORM_WAIT: state <= S_NORM_CAP;
                S_NORM_CAP: begin
                    cosine[norm_index] <= angle_q[31:16];
                    sine[norm_index] <= angle_q[15:0];
                    if (norm_index == 4) begin
                        mat_stage <= 2'd0;
                        state <= S_MAT_LOAD;
                    end else begin
                        norm_index <= norm_index + 3'd1;
                        state <= S_NORM_LOAD;
                    end
                end
                S_MAT_LOAD: begin
                    for (i = 0; i < 9; i = i + 1) begin
                        mat_a[i] <= 16'sd0;
                        mat_b[i] <= 16'sd0;
                    end
                    case (mat_stage)
                        2'd0: begin // Rx(sensor roll) * Ry(sensor pitch)
                            mat_a[0] <= 16'sd32767;
                            mat_a[4] <= cosine[0]; mat_a[5] <= -sine[0];
                            mat_a[7] <= sine[0]; mat_a[8] <= cosine[0];
                            mat_b[0] <= cosine[1]; mat_b[2] <= sine[1];
                            mat_b[4] <= 16'sd32767;
                            mat_b[6] <= -sine[1]; mat_b[8] <= cosine[1];
                        end
                        2'd1: begin // Rz(mount yaw) * Ry(mount pitch)
                            mat_a[0] <= cosine[2]; mat_a[1] <= -sine[2];
                            mat_a[3] <= sine[2]; mat_a[4] <= cosine[2];
                            mat_a[8] <= 16'sd32767;
                            mat_b[0] <= cosine[3]; mat_b[2] <= sine[3];
                            mat_b[4] <= 16'sd32767;
                            mat_b[6] <= -sine[3]; mat_b[8] <= cosine[3];
                        end
                        2'd2: begin // Rt * Rx(mount roll)
                            for (i = 0; i < 9; i = i + 1) mat_a[i] <= mat_result[i];
                            mat_b[0] <= 16'sd32767;
                            mat_b[4] <= cosine[4]; mat_b[5] <= -sine[4];
                            mat_b[7] <= sine[4]; mat_b[8] <= cosine[4];
                        end
                        2'd3: begin // Rsys * Roff
                            for (i = 0; i < 9; i = i + 1) begin
                                mat_a[i] <= mat_system[i];
                                mat_b[i] <= mat_result[i];
                            end
                        end
                    endcase
                    mat_row_base <= 4'd0; mat_col <= 2'd0; mat_k <= 2'd0;
                    accumulator <= 36'sd0;
                    state <= S_MAT_MUL;
                end
                S_MAT_MUL: begin
                    product <= $signed(mat_a[mat_a_index]) * $signed(mat_b[mat_b_index]);
                    state <= S_MAT_ACC;
                end
                S_MAT_ACC: begin
                    accumulator <= accumulator + {{4{product[31]}}, product};
                    if (mat_k == 2) state <= S_MAT_STORE;
                    else begin mat_k <= mat_k + 2'd1; state <= S_MAT_MUL; end
                end
                S_MAT_STORE: begin
                    mat_result[mat_out_index] <= round_clamp_q15(accumulator);
                    if (mat_stage == 0) mat_system[mat_out_index] <= round_clamp_q15(accumulator);
                    accumulator <= 36'sd0; mat_k <= 2'd0;
                    if (mat_col != 2) begin
                        mat_col <= mat_col + 2'd1;
                        state <= S_MAT_MUL;
                    end else if (mat_row_base != 6) begin
                        mat_col <= 2'd0; mat_row_base <= mat_row_base + 4'd3;
                        state <= S_MAT_MUL;
                    end else if (mat_stage != 3) begin
                        mat_stage <= mat_stage + 2'd1;
                        state <= S_MAT_LOAD;
                    end else state <= S_ASIN_CLAMP;
                end
                S_ASIN_CLAMP: begin
                    if (neg_r20 > 17'sd32767) asin_v <= 16'sd32767;
                    else if (neg_r20 < -17'sd32767) asin_v <= -16'sd32767;
                    else asin_v <= neg_r20[15:0];
                    state <= S_ASIN_SQUARE;
                end
                S_ASIN_SQUARE: begin
                    asin_square <= asin_v * asin_v;
                    state <= S_ROOT_INIT;
                end
                S_ROOT_INIT: begin
                    // Clamping asin_v proves its square <= 2^30.
                    root_rem <= 32'h40000000 - asin_square;
                    root_res <= 32'd0;
                    root_bit <= 32'h40000000;
                    state <= S_ROOT_TRIAL;
                end
                S_ROOT_TRIAL: begin
                    root_trial <= root_res + root_bit;
                    state <= S_ROOT_DIFF;
                end
                S_ROOT_DIFF: begin
                    root_diff <= {1'b0, root_rem} - {1'b0, root_trial};
                    state <= S_ROOT_UPDATE;
                end
                S_ROOT_UPDATE: begin
                    if (!root_diff[32]) begin
                        root_rem <= root_diff[31:0];
                        root_res <= (root_res >> 1) + root_bit;
                    end else root_res <= root_res >> 1;
                    root_bit <= root_bit >> 2;
                    state <= (root_bit == 1) ? S_ROOT_DONE : S_ROOT_TRIAL;
                end
                S_ROOT_DONE: begin
                    atan_y <= {{16{asin_v[15]}}, asin_v};
                    atan_x <= $signed(root_res);
                    atan_kind <= 2'd0;
                    state <= S_ATAN_INIT;
                end
                S_ATAN_INIT: begin
                    if ((atan_x == 0) && (atan_y == 0)) begin
                        atan_base <= 32'sd0;
                        state <= S_ATAN_QUAD;
                    end else if (atan_x == 0) begin
                        atan_base <= 32'sd9000;
                        state <= S_ATAN_QUAD;
                    end else begin
                        atan_swap <= abs_y > abs_x;
                        divisor <= atan_max[15:0];
                        div_shift <= (atan_min << 12) + (atan_max >> 1);
                        div_rem <= 16'd0; quotient <= 32'd0;
                        bit_count <= 6'd31;
                        state <= S_DIV_STEP;
                    end
                end
                S_DIV_STEP: begin
                    div_shift <= {div_shift[30:0], 1'b0};
                    if (div_trial >= {1'b0, divisor}) begin
                        div_rem <= div_sub[15:0];
                        quotient <= {quotient[30:0], 1'b1};
                    end else begin
                        div_rem <= div_trial[15:0];
                        quotient <= {quotient[30:0], 1'b0};
                    end
                    bit_count <= bit_count - 6'd1;
                    if (bit_count == 0) state <= S_ATAN_ADDR;
                end
                S_ATAN_ADDR: begin
                    atan_addr <= (quotient > 32'd4096) ? 13'd4096 : quotient[12:0];
                    state <= S_ATAN_WAIT;
                end
                S_ATAN_WAIT: state <= S_ATAN_CAP;
                S_ATAN_CAP: begin
                    atan_base <= atan_swap ? 32'sd9000 - $signed({16'd0, atan_q})
                                           : $signed({16'd0, atan_q});
                    state <= S_ATAN_QUAD;
                end
                S_ATAN_QUAD: begin
                    case (atan_kind)
                        2'd0: begin
                            pending_pitch <= atan_result;
                            // asin output is already in [-9000,9000].
                            angle_addr <= atan_result[31] ? 32'sd36000 + atan_result : atan_result;
                            state <= S_PITCH_WAIT;
                        end
                        2'd1: begin
                            pending_roll <= atan_result;
                            atan_y <= {{16{mat_result[3][15]}}, mat_result[3]};
                            atan_x <= {{16{mat_result[0][15]}}, mat_result[0]};
                            atan_kind <= 2'd2;
                            state <= S_ATAN_INIT;
                        end
                        default: begin
                            camera_roll_cd <= pending_roll;
                            camera_pitch_cd <= pending_pitch;
                            camera_yaw_cd <= atan_result;
                            busy <= 1'b0; done <= 1'b1;
                            state <= S_IDLE;
                        end
                    endcase
                end
                S_PITCH_WAIT: state <= S_PITCH_CAP;
                S_PITCH_CAP: begin
                    if ((pitch_cos > 16'sd8) || (pitch_cos < -16'sd8)) begin
                        atan_y <= {{16{mat_result[7][15]}}, mat_result[7]};
                        atan_x <= {{16{mat_result[8][15]}}, mat_result[8]};
                        atan_kind <= 2'd1;
                    end else begin
                        pending_roll <= 32'sd0;
                        atan_y <= -$signed({{16{mat_result[1][15]}}, mat_result[1]});
                        atan_x <= {{16{mat_result[4][15]}}, mat_result[4]};
                        atan_kind <= 2'd2;
                    end
                    state <= S_ATAN_INIT;
                end
                default: begin state <= S_IDLE; busy <= 1'b0; end
            endcase
        end
    end
endmodule
