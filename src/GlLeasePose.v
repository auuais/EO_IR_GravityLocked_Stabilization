`timescale 1ns/1ps
// Associate the source frameset lease with its captured pose, then prepare one
// immutable six-camera angle set before the output copy can start. All ports
// are in clk (MIG UI). Epoch association is not an exposure timestamp.
//
// Calibration is captured when a lease is prepared. If the epoch was captured
// under a different calibration revision, use the latest static offsets for
// that pass and report fallback; never silently mix old calibration metadata.
// Missing/stale pose or disabled epoch control also selects exact static bypass.
// MAX_POSE_AGE_CYCLES is a configurable freshness policy (100 ms at233.4MHz by
// default), evaluated at epoch capture, not a measured sensor-latency budget.
// Outputs remain fixed throughout render_active. A lease/mode change outside
// a pass aborts in-flight math and prepares the new lease. rst also aborts.
module GlLeasePose #(
    parameter [31:0] MAX_POSE_AGE_CYCLES = 32'd23340000,
    parameter ANGLE_ROM_FILE = "../../reference/gravity_math/angle_centi_q15.mem",
    parameter ATAN_ROM_FILE = "../../reference/gravity_math/atan_ratio_centi.mem"
) (
    input wire clk, rst,
    input wire epoch_capture,
    input wire [15:0] epoch_id,
    input wire pose_update,
    input wire signed [15:0] pose_roll_cd, pose_pitch_cd,
    input wire [31:0] pose_sequence,
    input wire stabilization_enabled,
    input wire [31:0] calibration_revision,
    input wire panorama_enable, sensor_ir,
    input wire lease_valid,
    input wire [15:0] lease_epoch,
    input wire render_active,
    input wire [95:0] static_roll_cd, static_pitch_cd,
    output wire ready,
    output reg [95:0] camera_roll_cd, camera_pitch_cd,
    output reg [31:0] applied_sequence,
    output reg [15:0] applied_epoch,
    output reg [31:0] applied_revision,
    output reg applied_enable,
    output reg fallback,
    output reg history_miss,
    output reg stale_pose,
    output reg calibration_mismatch,
    output reg limited,
    output reg out_of_range
);
    localparam [1:0] IDLE=0, HISTORY=1, MATH=2, READY=3;
    reg [1:0] state;
    reg [15:0] epoch_l;
    reg sensor_l;
    reg [31:0] revision_l;
    reg [95:0] static_roll_l, static_pitch_l;
    reg history_req;
    wire history_response, history_found, history_usable, history_enable;
    wire [15:0] history_epoch;
    wire signed [15:0] history_roll, history_pitch;
    wire [31:0] history_sequence, history_revision;
    wire lease_matches = panorama_enable && lease_valid &&
        (lease_epoch == epoch_l) && (sensor_ir == sensor_l);
    wire cancel_work = (state != IDLE) && !render_active && !lease_matches;
    assign ready = (state == READY) && (render_active || lease_matches);

    GlPoseEpochHistory u_history (
        .clk(clk), .rst(rst), .pose_update(pose_update),
        .pose_roll_cd(pose_roll_cd), .pose_pitch_cd(pose_pitch_cd),
        .pose_receipt_sequence(pose_sequence),
        .epoch_capture(epoch_capture), .epoch_id(epoch_id),
        .max_age_cycles(MAX_POSE_AGE_CYCLES),
        .stabilization_enable(stabilization_enabled),
        .calibration_revision(calibration_revision),
        .lookup_req(history_req), .lookup_epoch(epoch_l),
        .response_valid(history_response), .response_found(history_found),
        .response_epoch(history_epoch), .response_roll_cd(history_roll),
        .response_pitch_cd(history_pitch),
        .response_receipt_sequence(history_sequence), .response_age_cycles(),
        .response_sample_valid(), .response_usable(history_usable),
        .response_age_overflow(), .response_enable(history_enable),
        .response_calibration_revision(history_revision)
    );
    reg math_start, math_enable;
    reg signed [15:0] math_roll, math_pitch;
    wire math_done, math_busy, math_limited, math_range;
    wire [95:0] math_camera_roll, math_camera_pitch;
    GlFramePose #(.ANGLE_ROM_FILE(ANGLE_ROM_FILE), .ATAN_ROM_FILE(ATAN_ROM_FILE)) u_pose (
        .clk(clk), .rst(rst || cancel_work), .start(math_start),
        .enable(math_enable), .sensor_ir(sensor_l),
        .sensor_roll_cd(math_roll), .sensor_pitch_cd(math_pitch),
        .static_roll_cd(static_roll_l), .static_pitch_cd(static_pitch_l),
        .busy(math_busy), .done(math_done),
        .camera_roll_cd(math_camera_roll), .camera_pitch_cd(math_camera_pitch),
        .applied_roll_cd(), .applied_pitch_cd(),
        .limited(math_limited), .out_of_range(math_range)
    );
    reg [31:0] sequence_l;
    reg missing_l, stale_l, mismatch_l;
    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE; history_req <= 0; math_start <= 0;
            epoch_l <= 0; sensor_l <= 0; revision_l <= 0;
            static_roll_l <= 0; static_pitch_l <= 0;
            math_enable <= 0; math_roll <= 0; math_pitch <= 0;
            sequence_l <= 0; missing_l <= 0; stale_l <= 0; mismatch_l <= 0;
            camera_roll_cd <= 0; camera_pitch_cd <= 0;
            applied_sequence <= 0; applied_epoch <= 0; applied_revision <= 0;
            applied_enable <= 0; fallback <= 0; history_miss <= 0;
            stale_pose <= 0; calibration_mismatch <= 0;
            limited <= 0; out_of_range <= 0;
        end else begin
            history_req <= 0; math_start <= 0;
            if (cancel_work) begin
                state <= IDLE;
            end else case (state)
                IDLE: if (panorama_enable && lease_valid && !render_active) begin
                    epoch_l <= lease_epoch; sensor_l <= sensor_ir;
                    revision_l <= calibration_revision;
                    static_roll_l <= static_roll_cd;
                    static_pitch_l <= static_pitch_cd;
                    history_req <= 1;
                    state <= HISTORY;
                end
                HISTORY: if (history_response && history_epoch == epoch_l) begin
                    math_roll <= history_roll; math_pitch <= history_pitch;
                    math_enable <= history_found && history_usable && history_enable &&
                        (history_revision == revision_l);
                    sequence_l <= history_sequence;
                    missing_l <= !history_found;
                    stale_l <= history_found && !history_usable;
                    mismatch_l <= history_found && (history_revision != revision_l);
                    math_start <= 1;
                    state <= MATH;
                end
                MATH: if (math_done) begin
                    camera_roll_cd <= math_camera_roll;
                    camera_pitch_cd <= math_camera_pitch;
                    applied_sequence <= sequence_l; applied_epoch <= epoch_l;
                    applied_revision <= revision_l; applied_enable <= math_enable;
                    fallback <= !math_enable;
                    history_miss <= missing_l; stale_pose <= stale_l;
                    calibration_mismatch <= mismatch_l;
                    limited <= math_limited; out_of_range <= math_range;
                    state <= READY;
                end
                READY: ; // Replaced only when the lease goes away/changes.
                default: state <= IDLE;
            endcase
        end
    end
endmodule
