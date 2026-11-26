// Created by prof. Mingu Kang @VVIP Lab in UCSD ECE department
// Please do not spread this code without permission 
module mac_row (clk, out_s, in_w, in_n, valid, inst_w, reset);

  parameter bw = 4;
  parameter psum_bw = 16;
  parameter col = 8;
  parameter abw = bw;

  input clk, reset;
  output [psum_bw*col-1:0] out_s;
  output [col-1:0] valid;
  input [abw-1:0] in_w;
  input [1:0] inst_w;
  input [psum_bw*col-1:0] in_n;

  wire   [(col+1)*abw-1:0] temp;
  wire   [2*(col+1)-1:0] inst_temp;

  assign temp[abw-1:0] = in_w;
  assign inst_temp[1:0] = inst_w;

  genvar i;
  for (i=1; i < col+1 ; i=i+1) begin : col_num
      mac_tile #(.bw(bw), .psum_bw(psum_bw), .abw(abw)) mac_tile_instance (
         .clk(clk),
         .reset(reset),
         .in_w(temp[abw*i-1:abw*(i-1)]),
         .out_e(temp[abw*(i+1)-1:abw*i]),
         .inst_w(inst_temp[2*i-1:2*(i-1)]),
         .inst_e(inst_temp[2*(i+1)-1:2*i]),
         .in_n(in_n[psum_bw*i-1:psum_bw*(i-1)]),
         .out_s(out_s[psum_bw*i-1:psum_bw*(i-1)]));

        assign valid[i-1] = inst_temp[2*(i+1)-1];
  end

endmodule
