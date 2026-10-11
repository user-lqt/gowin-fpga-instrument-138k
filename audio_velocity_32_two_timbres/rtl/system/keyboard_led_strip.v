// 0807Z2RGB-5V-I4-H22 / 2812: GRB, MSB first, >=80 us reset.
// Clock: 725 MHz / 59 = 12.288136 MHz. 15 clocks/bit = 1.221 us;
// zero high 4 clocks = 0.326 us; one high 9 clocks = 0.732 us.
module keyboard_led_strip #(
    parameter integer LED_COUNT = 49
) (
    input wire clk, rst_n,
    input wire lesson_running,
    input wire [23:0] guide_keys,
    output reg led_din,
    output wire [23:0] remaining
);
    reg [23:0] frame_mask;
    reg [23:0] pixel;
    reg [15:0] lamp;
    reg [4:0] bit_index;
    reg [3:0] phase;
    reg [10:0] reset_count;
    reg sending;
    assign remaining = lesson_running ? guide_keys : 24'd0;

    // LED numbers in this function are one-based, as printed in the wiring map.
    function automatic [23:0] color;
        input [15:0] number;
        input [23:0] mask;
        reg [4:0] key_index;
        begin
            color = 24'd0;
            key_index = 0;
            if (number >= 2 && number <= 24 && !number[0]) begin
                key_index = number[5:1] - 5'd1;
                if (mask[key_index]) color = 24'h200000;
            end else if (number >= 27 && number <= 49 && number[0]) begin
                key_index = number[5:1] - 5'd1;
                if (mask[key_index]) color = 24'h200000;
            end
        end
    endfunction
    wire [23:0] next_color = color(lamp+16'd1,frame_mask);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame_mask <= 0;
            pixel <= 0;
            lamp <= 1;
            bit_index <= 23;
            phase <= 0;
            reset_count <= 0;
            sending <= 0;
            led_din <= 0;
        end else begin
            if (!sending) begin
                led_din <= 0;
                if (reset_count == 1499) begin
                    reset_count <= 0;
                    frame_mask <= lesson_running ? guide_keys : 24'd0;
                    pixel <= 24'd0; // lamp 1 is outside the 24-key mapping
                    lamp <= 1;
                    bit_index <= 23;
                    phase <= 0;
                    sending <= 1;
                end else reset_count <= reset_count+1'b1;
            end else begin
                led_din <= (phase < (pixel[bit_index] ? 9 : 4));
                if (phase == 14) begin
                    phase <= 0;
                    if (bit_index == 0) begin
                        bit_index <= 23;
                        if (lamp == LED_COUNT) begin
                            sending <= 0;
                            reset_count <= 0;
                        end else begin
                            lamp <= lamp+1'b1;
                            // frame_mask is latched at the start of this frame.
                            // Use the live target for the first transition so
                            // entering SONG is visible in the very first frame.
                            pixel <= lamp==16'd1 ?
                                color(16'd2, lesson_running ? guide_keys : 24'd0) : next_color;
                        end
                    end else bit_index <= bit_index-1'b1;
                end else phase <= phase+1'b1;
            end
        end
    end
endmodule
