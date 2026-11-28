module fifo #(
	parameter bw = 4,
	parameter depth = 64
) (
	input wire clk, reset,
	output wire full, empty,
	input wire [bw-1:0] din,
	output wire [bw-1:0] dout,
	input wire rd, wr
);

	logic [bw-1:0] queue [depth];

	localparam fifo_bw = $clog2(depth);

	logic [fifo_bw:0] rdx, wdx;

	assign dout = (empty == 1'b1) || (rd == 1'b0) ? 
		'0 : 
		queue[rdx[fifo_bw-1:0]];

	always_ff @(clk) begin
		if (reset) begin
			rdx <= '0;
			wdx <= '0;
		end
		else begin
			if (rd == 1'b1 && empty == 1'b0) begin
				rdx <= rdx + 1;
			end
			if (wr == 1'b1 && full == 1'b0) begin
				queue[wdx[fifo_bw-1:0]] <= dout;
				wdx <= wdx + 1;
			end
		end
	end

endmodule