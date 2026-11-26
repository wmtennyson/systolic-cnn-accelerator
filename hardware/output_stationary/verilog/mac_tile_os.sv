module mac_tile #(
    parameter bw = 4,
    parameter psum_bw = 16
)(
    input                     clk,
    input                     reset,

    // Inputs
    input logic [1:0]         inst_w,
    input logic [bw-1:0]      in_w,       // X - Input
    input logic [bw-1:0]      in_n,       // W - Weights

    input logic [psum_bw-1:0] in_psum_n,  // Drain Result Path

    // Outputs
    output logic [1:0]         inst_e,
    output logic [bw-1:0]      out_e,
    output logic [bw-1:0]      out_s,

    output logic [psum_bw-1:0] out_psum_s
);

    // Variables
    typedef enum logic [1:0] {
        HOLD  = 2'b00,
        CLEAR = 2'b01,
        ACC   = 2'b10,
        DRAIN = 2'b11
    } inst_t;

    inst_t inst_q, inst_next;

    logic [bw-1:0]      a_q, a_next;
    logic [bw-1:0]      b_q, b_next;
    logic [psum_bw-1:0] c_q, c_next;

    logic [psum_bw-1:0] mac_out;

    // Mac Inst.
    mac #(
        .bw      (bw),
        .psum_bw (psum_bw)
    ) mac_instance (
        .a       (a_q),
        .b       (b_q),
        .c       (c_q),
        .out     (mac_out)
    );

    // Regs
    always @ (posedge clk) begin
      if (reset) begin
        inst_q <= 2'b00;
        a_q <= 0;
        b_q <= 0;
        c_q <= 0;
      end else begin
        inst_q <= inst_next;
        a_q <= a_next;
        b_q <= b_next;
        c_q <= c_next;
        end
    end

    // Assignments
    assign inst_next = inst_t'(inst_w[1:0]);
    assign a_next = (inst_w == ACC) ? in_w : a_q;
    assign b_next = (inst_w == ACC) ? in_n : b_q;

    always_comb begin
        unique case (inst_q)
            DRAIN   : c_next = in_psum_n;
            CLEAR   : c_next = '0;
            ACC     : c_next = mac_out;
            default : c_next = c_q;         //HOLD
        endcase
    end

    // Output Assignments
    assign inst_e = inst_q;
    assign out_e = a_q;
    assign out_s = b_q;

    assign out_psum_s = c_q;

endmodule
