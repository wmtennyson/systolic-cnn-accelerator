module mac_tile #(
	parameter bw = 4,
	parameter psum_bw = 16
) (
	input wire 										clk, reset,
	input wire 		[bw-1:0] 				data_w,
	output logic 	[bw-1:0] 				data_e,
	input wire 		[psum_bw-1:0] 	data_n,
	output logic 	[psum_bw-1:0] 	data_s,
	input wire 										drain
);

	logic [psum_bw-1:0] psum_reg;
	wire [psum_bw-1:0] mac_out;

	mac #(
		.bw(bw),
		.psum_bw(psum_bw)
	) mac_instance (
		.a(data_w),
		.b(data_n[bw-1:0]),
		.c(psum_reg),
		.out(mac_out)
	);

	always_ff @( clk ) begin
		if ( reset ) begin
			data_e <= '0;
			data_s <= '0;
			psum_reg <= '0;
		end
		else begin
			data_e <= data_w;
			if ( drain == 1'b1 ) begin
				psum_reg <= data_n;
				data_s <= psum_reg;
			end
			else begin
				psum_reg <= mac_out;
				data_s <= data_n;
			end
		end
	end


endmodule