`timescale 1ns/1ps
module tb_GlPoseEpochHistory;
    parameter integer HISTORY_DEPTH = 16;
    parameter integer AGE_WIDTH = 4;
    localparam integer AGE_MAX = (1 << AGE_WIDTH) - 1;
    localparam integer PAYLOAD_WIDTH = 100 + AGE_WIDTH;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1;
    reg pose_update = 0, epoch_capture = 0, lookup_req = 0;
    reg signed [15:0] pose_roll_cd = 0, pose_pitch_cd = 0;
    reg [31:0] pose_receipt_sequence = 0, calibration_revision = 0;
    reg [15:0] epoch_id = 0, lookup_epoch = 0;
    reg [AGE_WIDTH-1:0] max_age_cycles = 0;
    reg stabilization_enable = 0;
    wire response_valid, response_found, response_sample_valid, response_usable;
    wire response_age_overflow, response_enable;
    wire [15:0] response_epoch;
    wire signed [15:0] response_roll_cd, response_pitch_cd;
    wire [31:0] response_receipt_sequence, response_calibration_revision;
    wire [AGE_WIDTH-1:0] response_age_cycles;
    wire [PAYLOAD_WIDTH-1:0] response_payload = {
        response_sample_valid, response_usable, response_age_overflow,
        response_enable, response_calibration_revision, response_receipt_sequence,
        response_roll_cd, response_pitch_cd, response_age_cycles
    };
    GlPoseEpochHistory #(.HISTORY_DEPTH(HISTORY_DEPTH), .AGE_WIDTH(AGE_WIDTH)) dut (.*);

    // Reference uses unbounded elapsed cycles, then clips only the stored age.
    // Captures update a tagged software array before lookups, modelling the
    // externally specified write-through semantics independently of DUT RAMs.
    reg model_have = 0;
    integer elapsed = 0;
    reg signed [15:0] model_roll = 0, model_pitch = 0;
    reg [31:0] model_sequence = 0;
    reg model_valid [0:HISTORY_DEPTH-1];
    reg [15:0] model_tag [0:HISTORY_DEPTH-1];
    reg [PAYLOAD_WIDTH-1:0] model_payload [0:HISTORY_DEPTH-1];
    reg expected_valid = 0, expected_found = 0;
    reg [15:0] expected_epoch = 0;
    reg [PAYLOAD_WIDTH-1:0] expected_payload = 0;
    reg [AGE_WIDTH-1:0] clipped_age;
    reg sample_ok, sample_overflow;
    integer index, k;
    integer checks = 0, hits = 0, misses = 0;
    always @(posedge clk) begin
        if (rst) begin
            model_have = 0;
            elapsed = 0;
            model_roll = 0;
            model_pitch = 0;
            model_sequence = 0;
            for (k = 0; k < HISTORY_DEPTH; k = k + 1) model_valid[k] = 0;
            expected_valid = 0;
            expected_found = 0;
            expected_epoch = 0;
            expected_payload = 0;
        end else begin
            if (pose_update) begin
                model_have = 1;
                elapsed = 0;
                model_roll = pose_roll_cd;
                model_pitch = pose_pitch_cd;
                model_sequence = pose_receipt_sequence;
            end else if (model_have) elapsed = elapsed + 1;
            if (epoch_capture) begin
                index = epoch_id % HISTORY_DEPTH;
                clipped_age = !model_have || elapsed > AGE_MAX ? AGE_MAX : elapsed;
                sample_overflow = model_have && elapsed > AGE_MAX;
                sample_ok = model_have && elapsed <= max_age_cycles;
                model_valid[index] = 1;
                model_tag[index] = epoch_id;
                model_payload[index] = {model_have, sample_ok, sample_overflow,
                    stabilization_enable, calibration_revision, model_sequence,
                    model_roll, model_pitch, clipped_age};
            end
            expected_valid = lookup_req;
            if (lookup_req) begin
                index = lookup_epoch % HISTORY_DEPTH;
                expected_epoch = lookup_epoch;
                expected_found = model_valid[index] && model_tag[index] == lookup_epoch;
                expected_payload = expected_found ? model_payload[index] : 0;
                if (expected_found) hits = hits + 1;
                else misses = misses + 1;
            end
        end
        #0.001;
        if (response_valid !== expected_valid || response_found !== expected_found ||
            response_epoch !== expected_epoch || response_payload !== expected_payload)
            $fatal(1, "history mismatch cycle=%0d epoch=%h found=%b/%b payload=%h/%h",
                checks, response_epoch, response_found, expected_found,
                response_payload, expected_payload);
        checks = checks + 1;
    end

    task automatic begin_cycle;
        begin
            @(negedge clk);
            pose_update = 0;
            epoch_capture = 0;
            lookup_req = 0;
        end
    endtask
    task automatic end_cycle;
        begin @(posedge clk); #0.002; end
    endtask
    task automatic idle(input integer count);
        integer n;
        begin
            for (n = 0; n < count; n = n + 1) begin
                begin_cycle(); end_cycle();
            end
        end
    endtask
    task automatic capture_lookup(input [15:0] epoch);
        begin
            epoch_capture = 1;
            epoch_id = epoch;
            lookup_req = 1;
            lookup_epoch = epoch;
        end
    endtask
    integer n;
    initial begin
        repeat (2) @(posedge clk);
        @(negedge clk); rst = 0;
        begin_cycle(); lookup_req = 1; lookup_epoch = 0; end_cycle();
        begin_cycle(); capture_lookup(16'd5); end_cycle();
        if (!response_found || response_sample_valid || response_usable)
            $fatal(1, "never-received epoch should be found but unusable");

        // Same-edge pose/capture/lookup, signed extremes and sequence wrap.
        begin_cycle();
        pose_update = 1; pose_roll_cd = -16'sd32768; pose_pitch_cd = 16'sd32767;
        pose_receipt_sequence = 32'hffffffff; calibration_revision = 32'hdead0001;
        stabilization_enable = 0; max_age_cycles = 0;
        capture_lookup(16'hffff); end_cycle();
        if (!response_usable || response_age_cycles != 0 || response_enable)
            $fatal(1, "freshness must be independent of enable");
        begin_cycle(); max_age_cycles = 1; capture_lookup(16'h0000); end_cycle();
        if (!response_usable || response_age_cycles != 1) $fatal(1, "inclusive age boundary failed");
        begin_cycle(); stabilization_enable = 1; calibration_revision = 2;
        capture_lookup(16'h0001); end_cycle();
        if (response_usable || !response_sample_valid) $fatal(1, "stale sample accepted");
        begin_cycle(); lookup_req = 1; lookup_epoch = 0;
        max_age_cycles = AGE_MAX; calibration_revision = 99; end_cycle();
        idle(3); // Stored fields remain fixed despite age/control changes.

        begin_cycle(); pose_update = 1; pose_receipt_sequence = 0;
        pose_roll_cd = 16'sd100; pose_pitch_cd = -16'sd200;
        capture_lookup(16'h1200); end_cycle();
        begin_cycle(); epoch_capture = 1; epoch_id = 16'h1200 + HISTORY_DEPTH;
        lookup_req = 1; lookup_epoch = 16'h1200; end_cycle();
        if (response_found) $fatal(1, "same-cycle alias overwrite returned old tag");
        begin_cycle(); lookup_req = 1; lookup_epoch = 16'h1200 + HISTORY_DEPTH; end_cycle();

        // Replace an already valid IDENTICAL tag, not merely an empty slot.
        begin_cycle(); pose_update = 1; pose_receipt_sequence = 32'habcdef01;
        pose_roll_cd = -16'sd1234; pose_pitch_cd = 16'sd2345;
        calibration_revision = 32'h76543210; stabilization_enable = 1;
        max_age_cycles = 0;
        capture_lookup(16'h1200 + HISTORY_DEPTH); end_cycle();
        if (!response_usable || response_age_cycles != 0 ||
            response_receipt_sequence != 32'habcdef01 ||
            response_calibration_revision != 32'h76543210)
            $fatal(1, "same-tag overwrite did not forward the new snapshot");

        begin_cycle(); pose_update = 1; pose_receipt_sequence = 32'h80000000;
        capture_lookup(16'd8); end_cycle();
        begin_cycle(); epoch_capture = 1; epoch_id = 9;
        lookup_req = 1; lookup_epoch = 8; end_cycle(); // different slot except depth=1

        // At exact AGE_MAX a max threshold accepts; the next edge is unusable
        // even though the visible age saturates and max_age remains all ones.
        begin_cycle(); pose_update = 1; max_age_cycles = AGE_MAX; end_cycle();
        idle(AGE_MAX - 1);
        begin_cycle(); capture_lookup(16'd77); end_cycle();
        if (!response_usable || response_age_overflow || response_age_cycles != AGE_MAX)
            $fatal(1, "exact maximum-age boundary failed");
        begin_cycle(); capture_lookup(16'd78); end_cycle();
        if (response_usable || !response_age_overflow || response_age_cycles != AGE_MAX)
            $fatal(1, "saturated age must not become permanently fresh");
        idle(5);
        begin_cycle(); lookup_req = 1; lookup_epoch = 78; end_cycle();

        begin_cycle(); rst = 1; epoch_capture = 1; lookup_req = 1; pose_update = 1; end_cycle();
        begin_cycle(); rst = 0; lookup_req = 1; lookup_epoch = 78; end_cycle();
        if (response_found) $fatal(1, "reset failed to invalidate history");
        begin_cycle(); capture_lookup(16'd78); end_cycle();
        if (response_sample_valid || response_usable) $fatal(1, "reset failed to invalidate latest pose");

        // Deterministic mixed traffic: matching tags, aliases and idle outputs.
        for (n = 0; n < 96; n = n + 1) begin
            begin_cycle();
            pose_update = (n % 5 == 0);
            pose_receipt_sequence = 32'hfffffff0 + n;
            pose_roll_cd = n * 131 - 30000; pose_pitch_cd = 30000 - n * 277;
            epoch_capture = (n % 2 == 0); epoch_id = 16'hfff0 + n;
            lookup_req = (n % 3 != 0); lookup_epoch = 16'hfff0 + n - (n % 4);
            max_age_cycles = n % (AGE_MAX + 1);
            stabilization_enable = n[0]; calibration_revision = 32'h12340000 + n;
            end_cycle();
        end
        idle(5);
        if (hits == 0 || misses == 0) $fatal(1, "missing hit/miss coverage");
        $display("PASS GlPoseEpochHistory depth=%0d age_width=%0d checks=%0d hits=%0d misses=%0d",
            HISTORY_DEPTH, AGE_WIDTH, checks, hits, misses);
        $finish;
    end
    initial begin #100000; $fatal(1, "testbench timeout"); end
endmodule
