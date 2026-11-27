module mac_array #(
    parameter bw      = 4,
    parameter psum_bw = 16,
    parameter col     = 8,
    parameter row     = 8
)(
    input logic clk,
    input logic reset,

    // Inputs
    input logic [row*bw-1:0] in_w,
    input logic [1:0] inst_w, // 00 = HOLD, 01 = CLEAR, 10 = ACC, 11 = DRAIN
    input logic [col*bw-1:0] in_n,

    // Outputs
    output logic [col-1:0]         valid,
    output logic [col*bw-1:0]      out_s,
    output logic [col*psum_bw-1:0] out_psum_s
);

    // Variables
    logic [2*row-1:0] inst_w_temp_q;

    logic [bw*col*(row+1)-1:0]      weight_temp;
    logic [psum_bw*col*(row+1)-1:0] psum_temp;

    logic [row*col-1:0] valid_temp;

    // Assignments
    assign weight_temp[col*bw-1:0] = in_n;
    assign psum_temp[col*psum_bw-1:0] = '0;

    // Rows
    genvar i;
    for (i = 1; i <= row; i = i + 1) begin : row_num

        mac_row #(
            .bw      (bw),
            .psum_bw (psum_bw),
            .col     (col)
        ) mac_row_instance (
            .clk        (clk),
            .reset      (reset),

            .inst_w     (inst_w_temp_q[2*i-1 : 2*(i-1)]),
            .in_w       (in_w[bw*i-1 : bw*(i-1)]),

            // Weights
            .in_n       (weight_temp[bw*col*i-1 : bw*col*(i-1)]),
            .out_s      (weight_temp[bw*col*(i+1)-1 : bw*col*i]),

            // Partial sums
            .in_psum_n  (psum_temp[psum_bw*col*i-1 : psum_bw*col*(i-1)]),
            .out_psum_s (psum_temp[psum_bw*col*(i+1)-1 : psum_bw*col*i]),

            .valid      (valid_temp[col*i-1 : col*(i-1)])
        );
    end

    // Instruction shift register (staggered for ACC/CLEAR, row-broadcast for DRAIN)
    always_ff @(posedge clk) begin
        if (reset) begin
            inst_w_temp_q <= '0;
        end else if (inst_w == 2'b11) begin         // Broadcast: DRAIN
            inst_w_temp_q <= {row{2'b11}};
        end else begin                              // Stagger: HOLDS, CLEAR, ACC
            inst_w_temp_q[1:0] <= inst_w;

            for (int r = 1; r < row; r = r + 1) begin
            inst_w_temp_q[2*r +: 2] <= (inst_w_temp_q[2*(r-1) +: 2] == 2'b11)
                                   ? 2'b00
                                   : inst_w_temp_q[2*(r-1) +: 2];
            end
        end
    Vend

    // Output Assigments
    assign valid = valid_temp[row*col-1 : (row-1)*col];
    assign out_s = weight_temp[bw*col*(row+1)-1 : bw*col*row];
    assign out_psum_s = psum_temp[psum_bw*col*(row+1)-1 : psum_bw*col*row];

endmodule
