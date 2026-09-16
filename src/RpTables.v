//============================================================================
// RpTables
//
// Rebuilds the source-driven renderer's schedule whenever the per-camera
// roll/pitch offsets change, and owns the resulting tables:
//
//   PARAMS[p]      one walk-ready entry per RowRun segment, ordered by the
//                  source row its first walked pixel samples (st).  144 bits:
//                  {sy 9, cam 3, seg 4, i 6, dir 1, last 6, ax 32, ay 32,
//                   step_x 24, step_y 24, 3'b0}
//   BUCKET_END[y]  one past the last PARAMS index with st <= y
//   ROW_READY[sy]  max en over the row: the source row after which output row
//                  sy is complete
//   ylo/yhi        first and last source row the pass has to visit
//   col_lo/col_hi  source column envelope (segment endpoints, clamped)
//
// Two passes over the 31680 segments with a prefix sum between them -- a
// counting sort that keeps ROM order inside a bucket.  Everything is serial
// (one segment at a time); a full rebuild is ~0.8 M cycles, ~3.5 ms at
// 233 MHz, and only happens when an offset changes.
//
// model/golden.py build_tables() is the reference.
//============================================================================
`timescale 1ns/1ps
module RpTables #(
    parameter integer NUM_ROWS  = 480,
    parameter integer SEGS      = 11,       // EO geometry
    parameter integer SEG_W     = 64,
    parameter integer CAM0_W    = 650,
    parameter integer CAM1_W    = 655,
    parameter integer CAM2_W    = 655,
    parameter integer CAM3_W    = 655,
    parameter integer CAM4_W    = 655,
    parameter integer CAM5_W    = 655,
    parameter integer SRC_W     = 1920,
    parameter integer SRC_H     = 1080,
    // IR geometry.  IR camera 2 is 640 wide, not 621: IrV19StreamingRenderer
    // extends it to source column 639 for the fold-straddling cam2/cam3 seam,
    // extrapolating its last RowRun segment.
    parameter integer IR_SEGS   = 10,
    parameter integer IR_CAM0_W = 616,
    parameter integer IR_CAM1_W = 621,
    parameter integer IR_CAM2_W = 640,
    parameter integer IR_CAM3_W = 621,
    parameter integer IR_CAM4_W = 621,
    parameter integer IR_CAM5_W = 621,
    parameter integer IR_SRC_W  = 640,
    parameter integer IR_SRC_H  = 512,
    parameter integer ANGLE_MAX = 1000,
    parameter         ANGLE_ROM_FILE    = "../../assets/rollpitch/eo_rp_angle.mem",
    parameter         IR_ANGLE_ROM_FILE = "../../assets/rollpitch/ir_rp_angle.mem"
) (
    input  wire         clk,
    input  wire         rst,
    input  wire         sensor_ir,          // latched at build_req

    input  wire         build_req,
    input  wire [95:0]  roll_cd,          // cam0 in [15:0], signed centi-degrees
    input  wire [95:0]  pitch_cd,
    output reg          busy,
    output reg          tables_valid,
    output reg          sat_seen,
    output reg  [31:0]  build_count,
    output reg  [10:0]  ylo,
    output reg  [10:0]  yhi,
    output reg  [10:0]  col_lo,
    output reg  [10:0]  col_hi,

    // segment ROMs (registered output, latency 1), one address for both
    output reg  [14:0]  rom_addr,
    input  wire [143:0] rom_data,           // EO: {day, dax, ay0, ax0} at [143:48]
    input  wire [95:0]  rom_data_ir,        // IR: {day, dax, ay0, ax0} at [95:0]
    output reg          built_ir,           // sensor the current tables describe

    // runtime read ports
    input  wire [14:0]  params_raddr,
    output reg  [143:0] params_rdata,     // latency 2
    input  wire [10:0]  bend_raddr,
    output reg  [15:0]  bend_rdata,       // latency 1
    input  wire [8:0]   rready_raddr,
    output reg  [10:0]  rready_rdata      // latency 1
);
    reg         ir_l;                     // sensor latched for this build
    wire [3:0]  segs_n      = ir_l ? IR_SEGS[3:0] : SEGS[3:0];
    wire [14:0] last_seg_k  = ir_l ? (NUM_ROWS * 6 * IR_SEGS - 1) : (NUM_ROWS * 6 * SEGS - 1);
    wire [10:0] last_bucket = ir_l ? (IR_SRC_H - 2) : (SRC_H - 2);   // sched_y 0..YMAX

    //------------------------------------------------------------------------
    // Memories
    //------------------------------------------------------------------------
    (* ram_style = "ultra" *) reg [143:0] params_mem [0:32767];
    reg [143:0] params_q;
    reg         params_we;
    reg [14:0]  params_waddr;
    reg [143:0] params_wdata;
    always @(posedge clk) begin
        if (params_we) params_mem[params_waddr] <= params_wdata;
    end
    always @(posedge clk) begin
        params_q     <= params_mem[params_raddr];
        params_rdata <= params_q;
    end

    (* ram_style = "block" *) reg [15:0] bend_mem [0:2047];
    reg        bend_we;
    reg [10:0] bend_waddr;
    reg [15:0] bend_wdata;
    always @(posedge clk) begin
        if (bend_we) bend_mem[bend_waddr] <= bend_wdata;
        bend_rdata <= bend_mem[bend_raddr];
    end

    // ROW_READY: the builder reads it while building (runtime is idle then),
    // so one read port is shared through a mux.
    (* ram_style = "block" *) reg [10:0] rr_mem [0:511];
    reg        rr_we;
    reg [8:0]  rr_waddr;
    reg [10:0] rr_wdata;
    reg [8:0]  rr_bld_raddr;
    wire [8:0] rr_raddr = busy ? rr_bld_raddr : rready_raddr;
    always @(posedge clk) begin
        if (rr_we) rr_mem[rr_waddr] <= rr_wdata;
        rready_rdata <= rr_mem[rr_raddr];
    end

    // Counts, then start pointers.
    (* ram_style = "block" *) reg [15:0] cnt_mem [0:2047];
    reg        cnt_we;
    reg [10:0] cnt_waddr, cnt_raddr;
    reg [15:0] cnt_wdata, cnt_rdata;
    always @(posedge clk) begin
        if (cnt_we) cnt_mem[cnt_waddr] <= cnt_wdata;
        cnt_rdata <= cnt_mem[cnt_raddr];
    end

    (* rom_style = "distributed" *) reg [40:0] angle_rom [0:ANGLE_MAX];
    (* rom_style = "distributed" *) reg [40:0] angle_rom_ir [0:ANGLE_MAX];
    initial $readmemh(ANGLE_ROM_FILE, angle_rom);
    initial $readmemh(IR_ANGLE_ROM_FILE, angle_rom_ir);
    reg [9:0]  ang_addr;
    reg [40:0] ang_q;
    // cos/sin are the same in both; only the pitch row shift (the sensor's
    // pitch_to_translation_factor) differs.
    always @(posedge clk) ang_q <= ir_l ? angle_rom_ir[ang_addr] : angle_rom[ang_addr];

    //------------------------------------------------------------------------
    // Per-camera offset constants
    //------------------------------------------------------------------------
    function signed [15:0] clamp_cd;
        input signed [15:0] v;
        begin
            if (v > ANGLE_MAX)       clamp_cd = ANGLE_MAX;
            else if (v < -ANGLE_MAX) clamp_cd = -ANGLE_MAX;
            else                     clamp_cd = v;
        end
    endfunction
    function [9:0] mag_cd;
        input signed [15:0] v;
        reg signed [15:0] c;
        begin
            c = clamp_cd(v);
            mag_cd = c[15] ? (-c) : c;
        end
    endfunction

    reg [95:0] roll_l, pitch_l;
    reg signed [17:0] cam_c [0:5];
    reg signed [16:0] cam_s [0:5];
    reg signed [7:0]  cam_ysh [0:5];

    function integer cam_width;
        input integer cam;
        input         ir;
        begin
            if (ir)
                case (cam)
                    0: cam_width = IR_CAM0_W; 1: cam_width = IR_CAM1_W; 2: cam_width = IR_CAM2_W;
                    3: cam_width = IR_CAM3_W; 4: cam_width = IR_CAM4_W; default: cam_width = IR_CAM5_W;
                endcase
            else
                case (cam)
                    0: cam_width = CAM0_W; 1: cam_width = CAM1_W; 2: cam_width = CAM2_W;
                    3: cam_width = CAM3_W; 4: cam_width = CAM4_W; default: cam_width = CAM5_W;
                endcase
        end
    endfunction

    //------------------------------------------------------------------------
    // Segment iterator and transform
    //------------------------------------------------------------------------
    reg  [8:0]  it_sy;
    reg  [2:0]  it_cam;
    reg  [3:0]  it_seg;
    reg  [14:0] it_k;
    reg  [5:0]  it_last;
    always @* begin : last_calc
        integer w, rem;
        w   = cam_width(it_cam, ir_l);
        rem = w - it_seg * SEG_W;
        it_last = ((rem >= SEG_W) ? SEG_W : rem) - 1;
    end

    reg                xf_in_valid;
    reg signed [17:0]  xf_c;
    reg signed [16:0]  xf_s;
    reg signed [7:0]   xf_ysh;
    reg [22:0]         xf_tag;
    reg [5:0]          xf_last;
    wire               xf_valid;
    wire [22:0]        xf_otag;
    wire [5:0]         xf_i0, xf_olast;
    wire               xf_dir, xf_sat;
    wire signed [31:0] xf_ax, xf_ay;
    wire signed [23:0] xf_stx, xf_sty;
    wire [10:0]        xf_st, xf_en, xf_xa, xf_xb;

    wire [95:0] rec = ir_l ? rom_data_ir : rom_data[143:48];
    RpSegXform #(.SRC_W(SRC_W), .SRC_H(SRC_H), .IR_SRC_W(IR_SRC_W), .IR_SRC_H(IR_SRC_H)) u_xf (
        .clk(clk), .in_ir(ir_l), .in_valid(xf_in_valid),
        .in_ax0($signed(rec[31:0])), .in_ay0($signed(rec[63:32])),
        .in_dax($signed(rec[79:64])), .in_day($signed(rec[95:80])),
        .in_last(xf_last), .in_c(xf_c), .in_s(xf_s), .in_ysh(xf_ysh), .in_tag(xf_tag),
        .out_valid(xf_valid), .out_tag(xf_otag), .out_i0(xf_i0), .out_dir(xf_dir),
        .out_last(xf_olast), .out_ax(xf_ax), .out_ay(xf_ay), .out_stx(xf_stx),
        .out_sty(xf_sty), .out_st(xf_st), .out_en(xf_en), .out_xa(xf_xa),
        .out_xb(xf_xb), .out_sat(xf_sat));

    // Captured transform result for the RMW steps.
    reg [8:0]   r_sy;
    reg [10:0]  r_st, r_en;
    reg [143:0] r_entry;

    //------------------------------------------------------------------------
    // FSM
    //------------------------------------------------------------------------
    localparam [4:0]
        S_IDLE    = 5'd0,
        S_ANG_REQ = 5'd1,
        S_ANG_WAIT= 5'd2,
        S_ANG_CAP = 5'd3,
        S_CLR     = 5'd4,
        S_ROM     = 5'd5,
        S_ROM_WAIT= 5'd6,
        S_XF      = 5'd7,
        S_XF_WAIT = 5'd8,
        S_A_RD    = 5'd9,
        S_A_RD2   = 5'd10,
        S_A_WR    = 5'd11,
        S_NEXT    = 5'd12,
        S_PFX_RD  = 5'd13,
        S_PFX_RD2 = 5'd14,
        S_PFX_WR  = 5'd15,
        S_B_RD    = 5'd16,
        S_B_RD2   = 5'd17,
        S_B_WR    = 5'd18,
        S_DONE    = 5'd19;

    reg [4:0]  state;
    reg        pass_b;
    reg [3:0]  ang_idx;      // 0..11: roll cam0..5 then pitch cam0..5
    reg [10:0] clr_idx;
    reg [15:0] acc;
    reg [3:0]  wait_cnt;

    always @(posedge clk) begin
        if (rst) begin
            state <= S_IDLE; busy <= 1'b0; tables_valid <= 1'b0; sat_seen <= 1'b0;
            ir_l <= 1'b0; built_ir <= 1'b0;
            build_count <= 32'd0;
            params_we <= 1'b0; bend_we <= 1'b0; rr_we <= 1'b0; cnt_we <= 1'b0;
            xf_in_valid <= 1'b0; rom_addr <= 15'd0;
            ylo <= 11'd0; yhi <= 11'd0; col_lo <= 11'd0; col_hi <= 11'd0;
        end else begin
            params_we <= 1'b0; bend_we <= 1'b0; rr_we <= 1'b0; cnt_we <= 1'b0;
            xf_in_valid <= 1'b0;
            case (state)
            S_IDLE: if (build_req) begin
                busy <= 1'b1; tables_valid <= 1'b0; sat_seen <= 1'b0;
                roll_l <= roll_cd; pitch_l <= pitch_cd; ir_l <= sensor_ir;
                ang_idx <= 4'd0;
                state <= S_ANG_REQ;
            end

            S_ANG_REQ: begin
                ang_addr <= (ang_idx < 6) ? mag_cd(roll_l[ang_idx*16 +: 16])
                                          : mag_cd(pitch_l[(ang_idx-6)*16 +: 16]);
                state <= S_ANG_WAIT;
            end
            S_ANG_WAIT: state <= S_ANG_CAP;
            S_ANG_CAP: begin
                if (ang_idx < 6) begin : cap_roll
                    reg signed [15:0] r;
                    r = clamp_cd(roll_l[ang_idx*16 +: 16]);
                    cam_c[ang_idx] <= $signed({1'b0, ang_q[16:0]});
                    // C++ rotates by -roll: sin(-roll) = -sign(roll)*sin(|roll|)
                    cam_s[ang_idx] <= (r > 0) ? -$signed({1'b0, ang_q[32:17]})
                                              :  $signed({1'b0, ang_q[32:17]});
                end else begin : cap_pitch
                    reg signed [15:0] p;
                    p = clamp_cd(pitch_l[(ang_idx-6)*16 +: 16]);
                    cam_ysh[ang_idx-6] <= p[15] ? -$signed(ang_q[40:33]) : $signed(ang_q[40:33]);
                end
                if (ang_idx == 4'd11) begin
                    clr_idx <= 11'd0; state <= S_CLR;
                end else begin
                    ang_idx <= ang_idx + 4'd1; state <= S_ANG_REQ;
                end
            end

            S_CLR: begin
                cnt_we <= 1'b1; cnt_waddr <= clr_idx; cnt_wdata <= 16'd0;
                if (clr_idx < NUM_ROWS) begin
                    rr_we <= 1'b1; rr_waddr <= clr_idx[8:0]; rr_wdata <= 11'd0;
                end
                if (clr_idx == last_bucket) begin
                    ylo <= 11'd2047; yhi <= 11'd0; col_lo <= 11'd2047; col_hi <= 11'd0;
                    it_sy <= 9'd0; it_cam <= 3'd0; it_seg <= 4'd0; it_k <= 15'd0;
                    pass_b <= 1'b0;
                    state <= S_ROM;
                end
                clr_idx <= clr_idx + 11'd1;
            end

            S_ROM: begin
                rom_addr <= it_k;
                state <= S_ROM_WAIT;
            end
            S_ROM_WAIT: state <= S_XF;      // rom_data valid next cycle
            S_XF: begin
                xf_in_valid <= 1'b1;
                xf_c <= cam_c[it_cam]; xf_s <= cam_s[it_cam]; xf_ysh <= cam_ysh[it_cam];
                xf_last <= it_last;
                xf_tag <= {it_sy, it_cam, it_seg, 7'd0};
                state <= S_XF_WAIT;
            end
            S_XF_WAIT: if (xf_valid) begin
                if (xf_sat) sat_seen <= 1'b1;
                r_sy <= xf_otag[22:14];
                r_st <= xf_st; r_en <= xf_en;
                r_entry <= {xf_otag[22:14], xf_otag[13:11], xf_otag[10:7],
                            xf_i0, xf_dir, xf_olast, xf_ax, xf_ay, xf_stx, xf_sty, 3'b000};
                if (!pass_b) begin
                    if (xf_st < ylo) ylo <= xf_st;
                    if (xf_en > yhi) yhi <= xf_en;
                    begin : cols
                        reg [10:0] mn, mx;
                        mn = (xf_xa < xf_xb) ? xf_xa : xf_xb;
                        mx = (xf_xa < xf_xb) ? xf_xb : xf_xa;
                        if (mn < col_lo) col_lo <= mn;
                        if (mx + 11'd1 > col_hi) col_hi <= mx + 11'd1;
                    end
                    cnt_raddr <= xf_st;
                    rr_bld_raddr <= xf_otag[22:14];
                    state <= S_A_RD;
                end else begin
                    cnt_raddr <= xf_st;
                    state <= S_B_RD;
                end
            end

            // pass A: CNT[st]++, ROW_READY[sy] = max(., en)
            S_A_RD:  state <= S_A_RD2;
            S_A_RD2: begin
                cnt_we <= 1'b1; cnt_waddr <= r_st; cnt_wdata <= cnt_rdata + 16'd1;
                rr_we <= 1'b1; rr_waddr <= r_sy;
                rr_wdata <= (r_en > rready_rdata) ? r_en : rready_rdata;
                state <= S_A_WR;
            end
            S_A_WR: state <= S_NEXT;

            // pass B: PARAMS[CNT[st]] = entry; CNT[st]++
            S_B_RD:  state <= S_B_RD2;
            S_B_RD2: begin
                params_we <= 1'b1; params_waddr <= cnt_rdata[14:0]; params_wdata <= r_entry;
                cnt_we <= 1'b1; cnt_waddr <= r_st; cnt_wdata <= cnt_rdata + 16'd1;
                state <= S_B_WR;
            end
            S_B_WR: state <= S_NEXT;

            S_NEXT: begin
                if (it_k == last_seg_k) begin
                    if (!pass_b) begin
                        clr_idx <= 11'd0; acc <= 16'd0; state <= S_PFX_RD;
                    end else begin
                        state <= S_DONE;
                    end
                end else begin
                    it_k <= it_k + 15'd1;
                    if (it_seg == segs_n - 4'd1) begin
                        it_seg <= 4'd0;
                        if (it_cam == 3'd5) begin it_cam <= 3'd0; it_sy <= it_sy + 9'd1; end
                        else it_cam <= it_cam + 3'd1;
                    end else begin
                        it_seg <= it_seg + 4'd1;
                    end
                    state <= S_ROM;
                end
            end

            // prefix: BUCKET_END[y] = acc + CNT[y]; CNT[y] = acc (start ptr)
            S_PFX_RD: begin cnt_raddr <= clr_idx; state <= S_PFX_RD2; end
            S_PFX_RD2: state <= S_PFX_WR;
            S_PFX_WR: begin
                bend_we <= 1'b1; bend_waddr <= clr_idx; bend_wdata <= acc + cnt_rdata;
                cnt_we <= 1'b1; cnt_waddr <= clr_idx; cnt_wdata <= acc;
                acc <= acc + cnt_rdata;
                if (clr_idx == last_bucket) begin
                    it_sy <= 9'd0; it_cam <= 3'd0; it_seg <= 4'd0; it_k <= 15'd0;
                    pass_b <= 1'b1;
                    state <= S_ROM;
                end else begin
                    clr_idx <= clr_idx + 11'd1;
                    state <= S_PFX_RD;
                end
            end

            S_DONE: begin
                busy <= 1'b0; tables_valid <= 1'b1; built_ir <= ir_l;
                build_count <= build_count + 32'd1;
                state <= S_IDLE;
            end
            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
