`timescale 1ns/1ps
module tb_EoV19SingleFrameSelect;
    reg clk=0,rst=1,mode=0,start=0,active=0;
    always #5 clk=~clk;
    reg [2:0] select_cam=0;
    reg [5:0] desc=0,full=0;
    reg [11:0] banks=0;
    wire pending,stale,copy_full,rd_valid;
    wire [2:0] cam;
    wire [1:0] bank;
    wire [28:0] rd_addr;
    integer checks=0;
    EoV19SingleFrameSelect #(.STALE_WIDTH(6)) dut (
        .clk(clk),.rst(rst),.eo_mode(mode),.cam_sel(select_cam),
        .desc_valid(desc),.desc_full_frame(full),.desc_bank(banks),
        .copy_start(start),.copy_active(active),.start_pending(pending),.stale(stale),
        .reader_cam(cam),.reader_bank(bank),.copy_has_frame(copy_full)
    );
    EoV19SingleCamReader #(.SRC_BASE_ADDR(1000),.CAM_STRIDE(10000),
        .FRAME_STRIDE(1000),.ROW_STRIDE(32),.BEATS_PER_ROW(4),.OUT_ROWS(2),.FOLD_HALF_ROWS(1),.ROW_CROP(0)) reader (
        .clk(clk),.rst_n(!rst),.ui_rst(rst),.run_enable(mode&&active&&copy_full),
        .cam_sel(cam),.bank_sel(bank),.rd_req_valid(rd_valid),.rd_req_addr(rd_addr),
        .rd_req_ready(1'b0),.rd_data_valid(1'b0),.rd_data(256'd0),.px_ready(1'b1)
    );
    task check(input bit ok,input string why);
        begin checks++; if(!ok) $fatal(1,"%s",why); end
    endtask
    task tick; begin @(posedge clk); #1; end endtask
    task descriptor(input integer c,input integer b,input bit f);
        begin @(negedge clk); desc[c]=1; full[c]=f; banks[c*2+:2]=b; tick();
            @(negedge clk); desc=0; end
    endtask
    task launch;
        begin @(negedge clk); start=1; tick(); active=1;
            @(negedge clk); start=0; repeat(3) tick(); end
    endtask
    task finish_copy;
        begin @(negedge clk); active=0; repeat(2) tick(); end
    endtask
    initial begin
        repeat(3) tick(); @(negedge clk); rst=0; mode=1; tick();
        check(stale&&!pending,"startup must await full descriptor");
        descriptor(0,1,0); check(stale&&!pending,"in-flight narrow frame cannot start full reader");
        descriptor(0,2,1); check(!stale&&pending&&bank==2,"full frame makes selected bank ready");
        launch(); check(copy_full&&cam==0&&bank==2,"copy captures full bank identity");
        check(rd_valid&&rd_addr==3000,"reader starts from current accepted bank, not prior register value");
        descriptor(0,3,0); check(stale&&!pending&&copy_full&&bank==2,"new narrow frame invalidates cache only");
        descriptor(1,3,1);
        @(negedge clk); select_cam=1; #1; check(stale&&!pending,"selection change immediately blocks cached readiness");
        tick(); check(stale&&copy_full&&cam==0&&bank==2,"active copy keeps old camera and bank");
        finish_copy(); check(stale&&!pending,"new selection needs fresh full descriptor");
        descriptor(1,1,1); launch();
        check(copy_full&&cam==1&&bank==1&&rd_addr==12000,"fresh selection uses its own full bank");
        finish_copy();
        // A narrow descriptor on the same edge as a pending copy must win.
        descriptor(1,2,1);
        @(negedge clk); desc[1]=1; full[1]=0; banks[3:2]=3; start=1;
        #1; check(stale&&!pending,"same-edge narrow descriptor suppresses cached full readiness");
        tick(); active=1; @(negedge clk); desc=0; start=0; repeat(3) tick();
        check(!copy_full&&!rd_valid,"narrow same-edge copy produces no source read");
        descriptor(1,0,1); check(!copy_full&&!rd_valid,"new full descriptor cannot restart a black in-flight copy");
        finish_copy(); launch(); check(copy_full&&bank==0&&rd_addr==11000,"next copy adopts newly full bank");
        finish_copy();
        @(negedge clk); desc[1]=1; full[1]=1; banks[3:2]=2; start=1;
        tick(); active=1; @(negedge clk); desc=0; start=0; repeat(3) tick();
        check(copy_full&&bank==2&&rd_addr==13000&&!pending,"same-edge full descriptor is consumed exactly once");
        finish_copy(); check(!pending,"same-edge descriptor cannot relaunch after copy completes");
        repeat(66) tick(); check(stale&&!pending,"stale bank expires");
        descriptor(1,2,1); @(negedge clk); mode=0; tick(); mode=1; tick();
        check(stale&&!pending,"mode re-entry discards cached full bank");
        descriptor(1,2,1); @(negedge clk); rst=1; tick();
        check(stale&&!pending&&!copy_full,"reset clears selection and copy state");
        $display("PASS EoV19SingleFrameSelect: %0d checks",checks); $finish;
    end
    initial begin #100000; $fatal(1,"selection timeout"); end
endmodule
