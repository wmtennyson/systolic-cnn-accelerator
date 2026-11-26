// Created by prof. Mingu Kang @VVIP Lab in UCSD ECE department
// Please do not spread this code without permission 
module l0 (clk, in, out, rd, wr, o_full, reset, o_ready);

  parameter row  = 8;
  parameter bw = 4;
  parameter skew = 1; // default to dense structure

  localparam sr_len = (row-1)*skew + 1;  // FIFO(row-1) starts (row-1)*skew cycles after FIFO 0

  input  clk;
  input  wr;
  input  rd;
  input  reset;
  input  [row*bw-1:0] in;
  output [row*bw-1:0] out;
  output o_full;
  output o_ready;

  wire [row-1:0] empty;
  wire [row-1:0] full;
  wire [row-1:0] rd_en;
  reg  [sr_len-1:0] rd_sr; // bit k of rd_sr delayed by k+1 cycles
  
  genvar i;

  assign o_full  = |full;
  assign o_ready = ~o_full;

  for (i=0; i<row ; i=i+1) begin : row_num
      fifo_depth64 #(.bw(bw)) fifo_instance (
	 .rd_clk(clk),
	 .wr_clk(clk),
	 .rd(rd_en[i]),
	 .wr(wr),
         .o_empty(empty[i]),
         .o_full(full[i]),
	 .in(in[bw*(i+1)-1 : bw*i]),
	 .out(out[bw*(i+1)-1 : bw*i]),
         .reset(reset));
      assign rd_en[i] = rd_sr[i*skew];  // FIFO i starts i*skew cycles after FIFO 0
  end


  always @ (posedge clk) begin
   if (reset) begin
      rd_sr <= {sr_len{1'b0}};
   end
   else

      /////////////// version1: read all row at a time ////////////////
      // when rd=1 all bits of rd_en become 1 together, and when rd=0 they all become 0
      //rd_en <= {row{rd}};
      ///////////////////////////////////////////////////////



      //////////////// version2: read 1 row at a time /////////////////
      rd_sr <= (rd_sr << 1) | rd; // shift rd in at bit 0
      ///////////////////////////////////////////////////////
    end

endmodule
