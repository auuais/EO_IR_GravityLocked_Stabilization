`timescale 1ns/1ps
// Expected vectors are emitted by the compiled C++ oracle, never by this bench.
module tb_GlCameraProjection;
    parameter ROOT = "../.."; // scripts/test_gl_camera_projection.ps1 build directory
    parameter integer EXPECTED_VECTOR_COUNT = 1342;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, start = 0;
    reg signed [31:0] sensor_roll_cd = 0, sensor_pitch_cd = 0;
    reg signed [31:0] mount_yaw_cd = 0, mount_pitch_cd = 0, mount_roll_cd = 0;
    wire busy, done;
    wire signed [31:0] camera_roll_cd, camera_pitch_cd, camera_yaw_cd;
    GlCameraProjection #(
        .ANGLE_ROM_FILE({ROOT, "/reference/gravity_math/angle_centi_q15.mem"}),
        .ATAN_ROM_FILE({ROOT, "/reference/gravity_math/atan_ratio_centi.mem"})
    ) dut (.*);

    integer fd, fields, vector_count = 0, latency;
    integer min_latency = 999999, max_latency = 0;
    reg signed [31:0] in_r, in_p, in_my, in_mp, in_mr;
    reg signed [31:0] expected_r, expected_p, expected_y;
    reg signed [31:0] held_r = 0, held_p = 0, held_y = 0;

    task automatic check_held;
        if (camera_roll_cd !== held_r || camera_pitch_cd !== held_p || camera_yaw_cd !== held_y)
            $fatal(1, "Outputs changed without done at vector %0d cycle %0d", vector_count, latency);
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk); rst = 1; start = 0;
            @(posedge clk); #1;
            if (busy !== 0 || done !== 0 || camera_roll_cd !== 0 ||
                camera_pitch_cd !== 0 || camera_yaw_cd !== 0)
                $fatal(1, "Reset failed to clear interface");
            held_r = 0; held_p = 0; held_y = 0;
            @(negedge clk); rst = 0;
        end
    endtask

    task automatic begin_case;
        begin
            @(negedge clk);
            sensor_roll_cd = in_r; sensor_pitch_cd = in_p;
            mount_yaw_cd = in_my; mount_pitch_cd = in_mp; mount_roll_cd = in_mr;
            start = 1;
            @(posedge clk); #1;
            if (busy !== 1 || done !== 0) $fatal(1, "Start was not accepted");
            check_held();
        end
    endtask

    initial begin
        reset_dut();
        // Abort during normalization and then during the matrix computation.
        in_r = -32'sd123456789; in_p = 32'sd333; in_my = 32'sd39000;
        in_mp = -32'sd75; in_mr = 32'sd50;
        begin_case();
        repeat (50) begin
            @(negedge clk); start = 0;
            @(posedge clk); #1; if (done) $fatal(1, "Unexpected early done");
        end
        reset_dut();
        begin_case();
        repeat (250) begin
            @(negedge clk); start = 0;
            @(posedge clk); #1; if (done) $fatal(1, "Unexpected early done");
        end
        reset_dut();
        repeat (700) begin
            @(posedge clk); #1;
            if (done || busy) $fatal(1, "Aborted operation resumed after reset");
            check_held();
        end

        fd = $fopen({ROOT, "/sim/gravity_math/engine_vectors.txt"}, "r");
        if (fd == 0) $fatal(1, "Cannot open compiled-C projection vectors");
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%d %d %d %d %d %d %d %d\n",
                             in_r, in_p, in_my, in_mp, in_mr,
                             expected_r, expected_p, expected_y);
            if (fields == 8) begin
                begin_case();
                latency = 0;
                while (!done) begin
                    @(negedge clk);
                    // Deliberately mutate every input and assert extra starts.
                    // Accepted inputs must remain frozen, and busy starts ignored.
                    start = ((latency % 37) == 5);
                    sensor_roll_cd = 32'sh80000000 + latency;
                    sensor_pitch_cd = 32'sh7fffffff - latency;
                    mount_yaw_cd = 32'sd27123 + latency;
                    mount_pitch_cd = -32'sd11223 - latency;
                    mount_roll_cd = 32'sd7333 + latency;
                    @(posedge clk); #1;
                    latency = latency + 1;
                    if (latency > 601) $fatal(1, "Projection exceeded 601-cycle bound at vector %0d", vector_count);
                    if (!done) begin
                        if (busy !== 1) $fatal(1, "busy dropped without done");
                        check_held();
                    end
                end
                if (busy !== 0) $fatal(1, "busy remains set with done");
                if (camera_roll_cd !== expected_r || camera_pitch_cd !== expected_p || camera_yaw_cd !== expected_y)
                    $fatal(1, "Vector %0d (%0d %0d %0d %0d %0d): got %0d %0d %0d expected %0d %0d %0d",
                           vector_count, in_r, in_p, in_my, in_mp, in_mr,
                           camera_roll_cd, camera_pitch_cd, camera_yaw_cd,
                           expected_r, expected_p, expected_y);
                held_r = expected_r; held_p = expected_p; held_y = expected_y;
                if (latency < min_latency) min_latency = latency;
                if (latency > max_latency) max_latency = latency;
                vector_count = vector_count + 1;
                @(negedge clk); start = 0;
                @(posedge clk); #1;
                if (done !== 0 || busy !== 0) $fatal(1, "Completion pulse was not one cycle");
                check_held();
            end else if (fields != -1) $fatal(1, "Malformed vector row %0d: %0d fields", vector_count, fields);
        end
        $fclose(fd);
        if (vector_count != EXPECTED_VECTOR_COUNT)
            $fatal(1, "Oracle fixture has %0d vectors; expected exactly %0d", vector_count, EXPECTED_VECTOR_COUNT);
        $display("PASS GlCameraProjection: %0d C-oracle vectors, latency %0d..%0d cycles; frozen inputs, busy-start rejection and reset abort verified",
                 vector_count, min_latency, max_latency);
        $finish;
    end

    initial begin
        #30000000;
        $fatal(1, "Projection test timeout");
    end
endmodule
