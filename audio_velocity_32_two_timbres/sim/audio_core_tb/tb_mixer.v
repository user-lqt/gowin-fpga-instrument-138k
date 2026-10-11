`timescale 1ns/1ps

module tb_mixer;
    reg [95:0] voice_samples = 96'd0;
    reg [15:0] volume = 16'hffff;
    wire signed [23:0] audio;
    wire overload_flag;

    integer checks = 0;
    integer failures = 0;

    mixer dut (
        .voice_samples(voice_samples),
        .volume(volume),
        .audio(audio),
        .overload_flag(overload_flag)
    );

`define CHECK(condition, label)            \
    begin                                    \
        checks = checks + 1;                 \
        if (!(condition)) begin              \
            failures = failures + 1;         \
            $display("[FAIL] %s", label);   \
        end else                             \
            $display("[PASS] %s", label);   \
    end

    task set_samples;
        input signed [23:0] a;
        input signed [23:0] b;
        input signed [23:0] c;
        input signed [23:0] d;
        begin
            voice_samples = {d, c, b, a};
            #1;
        end
    endtask

    initial begin
        #1;
        `CHECK(audio === 24'sd0 && !overload_flag, "silence is numeric zero");

        set_samples(24'sd1000000, 24'sd0, 24'sd0, 24'sd0);
        `CHECK(audio === 24'sd999984 && !overload_flag,
               "single voice preserves sign and volume scaling");

        set_samples(24'sd1000000, 24'sd2000000, 24'sd3000000, 24'sd1000000);
        `CHECK(audio === 24'sd6999893 && !overload_flag,
               "four positive voices sum without clipping");

        set_samples(-24'sd1000000, -24'sd2000000,
                    -24'sd3000000, -24'sd1000000);
        `CHECK(audio === -24'sd6999894 && !overload_flag,
               "four negative voices sum without sign reversal");

        set_samples(24'sd3000000, 24'sd3000000, 24'sd3000000, 24'sd3000000);
        `CHECK(audio === 24'sh7fffff && overload_flag,
               "positive overload saturates instead of wrapping");

        set_samples(-24'sd3000000, -24'sd3000000,
                    -24'sd3000000, -24'sd3000000);
        `CHECK(audio === 24'sh800000 && overload_flag,
               "negative overload saturates instead of wrapping");

        set_samples(24'sd7000000, -24'sd7000000,
                    24'sd7000000, -24'sd7000000);
        `CHECK(audio === 24'sd0 && !overload_flag,
               "opposite phases cancel without overload");

        set_samples(24'sd3000000, 24'sd3000000, 24'sd3000000, 24'sd3000000);
        volume = 16'd32768;
        #1;
        `CHECK(audio === 24'sd6000000 && !overload_flag,
               "half volume prevents clipping");

        volume = 16'd0;
        #1;
        `CHECK(audio === 24'sd0 && !overload_flag,
               "zero volume mutes overload");

        volume = 16'hffff;
        set_samples(24'sh7fffff, 24'sh7fffff,
                    24'sh7fffff, 24'sh7fffff);
        `CHECK(audio === 24'sh7fffff && overload_flag,
               "maximum positive four-voice sum stays saturated");

        set_samples(24'sh800000, 24'sh800000,
                    24'sh800000, 24'sh800000);
        `CHECK(audio === 24'sh800000 && overload_flag,
               "minimum negative four-voice sum stays saturated");

        if (failures == 0)
            $display("MIXER PASS (%0d/%0d)", checks, checks);
        else
            $fatal(1, "MIXER FAIL (%0d failed/%0d)", failures, checks);
        $finish;
    end
endmodule
