`timescale 1ns/1ps
module tb_bell_profile;
    reg [2:0] mode;
    reg [23:0] level;
    wire [15:0] ratio;
    wire [6:0] weight;
    wire [13:0] loss;
    bell_mode_profile dut(.mode(mode),.level(level),.ratio(ratio),
        .weight(weight),.loss(loss));
    integer m,n,expected,total;
    integer ratios[0:7];
    integer weights[0:7];
    initial begin
        ratios[0]=4096;ratios[1]=8192;ratios[2]=10962;ratios[3]=15044;
        ratios[4]=21092;ratios[5]=25102;ratios[6]=28824;ratios[7]=29480;
        weights[0]=16;weights[1]=56;weights[2]=32;weights[3]=48;
        weights[4]=24;weights[5]=40;weights[6]=24;weights[7]=8;
        total=0;
        for(m=0;m<8;m=m+1) begin
            mode=m;
            for(n=0;n<1024;n=n+1) begin
                level=n==0 ? 0 : n==1 ? 1 : n==2 ? 24'hffffff : $random;
                #1;
                case(m)
                    0:expected=(level+32767)/32768;
                    1:expected=(level+131071)/131072;
                    2:expected=(level+65535)/65536;
                    3:expected=(level+16383)/16384;
                    4,5:expected=(level+8191)/8192;
                    6:expected=(level+4095)/4096;
                    7:expected=(level+2047)/2048;
                endcase
                if(ratio!==ratios[m] || weight!==weights[m] || loss!==expected)
                    $fatal(1,"modal profile mismatch mode=%0d level=%0d",m,level);
                if(level!=0 && loss==0) $fatal(1,"stuck modal tail");
            end
            total=total+weight;
        end
        if(total>256) $fatal(1,"unbounded modal peak");
        $display("PASS reference modal ratios, bounded weights, exact damping and no stuck tails");
        $finish;
    end
endmodule
