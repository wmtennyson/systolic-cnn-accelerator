// core + on-chip controller (alpha_ctrl, stages 2-3).
//
// Wraps the unchanged core (corelet + xmem + pmem) and drives its inst / reset from ctrl.sv
// while a layer runs. While the controller is idle the external inst passes straight
// through, so the testbench preloads the SRAMs (and old-style manual sequences still work)
// exactly as before. core's reset = external reset OR the controller's per-kij reset.
//
// Stage-2 placement only: the controller sits outside corelet here so that no existing file
// changes, will move into corelet later so quartus can account for it
module core_ctrl #(
  parameter bw        = 4,
  parameter psum_bw   = 16,
  parameter col       = 8,
  parameter row       = 8,
  parameter num       = 2048,
  parameter SPARSE_NM = 0,
  parameter CTRL_OPT  = 0  // ctrl.sv cycle-saving options (bit mask, see ctrl.sv); 0 = baseline sequence
) (
  input  logic clk,
  input  logic reset,

  // manual interface (same as core)
  input  logic [33:0]           inst,
  input  logic [bw*row-1:0]     D_xmem,
  output logic                  ofifo_valid,
  output logic [col*psum_bw-1:0] sfp_out,

  // controller
  input  logic        start,
  input  logic [1:0]  cfg_k,
  input  logic [6:0]  cfg_h,
  input  logic [6:0]  cfg_w,
  input  logic [3:0]  cfg_n_it,
  input  logic [3:0]  cfg_n_ot,
  input  logic [10:0] cfg_x_base,
  input  logic [10:0] cfg_w_base,
  input  logic [10:0] cfg_psum_base,
  input  logic [10:0] cfg_out_base,
  output logic        busy,
  output logic        done
);

  logic [33:0] ctrl_inst;
  logic        ctrl_inst_valid;
  logic        ctrl_rst;
  logic        ctrl_arr_clr; // C7 array-only clear

  ctrl #(.col(col), .row(row), .OPT(CTRL_OPT)) ctrl_inst_u (
    .clk           (clk),
    .reset         (reset),
    .start         (start),
    .cfg_k         (cfg_k),
    .cfg_h         (cfg_h),
    .cfg_w         (cfg_w),
    .cfg_n_it      (cfg_n_it),
    .cfg_n_ot      (cfg_n_ot),
    .cfg_x_base    (cfg_x_base),
    .cfg_w_base    (cfg_w_base),
    .cfg_psum_base (cfg_psum_base),
    .cfg_out_base  (cfg_out_base),
    .busy          (busy),
    .done          (done),
    .inst_valid    (ctrl_inst_valid),
    .inst          (ctrl_inst),
    .core_rst      (ctrl_rst),
    .arr_clr       (ctrl_arr_clr)
  );

  core #(
    .bw        (bw),
    .psum_bw   (psum_bw),
    .col       (col),
    .row       (row),
    .num       (num),
    .SPARSE_NM (SPARSE_NM)
  ) core_instance (
    .clk         (clk),
    .reset       (reset | ctrl_rst),
    .arr_clr     (ctrl_arr_clr),
    .inst        (ctrl_inst_valid ? ctrl_inst : inst),
    .D_xmem      (D_xmem),
    .ofifo_valid (ofifo_valid),
    .sfp_out     (sfp_out)
  );

endmodule
