`timescale 1ns/1ps
module tb_GlTriggerEpoch;
    reg clk=0; always #5 clk=~clk;
    reg rst=1, eo_async=0, ir_async=0;
    wire eo_capture, ir_capture;
    wire [15:0] eo_next, ir_next, eo_gray, ir_gray;
    GlTriggerEpoch eo(.clk(clk),.rst(rst),.trigger_async(eo_async),
        .epoch_capture(eo_capture),.next_epoch(eo_next),.epoch_gray(eo_gray));
    GlTriggerEpoch ir(.clk(clk),.rst(rst),.trigger_async(ir_async),
        .epoch_capture(ir_capture),.next_epoch(ir_next),.epoch_gray(ir_gray));
    integer eo_count=0, ir_count=0, checks=0, i;
    reg [15:0] expected_eo=0, expected_ir=0;
    // Sample the epoch exactly as the history would at its capture edge;
    // after that edge the writer Gray tag must name the same epoch.
    always @(posedge clk) begin
        if (rst) begin expected_eo=0; eo_count=0; end
        else if (eo_capture) begin
            expected_eo=expected_eo+16'd1;
            if(eo_next!==expected_eo) $fatal(1,"EO history next-tag mismatch");
            eo_count=eo_count+1; checks=checks+1;
        end
        #1;
        if(eo_gray!==(expected_eo^(expected_eo>>1))) $fatal(1,"EO writer Gray mismatch");
    end
    always @(posedge clk) begin
        if (rst) begin expected_ir=0; ir_count=0; end
        else if (ir_capture) begin
            expected_ir=expected_ir+16'd1;
            if(ir_next!==expected_ir) $fatal(1,"IR history next-tag mismatch");
            ir_count=ir_count+1;
        end
        #1;
        if(ir_gray!==(expected_ir^(expected_ir>>1))) $fatal(1,"IR writer Gray mismatch");
    end
    initial begin
        repeat(3) @(negedge clk); rst=0;
        // Independent asynchronous phases, then coincident long pulses.
        #3; eo_async=1; #41; eo_async=0;
        #17; ir_async=1; #43; ir_async=0;
        #37; eo_async=1; ir_async=1; #203; eo_async=0; ir_async=0;
        #60;
        if(eo_count!=2 || ir_count!=2) $fatal(1,"long pulse counted more than once");
        // An entire IR tag wrap does not alter the unrelated EO epoch.
        for(i=0;i<65536;i=i+1) begin
            #31; ir_async=1; #31; ir_async=0;
        end
        #60;
        if(ir_count!=65538 || expected_ir!==16'd2 || eo_count!=2)
            $fatal(1,"independent epoch wrap/count failed %0d %0d",ir_count,eo_count);
        @(negedge clk); rst=1; repeat(3) @(negedge clk); rst=0;
        #60;
        if(eo_count!=0 || ir_count!=0 || eo_gray!==0 || ir_gray!==0)
            $fatal(1,"reset leaked old counter state");
        #3; ir_async=1; #41; ir_async=0; #60;
        if(ir_count!=1 || eo_count!=0) $fatal(1,"post-reset first IR epoch");
        $display("PASS GlTriggerEpoch: independent phases, simultaneous edges, long pulses, 65536-tag wrap, reset and history/writer alignment");
        $finish;
    end
    initial begin #6000000; $fatal(1,"timeout"); end
endmodule
