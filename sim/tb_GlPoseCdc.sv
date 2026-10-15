`timescale 1ns/1ps
module tb_GlPoseCdc;
    parameter integer SRC_HALF_NS = 5;
    parameter integer DST_HALF_NS = 7;
    parameter integer DST_PHASE_NS = 3;
    reg src_clk = 0;
    reg dst_clk = 0;
    reg rst = 0;
    reg src_update = 0;
    reg signed [15:0] src_roll_cd = 0;
    reg signed [15:0] src_pitch_cd = 0;
    reg [31:0] src_receipt_sequence = 0;
    wire dst_valid, dst_update;
    wire signed [15:0] dst_roll_cd, dst_pitch_cd;
    wire [31:0] dst_receipt_sequence;
    wire [63:0] dst_bus = {dst_receipt_sequence, dst_roll_cd, dst_pitch_cd};
    GlPoseCdc dut (.*);

    always #(SRC_HALF_NS) src_clk = ~src_clk;
    initial begin
        #(DST_PHASE_NS);
        forever #(DST_HALF_NS) dst_clk = ~dst_clk;
    end

    function automatic [63:0] pattern(input [31:0] seq);
        reg [15:0] r, p;
        begin
            r = seq[15:0] ^ seq[31:16] ^ 16'h57a3;
            p = {seq[7:0], seq[15:8]} ^ ~seq[31:16] ^ 16'h8c19;
            pattern = {seq, r, p};
        end
    endfunction

    // Model actual accepted source edges, not the DUT's request decisions.
    // Intermediate samples may be coalesced, but delivered samples must be
    // intact, unique and ordered by acceptance index even across seq wrap.
    reg [63:0] accepted [0:2047];
    integer sent_count = 0;
    integer received_count = 0;
    integer last_index = -1;
    integer found_index;
    integer i;
    reg seen_valid = 0;
    reg [63:0] previous_output = 0;
    always @(posedge src_clk or posedge rst) begin
        if (rst) sent_count = 0;
        else if (!dut.src_reset && src_update) begin
            if (sent_count >= 2048) $fatal(1, "scoreboard overflow");
            accepted[sent_count] = {src_receipt_sequence, src_roll_cd, src_pitch_cd};
            sent_count = sent_count + 1;
        end
    end
    always @(negedge dst_clk or posedge rst) begin
        if (rst) begin
            received_count = 0;
            last_index = -1;
            seen_valid = 0;
            previous_output = 0;
        end else if (!dut.dst_reset) begin
            if (dst_update) begin
                if (!dst_valid) $fatal(1, "update without valid");
                if (dst_bus !== pattern(dst_receipt_sequence))
                    $fatal(1, "torn pose/sequence: %h", dst_bus);
                found_index = -1;
                for (i = last_index + 1; i < sent_count; i = i + 1)
                    if ((found_index < 0) && (accepted[i] === dst_bus)) found_index = i;
                if (found_index < 0)
                    $fatal(1, "duplicate, unordered or invented delivery: %h", dst_bus);
                last_index = found_index;
                received_count = received_count + 1;
            end else if (seen_valid && (dst_bus !== previous_output)) begin
                $fatal(1, "output changed without update");
            end
            if (seen_valid && !dst_valid) $fatal(1, "valid dropped without reset");
            seen_valid = dst_valid;
            previous_output = dst_bus;
        end
    end

    reg previous_busy = 0;
    reg [63:0] previous_transfer = 0;
    always @(negedge src_clk or posedge rst) begin
        if (rst) begin
            previous_busy = 0;
            previous_transfer = 0;
        end else begin
            if (previous_busy && dut.src_busy && (dut.transfer_bus !== previous_transfer))
                $fatal(1, "transfer bus changed before acknowledgement");
            previous_busy = dut.src_busy;
            previous_transfer = dut.transfer_bus;
        end
    end

    task automatic drive(input [31:0] seq);
        begin
            @(negedge src_clk);
            {src_receipt_sequence, src_roll_cd, src_pitch_cd} = pattern(seq);
            src_update = 1;
        end
    endtask
    task automatic stop_source;
        begin
            @(negedge src_clk);
            src_update = 0;
        end
    endtask
    task automatic wait_latest(input [31:0] seq);
        integer cycles;
        begin
            cycles = 0;
            while (!(dst_valid && dst_receipt_sequence == seq) && cycles < 100) begin
                @(negedge dst_clk);
                #0.001;
                cycles = cycles + 1;
            end
            if (!(dst_valid && dst_receipt_sequence == seq))
                $fatal(1, "latest pending value was lost: expected %h", seq);
            repeat (20) @(negedge dst_clk);
            #0.001;
            if (last_index != sent_count - 1) $fatal(1, "latest index not delivered");
        end
    endtask
    task automatic release_reset;
        begin
            repeat (5) @(negedge src_clk);
            #1 rst = 0;
            repeat (4) @(negedge src_clk);
            repeat (4) @(negedge dst_clk);
            #0.001;
            if (dst_valid || dst_update) $fatal(1, "phantom delivery after reset");
        end
    endtask

    integer n;
    integer stable_count;
    initial begin
        #1 rst = 1;
        release_reset();
        drive(32'h00000000);
        stop_source();
        wait_latest(32'h00000000);
        if (received_count != 1) $fatal(1, "isolated update not delivered exactly once");

        // Source updates on every source edge while a transfer is in flight.
        for (n = 1; n <= 160; n = n + 1) drive(n);
        stop_source();
        wait_latest(32'd160);
        if (received_count >= sent_count) $fatal(1, "burst did not exercise coalescing");

        for (n = 0; n < 8; n = n + 1) drive(32'hfffffffc + n);
        stop_source();
        wait_latest(32'd3);
        stable_count = received_count;
        repeat (40) @(negedge dst_clk);
        #0.001;
        if (received_count != stable_count) $fatal(1, "duplicate delivery during idle");

        // Common reset before the new request can cross into the destination.
        drive(32'h71234567);
        @(posedge src_clk);
        #0.001;
        if (!dut.src_busy) $fatal(1, "reset scenario was not in flight");
        rst = 1;
        src_update = 0;
        #0.001;
        if (dst_valid || dst_update || dst_bus !== 64'd0)
            $fatal(1, "reset assertion did not clear outputs");
        release_reset();
        repeat (40) @(negedge dst_clk);
        if (dst_valid || received_count != 0) $fatal(1, "old epoch leaked after reset");

        // Bursts interspersed with idle gaps cover pending/drain collisions.
        for (n = 0; n < 96; n = n + 1) begin
            drive(32'ha5a50000 + n);
            if ((n % 7) == 3) begin
                stop_source();
                repeat (3) @(negedge src_clk);
            end
        end
        stop_source();
        wait_latest(32'ha5a5005f);
        $display("PASS GlPoseCdc src_half=%0d dst_half=%0d phase=%0d last_epoch_sent=%0d delivered=%0d",
                 SRC_HALF_NS, DST_HALF_NS, DST_PHASE_NS, sent_count, received_count);
        $finish;
    end
    initial begin
        #200000;
        $fatal(1, "testbench timeout");
    end
endmodule
