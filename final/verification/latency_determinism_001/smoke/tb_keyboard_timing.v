`timescale 1ns/1ps
// Clock period is normalized. Reported cycles are converted using the PLL ratio.
module tb_keyboard_timing;
    reg clk=0, rst_n=0;
    always #5 clk=~clk;
    reg [47:0] contacts=0;
    reg [5:0] columns;
    wire [7:0] rows;
    wire [23:0] state;
    wire valid;
    wire [1:0] kind;
    wire [6:0] note;
    wire [7:0] velocity;
    integer cycle=0, r, k, test_id=0, measuring=0, seen=0, expected=0;
    integer b_cycle, mask_arg, phase_arg, mode_arg, bounce_arg;
    integer sample_b[0:23], frame_b[0:23], qualified[0:23], emitted[0:23];
    reg [23:0] selected;
    keyboard_24_input #(.ROW_CYCLES(307),.DEBOUNCE_FRAMES(15),
        .RELEASE_DEBOUNCE_FRAMES(64),.AB_MAX_FRAMES(5004),
        .BASE_NOTE(60),.EVENT_INTERVAL_CYCLES(256)) dut (
        .clk(clk),.rst_n(rst_n),.col_in(columns),.row_out(rows),
        .key_state(state),.event_valid(valid),.event_type(kind),
        .note_id(note),.velocity(velocity));
    always @* begin
        columns=6'h3f;
        for(r=0;r<8;r=r+1)
            if(rows[r]===1'b0) columns=columns & ~contacts[r*6+:6];
    end
    always @(posedge clk) begin
        cycle=cycle+1;
        if(rst_n && measuring && dut.scanner.count==306)
            for(k=0;k<24;k=k+1)
                if(selected[k] && sample_b[k]<0 &&
                   dut.scanner.row_index==(k/6)*2+1 &&
                   !dut.scanner.col_sync[k%6])
                    sample_b[k]=cycle;
        #1;
        if(rst_n && measuring) begin
            for(k=0;k<24;k=k+1) if(selected[k]) begin
                if(frame_b[k]<0 && dut.scan_valid &&
                   dut.contact_raw[((k/6)*2+1)*6+k%6])
                    frame_b[k]=cycle;
                if(qualified[k]<0 && state[k]) qualified[k]=cycle;
            end
            if(valid && kind==1) begin
                if(note<60 || note>=84 || !selected[note-60] || emitted[note-60]>=0)
                    $fatal(1,"Unexpected or duplicate NOTE_ON");
                emitted[note-60]=cycle;
                seen=seen+1;
            end
        end
    end
    task close_contacts(input integer is_b, input integer pressed);
        integer j,idx;
        begin
            for(j=0;j<24;j=j+1) if(selected[j]) begin
                idx=((j/6)*2+is_b)*6+j%6;
                contacts[idx]=pressed;
            end
        end
    endtask
    initial begin
        if(!$value$plusargs("mask=%d",mask_arg)) mask_arg=1;
        if(!$value$plusargs("phase=%d",phase_arg)) phase_arg=0;
        if(!$value$plusargs("bounce=%d",bounce_arg)) bounce_arg=0;
        selected=mask_arg;
        for(k=0;k<24;k=k+1) begin
            sample_b[k]=-1;frame_b[k]=-1;qualified[k]=-1;emitted[k]=-1;
            if(selected[k]) expected=expected+1;
        end
        repeat(5) @(negedge clk);
        rst_n=1;
        close_contacts(0,1);
        // Qualify A in advance, so this test isolates stable B response.
        repeat(20) begin @(posedge dut.scan_valid);@(negedge clk);end
        repeat(phase_arg) @(negedge clk);
        b_cycle=cycle;
        measuring=1;
        close_contacts(1,1);
        if(bounce_arg>0) begin
            // Interrupt a partially accumulated B qualification for one frame.
            repeat(bounce_arg*2456) @(negedge clk);
            close_contacts(1,0);
            repeat(2456) @(negedge clk);
            close_contacts(1,1);
        end
        wait(seen==expected);
        @(negedge clk);
        for(k=0;k<24;k=k+1) if(selected[k]) begin
            if(sample_b[k]<0 || frame_b[k]<0 || qualified[k]<0)
                $fatal(1,"Missing timing marker");
            if(bounce_arg==0 && qualified[k]-frame_b[k]!=14*2456+1)
                $fatal(1,"Unexpected consecutive-frame qualification count: %0d",
                    qualified[k]-frame_b[k]);
            $display("KEY,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d,%0d",
                mask_arg,phase_arg,bounce_arg,k+1,b_cycle,sample_b[k],
                frame_b[k],qualified[k],emitted[k],velocity);
        end
        $display("PASS keyboard timing");
        $finish;
    end
    initial begin
        repeat(150000) @(negedge clk);
        $fatal(1,"Keyboard timing timeout");
    end
endmodule
