// =============================================================================
// 100% LUT-Free Analytic Q7.8 GELU Activation Engine (yt_gelu_engine.sv)
// - Default Mode (`FAST_QUAD_MODE = 0`): Exact GPT-2 Analytic Tanh/Sigmoid GELU
//     GELU(x) = x * sigmoid(2 * sqrt(2/pi) * (x + 0.044715 * x^3))
//   Evaluates cubic argument u_q78 in 2 cycles, then reuses `yt_sfu_exp` and
//   `yt_sfu_recip` to compute exact sigmoid(u) with <= 1 LSB error in Q7.8!
//   Inputs outside (-5.0, +5.0) take a 1-cycle exact asymptote fast path!
// - Optional Mode (`FAST_QUAD_MODE = 1`): 2-cycle I-BERT quadratic erf polynomial
// =============================================================================
`default_nettype none

module yt_gelu_engine
    import yt_npu_pkg::*;
#(
    parameter bit FAST_QUAD_MODE = 1'b0
)(
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       cmd_valid,
    input  wire  [15:0]               cmd_rows,     // M rows
    input  wire  [15:0]               cmd_length,   // N cols
    input  wire  [15:0]               cmd_src_base, // ACT_SRAM input base
    input  wire  [15:0]               cmd_dst_base, // ACT_SRAM output base

    output logic                      act_rd_en,
    output logic [ACT_ADDR_W-1:0]     act_rd_addr,
    input  wire  signed [15:0]        act_rd_data,

    output logic                      act_wr_en,
    output logic [ACT_ADDR_W-1:0]     act_wr_addr,
    output logic signed [15:0]        act_wr_data,

    output logic                      busy,
    output logic                      done
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_RD,
        S_LATCH_X,
        S_CUBIC_U,
        S_WAIT_EXP,
        S_WAIT_RECIP,
        S_MUL_OUT,
        S_QUAD_EVAL,
        S_WR,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [31:0]        r_total, r_idx;
    logic [15:0]        r_src, r_dst;
    logic signed [15:0] r_x;
    logic signed [31:0] r_x2_q8;
    logic               r_u_neg;
    logic        [16:0] r_sig_q15;
    logic signed [15:0] r_out;

    // Sub-SFU wires (LUT-free exp & recip)
    logic        exp_req;
    logic [12:0] exp_d_q78;
    wire         exp_valid;
    wire  [15:0] exp_q15;

    logic        recip_req;
    logic [15:0] recip_m_u16;
    wire         recip_valid;
    wire  [15:0] recip_q14;

    yt_sfu_exp u_sfu_exp (
        .clk        (clk),
        .rst_n      (rst_n),
        .req_valid  (exp_req),
        .d_q78      (exp_d_q78),
        .resp_valid (exp_valid),
        .exp_q15    (exp_q15)
    );

    yt_sfu_recip u_sfu_recip (
        .clk        (clk),
        .rst_n      (rst_n),
        .req_valid  (recip_req),
        .m_u16      (recip_m_u16),
        .resp_valid (recip_valid),
        .recip_q14  (recip_q14)
    );

    // Asymptote detection in S_LATCH_X: |x| >= 1280 (5.0 in Q7.8)
    wire is_pos_asym = (act_rd_data >= 16'sd1280);
    wire is_neg_asym = (act_rd_data <= -16'sd1280);

    // Cubic evaluation in S_CUBIC_U: u_q78 = ((x * 26145) + (x3_q8 * 1169)) >>> 14
    wire signed [47:0] x3_q8     = (48'(r_x2_q8) * 48'(r_x)) >>> 8;
    wire signed [47:0] u_num     = (48'(r_x) * 48'sd26145) + (x3_q8 * 48'sd1169);
    wire signed [31:0] u_q78     = 32'(u_num >>> 14);
    wire        [31:0] abs_u_q78 = (u_q78 < 32'sd0) ? 32'(-u_q78) : u_q78;

    // Optional I-BERT 2-multiply quadratic erf datapath (when FAST_QUAD_MODE=1)
    wire        [15:0] abs_x_q78  = (r_x < 16'sd0) ? 16'(-r_x) : 16'(r_x);
    wire        [15:0] min_abs_x  = (abs_x_q78 > 16'd642) ? 16'd642 : abs_x_q78;
    wire        [15:0] q_delta    = 16'd642 - min_abs_x;
    wire        [47:0] q_om_erf   = ((48'(q_delta) * 48'(q_delta)) * 48'd20841) >> 18;
    wire signed [16:0] q_erf_abs  = (q_om_erf > 48'd32768) ? 17'sd0 : (17'sd32768 - 17'(q_om_erf[16:0]));
    wire signed [16:0] q_erf_sgn  = (r_x >= 16'sd0) ? q_erf_abs : -q_erf_abs;
    wire signed [47:0] q_prod     = (48'(r_x) * (48'sd32768 + 48'(q_erf_sgn)) + 48'sd32768) >>> 16;

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE:       if (cmd_valid) state_nxt = S_RD;
            S_RD:         state_nxt = S_LATCH_X;
            S_LATCH_X: begin
                if (is_pos_asym || is_neg_asym)
                    state_nxt = S_WR;
                else if (FAST_QUAD_MODE)
                    state_nxt = S_QUAD_EVAL;
                else
                    state_nxt = S_CUBIC_U;
            end
            S_CUBIC_U:    state_nxt = S_WAIT_EXP;
            S_WAIT_EXP:   if (exp_valid)   state_nxt = S_WAIT_RECIP;
            S_WAIT_RECIP: if (recip_valid) state_nxt = S_MUL_OUT;
            S_MUL_OUT:    state_nxt = S_WR;
            S_QUAD_EVAL:  state_nxt = S_WR;
            S_WR:         state_nxt = (r_idx == r_total - 32'd1) ? S_DONE : S_RD;
            S_DONE:       state_nxt = S_IDLE;
            default:      state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    assign exp_req     = (state == S_CUBIC_U);
    assign exp_d_q78   = (abs_u_q78 > 32'd4095) ? 13'd4095 : abs_u_q78[12:0];

    assign recip_req   = (state == S_WAIT_EXP) && exp_valid;
    assign recip_m_u16 = 16'd32768 + exp_q15; // Always in [32768..65535]!

    assign act_rd_en   = (state == S_RD);
    assign act_rd_addr = ACT_ADDR_W'(32'(r_src) + r_idx);
    assign act_wr_en   = (state == S_WR);
    assign act_wr_addr = ACT_ADDR_W'(32'(r_dst) + r_idx);
    assign act_wr_data = r_out;

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_total   <= '0;
            r_idx     <= '0;
            r_src     <= '0;
            r_dst     <= '0;
            r_x       <= '0;
            r_x2_q8   <= '0;
            r_u_neg   <= 1'b0;
            r_sig_q15 <= '0;
            r_out     <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        automatic logic [15:0] m_eff = (cmd_rows == 16'd0) ? 16'd1 : cmd_rows;
                        r_total <= 32'(m_eff) * 32'(cmd_length);
                        r_idx   <= 32'd0;
                        r_src   <= cmd_src_base;
                        r_dst   <= cmd_dst_base;
                    end
                end

                S_LATCH_X: begin
                    r_x     <= act_rd_data;
                    r_x2_q8 <= (32'(act_rd_data) * 32'(act_rd_data)) >>> 8;
                    if (is_pos_asym)      r_out <= act_rd_data;
                    else if (is_neg_asym) r_out <= 16'sd0;
                end

                S_CUBIC_U: begin
                    r_u_neg <= (u_q78 < 32'sd0);
                end

                S_WAIT_RECIP: begin
                    if (recip_valid) begin
                        r_sig_q15 <= r_u_neg ? (17'd32768 - 17'(recip_q14)) : 17'(recip_q14);
                    end
                end

                S_MUL_OUT: begin
                    automatic logic signed [31:0] prod =
                        (32'(r_x) * 32'(signed'({1'b0, r_sig_q15})) + 32'sd16384) >>> 15;
                    r_out <= saturate_i16(prod);
                end

                S_QUAD_EVAL: begin
                    r_out <= saturate_i16(32'(q_prod));
                end

                S_WR: begin
                    if (r_idx < r_total - 32'd1)
                        r_idx <= r_idx + 32'd1;
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
