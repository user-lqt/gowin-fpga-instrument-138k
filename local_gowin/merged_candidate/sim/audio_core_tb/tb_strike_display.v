`timescale 1ns/1ps
module tb_strike_display;
    reg clk=0, reset_n=0;
    reg [31:0] debug_value=0;
    reg [15:0] frames_value=0;
    always #5 clk=~clk;
    instrument_24_rgb_top dut(.i_clk_in(clk),.i_rst_n(1'b0),
        .col_in(6'h3f),.enc_a(1'b1),.enc_b(1'b1),.enc_sw_n(1'b1),
        .enc2_a(1'b1),.enc2_b(1'b1),.enc2_sw_n(1'b1),
        .adc_miso(1'b0),.ble_uart_rx(1'b1));
    task check_text;
        input [19:0] time_bcd;
        input [7:0] key_bcd;
        input [11:0] velocity_bcd;
        begin
            repeat(frames_value+30) @(negedge clk);
            if(dut.u_strike_display.time_bcd!==time_bcd ||
               dut.u_strike_display.key_bcd!==key_bcd ||
               dut.u_strike_display.velocity_bcd!==velocity_bcd)
                $fatal(1,"format mismatch");
            force dut.u_lcd.frame={dut.u_display_bridge.source_status};
            #1;
            if(dut.u_lcd.character(25,4)!==8'd48+time_bcd[19:16] ||
               dut.u_lcd.character(25,9)!==8'd48+time_bcd[3:0] ||
               dut.u_lcd.character(25,8)!=="." ||
               dut.u_lcd.character(25,14)!==8'd48+key_bcd[7:4] ||
               dut.u_lcd.character(25,15)!==8'd48+key_bcd[3:0] ||
               dut.u_lcd.character(25,18)!==8'd48+velocity_bcd[11:8] ||
               dut.u_lcd.character(25,20)!==8'd48+velocity_bcd[3:0])
                $fatal(1,"LCD character mismatch");
            release dut.u_lcd.frame;
        end
    endtask
    initial begin
        force dut.clk_audio=clk;
        force dut.rst_n=reset_n;
        force dut.strike_debug=debug_value;
        force dut.strike_frames=frames_value;
        #1;reset_n=0;
        repeat(3) @(negedge clk);
        if(dut.u_strike_display.valid!==0) $fatal(1,"reset validity");
        force dut.u_lcd.frame=210'd0;
        #1;
        if(dut.u_lcd.character(25,4)!=="-") $fatal(1,"missing placeholder");
        release dut.u_lcd.frame;
        reset_n=1;
        debug_value={1'b1,2'b11,5'd0,8'd127,16'd0};
        frames_value=50;
        check_text(20'h00100,8'h01,12'h127);
        // Released contacts must not erase the most recent measurement.
        debug_value={1'b1,2'b00,5'd23,8'd16,16'd0};
        frames_value=150;
        check_text(20'h00300,8'h24,12'h016);
        repeat(100) @(negedge clk);
        check_text(20'h00300,8'h24,12'h016);
        frames_value=5004;
        check_text(20'h10001,8'h24,12'h016);
        frames_value=1;
        check_text(20'h00002,8'h24,12'h016);
        frames_value=0;
        check_text(20'h00000,8'h24,12'h016);
        $display("PASS strike display: reset, key 1/24, 0/0.2/10/30/1000.1 ms, velocity, release hold");
        $finish;
    end
endmodule
