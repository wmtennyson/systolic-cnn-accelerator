// Corelet is just core w/o srams
// Control bits are decoded from inst in core.v and passed in individually.
module corelet #(
  parameter bw      = 4,
  parameter psum_bw = 16,
  parameter col     = 8,
  parameter row     = 8,
  parameter SPARSE_NM = 0  // 0 is baseline, 1 is 2:4 pruned
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

  // Dense vs 2:4 sizes. 2:4: groups of 4 input channels, 2 kept weights (= 2 array rows) per group.
  localparam arr_row = SPARSE_NM ? row/2 : row;  // array rows
  localparam abw     = SPARSE_NM ? 4*bw  : bw;   // west->east bus per row (2:4: one group's 4 activations)
  localparam l0_row  = SPARSE_NM ? row/4 : row;  // L0 FIFOs (2:4: one per group)
  localparam l0_skew = SPARSE_NM ? 2     : 1;    // cycles between FIFOs (= array rows per FIFO)

  // Internal wires
  logic [l0_row*abw-1:0] l0_out;
  logic [arr_row*abw-1:0] array_in;  // L0 -> array west inputs
  logic [col*psum_bw-1:0] array_out;
  logic [col-1:0] array_valid; 

  l0 #(.row(l0_row), .bw(abw), .skew(l0_skew)) 
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

  // L0 -> array. Dense: one FIFO per row. 2:4: group g's FIFO feeds row 2g directly and
  // row 2g+1 through a 1-cycle register, matching the array's 1-cycle-per-row instruction delay.
  genvar g;
  generate
    if (SPARSE_NM) begin : gen_sparse_in
      for (g = 0; g < l0_row; g = g + 1) begin : grp
        logic [abw-1:0] dly_q;
        always_ff @(posedge clk) begin
         if (reset) dly_q <= '0;
          else       dly_q <= l0_out[g*abw +: abw];
        end
        assign array_in[(2*g)  *abw +: abw] = l0_out[g*abw +: abw];  // even row: FIFO g
        assign array_in[(2*g+1)*abw +: abw] = dly_q; // odd row: FIFO g, 1 cycle later
      end
    end else begin : gen_dense_in
      assign array_in = l0_out;
    end
  endgenerate


  mac_array #(.bw(bw), .psum_bw(psum_bw), .col(col), .row(arr_row), .abw(abw), .SPARSE_NM(SPARSE_NM)) 
  mac_array_inst (
    .clk    (clk),
    .reset  (reset),
    .in_w   (array_in),
    .in_n   ('0),
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
