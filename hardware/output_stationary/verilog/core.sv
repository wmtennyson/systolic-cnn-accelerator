module core #(
    parameter bw      = 4,
    parameter psum_bw = 16,
    parameter col     = 8,
    parameter row     = 8,
    parameter num     = 2048
) (
    input  logic clk,
    input  logic reset,

    // Mode & Control Inputs
    input  logic                   mode_os,  // 0 = WS, 1 = OS
    input  logic                   sfu_wb,   // 0 = write OFIFO to pmem, 1 = write SFU to pmem
    input  logic [33:0]            inst,
    input  logic [bw*row-1:0]      D_xmem,

    // Outputs
    output logic                   ofifo_valid,
    output logic [col*psum_bw-1:0] sfp_out
);

    // Control Wires
    logic [1:0]  array_inst; // inst[1:0] (WS: {execute, load}, OS: HOLD/CLEAR/ACC/DRAIN)
    logic        l0_wr;      // inst[2]
    logic        l0_rd;      // inst[3]
    logic        weight_rd;  // inst[4]   (maps to ififo_rd in core_tb)
    logic        weight_wr;  // inst[5]   (maps to ififo_wr in core_tb)
    logic        ofifo_rd;   // inst[6]

    logic [10:0] xmem_addr;  // inst[17:7]
    logic        xmem_wen;   // inst[18]
    logic        xmem_cen;   // inst[19]

    logic [10:0] pmem_addr;  // inst[30:20]
    logic        pmem_wen;   // inst[31]
    logic        pmem_cen;   // inst[32]

    logic        acc;        // inst[33]

    // Data Wires
    logic [bw*row-1:0]      xmem_q;
    logic [col*psum_bw-1:0] pmem_d;
    logic [col*psum_bw-1:0] pmem_q;
    logic [col*psum_bw-1:0] ofifo_data;

    // Control Assignments
    assign array_inst = inst[1:0];
    assign l0_wr      = inst[2];
    assign l0_rd      = inst[3];
    assign weight_rd  = inst[4];
    assign weight_wr  = inst[5];
    assign ofifo_rd   = inst[6];

    assign xmem_addr  = inst[17:7];
    assign xmem_wen   = inst[18];
    assign xmem_cen   = inst[19];

    assign pmem_addr  = inst[30:20];
    assign pmem_wen   = inst[31];
    assign pmem_cen   = inst[32];

    assign acc        = inst[33];

    // Activation & Weight SRAM
    sram_w2048 #(
        .num    (num),
        .width  (row*bw)
    ) xmem_inst (
        .CLK    (clk),
        .WEN    (xmem_wen),
        .CEN    (xmem_cen),
        .D      (D_xmem),
        .A      (xmem_addr),
        .Q      (xmem_q)
    );

    // Psum SRAM
    sram_w2048 #(
        .num    (num),
        .width  (col*psum_bw)
    ) pmem_inst (
        .CLK    (clk),
        .WEN    (pmem_wen),
        .CEN    (pmem_cen),
        .D      (pmem_d),
        .A      (pmem_addr),
        .Q      (pmem_q)
    );

    // Reconfigurable WS/OS Corelet
    corelet #(
        .bw             (bw),
        .psum_bw        (psum_bw),
        .col            (col),
        .row            (row)
    ) corelet_inst (
        .clk            (clk),
        .reset          (reset),
        .mode_os        (mode_os),

        .array_inst     (array_inst),
        .l0_wr          (l0_wr),
        .l0_rd          (l0_rd),
        .weight_rd      (weight_rd),
        .weight_wr      (weight_wr),
        .ofifo_rd       (ofifo_rd),
        .acc            (acc),

        .l0_in          (xmem_q),
        .weight_in      (xmem_q),
        .sfu_in         (pmem_q),
        .ofifo_out      (ofifo_data),
        .ofifo_valid    (ofifo_valid),
        .sfp_out        (sfp_out)
    );

    // SFU Writeback Mux
    // 0: write OFIFO partial sums to pmem, 1: write SFU output back to pmem
    assign pmem_d = sfu_wb ? sfp_out : ofifo_data;

endmodule
