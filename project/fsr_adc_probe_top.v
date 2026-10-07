`include "event_defs.vh"
// CH0-only board probe: RGB ADC/VIB telemetry, no keyboard or audio engine.
module fsr_adc_probe_top (
    input wire i_clk_in,i_rst_n,
    input wire [5:0] col_in,
    input wire enc_a,enc_b,enc_sw_n,enc2_a,enc2_b,enc2_sw_n,adc_miso,
    output wire [7:0] row_out,
    output wire o_hp_bck,o_hp_ws,o_hp_din,o_pa_en,o_led,o_locked,
    output wire adc_cs_n,adc_sclk,adc_mosi,
    output wire lcd_sc_clk,lcd_sc_hs,lcd_sc_vs,lcd_sc_de,
    output wire [5:0] lcd_r_out,lcd_g_out,lcd_b_out
);
    wire board_rst_n=~i_rst_n;
    wire clk_audio,pixel_clk,audio_locked,pixel_locked,rst_n,pixel_rst_n;
    clock_gen u_clock_gen (
        .i_clk_in(i_clk_in),.i_rst_n(board_rst_n),.o_clk_audio(clk_audio),
        .o_clk_sys(),.o_pll_locked(audio_locked)
    );
    clock_gen #(.IDIV_SEL(1),.MDIV_SEL(20),.ODIV0_SEL(30),.ODIV1_SEL(30)) u_pixel_clock (
        .i_clk_in(i_clk_in),.i_rst_n(board_rst_n),.o_clk_audio(pixel_clk),
        .o_clk_sys(),.o_pll_locked(pixel_locked)
    );
    reset_sync u_audio_reset (.clk(clk_audio),.arst_n(board_rst_n && audio_locked),.rst_n(rst_n));
    reset_sync u_pixel_reset (.clk(pixel_clk),.arst_n(board_rst_n && pixel_locked),.rst_n(pixel_rst_n));
    wire sample_valid,sample_error,sensor_ready;
    wire [2:0] sample_channel;
    wire [9:0] adc_ch0;
    wire [15:0] modulation;
    mcp3008_sampler #(.CLK_DIV(12),.CHANNEL_COUNT(1),.SAMPLE_DIV(4096)) u_adc (
        .clk(clk_audio),.rst_n(rst_n),.adc_miso(adc_miso),.busy(),
        .adc_cs_n(adc_cs_n),.adc_sclk(adc_sclk),.adc_mosi(adc_mosi),
        .sample_valid(sample_valid),.sample_error(sample_error),
        .sample_channel(sample_channel),.ch0_data(adc_ch0),.ch1_data(),.ch2_data()
    );
    fsr_expression_control u_fsr (
        .clk(clk_audio),.rst_n(rst_n),.sample_valid(sample_valid),
        .sample_error(sample_error),.sample_channel(sample_channel),.ch0_data(adc_ch0),
        .param_valid(),.param_id(),.param_value(),.filtered_value(),
        .modulation_value(modulation),.sensor_ready(sensor_ready)
    );
    function [15:0] decimal_digits;
        input [9:0] value;
        reg [15:0] bcd;
        integer bit_index,digit;
        begin
            bcd=0;
            for(bit_index=9;bit_index>=0;bit_index=bit_index-1) begin
                for(digit=0;digit<4;digit=digit+1)
                    if(bcd[digit*4+:4]>=5) bcd[digit*4+:4]=bcd[digit*4+:4]+4'd3;
                bcd={bcd[14:0],value[bit_index]};
            end
            decimal_digits=bcd;
        end
    endfunction
    reg [15:0] modulation_snapshot,adc_digits,vib_digits;
    reg [31:0] scaled;
    reg [9:0] adc_snapshot,adc_scaled,adc_percent,percent;
    reg ready_snapshot,ready_scaled,ready_percent,display_ready;
    always @(posedge clk_audio or negedge rst_n) begin
        if(!rst_n) begin
            modulation_snapshot<=0;scaled<=0;percent<=0;
            adc_snapshot<=0;adc_scaled<=0;adc_percent<=0;adc_digits<=0;vib_digits<=0;
            ready_snapshot<=0;ready_scaled<=0;ready_percent<=0;display_ready<=0;
        end else begin
            modulation_snapshot<=modulation;adc_snapshot<=adc_ch0;ready_snapshot<=sensor_ready;
            scaled<=modulation_snapshot*32'd100+32'd32767;
            adc_scaled<=adc_snapshot;ready_scaled<=ready_snapshot;
            percent<=scaled/32'd65535;adc_percent<=adc_scaled;ready_percent<=ready_scaled;
            adc_digits<=decimal_digits(adc_percent);vib_digits<=decimal_digits(percent);
            display_ready<=ready_percent;
        end
    end
    wire frame_start;
    wire [28:0] display_status;
    lcd_status_bridge #(.WIDTH(29)) u_bridge (
        .source_clk(clk_audio),.source_rst_n(rst_n),
        .source_status({display_ready,vib_digits[11:0],adc_digits}),
        .pixel_clk(pixel_clk),.pixel_rst_n(pixel_rst_n),.frame_start(frame_start),
        .pixel_status(display_status)
    );
    rgb_lcd_800x480 #(.ENABLE_FSR_STATUS(1)) u_lcd (
        .pixel_clk(pixel_clk),.rst_n(pixel_rst_n),.key_state(24'd0),
        .volume_value(16'd0),.instrument_value(16'd0),.diagnostic_state(32'd0),
        .control_menu(1'b0),.glide_value(7'd0),.effect_value(7'd0),
        .adc_digits(display_status[15:0]),.vibrato_digits(display_status[27:16]),
        .sensor_ready(display_status[28]),.frame_start(frame_start),
        .sc_clk(lcd_sc_clk),.sc_hs(lcd_sc_hs),.sc_vs(lcd_sc_vs),.sc_de(lcd_sc_de),
        .r_out(lcd_r_out),.g_out(lcd_g_out),.b_out(lcd_b_out)
    );
    assign row_out=8'hzz;
    assign o_hp_bck=0,o_hp_ws=0,o_hp_din=0,o_pa_en=0;
    assign o_locked=audio_locked && pixel_locked;
    assign o_led=sensor_ready;
endmodule
