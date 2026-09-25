`timescale 1ns/1ps
`include "../../rtl/common/event_defs.vh"
module tb_input_top;
    reg clk=0, rst_n=0, system_ready=0, sw=1;
    always #10 clk=~clk;
    reg [1:0] ab=3;
    reg [15:0] pressed=0;
    reg [3:0] cols;
    wire [3:0] rows, pid, page;
    wire [15:0] keys, sensor, pvalue, uivalue, vol, inst;
    wire ready, ev, pv, dirty;
    wire [1:0] kind;
    wire [6:0] note;
    wire [7:0] velocity;
    reg [3:0] low_rows, low_cols;
    reg [15:0] received=0;
    integer i,j,p,index,notes=0,params=0;
    reg [15:0] last_volume=0,last_instrument=0;
    input_top #(.ROW_CYCLES(4),.DEBOUNCE_FRAMES(2),.FILTER_CYCLES(3),.BUTTON_CYCLES(8),
        .INSTRUMENT_COUNT(4)) dut (
        .clk(clk),.rst_n(rst_n),.system_ready(system_ready),.col_in(cols),.row_out(rows),
        .enc_a(ab[1]),.enc_b(ab[0]),.enc_sw_n(sw),.active_voice_count(6'd4),
        .audio_locked(1'b1),.i2s_active(1'b1),.system_error(1'b0),
        .event_valid(ev),.event_type(kind),.note_id(note),.velocity(velocity),
        .param_valid(pv),.param_id(pid),.param_value(pvalue),.key_state(keys),
        .sensor_value(sensor),.input_ready(ready),.ui_page(page),.ui_param_value(uivalue),
        .ui_dirty(dirty),.volume_value(vol),.instrument_value(inst)
    );
    // Passive matrix model includes ghost paths through multiple closed contacts.
    always @* begin
        low_rows=0; low_cols=0;
        for(i=0;i<4;i=i+1) if(rows[i]===1'b0) low_rows[i]=1;
        for(p=0;p<8;p=p+1)
            for(i=0;i<4;i=i+1)
                for(j=0;j<4;j=j+1) if(pressed[4*i+j]) begin
                    if(low_rows[i]) low_cols[j]=1;
                    if(low_cols[j]) low_rows[i]=1;
                end
        cols=~low_cols;
    end
    // Model a receiver that samples valid on every clock, not only audio ticks.
    always @(posedge clk) begin
        if(!rst_n || !system_ready) begin
            received=0; notes=0; params=0; last_volume=0; last_instrument=0;
            if(ev || pv) $fatal(1,"Event while system not ready");
        end else begin
            if(ev) begin
                index=note-60;
                if(index<0 || index>15) $fatal(1,"Note range");
                if(kind===`EVENT_NOTE_ON) begin
                    if(received[index] || velocity!=127) $fatal(1,"Duplicate note-on");
                    received[index]=1;
                end else if(kind===`EVENT_NOTE_OFF) begin
                    if(!received[index] || velocity!=0) $fatal(1,"Unexpected note-off");
                    received[index]=0;
                end else $fatal(1,"Wrong note event type");
                notes=notes+1;
            end
            if(pv) begin
                if(pid==0) last_volume=pvalue;
                else if(pid==1) last_instrument=pvalue;
                else $fatal(1,"Unexpected parameter");
                params=params+1;
            end
        end
    end
    task phase;
        input [1:0] value;
        begin @(negedge clk); ab=value; repeat(12) @(negedge clk); end
    endtask
    task cw;
        begin phase(2);phase(0);phase(1);phase(3);end
    endtask
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        // No initialization is lost while the downstream system is booting.
        repeat(30) @(negedge clk);
        if(ready || rows!==4'bzzzz || params!=0) $fatal(1,"Startup gating");
        system_ready=1;
        repeat(100) @(negedge clk);
        if(!ready || params!=2 || last_volume!=16'd33026 || last_instrument!=0 || sensor!=0)
            $fatal(1,"Initialization protocol");
        pressed=16'h8421; // Four independent row/column notes, no ghost rectangle.
        cw;
        repeat(60) @(negedge clk);
        if(received!=16'h8421 || notes!=4 || vol!=65 || params!=3)
            $fatal(1,"Concurrent keyboard and volume");
        sw=0;repeat(30) @(negedge clk);
        cw;
        if(page!=1 || inst!=1 || vol!=65 || notes!=4 || params!=4 || last_instrument!=1)
            $fatal(1,"Instrument while holding chord");
        pressed=0;repeat(100) @(negedge clk);
        if(received!=0 || notes!=8) $fatal(1,"Independent release");
        // A/C reset together; B resends defaults and re-detects held keys.
        sw=1;system_ready=0;repeat(5) @(negedge clk);
        if(ready || rows!==4'bzzzz) $fatal(1,"Stop/reset");
        pressed=1;system_ready=1;repeat(100) @(negedge clk);
        if(params!=2 || received!=1 || notes!=1 || vol!=64 || inst!=0 || page!=0)
            $fatal(1,"Restart while key held");
        pressed=0;repeat(100) @(negedge clk);
        if(received!=0 || notes!=2) $fatal(1,"Release after restart");
        $display("PASS input_top: boot gating, parallel controls, defaults, held chord, restart");
        $finish;
    end
    initial begin #200000;$fatal(1,"timeout");end
endmodule
