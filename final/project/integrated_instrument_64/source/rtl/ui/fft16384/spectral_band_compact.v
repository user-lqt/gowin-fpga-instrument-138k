module spectral_band_compact(input wire clk,input wire [12:0] address,
 output reg [5:0] value);
 function [5:0] band;input [12:0] k;begin
 if(k<13'd305) begin
  if(k<13'd65) begin
   if(k<13'd30) begin
    if(k<13'd20) begin
     if(k<13'd17) begin
      if(k<13'd15) begin
       band=6'd0;
      end else begin
       band=6'd1;
      end
     end else begin
      if(k<13'd18) begin
       band=6'd2;
      end else begin
       band=6'd3;
      end
     end
    end else begin
     if(k<13'd24) begin
      if(k<13'd22) begin
       band=6'd4;
      end else begin
       band=6'd5;
      end
     end else begin
      if(k<13'd27) begin
       band=6'd6;
      end else begin
       band=6'd7;
      end
     end
    end
   end else begin
    if(k<13'd44) begin
     if(k<13'd36) begin
      if(k<13'd33) begin
       band=6'd8;
      end else begin
       band=6'd9;
      end
     end else begin
      if(k<13'd40) begin
       band=6'd10;
      end else begin
       band=6'd11;
      end
     end
    end else begin
     if(k<13'd53) begin
      if(k<13'd48) begin
       band=6'd12;
      end else begin
       band=6'd13;
      end
     end else begin
      if(k<13'd59) begin
       band=6'd14;
      end else begin
       band=6'd15;
      end
     end
    end
   end
  end else begin
   if(k<13'd140) begin
    if(k<13'd95) begin
     if(k<13'd78) begin
      if(k<13'd71) begin
       band=6'd16;
      end else begin
       band=6'd17;
      end
     end else begin
      if(k<13'd86) begin
       band=6'd18;
      end else begin
       band=6'd19;
      end
     end
    end else begin
     if(k<13'd116) begin
      if(k<13'd105) begin
       band=6'd20;
      end else begin
       band=6'd21;
      end
     end else begin
      if(k<13'd127) begin
       band=6'd22;
      end else begin
       band=6'd23;
      end
     end
    end
   end else begin
    if(k<13'd207) begin
     if(k<13'd170) begin
      if(k<13'd155) begin
       band=6'd24;
      end else begin
       band=6'd25;
      end
     end else begin
      if(k<13'd188) begin
       band=6'd26;
      end else begin
       band=6'd27;
      end
     end
    end else begin
     if(k<13'd251) begin
      if(k<13'd228) begin
       band=6'd28;
      end else begin
       band=6'd29;
      end
     end else begin
      if(k<13'd277) begin
       band=6'd30;
      end else begin
       band=6'd31;
      end
     end
    end
   end
  end
 end else begin
  if(k<13'd1444) begin
   if(k<13'd664) begin
    if(k<13'd450) begin
     if(k<13'd371) begin
      if(k<13'd336) begin
       band=6'd32;
      end else begin
       band=6'd33;
      end
     end else begin
      if(k<13'd409) begin
       band=6'd34;
      end else begin
       band=6'd35;
      end
     end
    end else begin
     if(k<13'd547) begin
      if(k<13'd496) begin
       band=6'd36;
      end else begin
       band=6'd37;
      end
     end else begin
      if(k<13'd602) begin
       band=6'd38;
      end else begin
       band=6'd39;
      end
     end
    end
   end else begin
    if(k<13'd979) begin
     if(k<13'd806) begin
      if(k<13'd732) begin
       band=6'd40;
      end else begin
       band=6'd41;
      end
     end else begin
      if(k<13'd888) begin
       band=6'd42;
      end else begin
       band=6'd43;
      end
     end
    end else begin
     if(k<13'd1189) begin
      if(k<13'd1079) begin
       band=6'd44;
      end else begin
       band=6'd45;
      end
     end else begin
      if(k<13'd1310) begin
       band=6'd46;
      end else begin
       band=6'd47;
      end
     end
    end
   end
  end else begin
   if(k<13'd3139) begin
    if(k<13'd2129) begin
     if(k<13'd1753) begin
      if(k<13'd1591) begin
       band=6'd48;
      end else begin
       band=6'd49;
      end
     end else begin
      if(k<13'd1932) begin
       band=6'd50;
      end else begin
       band=6'd51;
      end
     end
    end else begin
     if(k<13'd2585) begin
      if(k<13'd2346) begin
       band=6'd52;
      end else begin
       band=6'd53;
      end
     end else begin
      if(k<13'd2849) begin
       band=6'd54;
      end else begin
       band=6'd55;
      end
     end
    end
   end else begin
    if(k<13'd4629) begin
     if(k<13'd3812) begin
      if(k<13'd3459) begin
       band=6'd56;
      end else begin
       band=6'd57;
      end
     end else begin
      if(k<13'd4201) begin
       band=6'd58;
      end else begin
       band=6'd59;
      end
     end
    end else begin
     if(k<13'd5622) begin
      if(k<13'd5101) begin
       band=6'd60;
      end else begin
       band=6'd61;
      end
     end else begin
      if(k<13'd6195) begin
       band=6'd62;
      end else begin
       band=6'd63;
      end
     end
    end
   end
  end
 end
 end endfunction
 always @(posedge clk) value<=band(address);
endmodule
