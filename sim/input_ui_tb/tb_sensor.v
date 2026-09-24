`timescale 1ns/1ps
// B0 baseline contract test ONLY. B2 uses EC11, not a distance/pressure sensor.
// This does not claim to test B3 filtering/calibration or any sensor bus driver.
module tb_sensor;
    reg clk=0,rst_n=0,system_ready=0;
    always #10 clk=~clk;
    wire [15:0] sensor;
    wire valid;
    input_top #(.ROW_CYCLES(4),.DEBOUNCE_FRAMES(1),.FILTER_CYCLES(1),.BUTTON_CYCLES(1)) dut (
        .clk(clk),.rst_n(rst_n),.system_ready(system_ready),.col_in(4'hf),.row_out(),
        .enc_a(1'b1),.enc_b(1'b1),.enc_sw_n(1'b1),.active_voice_count(6'd0),
        .audio_locked(1'b0),.i2s_active(1'b0),.system_error(1'b0),
        .event_valid(valid),.event_type(),.note_id(),.velocity(),.param_valid(),.param_id(),
        .param_value(),.key_state(),.sensor_value(sensor),.input_ready(),.ui_page(),
        .ui_param_value(),.ui_dirty(),.volume_value(),.instrument_value()
    );
    always @(posedge clk) begin
        #1;
        if(sensor!==0 || valid!==0) $fatal(1,"Disabled sensor must not fabricate data/events");
    end
    initial begin
        repeat(4) @(negedge clk);rst_n=1;
        repeat(10) @(negedge clk);system_ready=1;
        repeat(100) @(negedge clk);system_ready=0;
        repeat(10) @(negedge clk);system_ready=1;
        repeat(100) @(negedge clk);
        $display("PASS sensor baseline: disabled sensor_value=0, no fabricated notes (B3 not implemented)");
        $finish;
    end
endmodule
