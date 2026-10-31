// Full additive oscillator with phase history in RAM and shared intermediates.
// Start after transient gains settle; all pitch snapshots precede clock 112.
// Report reference: 64 voices use eight instances with eight independent lanes.
// phase_ram stores fundamental/2nd/3rd/5th phase histories for EVERY lane.
// lane/step time-multiplex one sine lookup and product datapath; a lane's
// frequency, brightness and output sample remain distinct from its neighbors.
// Harmonic components and stereo channels must not be counted as extra voices.
module oscillator_state_bank #(parameter integer LANES=8,
    parameter integer ENABLE_ACCEPTANCE=0,
    parameter integer EXTERNAL_PITCH_SELECT=0)(
    input wire clk,rst_n,sample_tick,
    input wire acceptance_mode,
    input wire [LANES-1:0] note_on,
    input wire [LANES*32-1:0] fcs,
    input wire [LANES*2-1:0] instruments,
    input wire [LANES*8-1:0] brightnesses,
    output wire [LANES*16-1:0] waves,
    input wire [31:0] selected_fc,
    output wire [(LANES>1 ? $clog2(LANES) : 1)-1:0] pitch_lane
);
    localparam integer IB=LANES>1 ? $clog2(LANES) : 1;
    localparam [IB-1:0] LAST_LANE=LANES-1;
    reg [31:0] phase_ram[0:LANES*4-1] /* synthesis syn_ramstyle="distributed_ram" */;
    reg [31:0] read_phase;
    reg [LANES-1:0] valid,pending_note;
    reg [IB-1:0] lane;
    assign pitch_lane=lane;
    reg [4:0] step;
    reg [4:0] start_delay;
    reg [31:0] phase,p2,p3,p5,fc;
    reg [1:0] instrument;
    reg signed [15:0] output_wave[0:LANES-1];
    reg signed [17:0] fundamental,second,third,fifth;
    wire signed [15:0] acceptance_wave=$signed(fundamental) >>> 4;
    reg signed [23:0] h1,bright_product;
    reg signed [25:0] upper_sum;
    wire reset_phase=pending_note[lane] || note_on[lane];
    reg [31:0] address_phase;
    always @* begin
        case(step)
            5: address_phase=instrument==0 ? p2 : phase<<1;
            6: address_phase=instrument==0 ? p3 : phase+(phase<<1);
            7: address_phase=instrument==0 ? p5 : phase+(phase<<2);
            default: address_phase=phase;
        endcase
    end
    wire signed [15:0] sine;
    // Upper 12 phase bits address a 4096-entry sine ROM; the lower bits keep
    // tuning precision. Synchronous ROM latency is accounted for by step.
    wavetable table_rom(.clk(clk),.addr(address_phase[31:20]),.dout(sine));
    reg [31:0] phase_fc;
    reg phase_reset;
    reg [31:0] selected_phase,increment_base,increment_extra,increment_stretch;
    always @* begin
        selected_phase=phase;
        increment_base=fc;increment_extra=0;increment_stretch=0;
        case(step)
            4: begin
                selected_phase=p2;
                increment_base=phase_fc<<1;increment_stretch=phase_fc>>11;
            end
            5: begin
                selected_phase=p3;
                increment_base=phase_fc<<1;increment_extra=phase_fc;
                increment_stretch=phase_fc>>9;
            end
            6: begin
                selected_phase=p5;
                increment_base=phase_fc<<2;increment_extra=phase_fc;
                increment_stretch=phase_fc>>7;
            end
            default: ;
        endcase
    end
    // Each harmonic is updated before its ROM address is needed.
    // Unsigned 32-bit wrap implements modulo-2^32 phase accumulation.
    // Piano partial stretching changes increments, not the voice count.
    wire [31:0] phase_increment=increment_base+increment_extra+increment_stretch;
    wire [31:0] updated_phase=selected_phase+phase_increment;
    reg [7:0] g1,g2,g3,g5;
    always @* begin
        if(fc<32'd12418159) begin g1=96;g2=64;g3=32;g5=16;end
        else if(fc<32'd24836318) begin g1=128;g2=64;g3=24;g5=8;end
        else if(fc<32'd49672636) begin g1=168;g2=40;g3=12;g5=3;end
        else begin g1=192;g2=28;g3=6;g5=1;end
    end
    wire signed [25:0] shifted_upper=upper_sum >>> 8;
    wire signed [17:0] piano_upper=shifted_upper[17:0];
    wire signed [17:0] body=instrument==2 ? 18'sd0 :
        (fundamental >>> 1)+(instrument==3 ? second >>> 3 :
            instrument==0 ? fundamental >>> 3 : 18'sd0);
    wire signed [17:0] upper=instrument==2 ? 18'sd0 :
        (instrument==0 ? second >>> 1 : second >>> 3)+
        (third >>> 2)+(fifth >>> 3);
    reg signed [17:0] operand;
    reg [7:0] gain;
    always @* begin
        case(step)
            6: begin operand=fundamental;gain=g1;end
            7: begin operand=second;gain=g2;end
            8: begin operand=third;gain=g3;end
            9: begin operand=fifth;gain=g5;end
            default: begin
                operand=instrument==0 ? $signed(piano_upper[15:0]) : upper;
                gain=brightnesses[lane*8+:8];
            end
        endcase
    end
    wire signed [26:0] product=operand*$signed({1'b0,gain});
    wire signed [25:0] upper_product={{2{product[23]}},product[23:0]};
    wire signed [23:0] shifted_h1=h1 >>> 8;
    wire signed [17:0] result_base=instrument==0 ? shifted_h1[17:0] : body;
    wire signed [17:0] result_upper=instrument==0 ? piano_upper >>> 1 : 18'sd0;
    wire signed [23:0] shifted_bright=bright_product >>> 7;
    wire signed [29:0] result_math={{6{result_base[17]}},result_base}+
        {{6{result_upper[17]}},result_upper}+
        {{6{shifted_bright[23]}},shifted_bright};
    wire signed [17:0] result=instrument==2 ? 18'sd0 : result_math[17:0];
    wire [1:0] read_component=step==2 ? 2'd1 :
        step==3 ? 2'd2 : step==4 ? 2'd3 : 2'd0;
    wire [1:0] write_component=step[1:0]-2'd3;
    wire writing_phase=rst_n && step>=3 && step<=6;
    wire clear_phase=step==3 ? reset_phase : phase_reset;
    wire [31:0] stored_phase=clear_phase ? 32'd0 : updated_phase;
    always @(posedge clk) begin
        read_phase<=phase_ram[{lane,read_component}];
        if(writing_phase) phase_ram[{lane,write_component}]<=stored_phase;
    end
    integer i;
    always @(posedge clk or negedge rst_n) begin
        if(!rst_n) begin
            valid<=0;pending_note<=0;lane<=0;step<=0;start_delay<=0;
            phase<=0;p2<=0;p3<=0;p5<=0;fc<=0;instrument<=0;
            phase_fc<=0;phase_reset<=0;
            fundamental<=0;second<=0;third<=0;fifth<=0;
            h1<=0;upper_sum<=0;bright_product<=0;
            for(i=0;i<LANES;i=i+1) output_wave[i]<=0;
        end else begin
            pending_note<=pending_note|note_on;
            if(sample_tick) begin lane<=0;step<=0;start_delay<=16;end
            else if(start_delay!=0) begin
                start_delay<=start_delay-5'd1;
                if(start_delay==1) step<=1;
            end
            else if(step!=0) begin
                if(step==13) begin
                    step<=lane==LAST_LANE ? 5'd0 : 5'd1;
                    if(lane!=LAST_LANE) lane<=lane+1'b1;
                end else step<=step+5'd1;
                case(step)
                    2: begin
                        phase<=valid[lane] && !reset_phase ? read_phase : 32'd0;
                        fc<=EXTERNAL_PITCH_SELECT ? selected_fc : fcs[lane*32+:32];
                        instrument<=instruments[lane*2+:2];
                    end
                    3: begin
                        // NOTE_ON pitch lookup commits alongside step 2.
                        // Refresh coefficients after that synchronous update.
                        fc<=EXTERNAL_PITCH_SELECT ? selected_fc : fcs[lane*32+:32];
                        phase_fc<=fc;phase_reset<=reset_phase;
                        phase<=reset_phase ? 32'd0 : updated_phase;
                        p2<=valid[lane] && !reset_phase ? read_phase : 32'd0;
                        pending_note[lane]<=note_on[lane];
                    end
                    4: begin
                        p2<=phase_reset ? 32'd0 : updated_phase;
                        p3<=valid[lane] && !phase_reset ? read_phase : 32'd0;
                    end
                    5: begin
                        p3<=phase_reset ? 32'd0 : updated_phase;
                        p5<=valid[lane] && !phase_reset ? read_phase : 32'd0;
                        fundamental<=sine;
                    end
                    6: begin
                        p5<=phase_reset ? 32'd0 : updated_phase;
                        second<=fc<32'h40000000 ? sine : 16'sd0;h1<=product[23:0];
                    end
                    7: begin third<=fc<32'h2aaaaaaa ? sine : 16'sd0;upper_sum<=upper_product;end
                    8: begin fifth<=fc<32'h19999999 ? sine : 16'sd0;upper_sum<=upper_sum+upper_product;end
                    9: upper_sum<=upper_sum+upper_product;
                    10: bright_product<=product[23:0];
                    // TEST selects only the fundamental; normal mode retains
                    // the additive timbre. Both use the same per-lane history.
                    11: begin
                        valid[lane]<=1;
                        output_wave[lane]<=(ENABLE_ACCEPTANCE && acceptance_mode) ?
                            acceptance_wave : result>32767 ? 16'sh7fff :
                            result< -32768 ? 16'sh8000 : result[15:0];
                    end
                    default: ;
                endcase
            end
        end
    end
    genvar g;
    generate for(g=0;g<LANES;g=g+1) begin : outputs
        assign waves[g*16+:16]=output_wave[g];
    end endgenerate
endmodule
