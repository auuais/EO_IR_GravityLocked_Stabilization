`timescale 1ns/1ps
module tb_GlPoseReceiver;
    reg clk = 1'b0;
    always #5 clk = ~clk;
    reg rst = 1'b1;
    reg transaction_start = 1'b0;
    reg transaction_stop = 1'b0;
    reg byte_write = 1'b0;
    reg [7:0] byte_addr = 8'd0;
    reg [7:0] byte_data = 8'd0;
    wire signed [15:0] roll_cd, pitch_cd;
    wire pose_valid, pose_update;
    wire [31:0] sample_sequence, rejected_count;

    GlPoseReceiver dut (.*);

    reg signed [15:0] expected_roll = 16'sd0;
    reg signed [15:0] expected_pitch = 16'sd0;
    reg expected_valid = 1'b0;
    reg [31:0] expected_sequence = 32'd0;
    reg [31:0] expected_rejected = 32'd0;
    integer checks = 0;
    integer k, n;

    task automatic check_state(input bit update_expected);
        begin
            checks = checks + 1;
            if (roll_cd !== expected_roll || pitch_cd !== expected_pitch ||
                pose_valid !== expected_valid || pose_update !== update_expected ||
                sample_sequence !== expected_sequence || rejected_count !== expected_rejected)
                $fatal(1, "check %0d: got r=%0d p=%0d valid=%b update=%b seq=%0d rejects=%0d; expected r=%0d p=%0d valid=%b update=%b seq=%0d rejects=%0d",
                       checks, roll_cd, pitch_cd, pose_valid, pose_update, sample_sequence, rejected_count,
                       expected_roll, expected_pitch, expected_valid, update_expected,
                       expected_sequence, expected_rejected);
        end
    endtask

    task automatic tick(input bit starts, input bit stops, input bit writes,
                        input [7:0] addr, input [7:0] data);
        begin
            @(negedge clk);
            transaction_start = starts;
            transaction_stop = stops;
            byte_write = writes;
            byte_addr = addr;
            byte_data = data;
            @(posedge clk); #1;
        end
    endtask

    task automatic idle_tick;
        begin tick(0, 0, 0, 0, 0); check_state(0); end
    endtask

    task automatic start_tx(input bit rejects_previous);
        begin
            if (rejects_previous) expected_rejected = expected_rejected + 1;
            tick(1, 0, 0, 0, 0); check_state(0);
        end
    endtask

    task automatic put_byte(input [7:0] addr, input [7:0] data);
        begin tick(0, 0, 1, addr, data); check_state(0); end
    endtask

    task automatic put_pose(input signed [15:0] roll, input signed [15:0] pitch);
        begin
            put_byte(8'h10, roll[7:0]);
            put_byte(8'h11, roll[15:8]);
            put_byte(8'h12, pitch[7:0]);
            put_byte(8'h13, pitch[15:8]);
        end
    endtask

    task automatic accept_stop(input signed [15:0] roll, input signed [15:0] pitch);
        begin
            expected_roll = roll;
            expected_pitch = pitch;
            expected_valid = 1;
            expected_sequence = expected_sequence + 1;
            tick(0, 1, 0, 0, 0); check_state(1);
        end
    endtask

    task automatic discard_stop(input bit rejection_expected);
        begin
            if (rejection_expected) expected_rejected = expected_rejected + 1;
            tick(0, 1, 0, 0, 0); check_state(0);
        end
    endtask

    task automatic reset_dut;
        begin
            @(negedge clk);
            rst = 1;
            transaction_start = 0; transaction_stop = 0; byte_write = 0;
            expected_roll = 0; expected_pitch = 0; expected_valid = 0;
            expected_sequence = 0; expected_rejected = 0;
            @(posedge clk); #1; check_state(0);
            @(negedge clk); rst = 0;
        end
    endtask

    initial begin
        reset_dut();

        // No transaction means no commit, even if a producer presents bytes.
        put_pose(16'sd123, -16'sd456); discard_stop(0);
        start_tx(0); discard_stop(0); // empty transaction/address-only read

        // Signed extremes, LE ordering, and no clamp on the received value.
        start_tx(0); put_pose(16'sh1234, 16'shfedc);
        repeat (12) idle_tick(); // exact bytes alone are insufficient
        accept_stop(16'sh1234, 16'shfedc); idle_tick();
        start_tx(0); put_pose(16'sh7fff, 16'sh8000);
        accept_stop(16'sh7fff, 16'sh8000);

        // Starts on the immediately following cycle: no artificial dead time.
        start_tx(0); put_pose(-16'sd1000, 16'sd1000);
        accept_stop(-16'sd1000, 16'sd1000); idle_tick();

        // One, two, or three complete bytes must preserve the last good pair.
        for (n = 1; n <= 3; n = n + 1) begin
            start_tx(0);
            for (k = 0; k < n; k = k + 1) put_byte(8'h10 + k, 8'h5a + k);
            discard_stop(1); idle_tick();
        end

        // Repeated START discards both partial and complete-but-uncommitted data.
        start_tx(0); put_byte(8'h10, 8'h12); put_byte(8'h11, 8'h34);
        start_tx(1); discard_stop(0);
        start_tx(0); put_pose(16'sd111, 16'sd222);
        start_tx(1); put_pose(-16'sd333, -16'sd444);
        accept_stop(-16'sd333, -16'sd444); idle_tick();

        // A repeated START cannot turn the tail of the old transfer into a pose.
        start_tx(0); put_byte(8'h10, 8'h00);
        start_tx(1); put_byte(8'h11, 8'hff); put_byte(8'h12, 8'h00); put_byte(8'h13, 8'hff);
        discard_stop(1);

        // Any fifth byte, even unrelated, disqualifies the entire transaction.
        start_tx(0); put_pose(16'sd555, 16'sd666); put_byte(8'h14, 8'h77);
        discard_stop(1);
        start_tx(0); put_pose(16'sd555, 16'sd666); put_byte(8'h20, 8'h77);
        discard_stop(1);

        // Nonsequential, duplicate and misaligned byte events cannot commit.
        start_tx(0); put_byte(8'h10, 1); put_byte(8'h12, 2);
        put_byte(8'h11, 3); put_byte(8'h13, 4); discard_stop(1);
        start_tx(0); put_byte(8'h10, 1); put_byte(8'h10, 2);
        put_byte(8'h11, 3); put_byte(8'h12, 4); put_byte(8'h13, 5); discard_stop(1);
        start_tx(0); put_byte(8'h11, 1); put_byte(8'h12, 2);
        put_byte(8'h13, 3); put_byte(8'h14, 4); discard_stop(1);

        // Mixed leading configuration bytes are not mistaken for a pose burst.
        start_tx(0); put_byte(8'h0f, 8'h99); put_pose(16'sd777, 16'sd888);
        discard_stop(1);
        start_tx(0); put_byte(8'h20, 1); put_byte(8'h21, 2); discard_stop(0);
        start_tx(0); put_byte(8'h50, 3); start_tx(0); discard_stop(0);

        // A negative high-byte update must never leak a torn positive value.
        start_tx(0); put_pose(16'sd255, 16'sd256); accept_stop(16'sd255, 16'sd256);
        start_tx(0); put_byte(8'h10, 8'h00); repeat (3) idle_tick();
        put_byte(8'h11, 8'hff); repeat (3) idle_tick();
        put_byte(8'h12, 8'hff); repeat (3) idle_tick();
        put_byte(8'h13, 8'hfe); repeat (3) idle_tick();
        accept_stop(-16'sd256, -16'sd257); idle_tick();

        // STOP cannot acknowledge a final byte on the same event cycle.
        start_tx(0); put_byte(8'h10, 1); put_byte(8'h11, 2); put_byte(8'h12, 3);
        expected_rejected = expected_rejected + 1;
        tick(0, 1, 1, 8'h13, 4); check_state(0);
        // Even a previously complete candidate is rejected on conflicting STOP/write.
        start_tx(0); put_pose(16'sd55, 16'sd66);
        expected_rejected = expected_rejected + 1;
        tick(0, 1, 1, 8'h20, 5); check_state(0);

        // START conflicts must not create an apparently valid transaction.
        tick(1, 0, 1, 8'h10, 8'h99); check_state(0);
        put_pose(16'sd11, 16'sd22); discard_stop(1);
        tick(1, 1, 0, 0, 0); check_state(0);
        put_pose(16'sd11, 16'sd22); discard_stop(1);

        // Reset removes in-flight data and last-good validity without a pulse.
        start_tx(0); put_byte(8'h10, 8'hfe); put_byte(8'h11, 8'hff);
        reset_dut(); put_byte(8'h12, 8'hff); put_byte(8'h13, 8'hff); discard_stop(0);
        start_tx(0); put_pose(-16'sd1, 16'sd1); accept_stop(-16'sd1, 16'sd1);
        idle_tick(); discard_stop(0); // duplicate STOP cannot duplicate a receipt

        $display("PASS GlPoseReceiver: %0d state checks; atomic pose receipt and rejection cases", checks);
        $finish;
    end

    initial begin
        #100000;
        $fatal(1, "GlPoseReceiver test timeout");
    end
endmodule
