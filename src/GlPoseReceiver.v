`timescale 1ns/1ps
// Atomic receipt of the MCU's existing orientation write transaction.
//
// All inputs are synchronous to clk. transaction_start is every I2C START,
// including a repeated START. byte_write is one pulse AFTER the slave has
// completed the ACK for a received data byte; its addr/data must describe that
// acknowledged byte. The I2C register-address byte is not a byte_write event.
// transaction_stop is the bus STOP. Commit requires an entire transaction
// containing exactly four bytes at 0x10, 0x11, 0x12, 0x13 in that order.
//
// A START abandons any earlier transaction. Bad, partial, excess, mixed and
// unrelated writes never change the committed pose. Reset clears validity.
// Simultaneous START/STOP/write events are invalid: START has abort priority,
// and STOP combined with a byte cannot commit. Normal producers must emit
// these events separately. No idle-time heuristic or angle clamp is applied.
//
// sample_sequence counts accepted FPGA receipts (wrapping modulo 2^32). It is
// NOT an IMU sample counter, camera exposure identifier, or timestamp.
// rejected_count counts abandoned/malformed transactions that touch at least
// one of the four pose addresses; wholly unrelated transactions are ignored.
module GlPoseReceiver (
    input  wire               clk,
    input  wire               rst,
    input  wire               transaction_start,
    input  wire               transaction_stop,
    input  wire               byte_write,
    input  wire [7:0]         byte_addr,
    input  wire [7:0]         byte_data,
    output reg  signed [15:0] roll_cd,
    output reg  signed [15:0] pitch_cd,
    output reg                pose_valid,
    output reg                pose_update,
    output reg  [31:0]        sample_sequence,
    output reg  [31:0]        rejected_count
);
    reg        active;
    reg        malformed;
    reg        pose_touched;
    reg [2:0]  byte_count;
    reg [31:0] staging;

    wire is_pose_addr = (byte_addr >= 8'h10) && (byte_addr <= 8'h13);
    wire [7:0] expected_addr = 8'h10 + {5'd0, byte_count};

    always @(posedge clk) begin
        if (rst) begin
            active          <= 1'b0;
            malformed       <= 1'b0;
            pose_touched    <= 1'b0;
            byte_count      <= 3'd0;
            staging         <= 32'd0;
            roll_cd         <= 16'sd0;
            pitch_cd        <= 16'sd0;
            pose_valid      <= 1'b0;
            pose_update     <= 1'b0;
            sample_sequence <= 32'd0;
            rejected_count  <= 32'd0;
        end else begin
            pose_update <= 1'b0;
            if (transaction_start) begin
                if (active && pose_touched)
                    rejected_count <= rejected_count + 32'd1;
                active       <= 1'b1;
                malformed    <= transaction_stop || byte_write;
                pose_touched <= byte_write && is_pose_addr;
                byte_count   <= 3'd0;
                staging      <= 32'd0;
            end else if (transaction_stop) begin
                if (active && !malformed && (byte_count == 3'd4) && !byte_write) begin
                    roll_cd         <= staging[15:0];
                    pitch_cd        <= staging[31:16];
                    pose_valid      <= 1'b1;
                    pose_update     <= 1'b1;
                    sample_sequence <= sample_sequence + 32'd1;
                end else if (active && (pose_touched || (byte_write && is_pose_addr))) begin
                    rejected_count <= rejected_count + 32'd1;
                end
                active       <= 1'b0;
                malformed    <= 1'b0;
                pose_touched <= 1'b0;
                byte_count   <= 3'd0;
            end else if (byte_write && active) begin
                if (is_pose_addr)
                    pose_touched <= 1'b1;
                if (!malformed && (byte_count < 3'd4) && (byte_addr == expected_addr)) begin
                    case (byte_count)
                        3'd0: staging[7:0]   <= byte_data;
                        3'd1: staging[15:8]  <= byte_data;
                        3'd2: staging[23:16] <= byte_data;
                        3'd3: staging[31:24] <= byte_data;
                        default: ;
                    endcase
                    byte_count <= byte_count + 3'd1;
                end else begin
                    malformed <= 1'b1;
                end
            end
        end
    end
endmodule
