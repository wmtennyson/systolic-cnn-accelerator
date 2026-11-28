// SFU performing online accumulation + ReLU
//
// Receives partial sums from OFIFO.
// Maintains a running sum for each output pixel and column.
// Initialize each pixel during the first kij.
// Accumulate subsequent kij values into the same registers.
// Optionally apply ReLU and pack result.

module sfu #(
  parameter col = 8,
  parameter psum_bw = 16,
  parameter len_onij = 16
) (
  input logic clk,
  input logic acc,
  input logic first_kij,
  input logic relu_en,
  input logic [$clog2(len_onij)-1:0] pixel_addr,
  input logic [col*psum_bw-1:0] in,
  output logic [col*psum_bw-1:0] out
);

  // Signed accumulators for each output pixel and column
  logic signed [psum_bw-1:0] acc_reg [len_onij][col];

  always @(posedge clk) begin
    if (acc) begin
      for (int i = 0; i < col; i++) begin

        // Initialize running sum during first kernel position
        if (first_kij)
          acc_reg[pixel_addr][i] <=
            $signed(in[i*psum_bw +: psum_bw]);

        // Accumulate subsequent kernel positions
        else
          acc_reg[pixel_addr][i] <=
            acc_reg[pixel_addr][i] +
            $signed(in[i*psum_bw +: psum_bw]);

      end
    end
  end

  // Optionally apply ReLU to selected pixel and pack result
  always @(*) begin
    for (int i = 0; i < col; i++) begin
      if (relu_en && acc_reg[pixel_addr][i] < 0)
        out[i*psum_bw +: psum_bw] = '0;
      else
        out[i*psum_bw +: psum_bw] =
          acc_reg[pixel_addr][i];
    end
  end

endmodule