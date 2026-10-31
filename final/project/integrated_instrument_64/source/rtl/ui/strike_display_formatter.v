// Slow diagnostic data; constant scaling and serial BCD avoid a pixel-path divider.
module strike_display_formatter #(
    parameter integer ROW_CYCLES=307
) (
    input wire clk,rst_n,
    input wire [31:0] debug_value,
    input wire [15:0] frames,
    output wire [40:0] display_value
);
    localparam [63:0] NUMERATOR=64'd80000*ROW_CYCLES;
    localparam [31:0] WHOLE=NUMERATOR/64'd12288000;
    localparam [23:0] REMAINDER=NUMERATOR%64'd12288000;
    reg [1:0] state;
    reg [28:0] snapshot;
    reg [15:0] remaining,binary_time;
    reg [23:0] fraction;
    wire [24:0] fraction_sum={1'b0,fraction}+{1'b0,REMAINDER};
    wire carry=fraction_sum>=25'd12288000;
    wire [24:0] fraction_next=carry ? fraction_sum-25'd12288000 : fraction_sum;
    wire [32:0] time_next={17'd0,binary_time}+{1'b0,WHOLE}+{32'd0,carry};
    reg [15:0] shift_time,shift_key,shift_velocity;
    reg [19:0] decimal_time,decimal_key,decimal_velocity;
    reg [4:0] step;
    reg valid;
    reg [19:0] time_bcd;
    reg [7:0] key_bcd;
    reg [11:0] velocity_bcd;
    assign display_value={valid,key_bcd,velocity_bcd,time_bcd};
    function [19:0] adjust;
        input [19:0] value;
        integer i;
        begin
            adjust=value;
            for(i=0;i<5;i=i+1)
                if(value[i*4+:4]>=4'd5) adjust[i*4+:4]=value[i*4+:4]+4'd3;
        end
    endfunction
    wire [19:0] adjusted_time=adjust(decimal_time);
    wire [19:0] adjusted_key=adjust(decimal_key);
    wire [19:0] adjusted_velocity=adjust(decimal_velocity);
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            state<=0;snapshot<=0;remaining<=0;binary_time<=0;fraction<=0;
            shift_time<=0;shift_key<=0;shift_velocity<=0;
            decimal_time<=0;decimal_key<=0;decimal_velocity<=0;step<=0;
            valid<=0;time_bcd<=0;key_bcd<=0;velocity_bcd<=0;
        end else case(state)
            0: if(debug_value[31] && (!valid || snapshot!={debug_value[28:16],frames})) begin
                snapshot<={debug_value[28:16],frames};
                remaining<=frames;binary_time<=0;fraction<=24'd6144000;state<=1;
            end
            1: if(remaining!=0) begin
                remaining<=remaining-16'd1;
                fraction<=fraction_next[23:0];
                binary_time<=time_next>33'd65535 ? 16'hffff : time_next[15:0];
            end else begin
                shift_time<=binary_time;
                shift_key<={11'd0,snapshot[28:24]}+16'd1;
                shift_velocity<={8'd0,snapshot[23:16]};
                decimal_time<=0;decimal_key<=0;decimal_velocity<=0;step<=0;state<=2;
            end
            2: begin
                decimal_time<={adjusted_time[18:0],shift_time[15]};
                decimal_key<={adjusted_key[18:0],shift_key[15]};
                decimal_velocity<={adjusted_velocity[18:0],shift_velocity[15]};
                shift_time<={shift_time[14:0],1'b0};
                shift_key<={shift_key[14:0],1'b0};
                shift_velocity<={shift_velocity[14:0],1'b0};
                step<=step+5'd1;
                if(step==5'd15) state<=3;
            end
            3: begin
                time_bcd<=decimal_time;key_bcd<=decimal_key[7:0];
                velocity_bcd<=decimal_velocity[11:0];valid<=1;state<=0;
            end
        endcase
    end
endmodule
