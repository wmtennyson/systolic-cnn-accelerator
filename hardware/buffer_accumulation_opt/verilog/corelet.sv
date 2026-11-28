// Corelet is just core w/o srams
// Control bits are decoded from inst in core.v and passed in individually.
module corelet #(
  parameter bw       = 4,
  parameter psum_bw  = 16,
  parameter col      = 8,
  parameter row      = 8,
  parameter len_onij = 16
) (
  input  logic clk,
  input  logic reset,

  // Control
  input  logic load,       // inst[0]
  input  logic execute,    // inst[1]
  input  logic l0_wr,      // inst[2]
  input  logic l0_rd,      // inst[3]
  input  logic ofifo_rd,   // inst[6]
  input  logic acc,        // inst[33]

  // Online accumulation control
  input  logic first_kij,
  input  logic relu_en,
  input  logic [$clog2(len_onij)-1:0] pixel_addr,

  // Data
  input  logic [row*bw-1:0] l0_in,          // xmem read data
  output logic [col*psum_bw-1:0] ofifo_out, // -> SFU input
  output logic                   ofifo_valid,
  output logic [col*psum_bw-1:0] sfp_out   // -> pmem write data
);

  // Internal wires
  logic [row*bw-1:0] l0_out;
  logic [col*psum_bw-1:0] array_out;
  logic [col-1:0] array_valid;

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

  mac_array #(.bw(bw), .psum_bw(psum_bw), .col(col), .row(row))
  mac_array_inst (
    .clk    (clk),
    .reset  (reset),
    .in_w   (l0_out),
    .in_n   ({col*psum_bw{1'b0}}),
    .inst_w ({execute, load}),
    .out_s  (array_out),
    .valid  (array_valid)
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

  // Online partial-sum accumulation and ReLU
  sfu #(
    .col      (col),
    .psum_bw  (psum_bw),
    .len_onij (len_onij)
  )
  sfu_inst (
    .clk        (clk),
    .acc        (acc),
    .first_kij  (first_kij),
    .relu_en    (relu_en),
    .pixel_addr (pixel_addr),
    .in         (ofifo_out),
    .out        (sfp_out)
  );

endmodule