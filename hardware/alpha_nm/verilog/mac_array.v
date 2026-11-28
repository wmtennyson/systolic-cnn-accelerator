// Created by prof. Mingu Kang @VVIP Lab in UCSD ECE department
// Please do not spread this code without permission 
module mac_array (clk, reset, out_s, in_w, in_n, inst_w, valid);

  parameter bw = 4;
  parameter psum_bw = 16;
  parameter col = 8;
  parameter row = 8;
  parameter abw = bw;
  parameter SPARSE_NM = 0;

  input  clk, reset;
  output [psum_bw*col-1:0] out_s;
  input  [row*abw-1:0] in_w; // inst[1]:execute, inst[0]: kernel loading
  input  [1:0] inst_w;
  input  [psum_bw*col-1:0] in_n;
  output [col-1:0] valid;


  reg    [2*row-1:0] inst_w_temp;
  wire   [psum_bw*col*(row+1)-1:0] temp;
  wire   [row*col-1:0] valid_temp;


  genvar i;
 
  // take bottom rows psums without hardcoding to 8 rows
  assign out_s = temp[psum_bw*col*(row+1)-1:psum_bw*col*row];
  assign temp[psum_bw*col*1-1:psum_bw*col*0] = 0;
  // Updated to use row instead of hardcoding 8 to work for any row count
  assign valid = valid_temp[row*col-1:(row-1)*col];
  generate
  for (i=1; i < row+1 ; i=i+1) begin : row_num
      mac_row #(.bw(bw), .psum_bw(psum_bw), .col(col), .abw(abw),
      .SPARSE_NM(SPARSE_NM), .W_SLOT((i-1) % 2)) mac_row_instance (
         .clk(clk),
         .reset(reset),
	 .in_w(in_w[abw*i-1:abw*(i-1)]),
	 .inst_w(inst_w_temp[2*i-1:2*(i-1)]),
	 .in_n(temp[psum_bw*col*i-1:psum_bw*col*(i-1)]),
         .valid(valid_temp[col*i-1:col*(i-1)]),
	 .out_s(temp[psum_bw*col*(i+1)-1:psum_bw*col*(i)]));
  end
  endgenerate

  integer k;
  always @ (posedge clk) begin
    inst_w_temp[1:0]   <= inst_w; 
    for (k = 1; k < row; k = k + 1)
      inst_w_temp[2*k +: 2] <= inst_w_temp[2*(k-1) +: 2];
  end



endmodule
