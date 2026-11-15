// =============================================================================
// 16x16 W8A16 Systolic Array (yt_systolic_array.sv)
// 256 Processing Elements: INT16 activations flow east, INT8 weights flow south
// =============================================================================
`default_nettype none

module yt_systolic_array #(
    parameter int M     = 16,
    parameter int N     = 16,
    parameter int ACT_W = 16,
    parameter int WGT_W = 8,
    parameter int ACC_W = 32
)(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       clear_acc,
    input  wire                       en,
    input  wire  signed [ACT_W-1:0]   a_col   [M],
    input  wire  signed [WGT_W-1:0]   b_row   [N],
    output logic signed [ACC_W-1:0]   acc_out [M][N]
);

    logic signed [ACT_W-1:0] a_wire [M][N+1];
    logic signed [WGT_W-1:0] b_wire [M+1][N];

    genvar gi, gj;
    generate
        for (gi = 0; gi < M; gi++) begin : gen_a_in
            assign a_wire[gi][0] = a_col[gi];
        end
        for (gj = 0; gj < N; gj++) begin : gen_b_in
            assign b_wire[0][gj] = b_row[gj];
        end

        for (gi = 0; gi < M; gi++) begin : gen_row
            for (gj = 0; gj < N; gj++) begin : gen_col
                yt_pe #(
                    .ACT_W (ACT_W),
                    .WGT_W (WGT_W),
                    .ACC_W (ACC_W)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .clear_acc (clear_acc),
                    .en        (en),
                    .a_in      (a_wire[gi][gj]),
                    .b_in      (b_wire[gi][gj]),
                    .a_out     (a_wire[gi][gj+1]),
                    .b_out     (b_wire[gi+1][gj]),
                    .acc_out   (acc_out[gi][gj])
                );
            end
        end
    endgenerate

endmodule

`default_nettype wire
