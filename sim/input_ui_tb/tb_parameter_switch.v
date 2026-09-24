`timescale 1ns/1ps
module tb_parameter_switch;
    reg clk=0,rst_n=0,up=0,down=0,select_press=0;
    always #10 clk=~clk;
    wire [15:0] vol,inst,pvalue,ui;
    wire [3:0] pid,page;
    wire valid,dirty;
    parameter_manager #(.ENABLE_INSTRUMENT(1),.INSTRUMENT_COUNT(1)) dut (
        .clk(clk),.rst_n(rst_n),.step_up(up),.step_down(down),.select_press(select_press),
        .volume_value(vol),.instrument_value(inst),.param_valid(valid),.param_id(pid),
        .param_value(pvalue),.ui_param_value(ui),.ui_page(page),.ui_dirty(dirty)
    );
    task drive;
        input u,d,s;
        begin @(negedge clk);up=u;down=d;select_press=s;@(posedge clk);#1;end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        @(posedge clk);#1;if(!valid || pid!=0 || pvalue!=64) $fatal(1,"Default volume");
        @(posedge clk);#1;if(!valid || pid!=1 || pvalue!=0) $fatal(1,"Adjacent default instrument");
        drive(1,0,1);
        if(page!=1 || vol!=64 || valid || !dirty) $fatal(1,"Select must win over rotation");
        drive(1,0,0);if(inst!=0 || valid || dirty) $fatal(1,"One-instrument clamp");
        drive(0,1,0);if(inst!=0 || valid || dirty) $fatal(1,"Lower clamp");
        drive(0,0,1);if(page!=0 || valid || !dirty) $fatal(1,"Page switch");
        drive(1,1,0);if(vol!=64 || valid || dirty) $fatal(1,"Opposite steps cancel");
        drive(1,0,0);if(vol!=65 || !valid || pid!=0 || pvalue!=65 || !dirty) $fatal(1,"Volume after switch");
        drive(0,0,0);if(valid || dirty) $fatal(1,"Pulse width");
        $display("PASS parameter switching: simultaneous controls, adjacent init, one instrument, pulse width");
        $finish;
    end
endmodule
