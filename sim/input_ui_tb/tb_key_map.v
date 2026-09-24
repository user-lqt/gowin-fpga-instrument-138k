`timescale 1ns/1ps
module tb_key_map;
    reg clk=0, rst_n=0;
    reg [15:0] keys=0;
    wire valid;
    wire [1:0] kind;
    wire [6:0] note_id;
    wire [7:0] velocity;
    reg [15:0] received=0;
    integer errors=0, events=0, idx, i, phase;
    key_map dut (.clk(clk),.rst_n(rst_n),.key_state(keys),
        .event_valid(valid),.event_type(kind),.note_id(note_id),.velocity(velocity));
    always #10 clk=~clk;
    // Model a synchronous downstream receiver (sample BEFORE NBA updates).
    always @(posedge clk) begin
        if (!rst_n) received=0;
        else if(valid) begin
            events=events+1;
            idx=note_id-60;
            if(idx<0 || idx>15) errors=errors+1;
            else if(kind==0) begin
                if(received[idx] || velocity!==127) errors=errors+1;
                received[idx]=1;
            end else if(kind==1) begin
                if(!received[idx] || velocity!==0) errors=errors+1;
                received[idx]=0;
            end else errors=errors+1;
        end
    end
    task pattern;
        input [15:0] value;
        input integer n;
        begin
            @(negedge clk); keys=value;
            repeat(n) @(posedge clk);
            #2;
        end
    endtask
    task check;
        input [15:0] value;
        input integer expected_events;
        begin
            if(received!==value || events!=expected_events) begin
                $display("FAIL received=%h events=%0d expected=%h/%0d",received,events,value,expected_events);
                errors=errors+1;
            end
        end
    endtask
    initial begin
        repeat(3) @(negedge clk); rst_n=1;
        pattern(0,20); check(0,0);
        for(i=0;i<16;i=i+1) begin
            pattern(16'h1<<i,18); check(16'h1<<i,2*i+1);
            pattern(0,18); check(0,2*i+2);
        end
        pattern(16'hffff,18); check(16'hffff,48);
        pattern(16'hffff,64); check(16'hffff,48);
        pattern(16'h5555,18); check(16'h5555,56);
        pattern(16'haaaa,18); check(16'haaaa,72);
        pattern(0,18); check(0,80);
        // Worst permitted update rate; vary phase relative to mapper cursor.
        for(phase=0;phase<16;phase=phase+1) begin
            pattern(16'hffff,16);
            pattern(0,18);
            check(0,80+32*(phase+1));
            pattern(0,1);
        end
        @(negedge clk); rst_n=0;
        repeat(3) @(negedge clk);
        events=0; keys=16'h8000; rst_n=1;
        repeat(18) @(posedge clk); #2;
        check(16'h8000,1);
        pattern(0,18); check(0,2);
        if(errors==0) $display("PASS: note mapping, simultaneous changes, no repeats, 16-cycle boundary, reset");
        else $fatal(1,"FAIL: %0d errors",errors);
        $finish;
    end
    initial begin #1000000; $fatal(1,"timeout"); end
endmodule
