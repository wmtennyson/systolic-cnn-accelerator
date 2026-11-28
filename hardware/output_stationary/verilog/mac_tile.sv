module mac_tile #(
    parameter bw = 4,
    parameter psum_bw = 16
)(
    input logic               clk,
    input logic               reset,
    input logic               mode_os,

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
        CLEAR = 2'b01,  // LOAD for WS
        ACC   = 2'b10,
        DRAIN = 2'b11   // OS only
    } inst_t;

    inst_t inst_q, inst_next;

    logic               load_ready_q, load_ready_next;
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
        inst_q <= HOLD;
        a_q <= 0;
        b_q <= 0;
        c_q <= 0;
        load_ready_q <= 1'b1;
      end else begin
        // Output Stationary
        inst_q <= inst_next;
        a_q <= a_next;
        b_q <= b_next;
        c_q <= c_next;
        load_ready_q <= load_ready_next;
        end
    end

    // Assignments
    always_comb begin
        // Default: hold current state (prevents inferred latches)
        inst_next       = inst_q;
        a_next          = a_q;
        b_next          = b_q;
        c_next          = c_q;
        load_ready_next = load_ready_q;

        if (mode_os) begin
            // Output Stationary (OS)
            inst_next       = inst_t'(inst_w[1:0]);
            load_ready_next = 1'b1;

            if (inst_w == ACC) begin
                a_next = in_w;
                b_next = in_n;
            end

            case (inst_q)
                DRAIN   : c_next = in_psum_n;
                CLEAR   : c_next = '0;
                ACC     : c_next = mac_out;
                default : c_next = c_q; // HOLD
            endcase
        end else begin
            // Weight Stationary (WS)
            inst_next[1] = inst_w[1];
            c_next       = in_psum_n;

            if (inst_w[0] | inst_w[1])
                a_next = in_w;

            if (inst_w[0] & load_ready_q) begin
                b_next          = in_w;
                load_ready_next = 1'b0;
            end

            if (load_ready_q == 1'b0)
                inst_next[0] = inst_w[0];
        end
    end

    // Output Assignments
    assign inst_e = inst_q;
    assign out_e = a_q;
    assign out_s = b_q;
    assign out_psum_s = mode_os ? c_q : mac_out;

endmodule
