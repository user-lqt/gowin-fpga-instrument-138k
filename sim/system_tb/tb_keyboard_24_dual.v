`timescale 1ns/1ps
module tb_keyboard_24_dual;
    reg clk=0, rst_n=0, scan_valid=0;
    always #5 clk=~clk;
    reg [47:0] contacts=0;
    wire valid;
    wire [1:0] kind;
    wire [4:0] key;
    wire [7:0] velocity;
    wire [23:0] state;
    integer ons=0, offs=0, cycle=0, last_event=-1000;
    reg [7:0] last_velocity;
    reg [23:0] seen_on=0, seen_off=0;
    keyboard_24_dual dut (.clk(clk), .rst_n(rst_n), .scan_valid(scan_valid),
        .contact_raw(contacts), .event_valid(valid), .event_type(kind),
        .key_id(key), .velocity(velocity), .key_state(state));
    always @(posedge clk) begin
        cycle=cycle+1;
        if (valid) begin
            if (cycle-last_event < 256) $fatal(1,"events exceeded audio consumer rate");
            last_event=cycle;
            if (kind==1) begin ons=ons+1; seen_on[key]=1; last_velocity=velocity; end
            if (kind==2) begin offs=offs+1; seen_off[key]=1; end
        end
    end
    task frame;
        input [47:0] value;
        begin
            @(negedge clk); contacts=value; scan_valid=1;
            @(negedge clk); scan_valid=0;
            repeat(12000) @(negedge clk);
        end
    endtask
    initial begin
        repeat(4) @(negedge clk); rst_n=1;
        // Same-frame fast closure of A (bit 0) and B (bit 6).
        frame(48'h41); frame(48'h41);
        if(ons!=1 || velocity!=127 || state!=1) $fatal(1,"same-frame closure lost note");
        // A one-frame opening must not release the key.
        frame(0); frame(48'h41);
        if(offs!=0 || ons!=1) $fatal(1,"contact bounce retriggered note");
        frame(0); frame(0);
        if(offs!=1 || state!=0) $fatal(1,"release failed");
        // Slow travel should generate lower velocity.
        frame(1); frame(1); frame(1); frame(1); frame(1);
        frame(48'h41); frame(48'h41);
        if(ons!=2 || last_velocity>=127 || last_velocity<1) $fatal(1,"travel velocity failed");
        frame(0); frame(0);
        seen_on=0; seen_off=0;
        frame(48'hffffffffffff); frame(48'hffffffffffff);
        if(seen_on!=24'hffffff || state!=24'hffffff || ons!=26)
            $fatal(1,"simultaneous 24-key press lost events");
        frame(0); frame(0);
        if(seen_off!=24'hffffff || state!=0 || offs!=26)
            $fatal(1,"simultaneous release lost events");
        $display("PASS keyboard24 fast/slow travel, bounce, 24-key serialization and release");
        $finish;
    end
    initial begin #10000000; $fatal(1,"keyboard test timeout"); end
endmodule
