`timescale 1ns/1ps
module tb_oled_display #(
    parameter [6:0] SCREEN_ADDRESS=7'h3c,
    parameter ALL_ON=0
);
    reg clk=0;
    always #50 clk=~clk;
    reg rst_n=0, dirty=0;
    reg [15:0] volume=64;
    reg [5:0] voices=0;
    tri1 scl, sda;
    reg slave_ack=0, ack_enabled=0, stretch=0;
    assign sda=slave_ack ? 1'b0 : 1'bz;
    assign scl=stretch ? 1'b0 : 1'bz;
    wire initialized, fault, frame_done;
    oled_display #(.CLK_HZ(10000000), .I2C_HZ(500000),
        .ALL_ON_DIAGNOSTIC(ALL_ON),
        .POWERUP_CYCLES(50), .REFRESH_CYCLES(100), .TIMEOUT_TICKS(40)) dut (
        .clk(clk), .rst_n(rst_n), .ui_dirty(dirty), .ui_page(4'd0),
        .volume_value(volume), .instrument_value(16'd0), .active_voice_count(voices),
        .input_ready(1'b1), .audio_locked(1'b1), .i2s_active(1'b1), .system_error(1'b0),
        .oled_scl(scl), .oled_sda(sda), .initialized(initialized), .fault(fault), .frame_done(frame_done)
    );
    reg active=0, addressed=0;
    integer bits=0, tx_index=0, mode=0, page=0, column=0;
    integer init_transactions=0, resume_transactions=0, data_transactions=0, stops=0;
    reg [7:0] received=0;
    reg [7:0] memory[0:1023];
    reg saw_af=0, saw_page_mode=0, saw_all_on=0, saw_normal=0;
    // Model a write-only SSD1306 at the physical I2C pins.
    always @(negedge sda) if (scl===1'b1) begin
        active=1; bits=0; tx_index=0; received=0; addressed=0;
    end
    always @(posedge sda) if (scl===1'b1 && active) begin
        active=0; stops=stops+1;
        if (ack_enabled && addressed && mode==8'h40 && tx_index>1) begin
            if (tx_index!=130) $fatal(1,"pixel transaction length %0d",tx_index);
            data_transactions=data_transactions+1;
        end
    end
    always @(posedge scl) if (active) begin
        if (bits<8) begin
            received={received[6:0],sda}; bits=bits+1;
            if (bits==8 && tx_index==0) addressed=(received=={SCREEN_ADDRESS,1'b0});
        end
        else begin
            bits=0;
            if (tx_index==0) begin
                if (received!=8'h78 && received!=8'h7a) $fatal(1,"wrong OLED address %h",received);
                mode=0;
            end else if (tx_index==1) begin
                mode=received;
                if (mode!=0 && mode!=8'h40) $fatal(1,"invalid control byte");
            end else if (ack_enabled && addressed) begin
                if (mode==8'h40) begin
                    if (column>127) $fatal(1,"column overflow");
                    memory[page*128+column]=received; column=column+1;
                end else if (tx_index==2 && received==8'hae) begin
                    init_transactions=init_transactions+1;
                end else if (tx_index==2 && (received==8'ha4 || received==8'ha5)) begin
                    resume_transactions=resume_transactions+1;
                end else if (received==8'haf) saw_af=1;
                else if (received==8'ha5) saw_all_on=1;
                else if (received==8'ha4) saw_normal=1;
                else if (tx_index==13 && received==8'h02) saw_page_mode=1;
                else if (tx_index==2 && received[7:4]==4'hb) begin page=received[2:0]; column=0; end
            end
            tx_index=tx_index+1;
        end
    end
    always @(negedge scl) slave_ack=active && bits==8 && ack_enabled && addressed;
    task update;
        begin
            @(negedge clk); volume=65; voices=2; dirty=1;
            @(negedge clk); dirty=0;
        end
    endtask
    initial begin
        repeat(5) @(negedge clk); rst_n=1;
        // An unplugged screen must terminate, leave the bus idle and retry.
        wait(fault);
        if (initialized || scl!==1 || sda!==1) $fatal(1,"NACK did not release bus");
        @(negedge clk); ack_enabled=1;
        wait(dut.state==5 && dut.byte_index==30);
        update();
        wait(frame_done); @(negedge clk);
        if (!initialized || fault || !saw_af || !saw_page_mode || data_transactions!=8 ||
            (ALL_ON && (!saw_all_on || saw_normal)) ||
            (!ALL_ON && (!saw_normal || saw_all_on)))
            $fatal(1,"initialization/frame failed");
        // V first column: 0x1f doubled into top ff, bottom 03.
        if (memory[9]!=8'hff || memory[137]!=8'h03)
            $fatal(1,"font/page layout incorrect");
        // Snapshot must retain old volume 064 through the first frame.
        // Digit 4 first column is 0x18 -> doubled 0x03c0.
        if (memory[57]!=8'hc0 || memory[185]!=8'h03)
            $fatal(1,"mid-frame volume update tore snapshot");
        wait(!frame_done); wait(frame_done); @(negedge clk);
        // Next frame digit 5 first column is 0x27 -> doubled 0x0c3f.
        if (memory[57]!=8'h3f || memory[185]!=8'h0c || data_transactions!=16)
            $fatal(1,"pending redraw lost");
        if (memory[577]!=8'h0c || memory[705]!=8'h30)
            $fatal(1,"voice count display incorrect");
        // A brief slave stretch must preserve the transaction and its pixels.
        @(negedge clk); dirty=1;
        @(negedge clk); dirty=0;
        wait(dut.bus.state==5); stretch=1;
        repeat(100) @(negedge clk);
        stretch=0;
        wait(frame_done); @(negedge clk);
        if (fault || data_transactions!=24) $fatal(1,"short clock stretch failed");
        // NACK in a pixel stream also requires full initialization on retry.
        @(negedge clk); dirty=1;
        @(negedge clk); dirty=0;
        wait(dut.state==5 && dut.byte_index==30);
        ack_enabled=0;
        wait(fault); @(negedge clk); ack_enabled=1;
        wait(frame_done); @(negedge clk);
        if (fault || !initialized) $fatal(1,"pixel NACK recovery failed");
        // Trigger redraw, hold SCL beyond the bounded wait, then reconnect.
        @(negedge clk); dirty=1;
        @(negedge clk); dirty=0;
        wait(dut.bus.state==5);
        stretch=1;
        wait(fault); @(negedge clk); stretch=0;
        wait(frame_done); @(negedge clk);
        if (fault || !initialized || init_transactions!=1 || resume_transactions<2)
            $fatal(1,"stretch timeout recovery blanked the display");
        // Reset releases both outputs immediately.
        rst_n=0; #200;
        if (scl!==1 || sda!==1) $fatal(1,"reset bus release failed");
        $display("PASS OLED physical I2C init, 1024 pixels, font, snapshot, redraw, NACK and stretch recovery");
        $finish;
    end
    initial begin #200000000; $fatal(1,"OLED timeout state=%0d byte=%0d fault=%b frames=%0d",dut.state,dut.byte_index,fault,data_transactions/8); end
endmodule
