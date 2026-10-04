`timescale 1ns/1ps
// Sample at the physical DAC edge, including independent package/PCB skew.
module tb_pt8211_tx;
    reg clk = 0;
    always #40.6901 clk = ~clk;
    reg rst_n = 0;
    reg signed [15:0] left = 16'ha55a, right = 16'h5aa5;
    wire tick, bck, enable, tx_bck, tx_ws, tx_din, frame_start;
    wire rx_bck, rx_ws, rx_din;
    assign #3 rx_bck = tx_bck;
    assign #1 rx_ws = tx_ws;
    assign #7 rx_din = tx_din;
    sample_scheduler #(.CLK_DIV_BCK(4), .CLK_DIV_SAMPLE(256)) scheduler (
        .clk_audio(clk), .rst_n(rst_n), .sample_tick(tick), .bck(bck), .bck_en(enable)
    );
    i2s_tx_official dut (
        .clk_audio(clk), .rst_n(rst_n), .bck_in(bck), .bck_en(enable),
        .sample_l(left), .sample_r(right), .frame_start(frame_start),
        .o_bck(tx_bck), .o_ws(tx_ws), .o_din(tx_din)
    );
    reg [15:0] shift = 0;
    reg previous_ws = 0;
    integer words = 0, bits = 0, phase = 0;
    realtime last_din = 0, last_ws = 0, minimum_setup = 1000000;
    realtime margin;
    always @(rx_din) last_din = $realtime;
    always @(rx_ws) last_ws = $realtime;
    always @(posedge rx_bck) begin
        if (rst_n) begin
            if (words > 1) begin
                margin = $realtime - last_din;
                if ($realtime - last_ws < margin) margin = $realtime - last_ws;
                if (margin < minimum_setup) minimum_setup = margin;
                if (margin < 250) $fatal(1, "DAC capture edge races DIN/WS");
            end
            if (rx_ws != previous_ws) begin
                if (words > 0 && bits != 16) $fatal(1, "channel word is not 16 bits");
                if (phase == 1 || phase == 3) begin
                    if (shift !== (previous_ws ? right : left))
                        $fatal(1, "DAC decode mismatch ws=%b got=%h", previous_ws, shift);
                end
                words = words + 1;
                bits = 0;
            end
            shift = {shift[14:0], rx_din};
            bits = bits + 1;
            previous_ws = rx_ws;
        end else begin
            shift = 0; words = 0; bits = 0; previous_ws = 0;
        end
    end
    initial begin
        repeat (5) @(negedge clk);
        rst_n = 1;
        wait (words == 3); phase = 1;
        wait (words == 20); phase = 2;
        @(negedge clk); left = 16'hffff; right = 16'h8000;
        wait (words == 24); phase = 3;
        wait (words == 40);
        $display("PASS PT8211 decode: 16-bit words, signed rails, minimum setup=%0.3f ns", minimum_setup);
        $finish;
    end
    initial begin
        #1000000;
        $fatal(1, "PT8211 test timeout");
    end
endmodule
