function integer digit_base;
input integer scale;
begin case(scale)
2:digit_base=1;
3:digit_base=41;
5:digit_base=131;
default:digit_base=0;
endcase end
endfunction
function integer label_index;
input integer slot,variant,row,col;
begin case(slot)
0:label_index=0+variant*36+row*12+col;
4:label_index=180+variant*24+row*8+col;
5:label_index=252+variant*15+row*5+col;
1:label_index=282+variant*27+row*9+col;
13:label_index=363+variant*12+row*6+col;
2:label_index=387+variant*36+row*12+col;
3:label_index=459+variant*27+row*9+col;
8:label_index=567+variant*39+row*13+col;
7:label_index=684+variant*30+row*10+col;
12:label_index=774+variant*39+row*13+col;
9:label_index=852+variant*36+row*12+col;
6:label_index=924+variant*30+row*10+col;
default:label_index=0;
endcase end
endfunction
