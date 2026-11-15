// =============================================================================
// Systolic Processing Element (yt_pe.sv)
// Output-stationary PE: forwards INT16 activation east, INT8 weight south,
// accumulates INT32 inner product locally.
// =============================================================================
`default_nettype none

module yt_pe #(
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
    output logic signed [ACT_W-1:0]   a_out,
    output logic signed [WGT_W-1:0]   b_out,
    output logic signed [ACC_W-1:0]   acc_out
);

    yt_mac_w8a16 #(
        .ACT_W (ACT_W),
        .WGT_W (WGT_W),
        .ACC_W (ACC_W)
    ) u_mac (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear_acc (clear_acc),
        .en        (en),
        .a_in      (a_in),
        .b_in      (b_in),
        .acc_out   (acc_out)
    );

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            a_out <= '0;
            b_out <= '0;
        end else if (clear_acc) begin
            a_out <= '0;
            b_out <= '0;
        end else if (en) begin
            a_out <= a_in;
            b_out <= b_in;
        end
    end

endmodule

`default_nettype wire
