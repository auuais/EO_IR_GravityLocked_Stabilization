`timescale 1ns/1ps
// Enabled expectations come from the compiled original C++ FRAME oracle.
// Disabled expectations explicitly preserve the existing exact manual trims.
module tb_GlFramePose;
    parameter ROOT = "../..";
    parameter integer EXPECTED_VECTOR_COUNT = 266;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst = 1, start = 0, enable = 0, sensor_ir = 0;
    reg signed [15:0] sensor_roll_cd = 0, sensor_pitch_cd = 0;
    reg [95:0] static_roll_cd = 0, static_pitch_cd = 0;
    wire busy, done, limited, out_of_range;
    wire [95:0] camera_roll_cd, camera_pitch_cd;
    wire signed [15:0] applied_roll_cd, applied_pitch_cd;
    GlFramePose #(
        .ANGLE_ROM_FILE({ROOT, "/reference/gravity_math/angle_centi_q15.mem"}),
        .ATAN_ROM_FILE({ROOT, "/reference/gravity_math/atan_ratio_centi.mem"})
    ) dut (.*);

    integer fd, fields, vector_count = 0, latency = 0;
    integer min_enabled_latency = 999999, max_enabled_latency = 0;
    integer enabled_count = 0, disabled_count = 0, limited_count = 0;
    integer range_count = 0, eo_count = 0, ir_count = 0, abort_count = 0;
    integer in_enable, in_ir, in_r, in_p, expected_ar, expected_ap;
    integer expected_limited, expected_range;
    reg [95:0] in_sr, in_sp, expected_r, expected_p;
    reg [95:0] held_r = 0, held_p = 0;
    reg signed [15:0] held_ar = 0, held_ap = 0;
    reg held_limited = 0, held_range = 0;

    task automatic check_held;
        begin
            if (camera_roll_cd !== held_r || camera_pitch_cd !== held_p ||
                applied_roll_cd !== held_ar || applied_pitch_cd !== held_ap ||
                limited !== held_limited || out_of_range !== held_range)
                $fatal(1, "Partial result escaped before done at vector %0d cycle %0d", vector_count, latency);
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk); rst = 1; start = 0;
            @(posedge clk); #1;
            if (busy !== 0 || done !== 0 || camera_roll_cd !== 0 || camera_pitch_cd !== 0 ||
                applied_roll_cd !== 0 || applied_pitch_cd !== 0 || limited !== 0 || out_of_range !== 0)
                $fatal(1, "Reset failed to clear interface");
            held_r = 0; held_p = 0; held_ar = 0; held_ap = 0;
            held_limited = 0; held_range = 0;
            @(negedge clk); rst = 0;
        end
    endtask

    task automatic begin_case;
        begin
            @(negedge clk);
            enable = in_enable; sensor_ir = in_ir;
            sensor_roll_cd = in_r; sensor_pitch_cd = in_p;
            static_roll_cd = in_sr; static_pitch_cd = in_sp;
            start = 1;
            @(posedge clk); #1;
            if (busy !== 1 || done !== 0) $fatal(1, "Start was not accepted");
            check_held();
        end
    endtask

    task automatic mutate_busy_inputs;
        begin
            // Includes all control/trim inputs and repeated starts while busy.
            start = ((latency % 37) == 5);
            enable = ~enable; sensor_ir = ~sensor_ir;
            sensor_roll_cd = 16'h8000 + latency;
            sensor_pitch_cd = 16'h7fff - latency;
            static_roll_cd = {32'h87654321, 32'h76543210, 32'h65432109} ^ latency;
            static_pitch_cd = {32'h12345678, 32'h23456789, 32'h3456789a} ^ (latency << 1);
        end
    endtask

    task automatic abort_at;
        input integer target;
        integer guard;
        begin
            // This pose always enters global limiting, allowing each phase to be aborted.
            in_enable = 1; in_ir = 1; in_r = -3000; in_p = 2300;
            in_sr = 0; in_sp = 0;
            begin_case();
            guard = 0;
            while (!((target == 0 && dut.state == 3 && dut.camera_index == 0 && guard >= 60) ||
                     (target == 1 && dut.state == 3 && dut.camera_index == 3) ||
                     (target == 2 && dut.state == 6 && dut.scale_pitch == 1) ||
                     (target == 3 && dut.state == 3 && dut.final_pass == 1 && dut.camera_index == 2))) begin
                @(negedge clk); start = 0;
                @(posedge clk); #1;
                guard = guard + 1;
                if (done || guard > 7500) $fatal(1, "Abort phase %0d was not reached", target);
                check_held();
            end
            reset_dut();
            repeat (700) begin
                @(posedge clk); #1;
                if (done || busy) $fatal(1, "Aborted operation resumed after reset");
                check_held();
            end
            abort_count = abort_count + 1;
        end
    endtask

    initial begin
        reset_dut();
        abort_at(0); // Child normalization.
        abort_at(1); // Later camera after pending earlier-camera writes.
        abort_at(2); // Second live-angle restoring division.
        abort_at(3); // Recomputed camera pass after global scaling.
        fd = $fopen({ROOT, "/sim/gravity_math/frame_pose_vectors.txt"}, "r");
        if (fd == 0) $fatal(1, "Cannot open compiled-C frame-pose vectors");
        while (!$feof(fd)) begin
            fields = $fscanf(fd, "%d %d %d %d %h %h %h %h %d %d %d %d\n",
                in_enable, in_ir, in_r, in_p, in_sr, in_sp, expected_r, expected_p,
                expected_ar, expected_ap, expected_limited, expected_range);
            if (fields == 12) begin
                begin_case();
                latency = 0;
                while (!done) begin
                    @(negedge clk); mutate_busy_inputs();
                    @(posedge clk); #1;
                    latency = latency + 1;
                    if (latency > 7500) $fatal(1, "Frame pose exceeded 7500-cycle bound at vector %0d", vector_count);
                    if (!done) begin
                        if (busy !== 1) $fatal(1, "busy dropped without done");
                        check_held();
                    end
                end
                if (busy !== 0) $fatal(1, "busy remains set with done");
                if (camera_roll_cd !== expected_r || camera_pitch_cd !== expected_p ||
                    $signed(applied_roll_cd) !== expected_ar || $signed(applied_pitch_cd) !== expected_ap ||
                    limited !== expected_limited[0] || out_of_range !== expected_range[0])
                    $fatal(1, "Vector %0d enable=%0d ir=%0d live=(%0d,%0d): got %h %h pose=(%0d,%0d) flags=%0d/%0d; expected %h %h pose=(%0d,%0d) flags=%0d/%0d",
                        vector_count, in_enable, in_ir, in_r, in_p,
                        camera_roll_cd, camera_pitch_cd, applied_roll_cd, applied_pitch_cd, limited, out_of_range,
                        expected_r, expected_p, expected_ar, expected_ap, expected_limited, expected_range);
                if (!in_enable && latency != 1) $fatal(1, "Disabled bypass was not one cycle");
                if (in_enable) begin
                    enabled_count = enabled_count + 1;
                    if (latency < min_enabled_latency) min_enabled_latency = latency;
                    if (latency > max_enabled_latency) max_enabled_latency = latency;
                end else disabled_count = disabled_count + 1;
                if (expected_limited) limited_count = limited_count + 1;
                if (expected_range) range_count = range_count + 1;
                if (in_ir) ir_count = ir_count + 1; else eo_count = eo_count + 1;
                held_r = expected_r; held_p = expected_p;
                held_ar = expected_ar; held_ap = expected_ap;
                held_limited = expected_limited; held_range = expected_range;
                vector_count = vector_count + 1;
                @(negedge clk); start = 0;
                @(posedge clk); #1;
                if (done !== 0 || busy !== 0) $fatal(1, "Completion pulse was not one cycle");
                check_held();
            end else if (fields != -1) $fatal(1, "Malformed vector row %0d: %0d fields", vector_count, fields);
        end
        $fclose(fd);
        if (vector_count != EXPECTED_VECTOR_COUNT)
            $fatal(1, "Fixture has %0d vectors; expected exactly %0d", vector_count, EXPECTED_VECTOR_COUNT);
        if (enabled_count == 0 || disabled_count == 0 || limited_count == 0 || range_count == 0 || eo_count == 0 || ir_count == 0)
            $fatal(1, "Required coverage class missing");
        $display("PASS GlFramePose: %0d cases (%0d enabled C, %0d exact disabled), %0d limited, %0d out-of-range, EO/IR=%0d/%0d; enabled latency %0d..%0d cycles; disabled=1; frozen inputs, atomic six-camera outputs, busy-start rejection, %0d reset phases verified",
            vector_count, enabled_count, disabled_count, limited_count, range_count, eo_count, ir_count,
            min_enabled_latency, max_enabled_latency, abort_count);
        $finish;
    end

    initial begin
        #50000000;
        $fatal(1, "Frame-pose test timeout");
    end
endmodule
