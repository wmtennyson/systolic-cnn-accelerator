// Corelet is just core w/o srams
// Control bits are decoded from inst in core.v and passed in individually.
module corelet #(
  parameter bw      = 4,
  parameter psum_bw = 16,
  parameter col     = 8,
  parameter row     = 8
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

  // Data
  input  logic [row*bw-1:0]      l0_in,      // xmem read data
  input  logic [col*psum_bw-1:0] sfu_in,     // pmem read data
  output logic [col*psum_bw-1:0] ofifo_out,  // -> pmem write data
  output logic                   ofifo_valid,
  output logic [col*psum_bw-1:0] sfp_out
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
    .in_n   (128'b0),
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

  sfu #(.col(col), .psum_bw(psum_bw)) 
  sfu_inst (
    .clk   (clk),
    .reset (reset),
    .acc   (acc),
    .in    (sfu_in),
    .out   (sfp_out)
  );

endmodule
