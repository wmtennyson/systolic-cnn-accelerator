module corelet #(
	parameter bw = 4,
	parameter psum_bw = 16,
	parameter row = 8,
	parameter col = 8
) (
	input wire clk, reset,
	input wire [bw-1:0] fifo_w_din [row],
	input wire fifo_w_wr,
	input wire [bw-1:0] fifo_n_din [col],
	input wire fifo_n_wr,
	output wire [psum_bw-1:0] fifo_s_dout [col],
	input wire fifo_s_rd,
	input wire exec, drain
);

	/* 
	The mac tiles do not take in instruction aside from the
	drain signal and reset. They are always multiplying the
	inputs and accumulating.
	When exec is low the reads for the north and west fifos are
	low, and the fifos are designed to output zero when not
	being read. This ensures the fifos multipltication equals
	zero, and the psum is not accumulated.
	When exec is high, this module should shift ones to the read 
	signals down the rows and column, beginning execution, and 
	should shift zeros when exec goes low.
	Then, when the drain signal is asserted, the mac tiles will
	shift in the north psum and shift out the south psum, which
	can be written to the output fifos, with sfu operation 
	happening afterwards.
	*/

endmodule