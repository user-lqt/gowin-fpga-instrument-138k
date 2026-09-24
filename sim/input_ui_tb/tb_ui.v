`timescale 1ns/1ps
module tb_ui;
    reg clk=0,rst_n=0,start=0;
    always #10 clk=~clk;
    reg [5:0] addr=0,voices=4;
    reg [3:0] page=0;
    reg [15:0] vol=64,inst=0;
    reg ready=1,locked=1,streaming=1,error=0;
    wire [7:0] ch;
    wire dirty;
    integer n,updates=0;
    reg [127:0] expected_line;
    oled_content dut(clk,rst_n,start,addr,page,vol,inst,voices,ready,locked,streaming,error,ch);
    ui_state notify(clk,rst_n,page,vol,inst,voices,ready,locked,streaming,error,dirty);
    always @(posedge clk) begin #1;if(rst_n && dirty) updates=updates+1;end
    task capture;
        begin @(negedge clk);start=1;@(negedge clk);start=0;end
    endtask
    task line_check;
        input integer line;
        input [127:0] text_line;
        begin
            expected_line=text_line;
            for(n=0;n<16;n=n+1) begin
                addr=line*16+n;#1;
                if(ch!==expected_line[127:120]) $fatal(1,"OLED char line=%0d col=%0d got=%h",line,n,ch);
                expected_line=expected_line<<8;
            end
        end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        repeat(4) @(negedge clk);
        if(updates!=1) $fatal(1,"Initial redraw");
        capture;
        line_check(0,">VOL:064        ");
        line_check(1," INS:00000      ");
        line_check(2," VOICE:04       ");
        line_check(3,"R1 L1 I1 E0     ");
        @(negedge clk);page=1;vol=127;inst=65535;voices=63;error=1;
        repeat(4) @(negedge clk);
        if(updates!=2) $fatal(1,"Redraw coalescing");
        // Without capture, text is still the previous coherent frame.
        line_check(0,">VOL:064        ");line_check(1," INS:00000      ");
        capture;
        line_check(0," VOL:127        ");line_check(1,">INS:65535      ");
        line_check(2," VOICE:63       ");line_check(3,"R1 L1 I1 E1     ");
        @(negedge clk);voices=0;ready=0;locked=0;streaming=0;
        repeat(4) @(negedge clk);capture;
        line_check(2," VOICE:00       ");line_check(3,"R0 L0 I0 E1     ");
        if(updates!=3) $fatal(1,"Status redraw");
        repeat(50) @(negedge clk);
        if(updates!=3) $fatal(1,"Idle repeats");
        $display("PASS UI: all 64 characters, selected page, coherent snapshot, status redraw");
        $finish;
    end
    initial begin #20000;$fatal(1,"timeout");end
endmodule
