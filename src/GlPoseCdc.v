`timescale 1ns/1ps

// Atomic latest-value pose mailbox. The receipt sequence counts completed
// incoming pose transactions; it is NOT an exposure timestamp or frame ID.
//
// Reset contract: rst is a COMMON active-high reset for BOTH clock domains.
// Assertion is asynchronous; each domain releases internally after two local
// edges. Independent domain resets are unsupported. An in-flight or pending
// sample is discarded by common reset. Clock stoppage delays delivery safely.
// src_update is ignored during reset and the first two source edges after rst
// falls. Once released, every asserted source edge supplies a new snapshot;
// bursts may discard intermediate snapshots, but retain the latest pending one.
//
// CDC contract: transfer_bus is held from request launch until the returned
// acknowledgement has crossed two source flops. The destination samples that
// stable bus only after the request crosses two destination flops. Do not add
// independent synchronizers to the data bits. Implementation still requires
// CDC review and suitable bundled-data timing/skew constraints; simulation is
// functional verification, not physical CDC signoff.
module GlPoseCdc (
    input  wire               rst,
    input  wire               src_clk,
    input  wire               src_update,
    input  wire signed [15:0] src_roll_cd,
    input  wire signed [15:0] src_pitch_cd,
    input  wire        [31:0] src_receipt_sequence,
    input  wire               dst_clk,
    output reg                dst_valid,
    output reg                dst_update,
    output reg signed [15:0]  dst_roll_cd,
    output reg signed [15:0]  dst_pitch_cd,
    output reg         [31:0] dst_receipt_sequence
);
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] src_reset_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] dst_reset_sync;
    wire src_reset = src_reset_sync[1];
    wire dst_reset = dst_reset_sync[1];

    always @(posedge src_clk or posedge rst) begin
        if (rst) src_reset_sync <= 2'b11;
        else     src_reset_sync <= {src_reset_sync[0], 1'b0};
    end
    always @(posedge dst_clk or posedge rst) begin
        if (rst) dst_reset_sync <= 2'b11;
        else     dst_reset_sync <= {dst_reset_sync[0], 1'b0};
    end

    reg req_toggle;
    reg ack_toggle;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] ack_sync;
    (* ASYNC_REG = "TRUE", SHREG_EXTRACT = "NO" *) reg [1:0] req_sync;
    reg [63:0] transfer_bus;
    reg [63:0] pending_bus;
    reg pending_valid;
    wire src_busy = req_toggle != ack_sync[1];
    wire [63:0] src_bus = {src_receipt_sequence, src_roll_cd, src_pitch_cd};

    // Reset all state from the domain-local reset: assertion propagates
    // asynchronously from common rst; release occurs only on local edges.
    // Avoid an additional synchronous reset mux between synchronizer stages.
    always @(posedge src_clk or posedge src_reset) begin
        if (src_reset) begin
            ack_sync <= 2'b00;
            req_toggle <= 1'b0;
            transfer_bus <= 64'd0;
            pending_bus <= 64'd0;
            pending_valid <= 1'b0;
        end else begin
            ack_sync <= {ack_sync[0], ack_toggle};
            if (!src_busy) begin
                // A new update supersedes an older queued value. Otherwise
                // drain the pending value even if no further updates arrive.
                if (src_update || pending_valid) begin
                    transfer_bus <= src_update ? src_bus : pending_bus;
                    req_toggle <= ~req_toggle;
                    pending_valid <= 1'b0;
                end
            end else if (src_update) begin
                pending_bus <= src_bus;
                pending_valid <= 1'b1;
            end
        end
    end

    always @(posedge dst_clk or posedge dst_reset) begin
        if (dst_reset) begin
            req_sync <= 2'b00;
            ack_toggle <= 1'b0;
            dst_valid <= 1'b0;
            dst_update <= 1'b0;
            dst_roll_cd <= 16'sd0;
            dst_pitch_cd <= 16'sd0;
            dst_receipt_sequence <= 32'd0;
        end else begin
            req_sync <= {req_sync[0], req_toggle};
            dst_update <= 1'b0;
            if (req_sync[1] != ack_toggle) begin
                {dst_receipt_sequence, dst_roll_cd, dst_pitch_cd} <= transfer_bus;
                dst_valid <= 1'b1;
                dst_update <= 1'b1;
                ack_toggle <= req_sync[1];
            end
        end
    end
endmodule
