module pack(input a, input b, output [1:0] pair);
  assign pair = {a, b};
endmodule
module high_bit(input [1:0] pair, output y);
  assign y = pair[1];
endmodule
module packed_loop(input a, output y);
  wire [1:0] pair;
  pack p(.a(a), .b(y), .pair(pair));
  high_bit h(.pair(pair), .y(y));
endmodule
