`timescale 1ns/1ps
// Freeze one source-frame pose/control/static-trim snapshot and produce all six
// camera roll/pitch values atomically. Inputs/outputs are signed centidegrees;
// camera 0 occupies bits [15:0] of each packed bus.
//
// Enabled: exact original C camera projection and one-pass GLOBAL live R/P
// rescaling if either live angle is nonzero and any camera angle exceeds 1000.
// Static trims are never scaled. Recalculate all six cameras after a limit.
// A final value may still exceed +/-1000; out_of_range reports that condition
// without silently changing the C result. The downstream safety clamp is a
// separate policy. Sensor yaw is absent from the current I2C pose contract.
//
// Disabled: return the captured static R/P bit-for-bit, applied pose zero,
// limited=0. This deliberate C bypass preserves existing manual-offset behavior.
// Enabled zero-live cases still execute C math, including its trim quantization.
//
// Yaw constants come from the selected mounting profile only. No optical maps,
// resize factors, pitch-to-pixel factors, stale-data or exposure policy are used.
// start is accepted only while !busy; busy starts are ignored. Outputs retain
// the prior complete set until a one-cycle done. Synchronous reset aborts work.
// Scaling uses bounded 32-cycle restoring division, never a combinational /.
module GlFramePose #(
    parameter ANGLE_ROM_FILE = "reference/gravity_math/angle_centi_q15.mem",
    parameter ATAN_ROM_FILE = "reference/gravity_math/atan_ratio_centi.mem"
) (
    input  wire               clk,
    input  wire               rst,
    input  wire               start,
    input  wire               enable,
    input  wire               sensor_ir,
    input  wire signed [15:0]  sensor_roll_cd,
    input  wire signed [15:0]  sensor_pitch_cd,
    input  wire [95:0]         static_roll_cd,
    input  wire [95:0]         static_pitch_cd,
    output reg                busy,
    output reg                done,
    output reg  [95:0]         camera_roll_cd,
    output reg  [95:0]         camera_pitch_cd,
    output reg  signed [15:0]  applied_roll_cd,
    output reg  signed [15:0]  applied_pitch_cd,
    output reg                limited,
    output reg                out_of_range
);
    localparam [3:0] S_IDLE = 0, S_BYPASS = 1, S_LAUNCH = 2,
        S_WAIT = 3, S_DECIDE = 4, S_SCALE_LOAD = 5, S_SCALE_STEP = 6,
        S_SCALE_STORE = 7, S_COMMIT = 8;
    reg [3:0] state;
    reg ir_l;
    reg [95:0] static_roll_l, static_pitch_l;
    reg signed [31:0] work_roll, work_pitch;
    reg [2:0] camera_index;
    reg final_pass;
    reg [15:0] maximum_angle;
    reg [95:0] pending_roll, pending_pitch;
    reg pending_limited, pending_out_of_range;

    function signed [31:0] mount_yaw;
        input ir;
        input [2:0] cam;
        begin
            case (cam)
                0: mount_yaw = ir ? 32'sd9000  : 32'sd0;
                1: mount_yaw = ir ? 32'sd15000 : 32'sd6000;
                2: mount_yaw = ir ? 32'sd21000 : 32'sd12000;
                3: mount_yaw = ir ? 32'sd27000 : 32'sd18000;
                4: mount_yaw = ir ? 32'sd33000 : 32'sd24000;
                default: mount_yaw = ir ? 32'sd39000 : 32'sd30000;
            endcase
        end
    endfunction

    function packed_out_of_range;
        input [95:0] rolls;
        input [95:0] pitches;
        integer cam;
        reg signed [15:0] r, p;
        begin
            packed_out_of_range = 1'b0;
            for (cam = 0; cam < 6; cam = cam + 1) begin
                r = rolls[cam*16 +: 16];
                p = pitches[cam*16 +: 16];
                if (r > 16'sd1000 || r < -16'sd1000 || p > 16'sd1000 || p < -16'sd1000)
                    packed_out_of_range = 1'b1;
            end
        end
    endfunction

    wire signed [15:0] selected_static_roll = static_roll_l[camera_index*16 +: 16];
    wire signed [15:0] selected_static_pitch = static_pitch_l[camera_index*16 +: 16];
    reg projection_start;
    wire projection_busy, projection_done;
    wire signed [31:0] projected_roll, projected_pitch, projected_yaw;
    GlCameraProjection #(.ANGLE_ROM_FILE(ANGLE_ROM_FILE), .ATAN_ROM_FILE(ATAN_ROM_FILE)) u_projection (
        .clk(clk), .rst(rst), .start(projection_start),
        .sensor_roll_cd(work_roll), .sensor_pitch_cd(work_pitch),
        .mount_yaw_cd(mount_yaw(ir_l, camera_index)),
        .mount_pitch_cd({{16{selected_static_pitch[15]}}, selected_static_pitch}),
        .mount_roll_cd({{16{selected_static_roll[15]}}, selected_static_roll}),
        .busy(projection_busy), .done(projection_done),
        .camera_roll_cd(projected_roll), .camera_pitch_cd(projected_pitch),
        .camera_yaw_cd(projected_yaw)
    );
    wire [31:0] abs_projected_roll = projected_roll[31] ? -projected_roll : projected_roll;
    wire [31:0] abs_projected_pitch = projected_pitch[31] ? -projected_pitch : projected_pitch;
    wire [31:0] projected_maximum = (abs_projected_roll > abs_projected_pitch)
        ? abs_projected_roll : abs_projected_pitch;
    wire projected_out_of_range = (abs_projected_roll > 32'd1000) || (abs_projected_pitch > 32'd1000);

    reg scale_pitch, division_negative;
    reg [31:0] division_shift, quotient;
    reg [15:0] remainder, divisor;
    reg [5:0] bit_count;
    wire signed [31:0] scale_value = scale_pitch ? work_pitch : work_roll;
    wire [31:0] scale_magnitude = scale_value[31] ? -scale_value : scale_value;
    // Inputs originated as signed16: |v|*1000 + max/2 fits unsigned32.
    wire [31:0] rounded_numerator = scale_magnitude * 32'd1000 + {17'd0, maximum_angle[15:1]};
    wire [16:0] division_trial = {remainder, division_shift[31]};
    wire [16:0] division_difference = division_trial - {1'b0, divisor};
    wire signed [31:0] signed_quotient = division_negative ? -$signed(quotient) : $signed(quotient);

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE;
            busy <= 1'b0; done <= 1'b0; projection_start <= 1'b0;
            camera_roll_cd <= 96'd0; camera_pitch_cd <= 96'd0;
            applied_roll_cd <= 16'sd0; applied_pitch_cd <= 16'sd0;
            limited <= 1'b0; out_of_range <= 1'b0;
        end else begin
            done <= 1'b0;
            projection_start <= 1'b0;
            case (state)
                S_IDLE: if (start) begin
                    ir_l <= sensor_ir;
                    static_roll_l <= static_roll_cd;
                    static_pitch_l <= static_pitch_cd;
                    work_roll <= enable ? {{16{sensor_roll_cd[15]}}, sensor_roll_cd} : 32'sd0;
                    work_pitch <= enable ? {{16{sensor_pitch_cd[15]}}, sensor_pitch_cd} : 32'sd0;
                    camera_index <= 3'd0; final_pass <= 1'b0;
                    maximum_angle <= 16'd0;
                    pending_roll <= 96'd0; pending_pitch <= 96'd0;
                    pending_limited <= 1'b0; pending_out_of_range <= 1'b0;
                    busy <= 1'b1;
                    state <= enable ? S_LAUNCH : S_BYPASS;
                end
                S_BYPASS: begin
                    camera_roll_cd <= static_roll_l;
                    camera_pitch_cd <= static_pitch_l;
                    applied_roll_cd <= 16'sd0; applied_pitch_cd <= 16'sd0;
                    limited <= 1'b0;
                    out_of_range <= packed_out_of_range(static_roll_l, static_pitch_l);
                    busy <= 1'b0; done <= 1'b1;
                    state <= S_IDLE;
                end
                S_LAUNCH: begin
                    projection_start <= 1'b1;
                    state <= S_WAIT;
                end
                S_WAIT: if (projection_done) begin
                    pending_roll[camera_index*16 +: 16] <= projected_roll[15:0];
                    pending_pitch[camera_index*16 +: 16] <= projected_pitch[15:0];
                    pending_out_of_range <= pending_out_of_range || projected_out_of_range;
                    if (!final_pass && projected_maximum > {16'd0, maximum_angle})
                        maximum_angle <= projected_maximum[15:0];
                    if (camera_index == 5) state <= S_DECIDE;
                    else begin camera_index <= camera_index + 3'd1; state <= S_LAUNCH; end
                end
                S_DECIDE: begin
                    if (!final_pass && (work_roll != 0 || work_pitch != 0) && maximum_angle > 16'd1000) begin
                        pending_limited <= 1'b1;
                        scale_pitch <= 1'b0;
                        state <= S_SCALE_LOAD;
                    end else state <= S_COMMIT;
                end
                S_SCALE_LOAD: begin
                    division_negative <= scale_value[31];
                    division_shift <= rounded_numerator;
                    divisor <= maximum_angle;
                    remainder <= 16'd0; quotient <= 32'd0;
                    bit_count <= 6'd31;
                    state <= S_SCALE_STEP;
                end
                S_SCALE_STEP: begin
                    division_shift <= {division_shift[30:0], 1'b0};
                    if (division_trial >= {1'b0, divisor}) begin
                        remainder <= division_difference[15:0];
                        quotient <= {quotient[30:0], 1'b1};
                    end else begin
                        remainder <= division_trial[15:0];
                        quotient <= {quotient[30:0], 1'b0};
                    end
                    bit_count <= bit_count - 6'd1;
                    if (bit_count == 0) state <= S_SCALE_STORE;
                end
                S_SCALE_STORE: begin
                    if (!scale_pitch) begin
                        work_roll <= signed_quotient;
                        scale_pitch <= 1'b1;
                        state <= S_SCALE_LOAD;
                    end else begin
                        work_pitch <= signed_quotient;
                        final_pass <= 1'b1;
                        camera_index <= 3'd0;
                        pending_out_of_range <= 1'b0;
                        state <= S_LAUNCH;
                    end
                end
                S_COMMIT: begin
                    camera_roll_cd <= pending_roll;
                    camera_pitch_cd <= pending_pitch;
                    applied_roll_cd <= work_roll[15:0];
                    applied_pitch_cd <= work_pitch[15:0];
                    limited <= pending_limited;
                    out_of_range <= pending_out_of_range;
                    busy <= 1'b0; done <= 1'b1;
                    state <= S_IDLE;
                end
                default: begin state <= S_IDLE; busy <= 1'b0; end
            endcase
        end
    end
endmodule
