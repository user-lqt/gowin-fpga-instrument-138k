// Reference-guided modal parameters, shared by all three rendering paths.
// A quiet pitch anchor supports a brighter octave body and inharmonic crown.
module bell_mode_profile (
    input wire [2:0] mode,
    input wire [23:0] level,
    output reg [15:0] ratio,
    output reg [6:0] weight,
    output reg [13:0] loss
);
    always @* begin
        case(mode)
            0: begin
                ratio=4096;weight=16;
                loss={5'd0,level[23:15]}+{13'd0,(|level[14:0])};
            end
            1: begin
                ratio=8192;weight=56;
                loss={7'd0,level[23:17]}+{13'd0,(|level[16:0])};
            end
            2: begin
                ratio=10962;weight=32;
                loss={6'd0,level[23:16]}+{13'd0,(|level[15:0])};
            end
            3: begin
                ratio=15044;weight=48;
                loss={4'd0,level[23:14]}+{13'd0,(|level[13:0])};
            end
            4: begin
                ratio=21092;weight=24;
                loss={3'd0,level[23:13]}+{13'd0,(|level[12:0])};
            end
            5: begin
                ratio=25102;weight=40;
                loss={3'd0,level[23:13]}+{13'd0,(|level[12:0])};
            end
            6: begin
                ratio=28824;weight=24;
                loss={2'd0,level[23:12]}+{13'd0,(|level[11:0])};
            end
            default: begin
                ratio=29480;weight=8;
                loss={1'd0,level[23:11]}+{13'd0,(|level[10:0])};
            end
        endcase
    end
endmodule
