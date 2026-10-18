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
    wire [7:0] debug_velocity;
    integer ons=0, offs=0, cycle=0, last_event=-1000;
    integer k;
    integer hard_frames [0:23], hard_medium_frames [0:23];
    integer medium_frames [0:23], medium_soft_frames [0:23], soft_frames [0:23];
    integer t;
    reg [7:0] previous_velocity;
    reg [7:0] last_velocity;
    reg [23:0] seen_on=0, seen_off=0;
    // Cover K2's calibrated boundaries and the 100-frame medium strike.
    keyboard_24_dual #(.AB_MAX_FRAMES(200)) dut (.clk(clk), .rst_n(rst_n), .scan_valid(scan_valid),
        .contact_raw(contacts), .event_valid(valid), .event_type(kind),
        .key_id(key), .velocity(velocity), .key_state(state),
        .measured_frames(measured_frames), .measured_key(measured_key),
        .measured_valid(measured_valid), .measured_velocity(debug_velocity));
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
        hard_frames[0]=4; hard_frames[1]=9; hard_frames[2]=4; hard_frames[3]=4;
        hard_frames[4]=12; hard_frames[5]=19; hard_frames[6]=27; hard_frames[7]=25;
        hard_frames[8]=4; hard_frames[9]=6; hard_frames[10]=3; hard_frames[11]=3;
        hard_frames[12]=17; hard_frames[13]=10; hard_frames[14]=11; hard_frames[15]=15;
        hard_frames[16]=8; hard_frames[17]=1; hard_frames[18]=9; hard_frames[19]=6;
        hard_frames[20]=13; hard_frames[21]=2; hard_frames[22]=48; hard_frames[23]=26;
        hard_medium_frames[0]=16; hard_medium_frames[1]=69; hard_medium_frames[2]=10; hard_medium_frames[3]=12;
        hard_medium_frames[4]=75; hard_medium_frames[5]=52; hard_medium_frames[6]=79; hard_medium_frames[7]=74;
        hard_medium_frames[8]=8; hard_medium_frames[9]=29; hard_medium_frames[10]=9; hard_medium_frames[11]=6;
        hard_medium_frames[12]=71; hard_medium_frames[13]=67; hard_medium_frames[14]=52; hard_medium_frames[15]=49;
        hard_medium_frames[16]=32; hard_medium_frames[17]=3; hard_medium_frames[18]=24; hard_medium_frames[19]=11;
        hard_medium_frames[20]=62; hard_medium_frames[21]=3; hard_medium_frames[22]=99; hard_medium_frames[23]=59;
        medium_frames[0]=28; medium_frames[1]=130; medium_frames[2]=16; medium_frames[3]=20;
        medium_frames[4]=139; medium_frames[5]=84; medium_frames[6]=132; medium_frames[7]=124;
        medium_frames[8]=12; medium_frames[9]=53; medium_frames[10]=16; medium_frames[11]=10;
        medium_frames[12]=125; medium_frames[13]=124; medium_frames[14]=93; medium_frames[15]=84;
        medium_frames[16]=57; medium_frames[17]=6; medium_frames[18]=40; medium_frames[19]=17;
        medium_frames[20]=112; medium_frames[21]=5; medium_frames[22]=151; medium_frames[23]=93;
        medium_soft_frames[0]=128; medium_soft_frames[1]=301; medium_soft_frames[2]=36; medium_soft_frames[3]=38;
        medium_soft_frames[4]=239; medium_soft_frames[5]=381; medium_soft_frames[6]=256; medium_soft_frames[7]=256;
        medium_soft_frames[8]=19; medium_soft_frames[9]=201; medium_soft_frames[10]=147; medium_soft_frames[11]=59;
        medium_soft_frames[12]=445; medium_soft_frames[13]=731; medium_soft_frames[14]=239; medium_soft_frames[15]=172;
        medium_soft_frames[16]=116; medium_soft_frames[17]=59; medium_soft_frames[18]=120; medium_soft_frames[19]=47;
        medium_soft_frames[20]=251; medium_soft_frames[21]=12; medium_soft_frames[22]=426; medium_soft_frames[23]=222;
        soft_frames[0]=228; soft_frames[1]=473; soft_frames[2]=56; soft_frames[3]=57;
        soft_frames[4]=339; soft_frames[5]=677; soft_frames[6]=380; soft_frames[7]=389;
        soft_frames[8]=26; soft_frames[9]=349; soft_frames[10]=278; soft_frames[11]=108;
        soft_frames[12]=765; soft_frames[13]=1338; soft_frames[14]=384; soft_frames[15]=260;
        soft_frames[16]=176; soft_frames[17]=112; soft_frames[18]=200; soft_frames[19]=77;
        soft_frames[20]=390; soft_frames[21]=20; soft_frames[22]=702; soft_frames[23]=352;
        for(k=0;k<24;k=k+1) begin
            if(dut.travel_velocity(k,hard_frames[k])!=127 ||
               dut.travel_velocity(k,medium_frames[k])!=88 ||
               dut.travel_velocity(k,medium_soft_frames[k])!=68 ||
               dut.travel_velocity(k,soft_frames[k])!=48)
                $fatal(1,"key %0d calibrated anchor mismatch",k+1);
            if(hard_medium_frames[k]>hard_frames[k] &&
               dut.travel_velocity(k,hard_medium_frames[k])!=108)
                $fatal(1,"key %0d hard/medium interpolation mismatch",k+1);
            if(medium_soft_frames[k]>medium_frames[k] &&
               dut.travel_velocity(k,medium_soft_frames[k]-1)!=68)
                $fatal(1,"key %0d medium/soft interpolation mismatch",k+1);
            previous_velocity=127;
            for(t=0;t<=1500;t=t+1) begin
                if(dut.travel_velocity(k,t)>previous_velocity)
                    $fatal(1,"key %0d velocity is not monotonic at frame %0d",k+1,t);
                previous_velocity=dut.travel_velocity(k,t);
            end
        end
        if(dut.travel_velocity(5,84)!=88 || dut.travel_velocity(5,677)!=48 ||
           dut.travel_velocity(12,125)!=88 || dut.travel_velocity(12,765)!=48)
            $fatal(1,"K06/K13 replacement calibration mismatch");
        repeat(4) @(negedge clk); rst_n=1;
        // Same-frame fast closure of K2 (A bit 1, B bit 7; K2 has a 5-frame boundary).
        frame(48'h82); frame(48'h82);
        if(ons!=1 || velocity!=127 || state!=2) $fatal(1,"same-frame closure lost note");
        if(!measured_valid || measured_frames!=0 || measured_key!=1)
            $fatal(1,"simultaneous contact debug failed");
        if(debug_velocity!=127) $fatal(1,"fast-strike diagnostic velocity mismatch");
        // A one-frame opening must not release the key.
        frame(0); frame(48'h82);
        if(offs!=0 || ons!=1) $fatal(1,"contact bounce retriggered note");
        frame(0); frame(0);
        if(offs!=1 || state!=0) $fatal(1,"release failed");
        // Slow travel should generate lower velocity.
        repeat(100) frame(2);
        frame(48'h82); frame(48'h82);
        if(ons!=2 || last_velocity!=88) $fatal(1,"travel velocity failed ons=%0d vel=%0d measured=%0d key=%0d state=%h",ons,last_velocity,measured_frames,measured_key,state);
        if(measured_frames!=100 || measured_key!=1) $fatal(1,"slow travel debug failed");
        if(debug_velocity!=88) $fatal(1,"medium-strike diagnostic velocity mismatch");
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
