// Production inharmonic bell; coefficients are not a measured historical fit.
module bianzhong_candidate (
    input wire clk, rst_n, sample_tick, note_on,
    input wire [31:0] fc,
    output wire signed [15:0] wave
);
    wire signed [41:0] partial [0:7];
    genvar m;
    generate for (m=0; m<8; m=m+1) begin : modes
        localparam integer RATIO = m==0 ? 4096 : m==1 ? 6103 :
            m==2 ? 8356 : m==3 ? 10977 : m==4 ? 15442 :
            m==5 ? 20972 : m==6 ? 27976 : 33628;
        localparam integer WEIGHT = m==0 ? 72 : m==1 ? 28 :
            m==2 ? 40 : m==3 ? 24 : m==4 ? 24 :
            m==5 ? 20 : m==6 ? 12 : 8;
        localparam integer LOSS_SHIFT = m==0 ? 17 : m==1 ? 16 :
            m==2 ? 17 : m==3 ? 15 : m==4 ? 14 :
            m==5 ? 13 : m==6 ? 12 : 11;
        reg [31:0] phase;
        reg [23:0] level;
        wire [63:0] frequency_product = fc * RATIO;
        wire [51:0] increment = frequency_product >> 12;
        wire [23:0] loss = (level + ((1 << LOSS_SHIFT)-1)) >> LOSS_SHIFT;
        wire signed [15:0] sine;
        wavetable table_rom (.clk(clk), .addr(phase[31:20]), .dout(sine));
        wire signed [32:0] enveloped = sine * $signed({1'b0, level[23:8]});
        assign partial[m] = increment < 52'h080000000 ?
            enveloped * WEIGHT : 42'sd0;
        always @(posedge clk or negedge rst_n) begin
            if (!rst_n) begin phase <= 0; level <= 0; end
            else if (note_on) begin phase <= 0; level <= 24'hffffff; end
            else if (sample_tick) begin
                phase <= phase + increment[31:0];
                level <= level > loss ? level - loss : 0;
            end
        end
    end endgenerate
    wire signed [44:0] sum =
        {{3{partial[0][41]}}, partial[0]} +
        {{3{partial[1][41]}}, partial[1]} +
        {{3{partial[2][41]}}, partial[2]} +
        {{3{partial[3][41]}}, partial[3]} +
        {{3{partial[4][41]}}, partial[4]} +
        {{3{partial[5][41]}}, partial[5]} +
        {{3{partial[6][41]}}, partial[6]} +
        {{3{partial[7][41]}}, partial[7]};
    wire signed [20:0] rendered = sum >>> 24;
    assign wave = rendered > 32767 ? 16'sh7fff :
        rendered < -32768 ? 16'sh8000 : rendered[15:0];
endmodule
