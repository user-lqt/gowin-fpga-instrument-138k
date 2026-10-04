// OLED-only diagnostic driven directly by the board's 50 MHz oscillator.
// Explicit configuration-time reset also covers JTAG reload without pressing S2.
module oled_vendor_probe_top (
    input wire i_clk_in, i_rst_n,
    inout wire oled_scl, oled_sda,
    output wire o_led, o_locked
);
    reg [15:0] startup_count=0;
    always @(posedge i_clk_in) begin
        if(i_rst_n) startup_count<=0;
        else if(!(&startup_count)) startup_count<=startup_count+1'b1;
    end
    wire rst_n;
    reset_sync #(.SYNC_STAGES(3)) u_reset_sync (
        .clk(i_clk_in), .arst_n((&startup_count) & ~i_rst_n), .rst_n(rst_n)
    );
    wire finished, failed, nack_seen;
    oled_vendor_probe u_probe (
        .clk(i_clk_in), .rst_n(rst_n), .scl(oled_scl), .sda(oled_sda),
        .finished(finished), .failed(failed), .nack_seen(nack_seen)
    );
    // W22 heartbeat; W21: 1 pulse ACK, 2 NACK, 3 bus timeout.
    // W21/W22 are FPGA ball names, not verified board silkscreen labels.
    reg [26:0] blink_count;
    always @(posedge i_clk_in or negedge rst_n)
        if(!rst_n) blink_count<=0;
        else if(blink_count==99999999) blink_count<=0;
        else blink_count<=blink_count+1'b1;
    wire pulse=(blink_count<5000000) ||
        ((nack_seen || failed) && blink_count>=15000000 && blink_count<20000000) ||
        (failed && blink_count>=30000000 && blink_count<35000000);
    assign o_led=~((finished || failed) ? pulse : (blink_count<50000000));
    assign o_locked=~(blink_count<25000000 ||
        (blink_count>=50000000 && blink_count<75000000));
endmodule
