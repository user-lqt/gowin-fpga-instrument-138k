`timescale 1ns/1ps
module tb_encoder_control;
    reg clk=0;
    always #5 clk=~clk;
    reg rst_n=0, sw=1;
    reg [1:0] ab=3;
    wire ready, valid, dirty;
    wire [15:0] vol, inst, value, ui;
    wire [3:0] id, page;
    integer events=0, changes=0, i;
    encoder_control #(.FILTER_CYCLES(3), .BUTTON_CYCLES(8)) dut (
        .clk(clk), .rst_n(rst_n), .enc_a(ab[1]), .enc_b(ab[0]), .enc_sw_n(sw),
        .input_ready(ready), .volume_value(vol), .instrument_value(inst),
        .param_valid(valid), .param_id(id), .param_value(value),
        .ui_page(page), .ui_param_value(ui), .ui_dirty(dirty)
    );
    always @(posedge clk) begin
        #1;
        if (rst_n) begin
            if (dirty) changes=changes+1;
            if (valid) begin
                events=events+1;
                if (id==0 && value!==((vol * 32'd65535 + 63) / 127)) $fatal(1,"Volume payload");
                if (id==1 && value!==inst) $fatal(1,"Instrument payload");
                if (id>1) $fatal(1,"Unknown parameter");
                if (events==1 && (id!=0 || value!=16'd33026)) $fatal(1,"Initial volume");
                if (events==2 && (id!=1 || value!=0)) $fatal(1,"Initial instrument");
            end
            if (ui !== ((page==0)?vol:inst)) $fatal(1,"UI mismatch");
        end
    end
    task phase;
        input [1:0] state;
        begin @(negedge clk); ab=state; repeat(12) @(negedge clk); end
    endtask
    task cw;
        begin phase(2); phase(0); phase(1); phase(3); end
    endtask
    task ccw;
        begin phase(1); phase(0); phase(2); phase(3); end
    endtask
    task button;
        input level;
        input integer cycles;
        begin @(negedge clk); sw=level; repeat(cycles) @(negedge clk); end
    endtask
    task check;
        input integer v,t,p,e,c;
        begin
            if(vol!=v || inst!=t || page!=p || events!=e || changes!=c)
                $fatal(1,"Got vol=%0d inst=%0d page=%0d events=%0d dirty=%0d",vol,inst,page,events,changes);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        phase(3); check(64,0,0,2,1);
        cw; check(65,0,0,3,2);
        // Press bounce shorter than qualification time does not switch.
        button(0,2); button(1,2); button(0,2); button(1,15);
        check(65,0,0,3,2);
        button(0,20); check(65,0,1,3,3);
        button(0,100); check(65,0,1,3,3); // Hold: no repeat.
        for(i=0;i<5;i=i+1) cw;
        check(65,3,1,6,6); // Clamp upper instrument ID.
        for(i=0;i<5;i=i+1) ccw;
        check(65,0,1,9,9);
        cw; check(65,1,1,10,10);
        button(1,2); button(0,15); check(65,1,1,10,10);
        button(1,20); button(0,20); check(65,1,0,10,11);
        ccw; check(64,1,0,11,12);
        button(1,20); button(0,20); check(64,1,1,11,13);
        // Reset while held: restore defaults, then accept one debounced press.
        @(negedge clk); rst_n=0;
        repeat(4) @(negedge clk); events=0; changes=0; rst_n=1;
        repeat(30) @(negedge clk); check(64,0,1,2,2);
        repeat(100) @(negedge clk); check(64,0,1,2,2);
        $display("PASS encoder control: bounce, hold, switch, retention, limits, payload, reset");
        $finish;
    end
    initial begin #200000; $fatal(1,"Timeout"); end
endmodule
