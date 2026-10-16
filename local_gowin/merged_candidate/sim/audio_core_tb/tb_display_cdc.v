`timescale 1ns/1ps
module display_cdc_case #(parameter WIDTH=210)(
    input wire source_clk,pixel_clk,rst_n,frame_start,
    output reg [31:0] transfers=0
);
    reg [31:0] sequence_number=1;
    wire [WIDTH-1:0] payload,received;
    genvar bit_number;
    generate for(bit_number=0;bit_number<WIDTH;bit_number=bit_number+1) begin : pattern
        assign payload[bit_number]=sequence_number[bit_number%32] ^ (bit_number%2);
    end endgenerate
    lcd_status_bridge #(.WIDTH(WIDTH)) dut(
        .source_clk(source_clk),.source_rst_n(rst_n),.source_status(payload),
        .pixel_clk(pixel_clk),.pixel_rst_n(rst_n),.frame_start(frame_start),
        .pixel_status(received));
    always @(posedge source_clk)
        if(!rst_n) sequence_number<=1;
        else sequence_number<=sequence_number+1;
    reg [WIDTH-1:0] previous;
    reg [31:0] decoded,last_sequence;
    integer b;
    always @(posedge pixel_clk) begin
        #1;
        if(!rst_n) begin previous=0;last_sequence=0;transfers=0;end
        else if(received!==previous) begin
            decoded=received[31:0]^32'haaaaaaaa;
            for(b=0;b<WIDTH;b=b+1)
                if(received[b] !== (decoded[b%32] ^ (b%2)))
                    $fatal(1,"torn CDC snapshot width=%0d bit=%0d",WIDTH,b);
            if(decoded<=last_sequence)
                $fatal(1,"repeated or stale CDC snapshot width=%0d",WIDTH);
            last_sequence=decoded;previous=received;transfers=transfers+1;
        end
    end
endmodule

module tb_display_cdc;
    reg source_clk=0,pixel_clk=0,rst_n=0,frame_start=0;
    always #40.69 source_clk=~source_clk;
    always #15 pixel_clk=~pixel_clk;
    wire [31:0] n210,n49,n128;
    display_cdc_case #(.WIDTH(210)) status_bus(.*,.transfers(n210));
    display_cdc_case #(.WIDTH(49)) feature_bus(.*,.transfers(n49));
    display_cdc_case #(.WIDTH(128)) spectrum_bus(.*,.transfers(n128));
    integer round,cycle;
    initial begin
        repeat(5) @(negedge pixel_clk);rst_n=1;
        for(round=0;round<2;round=round+1) begin
            for(cycle=0;cycle<20000;cycle=cycle+1) begin
                @(negedge pixel_clk);
                frame_start=(cycle%17==0 || cycle%31==0 || cycle%97<12);
            end
            if(n210<100 || n49<100 || n128<100)
                $fatal(1,"CDC transfer stalled");
            rst_n=0;frame_start=0;
            repeat(12) @(negedge pixel_clk);rst_n=1;
        end
        $display("PASS asynchronous 210/49/128-bit snapshots: coherence, progress, burst requests and reset");
        $finish;
    end
endmodule
