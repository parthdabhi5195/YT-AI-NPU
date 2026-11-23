// =============================================================================
// MxN Systolic Array (default 16x16 = 256 MACs)
// Weight-stationary style: A flows east, B flows south
// =============================================================================
`default_nettype none

module systolic_array #(
    parameter int M      = 16,   // rows
    parameter int N      = 16,   // cols
    parameter int DATA_W = 8, // INT8 for input element
    parameter int ACC_W  = 32 // INT32 for accumulate
)(
    input  wire                        clk, // clock
    input  wire                        rst_n, // reset
    input  wire                        clear_acc, // clear accumulate
    input  wire                        en, // enable
    // Input: one column of A per row, one row of B per column
    input  wire  signed [DATA_W-1:0]   a_col  [M], // A array of size M with INT8 values
    input  wire  signed [DATA_W-1:0]   b_row  [N], // B column
    // Output: MxN accumulator grid
    output logic signed [ACC_W-1:0]    acc_out [M][N], // 2D unpacked array of 16x16 signed INT32 values
    output logic                       acc_valid
);

    // Internal wiring
    logic signed [DATA_W-1:0] a_wire [M][N+1]; // horizontal wires connecting PEs left to right 17 columns of wires for N
    logic signed [DATA_W-1:0] b_wire [M+1][N]; // vertical wires connecting PEs top to bottom
    logic signed [ACC_W-1:0]  pe_acc [M][N]; // 2D array holding INT32 accumulator output

    // Connect inputs
    genvar gi, gj;
    generate
        for (gi = 0; gi < M; gi++) begin : gen_a_input
            assign a_wire[gi][0] = a_col[gi];
        end
        for (gj = 0; gj < N; gj++) begin : gen_b_input
            assign b_wire[0][gj] = b_row[gj];
        end
    endgenerate

    // Instantiate MxN PE grid
    generate
        for (gi = 0; gi < M; gi++) begin : gen_row
            for (gj = 0; gj < N; gj++) begin : gen_col
                pe #(
                    .DATA_W (DATA_W),
                    .ACC_W  (ACC_W)
                ) u_pe (
                    .clk       (clk),
                    .rst_n     (rst_n),
                    .clear_acc (clear_acc),
                    .en        (en),
                    .a_in      (a_wire[gi][gj]),
                    .b_in      (b_wire[gi][gj]),
                    .a_out     (a_wire[gi][gj+1]),
                    .b_out     (b_wire[gi+1][gj]),
                    .acc_out   (pe_acc[gi][gj])
                );
            end
        end
    endgenerate

    // Output accumulator grid
    generate
        for (gi = 0; gi < M; gi++) begin : gen_acc_row
            for (gj = 0; gj < N; gj++) begin : gen_acc_col
                assign acc_out[gi][gj] = pe_acc[gi][gj];
            end
        end
    endgenerate

    // acc_valid: after data has propagated through entire array
    // Latency = K_depth (streaming) + M + N - 2 (wave propagation) + 2 (MAC pipeline)
    // We track with a shift register driven externally
    // For now, provide a simple counter-based valid
    // track when the data reaches the bottom right corner
    localparam int DRAIN_LATENCY = M + N; // 16 cycles for A to travel east and 16 cycles for B to travel south
    localparam int CNT_W = $clog2(DRAIN_LATENCY+1); // counts how many wires needed to count to 32, which is 6
    logic [CNT_W-1:0] valid_cnt; // hardware register that holds the count of the cycles
    localparam [CNT_W-1:0] DRAIN_MAX = CNT_W'(DRAIN_LATENCY); // converts 32 into 6 bit constant

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid_cnt <= '0;
            acc_valid <= 1'b0;
        end else if (clear_acc) begin
            valid_cnt <= '0;
            acc_valid <= 1'b0;
        end else if (en) begin
            if (valid_cnt < DRAIN_MAX)
                valid_cnt <= valid_cnt + 1;
            else
                acc_valid <= 1'b1; // this is a flag so that processing engines like gemm_post only access the final values, not intermediate
        end
    end

endmodule

`default_nettype wire
