// =============================================================================
// LUT-Free 2-Segment Seed + 2x Coupled Newton-Raphson Inverse Sqrt Unit
// (yt_sfu_rsqrt.sv)
// - Computes round((1.0 / sqrt(m_real)) * 16384) in Q2.14 [16384..32768] for
//   even-bit-pair normalized mantissa m_u16 in [16384..65535] (m_real in [0.25, 1.0))
// - ZERO lookup tables, ZERO hardware dividers!
// - Piecewise affine seed (split on MSB m_u16[15]) + 2 coupled NR iterations:
//     y_{n+1} = (y_n * (3 - m * y_n^2)) / 2
// - Critical path: strictly 1 integer multiply per clock cycle
// - Accuracy: <= 1 LSB error in Q2.14 (< 0.01% relative error)
// =============================================================================
`default_nettype none

module yt_sfu_rsqrt (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         req_valid,
    input  wire  [15:0] m_u16,      // Normalized Q0.16 mantissa [16384..65535]

    output logic        resp_valid,
    output logic [15:0] rsqrt_q14   // Unsigned Q2.14 1/sqrt(m) [16384..32768]
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_NR1_SQ,
        S_NR1_SUB,
        S_NR1_MUL,
        S_NR2_SQ,
        S_NR2_SUB,
        S_NR2_MUL,
        S_DONE
    } state_t;

    state_t state;

    logic [15:0] r_m;
    logic [15:0] r_y;
    logic [17:0] r_y2;          // Q4.14 (up to 4.0 = 65536 -> 18 bits!)
    logic [15:0] r_three_minus; // Q2.14

    wire [15:0] m_eff      = (m_u16 < 16'd16384) ? 16'd16384 : m_u16;
    wire [15:0] seed_slope = m_eff[15] ? 16'd13353 : 16'd37028;
    wire [15:0] seed_inter = m_eff[15] ? 16'd29573 : 16'd41779;
    wire [31:0] seed_prod  = (32'(m_eff) * 32'(seed_slope)) >> 16;
    wire [15:0] y_seed     = seed_inter - seed_prod[15:0];

    wire [35:0] y_sq_q14   = (36'(r_y) * 36'(r_y) + 36'd8192) >> 14;
    wire [35:0] my2_q14    = (36'(r_m) * 36'(r_y2) + 36'd32768) >> 16;
    wire [35:0] y_next_q14 = (36'(r_y) * 36'(r_three_minus) + 36'd16384) >> 15;

    assign resp_valid = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state         <= S_IDLE;
            r_m           <= '0;
            r_y           <= '0;
            r_y2          <= '0;
            r_three_minus <= '0;
            rsqrt_q14     <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_valid) begin
                        r_m   <= m_eff;
                        r_y   <= y_seed;
                        state <= S_NR1_SQ;
                    end
                end

                S_NR1_SQ: begin
                    r_y2  <= y_sq_q14[17:0];
                    state <= S_NR1_SUB;
                end

                S_NR1_SUB: begin
                    r_three_minus <= 16'd49152 - my2_q14[15:0];
                    state         <= S_NR1_MUL;
                end

                S_NR1_MUL: begin
                    r_y   <= (y_next_q14 > 36'd32768) ? 16'd32768 : y_next_q14[15:0];
                    state <= S_NR2_SQ;
                end

                S_NR2_SQ: begin
                    r_y2  <= y_sq_q14[17:0];
                    state <= S_NR2_SUB;
                end

                S_NR2_SUB: begin
                    r_three_minus <= 16'd49152 - my2_q14[15:0];
                    state         <= S_NR2_MUL;
                end

                S_NR2_MUL: begin
                    rsqrt_q14 <= (y_next_q14 > 36'd32768) ? 16'd32768 : y_next_q14[15:0];
                    state     <= S_DONE;
                end

                S_DONE: begin
                    state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
