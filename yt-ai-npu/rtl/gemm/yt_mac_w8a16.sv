// =============================================================================
// W8A16 Multiply-Accumulate Unit (yt_mac_w8a16.sv)
// Signed INT16 Activation (Q7.8 / Q0.15) x Signed INT8 Weight/KV -> Signed INT32
// Pure standard-cell friendly (zero FP, zero DSP hard-macro dependency for SKY130)
// =============================================================================
`default_nettype none

module yt_mac_w8a16 #(
    parameter int ACT_W = 16,
    parameter int WGT_W = 8,
    parameter int ACC_W = 32
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       clear_acc,
    input  wire                       en,
    input  wire  signed [ACT_W-1:0]   a_in,
    input  wire  signed [WGT_W-1:0]   b_in,
    output logic signed [ACC_W-1:0]   acc_out
);

    logic signed [ACT_W+WGT_W-1:0] prod; // 24-bit exact product
    logic signed [ACC_W:0]         sum_ext;

    assign prod    = a_in * b_in;
    assign sum_ext = 33'(acc_out) + 33'(prod);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acc_out <= '0;
        end else if (clear_acc) begin
            acc_out <= '0;
        end else if (en) begin
            // Saturating INT32 accumulation
            if (sum_ext > 33'sd2147483647)
                acc_out <= 32'sd2147483647;
            else if (sum_ext < -33'sd2147483648)
                acc_out <= -32'sd2147483648;
            else
                acc_out <= sum_ext[31:0];
        end
    end

endmodule

`default_nettype wire
