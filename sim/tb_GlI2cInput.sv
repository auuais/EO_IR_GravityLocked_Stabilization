`timescale 1ns/1ps
// Functional pad models; physical IO/CDC implementation needs separate review.
module BUFG(input I, output O); assign O=I; endmodule
module IBUF(input I, output O); assign O=I; endmodule
module IOBUF(input I, input T, output O, inout IO);
    assign IO=T ? 1'bz : I; assign O=IO;
endmodule

module tb_GlI2cInput;
    reg clk=0, ui=0, reset=1, scl=1, master_low=0;
    always #5 clk=~clk;
    initial begin #3; forever #7 ui=~ui; end
    tri1 sda;
    assign sda=master_low ? 1'b0 : 1'bz;
    wire valid, update, control_valid, enabled;
    wire signed [15:0] roll_cd, pitch_cd;
    wire [31:0] seq;
    wire [7:0] mode, control;
    wire [95:0] eo_pitch, eo_roll, ir_pitch, ir_roll;
    integer updates=0, checks=0;
    Kintex_top_I2C_test #(.SCLK_HZ(100000), .POR_MS(1)) dut (
        .FPGA_RESET(1'b0), .SCLK_IN(clk), .SCL(scl), .SDA(sda),
        .cam_select(), .mode_out(mode), .eo_pitch_cd_raw(eo_pitch),
        .eo_roll_cd_raw(eo_roll), .ir_pitch_cd_raw(ir_pitch), .ir_roll_cd_raw(ir_roll),
        .pose_dst_clk(ui), .pose_reset(reset), .pose_valid_ui(valid),
        .pose_update_ui(update), .pose_roll_cd_ui(roll_cd), .pose_pitch_cd_ui(pitch_cd),
        .pose_sequence_ui(seq), .control_byte_ui(control),
        .control_valid_ui(control_valid), .control_enabled_ui(enabled)
    );
    always @(posedge ui) if (update) updates=updates+1;
    task check(input bit ok, input string why);
        begin checks=checks+1; if (!ok) $fatal(1,"%s",why); end
    endtask
    task start_bus;
        begin master_low=0; scl=1; #300; master_low=1; #300; scl=0; #300; end
    endtask
    task stop_bus;
        begin scl=0; master_low=1; #300; scl=1; #300; master_low=0; #500; end
    endtask
    task bits8(input [7:0] data);
        integer b;
        begin
            for(b=7;b>=0;b=b-1) begin
                scl=0; master_low=~data[b]; #200; scl=1; #200; scl=0; #200;
            end
        end
    endtask
    task ack_high(input bit expected);
        begin master_low=0; #200; scl=1; #200; check((sda===1'b0)==expected,"ACK mismatch"); end
    endtask
    task write_byte(input [7:0] data);
        begin bits8(data); ack_high(1); scl=0; #300; end
    endtask
    task begin_write(input [7:0] addr);
        begin start_bus(); write_byte(8'h6c); write_byte(addr); end
    endtask
    task one_write(input [7:0] addr, input [7:0] data);
        begin begin_write(addr); write_byte(data); stop_bus(); #500; end
    endtask
    task pose_write(input [15:0] r, input [15:0] p);
        begin
            begin_write(8'h10); write_byte(r[7:0]); write_byte(r[15:8]);
            write_byte(p[7:0]); write_byte(p[15:8]); stop_bus(); #500;
        end
    endtask
    task read_reg(input [7:0] addr, output [7:0] data);
        integer b;
        begin
            begin_write(addr); start_bus(); write_byte(8'h6d); master_low=0;
            for(b=7;b>=0;b=b-1) begin
                #200; scl=1; #200; data[b]=sda; scl=0; #200;
            end
            master_low=0; #200; scl=1; #200; scl=0; #200; stop_bus();
        end
    endtask
    reg [7:0] readback;
    initial begin
        #2000; reset=0; #500;
        check(mode==8'h15,"baseline startup mode");
        check(!valid && !control_valid && !enabled,"reset invalid");
        one_write(8'h00,8'h14); read_reg(8'h00,readback);
        check(mode==8'h14 && readback==8'h14,"baseline mode write/read");
        begin_write(8'h2c); write_byte(8'h34); write_byte(8'hfe); stop_bus();
        check(eo_pitch[15:0]==16'hfe34,"static bank original LE layout");
        begin_write(8'h10); write_byte(8'h34); write_byte(8'h12); write_byte(8'h78);
        bits8(8'hd6); ack_high(1); #500;
        check(!valid && updates==0,"pose cannot publish before final ACK completion");
        scl=0; #300; check(!valid,"pose cannot publish before STOP");
        stop_bus(); #500;
        check(valid && roll_cd==16'h1234 && pitch_cd==16'hd678 && seq==1 && updates==1,"atomic LE signed pose");
        begin_write(8'h10); write_byte(8'h99); stop_bus(); #500;
        check(seq==1 && updates==1,"short pose rejected");
        begin_write(8'h10); write_byte(8'h99); write_byte(8'h88);
        start_bus(); write_byte(8'h6c); write_byte(8'h00); write_byte(8'h15); stop_bus(); #500;
        check(seq==1 && mode==8'h15,"repeated START rejects partial pose");
        begin_write(8'h10); write_byte(1); write_byte(2); write_byte(3); write_byte(4);
        master_low=1; #200; scl=1; #200; scl=0; #200; stop_bus(); #500;
        check(seq==1,"partial fifth byte rejects otherwise complete pose");
        begin_write(8'h10); write_byte(1); write_byte(2); write_byte(3); write_byte(4); write_byte(5); stop_bus(); #500;
        check(seq==1,"excess acknowledged byte rejected");
        start_bus(); bits8(8'h6e); ack_high(0); scl=0; #300; stop_bus();
        check(seq==1,"other slave address ignored");
        one_write(8'h04,8'h00); check(!control_valid && !enabled,"legacy zero invalid");
        begin_write(8'h04); bits8(8'ha1); ack_high(1); #500;
        check(!enabled,"control cannot publish before ACK falling edge");
        scl=0; #300; check(!enabled,"control cannot publish before STOP");
        stop_bus(); #500; check(control_valid && enabled && control==8'ha1,"A1 enables");
        begin_write(8'h04); write_byte(8'ha0); start_bus(); write_byte(8'h6c); write_byte(0); write_byte(8'h14); stop_bus(); #500;
        check(enabled,"restart abandons control candidate");
        begin_write(8'h04); write_byte(8'ha0); write_byte(0); stop_bus(); #500;
        check(enabled,"multi-byte control rejected");
        begin_write(8'h04); write_byte(8'ha0); master_low=1; #200; scl=1; #200; scl=0; #200; stop_bus(); #500;
        check(enabled,"partial excess control rejected");
        one_write(8'h04,8'ha2); check(!control_valid && !enabled,"invalid magic disables");
        one_write(8'h04,8'ha0); check(control_valid && !enabled,"A0 valid disabled");
        one_write(8'h04,8'ha1);
        begin_write(8'h10); write_byte(1); write_byte(2); write_byte(3); bits8(4); ack_high(1);
        reset=1; #100; check(!valid && !enabled && !control_valid,"common reset invalidates both mailboxes");
        scl=0; #300; stop_bus(); reset=0; #500;
        check(!valid && !enabled,"reset in-flight discarded");
        pose_write(16'h8000,16'h7fff);
        check(valid && seq==1 && roll_cd==16'h8000 && pitch_cd==16'h7fff,"post-reset fresh signed extrema");
        check(!control_valid && !enabled,"pose alone never enables feature");
        one_write(8'h04,8'ha1); check(enabled,"post-reset control");
        $display("PASS GlI2cInput checks=%0d",checks); $finish;
    end
    initial begin #2000000; $fatal(1,"timeout"); end
endmodule
