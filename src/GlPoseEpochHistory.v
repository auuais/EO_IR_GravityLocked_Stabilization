`timescale 1ns/1ps

// UI-clock pose/epoch association, independent of the production renderer.
// pose_update means a VALID coherent {roll,pitch,receipt_sequence} snapshot.
// There is no CDC here. All inputs, including synchronous active-high rst,
// must meet clk timing. Reset clears pose validity and every history tag.
//
// epoch_capture writes the slot indexed by epoch_id modulo HISTORY_DEPTH,
// retaining the complete 16-bit tag. It snapshots pose, elapsed age, validity,
// freshness, stabilization_enable and calibration_revision. The epoch ID is
// supplied by the caller; it does NOT establish exposure timing. Receipt
// sequence is opaque transaction metadata, not an exposure/frame identifier.
// Reuse of an identical 16-bit epoch after a full wrap denotes a new snapshot;
// callers must not retain ambiguous requests across a complete 65536-ID wrap.
//
// Age is 0 on the accepting pose edge, 1 on the next edge, and saturates at
// all ones. A sticky overflow bit distinguishes that exact maximum age from
// older samples, preventing an all-ones threshold from accepting them forever.
// Never-received age is all ones, with sample_valid=0 and age_overflow=0.
// Usable means sample_valid && !age_overflow && age <= max_age_cycles AT
// CAPTURE. Enable is captured independently; no fallback/bypass is selected.
// Same-edge pose_update wins over epoch_capture, with age=0 and overflow=0.
//
// lookup_req is sampled at an edge; response_valid and the registered result
// appear after that edge (one registered response, no combinational lookup).
// response_epoch echoes lookup_epoch. A missing/overwritten tag returns
// response_found=0 and zero payload. Payload/epoch/found hold without a lookup;
// response_valid alone pulses with requests. Capture precedes lookup: a
// same-tag capture returns its NEW snapshot, and an alias overwrite rejects
// the old tag even on that same edge. Downstream owns active-pass freezing.
module GlPoseEpochHistory #(
    parameter integer HISTORY_DEPTH = 16,
    parameter integer AGE_WIDTH = 32
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire                     pose_update,
    input  wire signed [15:0]       pose_roll_cd,
    input  wire signed [15:0]       pose_pitch_cd,
    input  wire [31:0]              pose_receipt_sequence,
    input  wire                     epoch_capture,
    input  wire [15:0]              epoch_id,
    input  wire [AGE_WIDTH-1:0]     max_age_cycles,
    input  wire                     stabilization_enable,
    input  wire [31:0]              calibration_revision,
    input  wire                     lookup_req,
    input  wire [15:0]              lookup_epoch,
    output reg                      response_valid,
    output reg                      response_found,
    output reg  [15:0]              response_epoch,
    output reg  signed [15:0]       response_roll_cd,
    output reg  signed [15:0]       response_pitch_cd,
    output reg  [31:0]              response_receipt_sequence,
    output reg  [AGE_WIDTH-1:0]     response_age_cycles,
    output reg                      response_sample_valid,
    output reg                      response_usable,
    output reg                      response_age_overflow,
    output reg                      response_enable,
    output reg  [31:0]              response_calibration_revision
);
    localparam integer INDEX_WIDTH = (HISTORY_DEPTH <= 1) ? 1 : $clog2(HISTORY_DEPTH);
    localparam integer SNAPSHOT_WIDTH = 100 + AGE_WIDTH;
    localparam [AGE_WIDTH-1:0] AGE_MAX = {AGE_WIDTH{1'b1}};

    initial begin
        if (HISTORY_DEPTH < 1 || HISTORY_DEPTH > 65536 ||
            ((HISTORY_DEPTH & (HISTORY_DEPTH - 1)) != 0) || AGE_WIDTH < 1) begin
            $error("GlPoseEpochHistory requires power-of-two depth 1..65536 and AGE_WIDTH >= 1");
            $finish;
        end
    end

    reg have_pose;
    reg signed [15:0] latest_roll, latest_pitch;
    reg [31:0] latest_sequence;
    reg [AGE_WIDTH-1:0] latest_age;
    reg latest_overflow;
    reg [HISTORY_DEPTH-1:0] slot_valid;
    reg [15:0] slot_epoch [0:HISTORY_DEPTH-1];
    reg [SNAPSHOT_WIDTH-1:0] slot_snapshot [0:HISTORY_DEPTH-1];

    wire [INDEX_WIDTH-1:0] capture_index = (HISTORY_DEPTH == 1) ? 0 : epoch_id[INDEX_WIDTH-1:0];
    wire [INDEX_WIDTH-1:0] lookup_index = (HISTORY_DEPTH == 1) ? 0 : lookup_epoch[INDEX_WIDTH-1:0];
    wire capture_sample_valid = have_pose || pose_update;
    wire [AGE_WIDTH-1:0] age_on_edge = pose_update ? {AGE_WIDTH{1'b0}} :
        ((latest_age == AGE_MAX) ? AGE_MAX : latest_age + 1'b1);
    wire overflow_on_edge = !pose_update && have_pose &&
        (latest_overflow || (latest_age == AGE_MAX));
    wire capture_usable = capture_sample_valid && !overflow_on_edge &&
        (age_on_edge <= max_age_cycles);
    wire [SNAPSHOT_WIDTH-1:0] capture_snapshot = {
        capture_sample_valid, capture_usable, overflow_on_edge,
        stabilization_enable, calibration_revision,
        (pose_update ? pose_receipt_sequence : latest_sequence),
        (pose_update ? pose_roll_cd : latest_roll),
        (pose_update ? pose_pitch_cd : latest_pitch), age_on_edge
    };

    // Explicit write-through handles same-address read/write consistently,
    // regardless of how synthesis implements this small register history.
    wire capture_alias = epoch_capture && (capture_index == lookup_index);
    wire lookup_hit = capture_alias ? (epoch_id == lookup_epoch) :
        (slot_valid[lookup_index] && (slot_epoch[lookup_index] == lookup_epoch));
    wire [SNAPSHOT_WIDTH-1:0] lookup_snapshot = !lookup_hit ? {SNAPSHOT_WIDTH{1'b0}} :
        (capture_alias ? capture_snapshot : slot_snapshot[lookup_index]);

    always @(posedge clk) begin
        if (rst) begin
            have_pose <= 1'b0;
            latest_roll <= 16'sd0;
            latest_pitch <= 16'sd0;
            latest_sequence <= 32'd0;
            latest_age <= AGE_MAX;
            latest_overflow <= 1'b0;
            slot_valid <= {HISTORY_DEPTH{1'b0}};
            response_valid <= 1'b0;
            response_found <= 1'b0;
            response_epoch <= 16'd0;
            {response_sample_valid, response_usable, response_age_overflow,
             response_enable, response_calibration_revision,
             response_receipt_sequence, response_roll_cd, response_pitch_cd,
             response_age_cycles} <= {SNAPSHOT_WIDTH{1'b0}};
        end else begin
            latest_age <= age_on_edge;
            latest_overflow <= overflow_on_edge;
            if (pose_update) begin
                have_pose <= 1'b1;
                latest_roll <= pose_roll_cd;
                latest_pitch <= pose_pitch_cd;
                latest_sequence <= pose_receipt_sequence;
            end
            if (epoch_capture) begin
                slot_valid[capture_index] <= 1'b1;
                slot_epoch[capture_index] <= epoch_id;
                slot_snapshot[capture_index] <= capture_snapshot;
            end
            response_valid <= lookup_req;
            if (lookup_req) begin
                response_epoch <= lookup_epoch;
                response_found <= lookup_hit;
                {response_sample_valid, response_usable, response_age_overflow,
                 response_enable, response_calibration_revision,
                 response_receipt_sequence, response_roll_cd, response_pitch_cd,
                 response_age_cycles} <= lookup_snapshot;
            end
        end
    end
endmodule
