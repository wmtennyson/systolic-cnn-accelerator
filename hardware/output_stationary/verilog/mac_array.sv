module mac_array #(
	parameter bw = 4,
	parameter psum_bw = 16,
	parameter col = 8,
	parameter row = 8
) (
	input wire 								clk, reset,
	input wire [bw-1:0] 			data_w [row],
	input wire [bw-1:0] 			data_n [col],
	output wire [psum_bw-1:0] data_s [col],
	input wire 								drain,
	output logic							drain_s // for ofifos
);

	wire [bw-1:0] bus_west_east [row][col+1];
	// The additional column is unused and should be removed by synthesis tool
	wire [psum_bw-1:0] bus_north_south [row+1][col];
	

	for (genvar r = 0; r < row; r++) begin : row_num
		for (genvar c = 0; c < col; c++) begin : col_num
			if (r == 0) begin
				assign bus_north_south[r][c] = drain == 1'b1 ?
					'0 :
					{{(psum_bw-bw){1'b0}}, data_n[c]};
			end
			if (c == 0) begin
				assign bus_west_east[r][c] = data_w[r];
			end
			mac_tile #(
				.bw(bw),
				.psum_bw(psum_bw)
			) mac_tile_instance (
				.clk(clk), .reset(reset),
				.data_w(bus_west_east[r][c]),
				.data_e(bus_west_east[r][c+1]),
				.data_n(bus_north_south[r][c]),
				.data_s(bus_north_south[r+1][c]),
				.drain(drain)
			);
		end
	end

	always_ff @( clk ) begin
			if ( reset ) begin
				drain_s <= 1'b0;
			end
			else begin
				drain_s <= drain;
			end
	end

endmodule