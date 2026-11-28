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

  // one gated clock per block (l0, mac_array, ofifo, sfu).
  // Each gate is a latch to avoid glitching + AND: en is latched while clk is low and frozen while clk is
  // high, so gclk = clk & en_l can never glitch or make an extra edge. A plain
  // AND would glitch when en changes right after a posedge (e.g. array_valid).
  // Every enable includes reset because all resets in the design are synchronous.
  // Everything in this section runs on the free-running clk.
  localparam ARRAY_DRAIN = row + col + 2; // cycles for the last load/execute wavefront to leave the array
  localparam L0_DRAIN    = row;           // cycles for l0's internal rd_en shift register to empty

  logic [4:0] array_cnt;   // array drain counter (ARRAY_DRAIN <= 31)
  logic [3:0] l0_cnt;      // l0 drain counter    (L0_DRAIN    <= 15)
  logic       ofifo_rd_q;  // copy of ofifo's internal rd_en (rd delayed 1 cycle)

  always_ff @(posedge clk) begin
    if (reset) begin
      array_cnt  <= '0;
      l0_cnt     <= '0;
      ofifo_rd_q <= 1'b0;
    end else begin
      array_cnt  <= (load | execute) ? ARRAY_DRAIN[4:0] : (array_cnt != 0 ? array_cnt - 1'b1 : '0);
      l0_cnt     <= l0_rd            ? L0_DRAIN[3:0]    : (l0_cnt    != 0 ? l0_cnt    - 1'b1 : '0);
      ofifo_rd_q <= ofifo_rd;
    end
  end

  logic en_l0, en_array, en_ofifo, en_sfu;
  assign en_l0    = reset | l0_wr | l0_rd | (l0_cnt != 0);
  assign en_array = reset | load | execute | (array_cnt != 0);
  assign en_ofifo = reset | (|array_valid) | ofifo_rd | ofifo_rd_q;
  assign en_sfu   = reset | acc;

  logic en_l0_l, en_array_l, en_ofifo_l, en_sfu_l;
  always_latch begin
    if (!clk) begin
      en_l0_l    = en_l0;
      en_array_l = en_array;
      en_ofifo_l = en_ofifo;
      en_sfu_l   = en_sfu;
    end
  end

  logic gclk_l0, gclk_array, gclk_ofifo, gclk_sfu;
  assign gclk_l0    = clk & en_l0_l;
  assign gclk_array = clk & en_array_l;
  assign gclk_ofifo = clk & en_ofifo_l;
  assign gclk_sfu   = clk & en_sfu_l;

  l0 #(.row(row), .bw(bw))
  l0_inst (
    // .clk     (clk),
    .clk     (gclk_l0), 
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
    // .clk    (clk), 
    .clk    (gclk_array),
    .reset  (reset),
    .in_w   (l0_out),
    .in_n   (128'b0),
    .inst_w ({execute, load}),
    .out_s  (array_out),
    .valid  (array_valid)
  );

  ofifo #(.col(col), .bw(psum_bw)) 
  ofifo_inst (
    // .clk     (clk), 
    .clk     (gclk_ofifo), 
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
    // .clk   (clk),
    .clk   (gclk_sfu), 
    .reset (reset),
    .acc   (acc),
    .in    (sfu_in),
    .out   (sfp_out)
  );

endmodule
