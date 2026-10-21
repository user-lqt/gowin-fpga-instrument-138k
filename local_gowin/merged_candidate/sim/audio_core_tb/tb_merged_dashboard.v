`timescale 1ns/1ps
module tb_merged_dashboard;
    reg clk=0,rst_n=0;
    reg [209:0] status=0;
    reg [48:0] features=0;
    always #5 clk=~clk;
    instrument_dashboard dut(.pixel_clk(clk),.rst_n(rst_n),.status(status),
        .spectrum(128'd0),.features(features),.xy_hit(1'b0),.xy_ready(1'b0),
        .wave_min(16'sd0),.wave_max(16'sd0),.wave_ready(1'b0));
    integer x,n,gain,expected,field,enabled_state,record_state,preset;
    reg [11:0] actual;
    reg [127:0] expected_glide,expected_record;
    reg [399:0] expected_line;
    reg [48:0] waveform_features;
    reg [209:0] page_status;
    task expect_card_text;
        input [4:0] row;
        input [127:0] expected_text;
        integer col;
        begin
            for(col=34;col<50;col=col+1)
                if(dut.character(row,col,dut.text_line(row))!==expected_text[127-(col-34)*8-:8])
                    $fatal(1,"card row %0d col %0d text mismatch",row,col);
        end
    endtask
    initial begin
        #1;repeat(3) @(negedge clk);rst_n=1;
        status[209:169]={1'b1,8'h24,12'h127,20'h00100};
        status[15:0]=1;
        repeat(3) @(negedge clk);
        for(n=0;n<1024;n=n+1)
            if(dut.decimal3(n)!==(((n/100)%10)*256+((n/10)%10)*16+n%10))
                $fatal(1,"BCD numeric regression %d",n);
        if(dut.character(0,19,dut.text_line(0))!=="G" || dut.character(0,24,dut.text_line(0))!=="R")
            $fatal(1,"guitar label");
        if(dut.character(25,14,dut.text_line(25))!=="2" || dut.character(25,15,dut.text_line(25))!=="4" ||
           dut.character(25,6,dut.text_line(25))!=="1" || dut.character(25,8,dut.text_line(25))!=="." ||
           dut.character(25,20,dut.text_line(25))!=="7") $fatal(1,"calibration text");
        // The counters must exactly replace /24 and %24 inside the bar panel.
        for(x=16;x<400;x=x+1) begin
            wait(dut.h==x);#1;
            if(dut.analysis_bar!==(x-16)/24 || dut.analysis_x!==(x-16)%24)
                $fatal(1,"bar position %d: %d %d",x,dut.analysis_bar,dut.analysis_x);
            if(dut.char_code!==dut.character(dut.v[8:4],dut.h[9:4],dut.text_line(dut.v[8:4])))
                $fatal(1,"character pipeline shifted text");
            @(negedge clk);
        end
        // Exercise row changes, frame wrap and both pages at the left edge,
        // where a line-cache lookahead error would corrupt the first glyph.
        for(n=0;n<2;n=n+1) begin
            page_status=status;
            page_status[149]=n;
            page_status[71:70]=n ? 2'd1 : 2'd0;
            force dut.frame=page_status;
            for(x=0;x<525;x=x+1) begin
                @(negedge clk);
                dut.h=1053;dut.v=x;
                repeat(7) begin
                    @(posedge clk);#1;
                    if(dut.h<800 &&
                       dut.char_code!==dut.character(dut.v[8:4],dut.h[9:4],dut.text_line(dut.v[8:4])))
                        $fatal(1,"line cache misalignment page=%d row=%d h=%d",n,dut.v,dut.h);
                end
            end
            release dut.frame;
        end
        // Check the production serial converter, not just the reference function.
        page_status=0;
        page_status[31:16]=16'd127;page_status[78:73]=32;
        page_status[106:102]=23;page_status[101:95]=127;
        page_status[94:87]=127;page_status[62:56]=127;
        page_status[168:167]=3;page_status[116]=1;
        page_status[154:150]=5'b11111;page_status[123:119]=5'b11110;
        page_status[164:155]=1023;page_status[114:107]=200;
        page_status[69:63]=25;
        force dut.frame=page_status;
        waveform_features=0;waveform_features[10:9]=3;
        waveform_features[20:11]=512;waveform_features[44:41]=15;
        force dut.feature_frame=waveform_features;
        force dut.levels=128'h78787878787878787878787878787878;
        repeat(330) @(negedge clk);
        for(field=0;field<15;field=field+1) begin
            case(field)
            0:begin actual=dut.b_volume;expected=127;end
            1:begin actual=dut.b_voices;expected=32;end
            2:begin actual=dut.b_key;expected=24;end
            3:begin actual=dut.b_note;expected=127;end
            4:begin actual=dut.b_velocity;expected=127;end
            5:begin actual=dut.b_fx;expected=127;end
            6:begin actual=dut.b_song;expected=3;end
            7:begin actual=dut.b_position;expected=1023;end
            8:begin actual=dut.b_total;expected=1023;end
            9:begin actual=dut.b_local_song;expected=3;end
            10:begin actual=dut.b_tempo;expected=200;end
            11:begin actual=dut.b_records;expected=512;end
            12:begin actual=dut.b_band;expected=16;end
            13:begin actual=dut.b_level;expected=120;end
            14:begin actual=dut.b_glide;expected=500;end
            endcase
            if(actual!==dut.decimal3(expected))
                $fatal(1,"serial BCD field %0d actual %h expected %0d",field,actual,expected);
        end
        // The GLIDE row and REC row must coexist. Exercise both independent
        // switches, every valid time preset, and retained time while bypassed.
        page_status=0;waveform_features=0;
        for(enabled_state=0;enabled_state<2;enabled_state=enabled_state+1)
            for(record_state=0;record_state<2;record_state=record_state+1)
                for(preset=0;preset<=25;preset=preset+1) begin
                    page_status[72]=enabled_state;page_status[69:63]=preset;
                    waveform_features[6]=record_state;
                    waveform_features[20:11]=record_state ? 512 : 127;
                    repeat(330) @(negedge clk);
                    expected_glide=enabled_state ? "GLIDE ON  000MS " : "GLIDE OFF 000MS ";
                    expected_glide[47:40]=8'd48+(preset*20)/100;
                    expected_glide[39:32]=8'd48+((preset*20)/10)%10;
                    expected_glide[31:24]=8'd48+(preset*20)%10;
                    expected_record=record_state ? "REC ON  512     " : "REC OFF 127     ";
                    expect_card_text(12,expected_glide);
                    expect_card_text(13,expected_record);
                end
        // Selecting another normal control page preserves the GLIDE status.
        for(n=1;n<4;n=n+1) begin
            page_status[71:70]=n;#1;
            expect_card_text(12,expected_glide);expect_card_text(13,expected_record);
        end
        // Analysis/TEST replace the card; no GLIDE/REC labels or numeric
        // overlays may leak onto those dedicated pages.
        page_status[149]=1;
        page_status[71:70]=1;#1;
        expect_card_text(12,{16{8'h20}});expect_card_text(13,{16{8'h20}});
        page_status[71:70]=0;#1;
        expected_line=dut.text_line(12);
        for(x=0;x<50;x=x+1)
            if(dut.character(12,x,expected_line)!==expected_line[399-x*8-:8])
                $fatal(1,"TEST row overwritten by GLIDE digits");
        expect_card_text(13,{16{8'h20}});
        for(n=0;n<3;n=n+1) begin
            case(n) 0:expected=0;1:expected=64;2:expected=127;endcase
            page_status[31:16]=expected;
            repeat(310) @(negedge clk);
            if(dut.b_volume!==dut.decimal3(expected)) $fatal(1,"UI volume %0d",expected);
            for(x=31;x<=33;x=x+1)
                if(dut.character(0,x,dut.text_line(0))!==dut.digit(dut.decimal3(expected),33-x))
                    $fatal(1,"VOL glyph %0d",x);
        end
        release dut.frame;release dut.feature_frame;release dut.levels;
        if(dut.frequency_bcd(15)!==20'h18750) $fatal(1,"frequency ROM");
        for(gain=0;gain<16;gain=gain+1) begin
            waveform_features=0;waveform_features[48:45]=gain;
            force dut.feature_frame=waveform_features;
            #1;
            for(n=-32768;n<32768;n=n+1) begin
                expected=144-(n>>>gain);
                if(expected<80) expected=80;
                if(expected>207) expected=207;
                if(dut.waveform_y(n)!==expected[7:0])
                    $fatal(1,"waveform coordinate n=%d gain=%d",n,gain);
            end
            release dut.feature_frame;
        end
        $display("PASS merged dashboard calibration, labels, BCD, GLIDE/REC separation, all glide times, page isolation, bar counter, frequency ROM");
        $finish;
    end
endmodule
