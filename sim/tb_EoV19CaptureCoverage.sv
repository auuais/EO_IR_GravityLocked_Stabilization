`timescale 1ns/1ps
module tb_EoV19CaptureCoverage;
    reg cam_clk=0, ui_clk=0, rst_n=0, ui_rst=1, capture_enable=0;
    always #5 cam_clk=~cam_clk;
    always #3 ui_clk=~ui_clk;
    reg hsync=0, vsync=0;
    reg [19:0] pixel=20'h12340;
    reg [15:0] epoch=0;
    reg [6:0] beat_lo=1, beat_hi=2;
    reg [10:0] row_lo=0, row_hi=1;
    reg free_valid=0, pop=0;
    reg [1:0] free_bank=0;
    wire free_ready, empty, marker, desc_valid, desc_full;
    wire [28:0] addr;
    wire [383:0] data;
    wire [1:0] marker_bank, desc_bank;
    wire [15:0] marker_epoch, desc_epoch;
    integer checks=0, retired=0;
    EoV19DdrCamWriter #(.INPUT_W(64),.INPUT_H(2),.FRAME_STRIDE_ADDR(64),
        .ROW_STRIDE_ADDR(32),.CAM_BASE_ADDR(29'h10000),.DYN_WINDOW(1),
        .WR_BEAT_LO(1),.WR_BEAT_HI(2),.WR_ROW_LO(0),.WR_ROW_HI(1)) dut (
        .rst_n(rst_n),.capture_enable(capture_enable),.join_enable(1'b1),
        .cap_fifo_rst_req(1'b0),.free_fifo_rst_req(1'b0),
        .global_epoch_gray_ui(epoch^(epoch>>1)),.cam_clk(cam_clk),
        .cam_hsync(hsync),.cam_vsync(vsync),.cam_pixel(pixel),.ui_clk(ui_clk),.ui_rst(ui_rst),
        .wr_beat_lo_ui(beat_lo),.wr_beat_hi_ui(beat_hi),.wr_row_lo_ui(row_lo),.wr_row_hi_ui(row_hi),
        .fifo_rd_en(pop),.fifo_empty(empty),.fifo_addr(addr),.fifo_data(data),
        .fifo_is_marker(marker),.fifo_marker_bank(marker_bank),.fifo_marker_epoch(marker_epoch),
        .free_bank_valid_ui(free_valid),.free_bank_ui(free_bank),.free_bank_ready_ui(free_ready),
        .desc_valid_ui(desc_valid),.desc_bank_ui(desc_bank),.desc_epoch_ui(desc_epoch),
        .desc_full_frame_ui(desc_full)
    );
    task check(input bit ok, input string why);
        begin checks++; if(!ok) $fatal(1,"%s",why); end
    endtask
    task push_bank(input [1:0] bank);
        begin
            wait(free_ready); @(negedge ui_clk); free_bank=bank; free_valid=1;
            @(negedge ui_clk); free_valid=0;
        end
    endtask
    task edge_frame(input bit late_row_crop);
        begin
            @(negedge cam_clk); epoch=epoch+1;
            repeat(8) @(negedge cam_clk);
            vsync=1; repeat(5) @(negedge cam_clk);
            vsync=0;
            if(late_row_crop) begin row_lo=1; row_hi=1; end
            repeat(3) @(negedge cam_clk);
        end
    endtask
    task pixels_frame;
        integer y,x;
        begin
            for(y=0;y<2;y++) begin
                @(negedge cam_clk); hsync=1;
                for(x=0;x<64;x++) begin pixel={8'(x+y*64),2'b00,8'h80,2'b00}; @(negedge cam_clk); end
                hsync=0; repeat(4) @(negedge cam_clk);
            end
        end
    endtask
    task pop_word;
        begin
            @(negedge ui_clk); pop=1;
            @(negedge ui_clk); pop=0;
            #1;
        end
    endtask
    task retire_frame(input integer bank, input integer first_row,
        input integer first_beat, input integer last_beat, input bit full);
        integer row,beat;
        begin
            for(row=first_row;row<2;row++) for(beat=first_beat;beat<=last_beat;beat++) begin
                wait(!empty); #1;
                check(!marker,"marker overtook frame payload");
                check(!desc_valid,"descriptor before final marker retirement");
                check(addr==29'h10000+bank*64+row*32+beat*8,"captured beat address/window mismatch");
                pop_word();
                check(!desc_valid,"payload pop published descriptor");
            end
            wait(!empty); #1;
            check(marker && marker_bank==bank && marker_epoch==bank+1,"marker frame identity");
            check(data[0]===full,"marker holds actual published-frame coverage");
            check(!desc_valid,"queued marker not yet published");
            pop_word();
            check(desc_valid && desc_bank==bank && desc_epoch==bank+1 && desc_full===full,
                  "descriptor coverage must publish with bank/epoch at marker retirement");
            retired++;
            repeat(3) @(negedge ui_clk);
        end
    endtask
    initial begin
        repeat(10) @(negedge cam_clk); rst_n=1;
        repeat(15) @(negedge ui_clk); ui_rst=0; capture_enable=1;
        repeat(25) @(negedge cam_clk);
        push_bank(0); push_bank(1); push_bank(2); push_bank(3);
        repeat(25) @(negedge cam_clk);
        edge_frame(0); pixels_frame();
        // Widen the UI request after the narrow frame has already started.
        beat_lo=0; beat_hi=3;
        edge_frame(0);
        check(dut.frame_full_window,"new frame adopted full window");
        retire_frame(0,0,1,2,0);
        pixels_frame();
        // Crop changes too late for this boundary's CDC adoption: frame3 must
        // remain full, even though the current UI request is already narrow.
        edge_frame(1);
        check(dut.frame_full_window,"unstable new window must retain full coverage");
        retire_frame(1,0,0,3,1);
        pixels_frame(); edge_frame(0);
        check(!dut.frame_full_window,"stable partial-height window is not full");
        retire_frame(2,0,0,3,1);
        pixels_frame(); edge_frame(0);
        retire_frame(3,1,0,3,0);
        check(retired==4,"exact frame count");
        $display("PASS EoV19CaptureCoverage: %0d checks, %0d ordered descriptors",checks,retired);
        $finish;
    end
    initial begin #2000000; $fatal(1,"coverage timeout"); end
endmodule
