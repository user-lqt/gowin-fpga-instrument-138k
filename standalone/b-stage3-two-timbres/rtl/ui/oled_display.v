`timescale 1ns/1ps
// SSD1306 128x64: page writes from one coherent B content snapshot per frame.
module oled_display #(
    parameter integer CLK_HZ = 12288136,
    parameter integer I2C_HZ = 50000,
    parameter [6:0] ADDRESS = 7'h3c,
    parameter integer AUTO_ADDRESS = 1,
    parameter integer ALL_ON_DIAGNOSTIC = 0,
    parameter integer INIT_ONLY_DIAGNOSTIC = 0,
    parameter integer POWERUP_CYCLES = CLK_HZ/2,
    parameter integer REFRESH_CYCLES = CLK_HZ/5,
    parameter integer TIMEOUT_TICKS = 2000
) (
    input wire clk, rst_n, ui_dirty,
    input wire [3:0] ui_page,
    input wire [15:0] volume_value, instrument_value,
    input wire [5:0] active_voice_count,
    input wire input_ready, audio_locked, i2s_active, system_error,
    inout wire oled_scl, oled_sda,
    output reg initialized, fault,
    output reg frame_done
);
    localparam WAIT_POWER=0, INIT=1, SNAPSHOT=2, SNAP_WAIT=3,
        PAGE_COMMAND=4, PAGE_DATA=5, WAIT_REFRESH=6, DIAGNOSTIC_HOLD=7;
    reg [2:0] state;
    reg [31:0] delay_count;
    reg [5:0] init_index;
    reg [7:0] byte_index;
    reg [2:0] page;
    reg outstanding, pending, snapshot_start;
    reg alternate_address, panel_started;
    wire [6:0] device_address=ADDRESS ^ {6'd0,alternate_address};
    wire [7:0] pixel_index=byte_index-8'd2;
    wire [5:0] char_addr={page[2:1], pixel_index[6:3]};
    wire [7:0] character, pixels;
    wire ready, done, bus_error;
    reg send, last;
    reg [7:0] tx_data;
    oled_content content (
        .clk(clk), .rst_n(rst_n), .frame_start(snapshot_start),
        .char_addr(char_addr), .ui_page(ui_page),
        .volume_value(volume_value), .instrument_value(instrument_value),
        .active_voice_count(active_voice_count), .input_ready(input_ready),
        .audio_locked(audio_locked), .i2s_active(i2s_active),
        .system_error(system_error), .char_data(character)
    );
    // Data transactions have two prefix bytes before the 128 pixel bytes.
    oled_font font (.character(character), .column(pixel_index[2:0]),
        .bottom(page[0]), .pixels(pixels));
    oled_i2c_master #(.CLK_HZ(CLK_HZ), .I2C_HZ(I2C_HZ),
        .TIMEOUT_TICKS(TIMEOUT_TICKS)) bus (
        .clk(clk), .rst_n(rst_n), .send(send), .last(last), .data(tx_data),
        .ready(ready), .done(done), .error(bus_error), .nack_seen(),
        .scl(oled_scl), .sda(oled_sda)
    );
    function [7:0] init_command;
        input [5:0] n;
        begin
            case (n)
                0:init_command=8'hae; 1:init_command=8'hd5; 2:init_command=8'h80;
                3:init_command=8'ha8; 4:init_command=8'h3f;
                5:init_command=8'hd3; 6:init_command=0; 7:init_command=8'h40;
                8:init_command=8'h8d; 9:init_command=8'h14;
                10:init_command=8'h20; 11:init_command=8'h02;
                12:init_command=8'ha1; 13:init_command=8'hc8;
                14:init_command=8'hda; 15:init_command=8'h12;
                16:init_command=8'h81; 17:init_command=8'h7f;
                18:init_command=8'hd9; 19:init_command=8'hf1;
                20:init_command=8'hdb; 21:init_command=8'h40;
                22:init_command=ALL_ON_DIAGNOSTIC ? 8'ha5 : 8'ha4;
                23:init_command=8'ha6;
                default:init_command=8'haf;
            endcase
        end
    endfunction
    always @* begin
        send=0; last=0; tx_data=0;
        if (ready && !outstanding) begin
            case (state)
                INIT: begin
                    send=1; last=(init_index==26);
                    if (init_index==0) tx_data={device_address,1'b0};
                    else if (init_index==1) tx_data=0;
                    else if (init_index==2 && panel_started)
                        tx_data=ALL_ON_DIAGNOSTIC ? 8'ha5 : 8'ha4;
                    else tx_data=init_command(init_index-2);
                end
                PAGE_COMMAND: begin
                    send=1; last=(byte_index==4);
                    case (byte_index)
                        0:tx_data={device_address,1'b0}; 1:tx_data=0;
                        2:tx_data=8'hb0|{5'd0,page};
                        3:tx_data=0; default:tx_data=8'h10;
                    endcase
                end
                PAGE_DATA: begin
                    send=1; last=(byte_index==129);
                    if (byte_index==0) tx_data={device_address,1'b0};
                    else if (byte_index==1) tx_data=8'h40;
                    else tx_data=pixels;
                end
                default: begin end
            endcase
        end
    end
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state<=WAIT_POWER; delay_count<=0; init_index<=0; byte_index<=0;
            page<=0; outstanding<=0; pending<=1; snapshot_start<=0;
            initialized<=0; fault<=0; frame_done<=0;
            alternate_address<=0; panel_started<=0;
        end else begin
            snapshot_start<=0; frame_done<=0;
            if (ui_dirty) pending<=1;
            if (send) outstanding<=1;
            if (done) outstanding<=0;
            if (done && bus_error) begin
                state<=WAIT_POWER; delay_count<=0; init_index<=0;
                initialized<=0; fault<=1; pending<=1;
                if (AUTO_ADDRESS && state==INIT && init_index==0)
                    alternate_address<=!alternate_address;
            end else case (state)
                WAIT_POWER: begin
                    if (delay_count==POWERUP_CYCLES-1) begin
                        state<=INIT; init_index<=0; delay_count<=0;
                    end else delay_count<=delay_count+1'b1;
                end
                INIT: if (done) begin
                    if (init_index==26) begin
                        panel_started<=1;
                        if (INIT_ONLY_DIAGNOSTIC) begin
                            state<=DIAGNOSTIC_HOLD; initialized<=1; fault<=0;
                        end else state<=SNAPSHOT;
                    end
                    else init_index<=init_index+1'b1;
                end
                SNAPSHOT: begin
                    snapshot_start<=1; pending<=ui_dirty;
                    state<=SNAP_WAIT; page<=0; byte_index<=0;
                end
                SNAP_WAIT: state<=PAGE_COMMAND;
                PAGE_COMMAND: if (done) begin
                    if (byte_index==4) begin state<=PAGE_DATA; byte_index<=0; end
                    else byte_index<=byte_index+1'b1;
                end
                PAGE_DATA: if (done) begin
                    if (byte_index==129) begin
                        byte_index<=0;
                        if (page==7) begin
                            state<=WAIT_REFRESH; delay_count<=0;
                            initialized<=1; fault<=0; frame_done<=1;
                        end else begin page<=page+1'b1; state<=PAGE_COMMAND; end
                    end else byte_index<=byte_index+1'b1;
                end
                WAIT_REFRESH: begin
                    if (delay_count==REFRESH_CYCLES-1) begin
                        delay_count<=0;
                        if (pending || ui_dirty) state<=SNAPSHOT;
                    end else delay_count<=delay_count+1'b1;
                end
                // Keep both I2C lines released after AF. No pixel transfer,
                // redraw, repeated initialization or timed display-off.
                DIAGNOSTIC_HOLD: begin end
                default: state<=WAIT_POWER;
            endcase
        end
    end
endmodule
