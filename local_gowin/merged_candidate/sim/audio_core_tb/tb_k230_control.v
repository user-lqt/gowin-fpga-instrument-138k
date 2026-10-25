`timescale 1ns/1ps
`include "event_defs.vh"
module tb_k230_control;
    localparam integer CLK_HZ = 12288000;
    localparam integer BIT_CYCLES = (CLK_HZ + 115200/2) / 115200;
    reg clk = 0, rst_n = 0, rx = 1;
    always #5 clk = ~clk;
    wire valid, error, parameter_valid;
    wire [3:0] id, parameter_id;
    wire [15:0] value, volume, instrument, parameter_value;
    integer updates = 0, errors = 0, last_volume = -1, last_instrument = -1;
    integer p, expected, before_updates;
    k230_control_rx receiver (.clk(clk), .rst_n(rst_n), .uart_rx(rx),
        .param_valid(valid), .param_id(id), .param_value(value), .frame_error(error));
    encoder_control #(.FILTER_CYCLES(2), .BUTTON_CYCLES(2),
        .INSTRUMENT_COUNT(3), .FORMAL_CONTROLS(1), .ENABLE_REMOTE(1)) control (
        .clk(clk), .rst_n(rst_n), .enc_a(1'b1), .enc_b(1'b1), .enc_sw_n(1'b1),
        .volume_value(volume), .instrument_value(instrument),
        .param_valid(parameter_valid), .param_id(parameter_id), .param_value(parameter_value),
        .remote_valid(valid), .remote_id(id), .remote_value(value));
    always @(posedge clk) begin
        if (error) errors = errors + 1;
        if (parameter_valid) begin
            updates = updates + 1;
            if (parameter_id == `PARAM_VOLUME) last_volume = parameter_value;
            if (parameter_id == `PARAM_INSTRUMENT) last_instrument = parameter_value;
        end
    end
    task send_byte;
        input [7:0] b;
        integer bit_index;
        begin
            rx = 0; repeat(BIT_CYCLES) @(negedge clk);
            for(bit_index = 0; bit_index < 8; bit_index = bit_index + 1) begin
                rx = b[bit_index]; repeat(BIT_CYCLES) @(negedge clk);
            end
            rx = 1; repeat(BIT_CYCLES) @(negedge clk);
        end
    endtask
    task send_frame;
        input [7:0] cmd, a, b, corrupt;
        begin
            send_byte(8'hA5); send_byte(cmd); send_byte(a); send_byte(b);
            send_byte(8'hA5 ^ cmd ^ a ^ b ^ corrupt);
            repeat(20) @(negedge clk);
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n = 1; repeat(30) @(negedge clk);
        for(p = 0; p <= 100; p = p + 5) begin
            send_frame(8'hB4, p, 0, 0);
            expected = (p * 127 + 50) / 100;
            if(volume !== expected[15:0] || last_volume != (expected*65535+63)/127)
                $fatal(1, "volume mapping %0d percent, UI %0d gain %0d",p,volume,last_volume);
        end
        send_frame(8'hB5, 1, 0, 0);
        if(instrument != 1 || last_instrument != 1) $fatal(1,"guitar mapping");
        send_frame(8'hB5, 2, 0, 0);
        if(instrument != 2 || last_instrument != 2) $fatal(1,"bell mapping");
        send_frame(8'hB5, 0, 0, 0);
        if(instrument != 0 || last_instrument != 0) $fatal(1,"piano mapping");
        before_updates = updates;
        send_frame(8'hB4, 25, 0, 1); // checksum error
        send_frame(8'hB4, 101, 0, 0); // out of range
        send_frame(8'hB4, 51, 0, 0); // not a five-percent step
        send_frame(8'hB4, 25, 1, 0); // reserved argument
        send_frame(8'hB5, 3, 0, 0); // unknown timbre
        send_frame(8'h90, 60, 100, 0); // note commands cannot enter parameter path
        if(updates != before_updates || volume != 127 || instrument != 0 || errors < 5)
            $fatal(1,"invalid frames changed state");
        // A truncated frame times out, then the next frame must recover.
        send_byte(8'hA5); send_byte(8'hB4);
        repeat(CLK_HZ/10 + 30) @(negedge clk);
        send_frame(8'hB4, 25, 0, 0);
        if(volume != 32 || last_volume != (32*65535+63)/127) $fatal(1,"timeout recovery");
        // UART false start shorter than half a bit must not alter parameters.
        before_updates = updates; rx = 0; repeat(4) @(negedge clk); rx = 1;
        repeat(BIT_CYCLES*12) @(negedge clk);
        if(updates != before_updates) $fatal(1,"false UART start");
        // Local encoder starts at the remote value, not an old private copy.
        force control.step_up = 1'b1;
        @(negedge clk); release control.step_up; repeat(5) @(negedge clk);
        if(volume != 36) $fatal(1,"local encoder jumps after remote volume");
        // Simultaneous remote volume + local timbre retains both updates.
        force control.remote_valid = 1'b1;
        force control.remote_id = `PARAM_VOLUME;
        force control.remote_value = 16'd64;
        force control.press = 1'b1;
        @(negedge clk);
        release control.remote_valid; release control.remote_id; release control.remote_value;
        release control.press; repeat(6) @(negedge clk);
        if(volume != 64 || instrument != 1 || last_instrument != 1)
            $fatal(1,"volume/timbre collision lost an event");
        // Simultaneous remote timbre + local volume also retains both.
        force control.remote_valid = 1'b1;
        force control.remote_id = `PARAM_INSTRUMENT;
        force control.remote_value = 16'd2;
        force control.step_down = 1'b1;
        @(negedge clk);
        release control.remote_valid; release control.remote_id; release control.remote_value;
        release control.step_down; repeat(6) @(negedge clk);
        if(volume != 60 || instrument != 2 || last_instrument != 2
                || last_volume != (60*65535+63)/127)
            $fatal(1,"timbre/volume collision lost an event");
        // An idle/unplugged link must never reset the selected parameters.
        before_updates = updates; repeat(BIT_CYCLES*40) @(negedge clk);
        if(updates != before_updates || volume != 60 || instrument != 2)
            $fatal(1,"idle link overwrote parameters");
        $display("PASS K230 UART: 21 levels, timbre IDs, bad frames, timeout, encoder handover and collisions");
        $finish;
    end
    initial begin #50000000; $fatal(1,"test timeout"); end
endmodule
