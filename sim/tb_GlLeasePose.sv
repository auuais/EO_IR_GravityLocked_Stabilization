`timescale 1ns/1ps
module tb_GlLeasePose;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, epoch_capture=0, pose_update=0;
    reg [15:0] epoch_id=0;
    reg signed [15:0] pose_roll_cd=0, pose_pitch_cd=0;
    reg [31:0] pose_sequence=0, calibration_revision=0;
    reg stabilization_enabled=1, panorama_enable=1, sensor_ir=0;
    reg lease_valid=0, render_active=0;
    reg [15:0] lease_epoch=0;
    reg [95:0] static_roll_cd=0, static_pitch_cd=0;
    wire ready;
    wire [95:0] camera_roll_cd, camera_pitch_cd;
    wire [31:0] applied_sequence, applied_revision;
    wire [15:0] applied_epoch;
    wire applied_enable, fallback, history_miss, stale_pose;
    wire calibration_mismatch, limited, out_of_range;
    GlLeasePose #(.MAX_POSE_AGE_CYCLES(32'd10)) dut (.*);
    integer checks=0, cycles;
    reg [95:0] held_roll, held_pitch;
    task tick;
        begin @(posedge clk); #1; end
    endtask
    task idle(input integer n);
        begin repeat(n) begin @(negedge clk); epoch_capture=0; pose_update=0; tick(); end end
    endtask
    task snapshot(input [15:0] ep, input integer r, input integer p, input [31:0] seq);
        begin
            @(negedge clk); epoch_capture=1; epoch_id=ep;
            pose_update=1; pose_roll_cd=r; pose_pitch_cd=p; pose_sequence=seq;
            tick(); idle(1);
        end
    endtask
    task release_lease;
        begin @(negedge clk); lease_valid=0; render_active=0; tick(); idle(2); end
    endtask
    task await_ready(input [15:0] ep);
        begin
            @(negedge clk); lease_epoch=ep; lease_valid=1;
            cycles=0;
            while (!ready) begin tick(); cycles=cycles+1; if(cycles>12000) $fatal(1,"lease timeout %0d",ep); end
            if(applied_epoch!==ep) $fatal(1,"wrong epoch");
            checks=checks+1;
        end
    endtask
    initial begin
        tick(); @(negedge clk); rst=0;
        // Two epochs have different complete poses. Rendering the older lease
        // must select its own receipt, regardless of a later arriving pose.
        snapshot(16'd100,200,-300,32'd7);
        snapshot(16'd101,-500,100,32'd8);
        await_ready(100);
        if(!applied_enable || applied_sequence!==7 || fallback ||
            $signed(camera_roll_cd[15:0])!==200 || $signed(camera_pitch_cd[15:0])!==-300)
            $fatal(1,"older lease did not use captured pose");
        held_roll=camera_roll_cd; held_pitch=camera_pitch_cd;
        @(negedge clk); render_active=1; calibration_revision=1;
        static_roll_cd=96'h0000_0000_0000_0000_0000_0021;
        snapshot(102,800,800,9);
        repeat(15) begin tick(); if(!ready || camera_roll_cd!==held_roll || camera_pitch_cd!==held_pitch)
            $fatal(1,"active pass mutated"); end
        release_lease();
        // Replacing calibration between capture and lease chooses static
        // fallback, rather than mixing an old revision with new trims.
        await_ready(101);
        if(applied_enable || !fallback || !calibration_mismatch || camera_roll_cd!==static_roll_cd)
            $fatal(1,"calibration mismatch fallback failed");
        release_lease();
        // Missing and overwritten history tags make forward progress by using
        // static offsets; no unbounded wait for a pose that cannot arrive.
        await_ready(999);
        if(!history_miss || applied_enable || camera_roll_cd!==static_roll_cd) $fatal(1,"missing tag");
        release_lease();
        snapshot(16'd200,200,-300,10); snapshot(16'd216,-500,100,11);
        await_ready(200);
        if(!history_miss || !fallback) $fatal(1,"alias tag accepted");
        release_lease();
        // Age is evaluated at epoch capture; long renderer latency itself does
        // not retroactively change the captured sample's freshness decision.
        idle(12);
        @(negedge clk); epoch_capture=1; epoch_id=217; tick(); idle(1);
        await_ready(217);
        if(!stale_pose || applied_enable || camera_roll_cd!==static_roll_cd) $fatal(1,"stale pose");
        release_lease();
        stabilization_enabled=0; snapshot(218,200,-300,12); await_ready(218);
        if(applied_enable || camera_roll_cd!==static_roll_cd) $fatal(1,"disabled static bypass");
        release_lease();
        // Abort a calculation when the lease changes. The obsolete done pulse
        // must never publish a ready result for the new lease.
        stabilization_enabled=1; static_roll_cd=0;
        snapshot(220,200,-300,13); snapshot(221,-500,100,14);
        @(negedge clk); lease_valid=1; lease_epoch=220;
        idle(100);
        @(negedge clk); lease_epoch=221; tick();
        if(ready) $fatal(1,"old lease remained ready after tag change");
        await_ready(221);
        if(applied_sequence!==14 || $signed(camera_roll_cd[15:0])!==-500 ||
            $signed(camera_pitch_cd[15:0])!==99) $fatal(1,"cancelled pose published");
        release_lease();
        // Mode cancellation also abandons preparation, while preserving
        // history for the next valid panorama request.
        @(negedge clk); lease_valid=1; lease_epoch=220; tick(); idle(20);
        @(negedge clk); panorama_enable=0; tick();
        if(ready) $fatal(1,"ready while panorama disabled");
        idle(10); @(negedge clk); panorama_enable=1; sensor_ir=1;
        await_ready(221);
        if(applied_sequence!==14 || !applied_enable) $fatal(1,"mode restart");
        @(negedge clk); rst=1; tick();
        if(ready || camera_roll_cd!==0 || applied_enable) $fatal(1,"reset failed");
        $display("PASS GlLeasePose: %0d leases; frame association, freeze, fallback, overwrite, cancellation and reset", checks);
        $finish;
    end
    initial begin #2000000; $fatal(1,"global timeout"); end
endmodule
