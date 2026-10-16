`timescale 1ns/1ps
// Independent receiver watches OUTPUT PINS at BCK rising edges.
module tb_pcm5102a_i2s;
    reg clk=0,rst=0;
    always #40.690104 clk=~clk; // nominal 12.288 MHz
    reg signed [23:0] left=24'h812345,right=24'h765432;
    wire tick,bck,en,frame,bck_pin,ws,din;
    sample_scheduler #(.CLK_DIV_BCK(2),.CLK_DIV_SAMPLE(256)) scheduler(
        .clk_audio(clk),.rst_n(rst),.sample_tick(tick),.bck(bck),.bck_en(en));
    i2s_tx_pcm5102a dut(.clk_audio(clk),.rst_n(rst),.bck_in(bck),.bck_en(en),
        .sample_l(left),.sample_r(right),.frame_start(frame),.o_bck(bck_pin),.o_ws(ws),.o_din(din));
    reg [23:0] expected_l,expected_r;
    reg [23:0] decoded;
    reg previous_ws=1,started=0;
    integer cycles=0,last_frame=-1,last_tick=-1,last_edge=-1;
    integer frames=0,slot=0,since_ws=0,right_frames=0;
    time changed_at=0;
    always @(ws or din) changed_at=$time;
    always @(posedge clk) begin
        if(!rst) begin cycles=0;last_frame=-1;last_tick=-1;end
        else begin
            cycles=cycles+1;
            if(frame) begin
                if(last_frame>=0 && cycles-last_frame!=256) $fatal(1,"frame cadence");
                last_frame=cycles;expected_l=left;expected_r=right;frames=frames+1;
            end
            if(tick) begin
                if(last_tick>=0 && cycles-last_tick!=256) $fatal(1,"sample cadence");
                last_tick=cycles;
            end
        end
    end
    always @(posedge bck_pin or negedge rst) begin
        if(!rst) begin previous_ws=1;started=0;slot=0;since_ws=0;decoded=0;last_edge=-1;end
        else begin
            #1;
            if(last_edge>=0 && cycles-last_edge!=4) $fatal(1,"BCK ratio");
            last_edge=cycles;
            if(started && $time-changed_at<100) $fatal(1,"insufficient setup at sampling edge");
            if(ws!=previous_ws) begin
                if(started && since_ws!=32) $fatal(1,"channel slot not 32 BCK");
                if(started && din!==0) $fatal(1,"boundary padding must be zero");
                if(ws==0) started=1;
                slot=0;since_ws=1;decoded=0;
            end else if(started) begin
                slot=slot+1;since_ws=since_ws+1;
                if(slot>=1 && slot<=24) begin
                    decoded={decoded[22:0],din};
                    if(slot==24) begin
                        if(decoded !== (ws ? expected_r : expected_l))
                            $fatal(1,"I2S one-bit delay/channel/sample mismatch WS=%b got=%h expected=%h",ws,decoded,ws?expected_r:expected_l);
                        if(ws) right_frames=right_frames+1;
                    end
                end else if(din!==0) $fatal(1,"nonzero slot padding");
            end
            previous_ws=ws;
        end
    end
    // Change input midframe: the RIGHT sample must still match the LEFT snapshot.
    integer stimulus=0;
    always @(negedge clk) if(rst) begin
        stimulus=stimulus+1;
        if(stimulus%97==0) begin left<=left+24'h123457;right<=right-24'h234569;end
    end
    initial begin
        $dumpfile("pcm5102a_i2s.vcd");$dumpvars(0,tb_pcm5102a_i2s);
        repeat(5) @(negedge clk);rst=1;
        wait(right_frames==8);@(negedge clk);rst=0;
        repeat(5) @(negedge clk);left=24'h800000;right=24'h7fffff;rst=1;
        wait(right_frames==16);@(negedge clk);left=0;right=0;
        wait(right_frames==20);
        $display("PASS: Philips I2S output pins, one-BCK MSB delay, low-left/high-right, 24-bit signed stereo, 32-bit slots, 64 BCK/frame, coherent snapshots, zero padding, silence and reset");
        $finish;
    end
    initial begin #1000000;$fatal(1,"timeout");end
endmodule
