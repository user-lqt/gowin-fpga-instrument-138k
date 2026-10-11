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
    wire [15:0] measured_frames;
    wire [4:0] measured_key;
    wire measured_valid;
    integer ons=0, offs=0, cycle=0, last_event=-1000;
    integer k;
    integer thresholds [0:23];
    reg [7:0] last_velocity;
    reg [23:0] seen_on=0, seen_off=0;
    // Cover the K2 boundary (90 frames) and the 100-frame slow-travel case.
    keyboard_24_dual #(.AB_MAX_FRAMES(200)) dut (.clk(clk), .rst_n(rst_n), .scan_valid(scan_valid),
        .contact_raw(contacts), .event_valid(valid), .event_type(kind),
        .key_id(key), .velocity(velocity), .key_state(state),
        .measured_frames(measured_frames), .measured_key(measured_key), .measured_valid(measured_valid));
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
        thresholds[0]=50; thresholds[1]=90; thresholds[2]=30; thresholds[3]=25;
        thresholds[4]=100; thresholds[5]=100; thresholds[6]=100; thresholds[7]=100;
        thresholds[8]=5; thresholds[9]=50; thresholds[10]=15; thresholds[11]=5;
        thresholds[12]=5; thresholds[13]=150; thresholds[14]=100; thresholds[15]=100;
        thresholds[16]=50; thresholds[17]=5; thresholds[18]=50; thresholds[19]=15;
        thresholds[20]=90; thresholds[21]=5; thresholds[22]=150; thresholds[23]=150;
        for(k=0;k<24;k=k+1)
            if(dut.travel_velocity(k,thresholds[k]-1)!=127 ||
               dut.travel_velocity(k,thresholds[k])!=16)
                $fatal(1,"key %0d threshold mismatch",k+1);
        repeat(4) @(negedge clk); rst_n=1;
        // Same-frame fast closure of K2 (A bit 1, B bit 7; K2 has a 5-frame boundary).
        frame(48'h82); frame(48'h82);
        if(ons!=1 || velocity!=127 || state!=2) $fatal(1,"same-frame closure lost note");
        if(!measured_valid || measured_frames!=0 || measured_key!=1)
            $fatal(1,"simultaneous contact debug failed");
        // A one-frame opening must not release the key.
        frame(0); frame(48'h82);
        if(offs!=0 || ons!=1) $fatal(1,"contact bounce retriggered note");
        frame(0); frame(0);
        if(offs!=1 || state!=0) $fatal(1,"release failed");
        // Slow travel should generate lower velocity.
        repeat(100) frame(2);
        frame(48'h82); frame(48'h82);
        if(ons!=2 || last_velocity>=127 || last_velocity<1) $fatal(1,"travel velocity failed ons=%0d vel=%0d measured=%0d key=%0d state=%h",ons,last_velocity,measured_frames,measured_key,state);
        if(measured_frames!=100 || measured_key!=1) $fatal(1,"slow travel debug failed");
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
    initial begin #30000000; $fatal(1,"keyboard test timeout"); end
endmodule
