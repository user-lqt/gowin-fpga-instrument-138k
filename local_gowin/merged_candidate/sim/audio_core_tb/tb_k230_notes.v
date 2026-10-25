`timescale 1ns/1ps
`include "event_defs.vh"
module tb_k230_notes;
    // Scaled clock/baud keeps the real UART parser and a 50ms lease inexpensive.
    localparam CLK_HZ=1000000, BAUD=100000, BIT_CYCLES=10;
    reg clk=0, rst_n=0, rx=1;
    always #5 clk=~clk;
    wire ev, err, pv;
    wire [1:0] kind;
    wire [6:0] note;
    wire [7:0] vel;
    integer events=0, params=0, errors=0, n;
    reg [1:0] kinds[0:31]; reg [6:0] notes[0:31]; reg [7:0] velocities[0:31];
    k230_control_rx #(.CLK_HZ(CLK_HZ),.BAUD(BAUD),.NOTE_TIMEOUT_MS(50)) dut(
        .clk(clk),.rst_n(rst_n),.uart_rx(rx),.param_valid(pv),.param_id(),.param_value(),
        .frame_error(err),.event_valid(ev),.event_type(kind),.note_id(note),.velocity(vel));
    always @(posedge clk) begin
        if(ev) begin kinds[events]=kind;notes[events]=note;velocities[events]=vel;events=events+1;end
        if(pv) params=params+1;
        if(err) errors=errors+1;
    end
    task byte_tx; input [7:0] b; integer i;
        begin
            rx=0;repeat(BIT_CYCLES) @(negedge clk);
            for(i=0;i<8;i=i+1) begin rx=b[i];repeat(BIT_CYCLES) @(negedge clk);end
            rx=1;repeat(BIT_CYCLES) @(negedge clk);
        end
    endtask
    task packet; input [7:0] cmd,a,b,bad;
        begin
            byte_tx(8'hA5);byte_tx(cmd);byte_tx(a);byte_tx(b);byte_tx(8'hA5^cmd^a^b^bad);
            repeat(20) @(negedge clk);
        end
    endtask
    task expect_event; input integer index; input [1:0] k; input [6:0] pitch;
        begin if(events<=index || kinds[index]!==k || notes[index]!==pitch)
            $fatal(1,"event %0d expected kind %0d note %0d; count %0d", index,k,pitch,events); end
    endtask
    initial begin
        repeat(5) @(negedge clk);rst_n=1;repeat(10) @(negedge clk);
        packet(8'h90,60,100,0);expect_event(0,`EVENT_NOTE_ON,60);
        if(velocities[0]!=100 || params!=0) $fatal(1,"note payload/parameter isolation");
        packet(8'hB4,25,0,0);packet(8'hB5,2,0,0);
        if(params!=2 || events!=1) $fatal(1,"parameter/note isolation");
        for(n=0;n<4;n=n+1) begin repeat(30000) @(negedge clk);packet(8'hB6,60,0,0);end
        if(events!=1) $fatal(1,"keepalive retriggers or times out");
        packet(8'h80,60,0,0);expect_event(1,`EVENT_NOTE_OFF,60);
        packet(8'h80,60,0,0);if(events!=2) $fatal(1,"duplicate release");
        packet(8'h90,62,100,0);packet(8'h90,64,100,0);
        expect_event(2,`EVENT_NOTE_ON,62);expect_event(3,`EVENT_NOTE_OFF,62);expect_event(4,`EVENT_NOTE_ON,64);
        packet(8'hB6,62,0,0); // Wrong note cannot renew the active note.
        repeat(51000) @(negedge clk);expect_event(5,`EVENT_NOTE_OFF,64);
        packet(8'hB6,64,0,0);if(events!=6) $fatal(1,"late heartbeat restarts note");
        packet(8'h90,65,90,0);packet(8'h90,65,0,0);
        expect_event(6,`EVENT_NOTE_ON,65);expect_event(7,`EVENT_NOTE_OFF,65);
        packet(8'h90,66,100,1);packet(8'h90,128,100,0);packet(8'h90,66,128,0);
        if(events!=8 || errors<3) $fatal(1,"invalid packet admitted");
        packet(8'h90,67,100,0);
        // Other parameter traffic must not mask a missing key heartbeat.
        repeat(30000) @(negedge clk);packet(8'hB4,50,0,0);
        repeat(22000) @(negedge clk);expect_event(9,`EVENT_NOTE_OFF,67);
        $display("PASS K230 notes: UART, release, slide recovery, heartbeat, timeout, invalid frames, parameter isolation");
        $finish;
    end
    initial begin #10000000;$fatal(1,"timeout");end
endmodule
