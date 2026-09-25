`timescale 1ns/1ps
`include "../../rtl/common/event_defs.vh"
module tb_keyboard_input;
    reg clk=0, rst_n=0;
    reg [15:0] pressed=0;
    reg [3:0] cols;
    wire [3:0] rows;
    wire [15:0] state;
    wire ready, valid;
    wire [1:0] kind;
    wire [6:0] note_id;
    wire [7:0] velocity;
    reg [3:0] low_rows,low_cols;
    reg [15:0] received=0;
    integer i,j,p,idx,errors=0,events=0;
    keyboard_input #(.ROW_CYCLES(4),.DEBOUNCE_FRAMES(2)) dut (
        .clk(clk),.rst_n(rst_n),.col_in(cols),.row_out(rows),
        .key_state(state),.input_ready(ready),.event_valid(valid),
        .event_type(kind),.note_id(note_id),.velocity(velocity));
    always #10 clk=~clk;
    always @* begin
        low_rows=0;low_cols=0;
        for(i=0;i<4;i=i+1) if(rows[i]===1'b0) low_rows[i]=1;
        for(p=0;p<8;p=p+1)
            for(i=0;i<4;i=i+1)
                for(j=0;j<4;j=j+1) if(pressed[4*i+j]) begin
                    if(low_rows[i]) low_cols[j]=1;
                    if(low_cols[j]) low_rows[i]=1;
                end
        cols=~low_cols;
    end
    always @(posedge clk) begin
        if(!rst_n) received=0;
        else if(valid) begin
            events=events+1;
            idx=note_id-60;
            if(idx<0 || idx>15) errors=errors+1;
            else if(kind===`EVENT_NOTE_ON) begin
                if(received[idx] || velocity!==127) errors=errors+1;
                received[idx]=1;
            end else if(kind===`EVENT_NOTE_OFF) begin
                if(!received[idx] || velocity!==0) errors=errors+1;
                received[idx]=0;
            end else errors=errors+1;
        end
    end
    task apply_keys;
        input [15:0] keys;
        input integer expected_events;
        begin
            @(negedge clk);pressed=keys;
            repeat(100) @(posedge clk);
            #2;
            if(state!==keys || received!==keys || events!=expected_events || ready!==1) begin
                $display("FAIL: state=%h received=%h events=%0d",state,received,events);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        apply_keys(0,0);
        // Short physical press before debounce confirmation must be ignored.
        @(negedge clk);pressed=16'h0001;
        repeat(4) @(posedge clk);
        apply_keys(0,0);
        apply_keys(16'h8421,4);
        apply_keys(16'h8421,4);
        apply_keys(0,8);
        apply_keys(16'hffff,24);
        apply_keys(16'h1111,36);
        apply_keys(0,40);
        if(errors==0) $display("PASS: physical matrix -> debounce -> MIDI events, hold and independent release");
        else $fatal(1,"FAIL: %0d errors",errors);
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
