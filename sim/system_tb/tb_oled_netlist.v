`timescale 1ns/1ps
// Decode the actual synthesized probe at its package pins. PLL is bypassed
// only in simulation; all display, divider, IOBUF and register logic is real.
module tb_oled_netlist #(parameter INIT_ONLY=0);
    reg clk=0, reset_n=0;
    always #40.6901 clk=~clk;
    tri1 scl,sda;
    reg ack=0, active=0;
    integer bits=0, index=0, transaction=0, pixels=0;
    reg [7:0] value=0;
    reg [7:0] expected[0:26];
    assign sda=ack ? 1'b0 : 1'bz;
    oled_panel_probe_top dut(.i_clk_in(clk),.i_rst_n(!reset_n),
        .oled_scl(scl),.oled_sda(sda),.o_led(),.o_locked());
    always @(negedge sda) if(scl===1) begin
        active=1; bits=0; index=0;
    end
    always @(posedge sda) if(scl===1 && active) begin
        if(transaction==0 && index!=27) $fatal(1,"init length %0d",index);
        if(transaction>0 && index!=((transaction%2)==1 ? 5:130))
            $fatal(1,"frame transaction length %0d: %0d",transaction,index);
        transaction=transaction+1; active=0;
        $display("STOP transaction=%0d pixels=%0d",transaction,pixels);
    end
    always @(posedge scl) if(active) begin
        if(bits<8) begin value={value[6:0],sda}; bits=bits+1; end
        else begin
            if(transaction==0) begin
                $display("INIT[%0d]=%02h",index,value);
                if(index>26 || value!==expected[index])
                    $fatal(1,"synthesized init byte %0d: %h expected %h",index,value,expected[index]);
            end else if(index==0 && value!==8'h78) $fatal(1,"address changed");
            else if(index==1 && value!==((transaction%2)==1 ? 8'h00:8'h40))
                $fatal(1,"bad control byte");
            else if(transaction%2==1 && index==2 && value!==(8'hb0+((transaction-1)/2)))
                $fatal(1,"bad page command");
            else if(transaction%2==1 && index==3 && value!==0) $fatal(1,"bad low column");
            else if(transaction%2==1 && index==4 && value!==8'h10) $fatal(1,"bad high column");
            else if(transaction%2==0 && index>=2) begin
                if(^value===1'bx) $fatal(1,"unknown pixel");
                pixels=pixels+1;
            end
            bits=0; index=index+1;
        end
    end
    always @(negedge scl) ack=active && bits==8;
    initial begin
        expected[0]=8'h78; expected[1]=0;
        expected[2]=8'hae; expected[3]=8'hd5; expected[4]=8'h80;
        expected[5]=8'ha8; expected[6]=8'h3f; expected[7]=8'hd3;
        expected[8]=0; expected[9]=8'h40; expected[10]=8'h8d;
        expected[11]=8'h14; expected[12]=8'h20; expected[13]=8'h02;
        expected[14]=8'ha1; expected[15]=8'hc8; expected[16]=8'hda;
        expected[17]=8'h12; expected[18]=8'h81; expected[19]=8'h7f;
        expected[20]=8'hd9; expected[21]=8'hf1; expected[22]=8'hdb;
        expected[23]=8'h40; expected[24]=8'ha5; expected[25]=8'ha6; expected[26]=8'haf;
        force dut.clk_audio=clk;
        force dut.o_locked_d=1'b1;
        force dut.rst_n=reset_n;
        #1000; reset_n=1;
        // Skip the power-on delay only. Serial timing remains synthesized.
        @(negedge clk); force dut.u_oled.delay_count=32'd6144067;
        @(negedge clk); release dut.u_oled.delay_count;
        wait(transaction==(INIT_ONLY ? 1:17));
        if(pixels!=(INIT_ONLY ? 0:1024)) $fatal(1,"pixel count %0d",pixels);
        // The init-only diagnostic must not send a second transaction.
        #1000000;
        if(scl!==1 || sda!==1 || transaction!=(INIT_ONLY ? 1:17))
            $fatal(1,"bus not idle after full frame");
        $display("PASS synthesized OLED exact init, transactions=%0d pixels=%0d, idle bus",transaction,pixels);
        $finish;
    end
    initial begin #400000000; $fatal(1,"gate test timeout tx=%0d index=%0d",transaction,index); end
endmodule
