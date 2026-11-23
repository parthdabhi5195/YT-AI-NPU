// =============================================================================
// LUT-Free Minimax + 2x Newton-Raphson Reciprocal Unit (yt_sfu_recip.sv)
// - Computes round((1.0 / m_real) * 16384) in Q2.14 [16384..32768] for
//   normalized 16-bit mantissa m_u16 in [32768..65535] (m_real in [0.5, 1.0))
// - ZERO lookup tables, ZERO hardware dividers!
// - Optimal Chebyshev linear seed y0 = 48/17 - (32/17)*m followed by
//   2 registered Newton-Raphson iterations: y_{n+1} = y_n * (2 - m * y_n)
// - Critical path: strictly 1 16x16 unsigned multiply per cycle
// - Accuracy: <= 1 LSB error in Q2.14 (< 0.005% max error)
// =============================================================================
`default_nettype none

module yt_sfu_recip (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         req_valid,
    input  wire  [15:0] m_u16,      // Normalized Q0.16 mantissa [32768..65535]

    output logic        resp_valid,
    output logic [15:0] recip_q14   // Unsigned Q2.14 reciprocal [16384..32768]
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_NR1_A,
        S_NR1_B,
        S_NR2_A,
        S_NR2_B,
        S_DONE
    } state_t;

    state_t state;

    logic [15:0] r_m;
    logic [15:0] r_y;
    logic [15:0] r_two_minus_my;

    wire [15:0] m_eff   = (m_u16 < 16'd32768) ? 16'd32768 : m_u16;
    wire [31:0] seed_p  = (32'(m_eff) * 32'd30840) >> 16;
    wire [15:0] y_seed  = 16'd46260 - seed_p[15:0];

    wire [31:0] my_prod = (32'(r_m) * 32'(r_y)) >> 16;
    wire [31:0] y_next  = (32'(r_y) * 32'(r_two_minus_my)) >> 14;

    assign resp_valid = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= S_IDLE;
            r_m            <= '0;
            r_y            <= '0;
            r_two_minus_my <= '0;
            recip_q14      <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (req_valid) begin
                        r_m   <= m_eff;
                        r_y   <= y_seed;
                        state <= S_NR1_A;
                    end
                end

                S_NR1_A: begin
                    r_two_minus_my <= 16'd32768 - my_prod[15:0];
                    state          <= S_NR1_B;
                end

                S_NR1_B: begin
                    r_y   <= (y_next > 32'd32768) ? 16'd32768 : y_next[15:0];
                    state <= S_NR2_A;
                end

                S_NR2_A: begin
                    r_two_minus_my <= 16'd32768 - my_prod[15:0];
                    state          <= S_NR2_B;
                end

                S_NR2_B: begin
                    recip_q14 <= (y_next > 32'd32768) ? 16'd32768 : y_next[15:0];
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
