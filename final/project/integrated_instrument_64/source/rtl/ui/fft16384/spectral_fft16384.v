// MIT r22sdf configuration. 1/N scaling; bit-reversed output order.
module spectral_fft16384(input wire clock,reset,di_en,
 input wire [15:0] di_re,di_im,
 output wire do_en,output wire [15:0] do_re,do_im);
 wire [7:0] enable;wire [15:0] re[0:7],im[0:7];
 assign enable[0]=di_en;assign re[0]=di_re;assign im[0]=di_im;
 genvar s;
 generate for(s=0;s<7;s=s+1) begin:stages
 SdfUnit #(.N(16384),.M(16384>>(2*s)),.WIDTH(16),.LP(1)) u_stage(
 .clock(clock),.reset(reset),.di_en(enable[s]),.di_re(re[s]),.di_im(im[s]),
 .do_en(enable[s+1]),.do_re(re[s+1]),.do_im(im[s+1]));
 end endgenerate
 assign do_en=enable[7];assign do_re=re[7];assign do_im=im[7];
endmodule
