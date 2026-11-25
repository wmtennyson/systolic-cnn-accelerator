// SFU performing accumulate + ReLU
//
// Sits between the pmem read port and the core output (sfp_out).
// Each cycle `acc` is high, take pmem read data and split across columns
// add each slice into its columns accumulator
// ReLU each accumulator and pack result

module sfu #(
  parameter col = 8,
  parameter psum_bw = 16
) (
  input logic clk,
  input logic reset,
  input logic acc,  // accumulate enable from inst[33] in tb
  input logic [col*psum_bw-1:0] in, // pmem read data
  output logic [col*psum_bw-1:0] out
);


  // signed accumulators for each column
  logic signed [psum_bw-1:0] acc_reg [col];

  always @(posedge clk) begin
    if (reset) begin
      for (int i = 0; i < col; i++)
        acc_reg[i] <= '0;
    end else if (acc) begin
        for (int i = 0; i < col; i++) begin
            acc_reg[i] <= acc_reg[i] + $signed(in[i*psum_bw +: psum_bw]);
        end
    end
  end


  // ReLU each column and pack into out
  always @(*) begin
    for (int i = 0; i < col; i++) begin
      if (acc_reg[i] < 0)
        out[i*psum_bw +: psum_bw] = '0;
      else
        out[i*psum_bw +: psum_bw] = acc_reg[i];
    end
  end


endmodule
