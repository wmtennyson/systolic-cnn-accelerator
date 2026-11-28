// Corelet is just core w/o srams
// Control bits are decoded from inst in core.v and passed in individually.
module corelet #(
  parameter bw      = 4,
  parameter psum_bw = 16,
  parameter col     = 8,
  parameter row     = 8
) (
  input  logic                  clk,
  input  logic                  reset,
  input  logic                  mode_os,    // 0 = WS, 1 = OS

  // Control
  input  logic [1:0]            array_inst, // inst[1:0]
  input  logic                  l0_wr,      // inst[2]
  input  logic                  l0_rd,      // inst[3]
  input  logic                  weight_rd,  // inst[4]
  input  logic                  weight_wr,  // inst[5]
  input  logic                  ofifo_rd,   // inst[6]
  input  logic                  acc,        // inst[33]

  // Data
  input  logic [row*bw-1:0]      l0_in,      // xmem read data (WS: wgt/act, OS: act)
  input  logic [col*bw-1:0]      weight_in,  // xmem read data (OS: north weights)
  input  logic [col*psum_bw-1:0] sfu_in,     // pmem read data
  output logic [col*psum_bw-1:0] ofifo_out,  // -> pmem write data
  output logic                   ofifo_valid,
  output logic [col*psum_bw-1:0] sfp_out
);

  // Internal wires
  logic [row*bw-1:0]      l0_out;
  logic [col*bw-1:0]      weight_out;
  logic [col*psum_bw-1:0] array_out;
  logic [col-1:0]         array_valid;

  // West Inst. and Input Buffer
  l0 #(.row(row), .bw(bw))
  l0_inst (
    .clk     (clk),
    .reset   (reset),
    .in      (l0_in),
    .out     (l0_out),
    .rd      (l0_rd),
    .wr      (l0_wr),
    .o_full  (),
    .o_ready ()
  );

  // North weight buffer (used in OS mode)
  l0 #(.row(col), .bw(bw))
  weight_buffer_inst (
    .clk     (clk),
    .reset   (reset),
    .in      (weight_in),
    .out     (weight_out),
    .rd      (weight_rd),
    .wr      (weight_wr),
    .o_full  (),
    .o_ready ()
  );

  mac_array #(.bw(bw), .psum_bw(psum_bw), .col(col), .row(row))
  mac_array_inst (
    .clk        (clk),
    .reset      (reset),
    .mode_os    (mode_os),
    .in_w       (l0_out),
    .in_n       (weight_out),
    .inst_w     (array_inst),
    .out_s      (),
    .out_psum_s (array_out),
    .valid      (array_valid)
  );

  ofifo #(.col(col), .bw(psum_bw))
  ofifo_inst (
    .clk     (clk),
    .reset   (reset),
    .in      (array_out),
    .out     (ofifo_out),
    .rd      (ofifo_rd),
    .wr      (array_valid),
    .o_full  (),
    .o_ready (),
    .o_valid (ofifo_valid)
  );

  sfu #(.col(col), .psum_bw(psum_bw))
  sfu_inst (
    .clk   (clk),
    .reset (reset),
    .acc   (acc),
    .in    (sfu_in),
    .out   (sfp_out)
  );

endmodule
