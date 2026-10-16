`timescale 1ns/1ps
`include "event_defs.vh"
module tb_bell_allocation;
    reg clk=0,rst_n=0,tick=0,event_valid=0;
    always #5 clk=~clk;
    reg [1:0] kind=0;
    reg [6:0] note=0;
    reg [31:0] active=0,used=0;
    wire [31:0] on,off,down;
    wire full;
    voice_allocator #(.VOICES(32),.STEAL_ON_FULL(1),
        .SHARED_AGE(1),.SERIAL_RANK(1)) dut(
        .clk(clk),.rst_n(rst_n),.sample_tick(tick),
        .event_valid(event_valid),.event_type(kind),.note_id(note),
        .velocity(8'd110),.instrument(2'd2),.note_fc(32'd46819660),
        .note_period(48'd1),.voice_active(active),
        .envelope_levels({32{16'd10000}}),.voice_note_on(on),
        .voice_note_off(off),.key_down(down),.voice_note_id(),
        .voice_velocity(),.voice_instrument(),.voice_fc(),.voice_period(),
        .full_pulse(full));
    integer k;
    reg [31:0] chosen;
    task event_step;
        input [1:0] event_kind;
        begin
            @(negedge clk);tick=1;event_valid=1;kind=event_kind;
            @(negedge clk);tick=0;event_valid=0;
        end
    endtask
    initial begin
        repeat(3) @(negedge clk);rst_n=1;
        // Keep every released voice active to model overlapping bell tails.
        // This isolates allocation policy, not the envelope's real-time decay.
        for(k=0;k<14;k=k+1) begin
            note=k/2+72;
            event_step(`EVENT_NOTE_ON);
            chosen=on;
            if(chosen==0 || (chosen & (chosen-1))!=0 || (chosen & used)!=0 || full)
                $fatal(1,"overwrote a ringing voice at strike %0d",k);
            active=active|chosen;used=used|chosen;
            repeat(255) @(negedge clk);
            event_step(`EVENT_NOTE_OFF);
            if(off!==chosen || down!=0) $fatal(1,"wrong repeated-note release target");
            repeat(255) @(negedge clk);
        end
        if(active!=used) $fatal(1,"lost ringing allocation");
        $display("PASS production 32-slot allocator: 14 independent ringing strikes, repeated notes, no tail steal");
        $finish;
    end
endmodule
