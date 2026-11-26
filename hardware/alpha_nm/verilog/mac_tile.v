// Created by prof. Mingu Kang @VVIP Lab in UCSD ECE department
// Please do not spread this code without permission 
module mac_tile (clk, out_s, in_w, out_e, in_n, inst_w, inst_e, reset);

parameter bw = 4;
parameter psum_bw = 16;
parameter abw = bw;
parameter SPARSE_NM = 0; // 0 = dense/baseline, 1 = 2:4 compressed
parameter W_SLOT = 0; // which byte of the 16-bit bus holds this row's {idx, w} (row % 2)

localparam idx_bw  = 2; // index into a group of 4 activations
localparam slot_bw = 8; // one weight entry on the bus {2'b00, idx, w}

output [psum_bw-1:0] out_s;
input [abw-1:0] in_w;
output [abw-1:0] out_e;
input [1:0] inst_w;
output [1:0] inst_e;
input [psum_bw-1:0] in_n;
input clk;
input reset;

reg [1:0] inst_q;
reg [abw-1:0] a_q;
reg [bw-1:0] b_q;
reg [idx_bw-1:0] idx_q;
reg [psum_bw-1:0] c_q;
reg load_ready_q;
wire [psum_bw-1:0] mac_out;

wire [bw-1:0] w_in; // weight to latch on load
wire [idx_bw-1:0] idx_in; // index to latch on load
wire [bw-1:0] a_sel; // activation into the mac

assign out_e = a_q;
assign inst_e = inst_q;
assign out_s = mac_out;

generate
  if (SPARSE_NM) begin : gen_sparse
    // In Load phase take this row's byte of the bus, in Execute pick activation idx_q of the group.
    assign w_in   = in_w[slot_bw*W_SLOT +: bw];
    assign idx_in = in_w[slot_bw*W_SLOT + bw +: idx_bw];
    assign a_sel  = a_q[idx_q*bw +: bw];
  end else begin : gen_dense
    // slices from baseline/dense impl
    assign w_in   = in_w[bw-1:0];
    assign idx_in = {idx_bw{1'b0}};
    assign a_sel  = a_q[bw-1:0];
  end
endgenerate

mac #(.bw(bw), .psum_bw(psum_bw)) mac_instance (
      .a(a_sel), .b(b_q), .c(c_q), .out(mac_out));

always @ (posedge clk) begin
  if (reset) begin
    inst_q <= 2'b00;
    load_ready_q <= 1'b1;
    a_q <= 0;
    b_q <= 0;
    c_q <= 0;
    idx_q <= 0;
  end
  else begin
    inst_q[1] <= inst_w[1];
    c_q <= in_n;
    if (inst_w[0] | inst_w[1])
      a_q <= in_w;
    if (inst_w[0] & load_ready_q) begin
      b_q <= w_in;
      idx_q <= idx_in; // weight and index always latched together
      load_ready_q <= 1'b0;
    end
    if (load_ready_q == 1'b0)
      inst_q[0] <= inst_w[0];
  end
end

endmodule
