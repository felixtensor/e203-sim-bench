// Two byte lanes write disjoint parts of the same unpacked array.
module masked_ram(input clk, input [1:0] wen, input [1:0] addr,
                  input [15:0] din, output [15:0] dout);
  reg [15:0] mem [0:3];
  always @(posedge clk)
    if (wen[0]) mem[addr][7:0] <= din[7:0];
  always @(posedge clk)
    if (wen[1]) mem[addr][15:8] <= din[15:8];
  assign dout = mem[addr];
endmodule
