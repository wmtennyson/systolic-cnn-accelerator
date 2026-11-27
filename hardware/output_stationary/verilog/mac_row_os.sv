module mac_row #(
    parameter bw = 4,
    parameter psum_bw = 16,
    parameter col = 8
)(
    input logic                   clk,
    input logic                   reset,

    // Inputs
    input logic [1:0]             inst_w,
    input logic [bw-1:0]          in_w,
    input logic [col*bw-1:0]      in_n,

    input logic [col*psum_bw-1:0] in_psum_n,

    // Outputs
    output logic [col-1:0]        valid,
    output logic [col*bw-1:0]     out_s,

    output logic [col*psum_bw-1:0] out_psum_s
);
    // Variables
    logic   [(col+1)*bw-1:0] temp;
    logic   [2*(col+1)-1:0]  inst_temp;

    // Assignments
    assign  temp[bw-1:0]   = in_w;
    assign  inst_temp[1:0] = inst_w;

    // Row Insantiation
    genvar i;
    for (i=1; i < col+1 ; i=i+1) begin : col_num
        mac_tile #(
            .bw         (bw),
            .psum_bw    (psum_bw)
        ) mac_tile_instance (
            .clk        (clk),
            .reset      (reset),

            .in_w       (temp[bw*i-1:bw*(i-1)]),
            .out_e      (temp[bw*(i+1)-1:bw*i]),

            .inst_w     (inst_temp[2*i-1:2*(i-1)]),
            .inst_e     (inst_temp[2*(i+1)-1:2*i]),

            .in_n       (in_n[bw*i-1:bw*(i-1)]),
            .out_s      (out_s[bw*i-1:bw*(i-1)]),

            .in_psum_n  (in_psum_n[psum_bw*i-1:psum_bw*(i-1)]),
            .out_psum_s (out_psum_s[psum_bw*i-1:psum_bw*(i-1)])
        );

        assign valid[i-1] = (inst_temp[2*(i+1)-1 : 2*i] == 2'b11);  // Valid if DRAINed
    end

endmodule
