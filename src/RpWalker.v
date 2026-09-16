//============================================================================
// RpWalker
//
// For one source row y0 at a time, issues a pixel token for every output
// pixel whose (clamped) source row is <= y0, in segment order.  Two sources of
// segments feed it:
//
//   queue   segments started on an earlier y0 and not yet exhausted (URAM
//           FIFO, entries in PARAMS layout with the walked i/ax/ay)
//   PARAMS  segments whose first walked pixel samples y0: indices
//           p_next .. BUCKET_END[y0]-1, p_next persisting across the pass
//
// Only the queue entries present when y0 starts are popped; segments pushed
// back during y0 are for later rows.  Per segment the walk takes pixels while
//
//   take = y0_last || ay < 0 || floor(ay) <= y0
//
// and, when a pixel is not taken, pushes the segment back with its current
// state.  A token costs one cycle; changing segment costs none (the next entry
// is prefetched), so a y0 costs (pixels + visits) cycles.
//
// RowWindow aliasing: a pixel for output row sy may only be issued while
// sy - sy_out < SLOTS-1 (sy_out is the row the emitter is on).  Otherwise the
// walker stalls if the emitter can still make progress, and drops the pixel
// (drop_valid) if it cannot -- the geometry then genuinely exceeds the window.
//============================================================================
`timescale 1ns/1ps
module RpWalker #(
    parameter integer SLOTS = 256,
    parameter integer QDEPTH_LOG2 = 12
) (
    input  wire         clk,
    input  wire         rst,            // also used as the pass abort
    input  wire         pass_start,     // clears queue and p_next

    input  wire         y0_go,          // start y0 (idle must be high)
    input  wire [10:0]  y0,
    input  wire         y0_last,
    input  wire [15:0]  bucket_end,     // BUCKET_END[y0], stable from y0_go
    output wire         idle,

    output reg  [14:0]  params_raddr,
    input  wire [143:0] params_rdata,   // latency 2

    input  wire [8:0]   sy_out,
    input  wire         emit_can_progress,

    output reg          tok_valid,
    output reg  [2:0]   tok_cam,
    output reg  [8:0]   tok_sy,
    output reg  [9:0]   tok_lx,
    output reg  signed [31:0] tok_ax,
    output reg  signed [31:0] tok_ay,
    output reg          drop_valid,
    output reg  [8:0]   drop_sy,

    output reg          queue_overflow_seen,
    output reg          alias_drop_seen,
    output reg  [QDEPTH_LOG2:0] queue_peak,
    output reg  [31:0]  visit_count
);
    localparam integer QDEPTH = 1 << QDEPTH_LOG2;

    //------------------------------------------------------------------------
    // Queue memory (URAM)
    //------------------------------------------------------------------------
    (* ram_style = "ultra" *) reg [143:0] qmem [0:QDEPTH-1];
    reg                    q_we;
    reg [QDEPTH_LOG2-1:0]  q_waddr, q_raddr;
    reg [143:0]            q_wdata, q_rq, q_rdata;
    always @(posedge clk) begin
        if (q_we) qmem[q_waddr] <= q_wdata;
    end
    always @(posedge clk) begin
        q_rq    <= qmem[q_raddr];
        q_rdata <= q_rq;
    end

    reg [QDEPTH_LOG2-1:0] wptr, rptr;
    reg [QDEPTH_LOG2:0]   qcount;

    //------------------------------------------------------------------------
    // Fetch: queue first, then PARAMS, into a 4-entry prefetch buffer
    //------------------------------------------------------------------------
    reg                   active;          // y0 in progress
    reg [QDEPTH_LOG2:0]   q_left;
    reg [15:0]            p_next;
    // {valid, from_params}: the read address is registered here (1), the
    // memory registers it (2) and its output register (3) -- data is usable
    // in the cycle infl_v3 marks.
    reg [1:0]             infl_v1, infl_v2, infl_v3;

    reg [143:0] buf_mem [0:3];
    reg [1:0]   buf_rd, buf_wr;
    reg [2:0]   buf_cnt;
    wire [2:0]  inflight = {2'b0, infl_v1[1]} + {2'b0, infl_v2[1]} + {2'b0, infl_v3[1]};
    wire        can_fetch = active && ((buf_cnt + inflight) < 3'd4);
    wire        fetch_q = can_fetch && (q_left != 0);
    wire        fetch_p = can_fetch && (q_left == 0) && (p_next < bucket_end);

    //------------------------------------------------------------------------
    // Current segment
    //------------------------------------------------------------------------
    reg         cur_v;
    reg [8:0]   cur_sy;
    reg [2:0]   cur_cam;
    reg [3:0]   cur_seg;
    reg [5:0]   cur_i;
    reg         cur_dir;
    reg [5:0]   cur_last;
    reg signed [31:0] cur_ax, cur_ay;
    reg signed [23:0] cur_stx, cur_sty;

    wire signed [15:0] cur_ay_int = cur_ay[31:16];
    wire take = y0_last || cur_ay[31] || (cur_ay_int <= $signed({5'd0, y0}));
    wire [8:0] dsy = cur_sy - sy_out;
    wire alias_ok = (dsy < SLOTS - 1);
    wire exhausted = cur_dir ? (cur_i == cur_last) : (cur_i == 6'd0);

    wire stall   = cur_v && take && !alias_ok && emit_can_progress;
    wire emit    = cur_v && take && !stall;
    wire release_seg = cur_v && ((take && !stall && exhausted) || !take);
    wire push    = cur_v && !take;
    wire want_next = !cur_v || release_seg;
    wire load    = want_next && (buf_cnt != 3'd0);

    wire [143:0] head = buf_mem[buf_rd];

    assign idle = !active && !cur_v && (buf_cnt == 0) && (inflight == 0);

    always @(posedge clk) begin
        if (rst) begin
            active <= 1'b0; q_left <= 0; p_next <= 16'd0;
            wptr <= 0; rptr <= 0; qcount <= 0;
            infl_v1 <= 2'b00; infl_v2 <= 2'b00; infl_v3 <= 2'b00;
            buf_rd <= 0; buf_wr <= 0; buf_cnt <= 0;
            cur_v <= 1'b0;
            q_we <= 1'b0;
            tok_valid <= 1'b0; drop_valid <= 1'b0;
            queue_overflow_seen <= 1'b0; alias_drop_seen <= 1'b0;
            queue_peak <= 0; visit_count <= 32'd0;
        end else begin
            q_we <= 1'b0;
            tok_valid <= 1'b0;
            drop_valid <= 1'b0;

            if (pass_start) begin
                p_next <= 16'd0; wptr <= 0; rptr <= 0; qcount <= 0;
                queue_peak <= 0; visit_count <= 32'd0;
            end

            // ---- y0 start --------------------------------------------------
            if (y0_go) begin
                active <= 1'b1;
                q_left <= qcount;
            end

            // ---- fetch -----------------------------------------------------
            infl_v1 <= {fetch_q | fetch_p, fetch_p};
            infl_v2 <= infl_v1;
            infl_v3 <= infl_v2;
            if (fetch_q) begin
                q_raddr <= rptr;
                rptr    <= rptr + 1'b1;
                q_left  <= q_left - 1'b1;
            end
            if (fetch_p) begin
                params_raddr <= p_next[14:0];
                p_next       <= p_next + 16'd1;
            end
            // Arrival: the stage-3 marker lines up with q_rdata/params_rdata.
            if (infl_v3[1]) begin
                buf_mem[buf_wr] <= infl_v3[0] ? params_rdata : q_rdata;
                buf_wr <= buf_wr + 2'd1;
            end
            buf_cnt <= buf_cnt + (infl_v3[1] ? 3'd1 : 3'd0) - (load ? 3'd1 : 3'd0);
            if (load) buf_rd <= buf_rd + 2'd1;

            // ---- walk ------------------------------------------------------
            if (emit) begin
                if (alias_ok) begin
                    tok_valid <= 1'b1;
                end else begin
                    drop_valid <= 1'b1;
                    drop_sy <= cur_sy;
                    alias_drop_seen <= 1'b1;
                end
                tok_cam <= cur_cam;
                tok_sy  <= cur_sy;
                tok_lx  <= {cur_seg, 6'd0} + {4'd0, cur_i};
                tok_ax  <= cur_ax;
                tok_ay  <= cur_ay;
                cur_i   <= cur_dir ? (cur_i + 6'd1) : (cur_i - 6'd1);
                cur_ax  <= cur_ax + cur_stx;
                cur_ay  <= cur_ay + cur_sty;
            end
            if (push) begin
                q_we    <= 1'b1;
                q_waddr <= wptr;
                q_wdata <= {cur_sy, cur_cam, cur_seg, cur_i, cur_dir, cur_last,
                            cur_ax, cur_ay, cur_stx, cur_sty, 3'b000};
                wptr    <= wptr + 1'b1;
            end
            if (qcount == QDEPTH && push) queue_overflow_seen <= 1'b1;
            qcount <= qcount + (push ? 1'b1 : 1'b0) - (fetch_q ? 1'b1 : 1'b0);
            if (qcount > queue_peak) queue_peak <= qcount;

            if (release_seg) cur_v <= 1'b0;
            if (load) begin
                cur_v    <= 1'b1;
                cur_sy   <= head[143:135];
                cur_cam  <= head[134:132];
                cur_seg  <= head[131:128];
                cur_i    <= head[127:122];
                cur_dir  <= head[121];
                cur_last <= head[120:115];
                cur_ax   <= head[114:83];
                cur_ay   <= head[82:51];
                cur_stx  <= head[50:27];
                cur_sty  <= head[26:3];
                visit_count <= visit_count + 32'd1;
            end

            // ---- y0 end: nothing left to fetch, buffer empty, no segment ----
            if (active && !y0_go && (q_left == 0) && !fetch_q && !fetch_p &&
                (p_next >= bucket_end) && (inflight == 0) && (buf_cnt == 0) &&
                !infl_v1[1] && !cur_v && !load)
                active <= 1'b0;
        end
    end
endmodule
