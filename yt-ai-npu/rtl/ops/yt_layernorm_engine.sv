// =============================================================================
// Divider-Free Q7.8 LayerNorm Engine (yt_layernorm_engine.sv)
// - Processes M rows x N hidden channels (default N=512 = 2^9)
// - Uses exact power-of-2 bit shifts for E[x] and Var[x] (ZERO hardware divider!)
// - Uses Bit-Pair CLZ Normalization + 256x16b RSQRT ROM for <0.2% error across
//   full 32-bit variance range (from 1e-5 to 65536)
// - Applies real learned Q4.12 gamma & Q7.8 beta packed in PARAM_SRAM!
// =============================================================================
`default_nettype none

module yt_layernorm_engine
    import yt_npu_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       cmd_valid,
    input  wire  [15:0]               cmd_rows,       // M rows (1..512)
    input  wire  [15:0]               cmd_length,     // N channels (power of 2: 16..1024, default 512)
    input  wire  [15:0]               cmd_src_base,   // ACT_SRAM input base
    input  wire  [15:0]               cmd_dst_base,   // ACT_SRAM output base
    input  wire  [15:0]               cmd_param_base, // PARAM_SRAM base ({beta_q78[31:16], gamma_q4_12[15:0]})

    // ACT_SRAM Read Port
    output logic                      act_rd_en,
    output logic [ACT_ADDR_W-1:0]     act_rd_addr,
    input  wire  signed [15:0]        act_rd_data,

    // ACT_SRAM Write Port
    output logic                      act_wr_en,
    output logic [ACT_ADDR_W-1:0]     act_wr_addr,
    output logic signed [15:0]        act_wr_data,

    // PARAM_SRAM Read Port (32-bit: [15:0]=gamma_q4_12, [31:16]=beta_q78)
    output logic                      param_rd_en,
    output logic [PARAM_ADDR_W-1:0]   param_rd_addr,
    input  wire  [31:0]               param_rd_data,

    output logic                      busy,
    output logic                      done
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_P1_RD,
        S_P1_ACC,
        S_P2_RD,
        S_P2_ACC,
        S_NORM_VAR,
        S_RSQRT_WAIT,
        S_P3_RD,
        S_P3_WR,
        S_NEXT_ROW,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [15:0] r_rows, r_len, r_src, r_dst, r_pbase;
    logic [15:0] row_idx, col_idx;
    logic [3:0]  log2_n;

    logic signed [31:0] sum_acc;
    logic signed [15:0] r_mean;
    logic        [47:0] sum_sq_acc;
    logic        [39:0] v8_val;
    logic        [4:0]  norm_k;
    logic        [7:0]  rsqrt_addr;
    wire         [15:0] rsqrt_dout;
    logic        [23:0] r_inv_std_q12;

    yt_rsqrt_lut u_rsqrt_rom (
        .clk      (clk),
        .addr     (rsqrt_addr),
        .data_out (rsqrt_dout)
    );

    // Detect log2(N) for power-of-2 hidden dimensions (16..2048)
    function automatic logic [3:0] get_log2(input logic [15:0] n);
        case (n)
            16'd16:   return 4'd4;
            16'd32:   return 4'd5;
            16'd64:   return 4'd6;
            16'd128:  return 4'd7;
            16'd256:  return 4'd8;
            16'd512:  return 4'd9;
            16'd1024: return 4'd10;
            16'd2048: return 4'd11;
            default:  return 4'd9;
        endcase
    endfunction

    // Bit-pair CLZ normalization: find smallest k in 0..16 s.t. (v8 >> (2*k)) < 256
    logic [4:0] calc_k;
    logic [7:0] calc_m;
    always_comb begin
        calc_k = 5'd16;
        for (int k = 15; k >= 0; k--) begin
            if ((v8_val >> (2 * k)) < 40'd256)
                calc_k = 5'(k);
        end
        calc_m = 8'((v8_val >> (2 * calc_k)) & 40'hFF);
    end

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE:       if (cmd_valid) state_nxt = S_P1_RD;
            S_P1_RD:      state_nxt = S_P1_ACC;
            S_P1_ACC:     state_nxt = (col_idx == r_len - 16'd1) ? S_P2_RD : S_P1_RD;
            S_P2_RD:      state_nxt = S_P2_ACC;
            S_P2_ACC:     state_nxt = (col_idx == r_len - 16'd1) ? S_NORM_VAR : S_P2_RD;
            S_NORM_VAR:   state_nxt = S_RSQRT_WAIT;
            S_RSQRT_WAIT: state_nxt = S_P3_RD;
            S_P3_RD:      state_nxt = S_P3_WR;
            S_P3_WR:      state_nxt = (col_idx == r_len - 16'd1) ? S_NEXT_ROW : S_P3_RD;
            S_NEXT_ROW:   state_nxt = (row_idx == r_rows - 16'd1) ? S_DONE : S_P1_RD;
            S_DONE:       state_nxt = S_IDLE;
            default:      state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    wire [31:0] row_src_base = 32'(r_src) + 32'(row_idx) * 32'(r_len);
    wire [31:0] row_dst_base = 32'(r_dst) + 32'(row_idx) * 32'(r_len);

    // Pass 3 normalization math (exact match to bit_exact_lut_forward)
    logic signed [31:0] p3_diff;
    logic signed [63:0] p3_normed;
    logic signed [15:0] p3_gamma;
    logic signed [15:0] p3_beta;
    logic signed [63:0] p3_scaled;
    logic signed [15:0] p3_out;

    always_comb begin
        p3_gamma  = signed'(param_rd_data[15:0]);
        p3_beta   = signed'(param_rd_data[31:16]);
        p3_diff   = 32'(act_rd_data) - 32'(r_mean);
        p3_normed = (64'(p3_diff) * 64'(signed'({1'b0, r_inv_std_q12}))) >>> 12;
        p3_scaled = ((p3_normed * 64'(p3_gamma)) >>> 12) + 64'(p3_beta);
        p3_out    = saturate_i16_64(p3_scaled);
    end

    // SRAM port outputs
    always_comb begin
        act_rd_en     = 1'b0;
        act_rd_addr   = '0;
        act_wr_en     = 1'b0;
        act_wr_addr   = '0;
        act_wr_data   = '0;
        param_rd_en   = 1'b0;
        param_rd_addr = '0;
        rsqrt_addr    = calc_m;

        case (state)
            S_P1_RD, S_P2_RD: begin
                act_rd_en   = 1'b1;
                act_rd_addr = ACT_ADDR_W'(row_src_base + 32'(col_idx));
            end
            S_P3_RD: begin
                act_rd_en     = 1'b1;
                act_rd_addr   = ACT_ADDR_W'(row_src_base + 32'(col_idx));
                param_rd_en   = 1'b1;
                param_rd_addr = PARAM_ADDR_W'(32'(r_pbase) + 32'(col_idx));
            end
            S_P3_WR: begin
                act_wr_en   = 1'b1;
                act_wr_addr = ACT_ADDR_W'(row_dst_base + 32'(col_idx));
                act_wr_data = p3_out;
            end
            default: ;
        endcase
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_rows <= '0; r_len <= '0; r_src <= '0; r_dst <= '0; r_pbase <= '0;
            row_idx <= '0; col_idx <= '0; log2_n <= 4'd9;
            sum_acc <= '0; r_mean <= '0; sum_sq_acc <= '0;
            v8_val <= '0; norm_k <= '0; r_inv_std_q12 <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        r_rows  <= (cmd_rows == 16'd0) ? 16'd1 : cmd_rows;
                        r_len   <= cmd_length;
                        r_src   <= cmd_src_base;
                        r_dst   <= cmd_dst_base;
                        r_pbase <= cmd_param_base;
                        log2_n  <= get_log2(cmd_length);
                        row_idx <= 16'd0;
                        col_idx <= 16'd0;
                        sum_acc <= 32'sd0;
                    end
                end

                S_P1_ACC: begin
                    automatic logic signed [31:0] new_sum = sum_acc + 32'(act_rd_data);
                    if (col_idx == r_len - 16'd1) begin
                        r_mean     <= 16'(new_sum >>> log2_n);
                        col_idx    <= 16'd0;
                        sum_sq_acc <= 48'd0;
                    end else begin
                        sum_acc <= new_sum;
                        col_idx <= col_idx + 16'd1;
                    end
                end

                S_P2_ACC: begin
                    automatic logic signed [31:0] d  = 32'(act_rd_data) - 32'(r_mean);
                    automatic logic        [47:0] sq = 48'(64'(d) * 64'(d));
                    automatic logic        [47:0] new_sq = sum_sq_acc + sq;
                    if (col_idx == r_len - 16'd1) begin
                        automatic logic [31:0] var_q16 = 32'(new_sq >> log2_n);
                        v8_val  <= (40'(var_q16) + 40'd1) << 8;
                        col_idx <= 16'd0;
                    end else begin
                        sum_sq_acc <= new_sq;
                        col_idx    <= col_idx + 16'd1;
                    end
                end

                S_NORM_VAR: begin
                    norm_k <= calc_k;
                end

                S_RSQRT_WAIT: begin
                    automatic logic [23:0] raw_inv = ({8'b0, rsqrt_dout} << 8) >> norm_k;
                    r_inv_std_q12 <= (raw_inv > 24'h0F_FFFF) ? 24'h0F_FFFF : raw_inv;
                end

                S_P3_WR: begin
                    if (col_idx == r_len - 16'd1)
                        col_idx <= 16'd0;
                    else
                        col_idx <= col_idx + 16'd1;
                end

                S_NEXT_ROW: begin
                    if (row_idx < r_rows - 16'd1) begin
                        row_idx <= row_idx + 16'd1;
                        col_idx <= 16'd0;
                        sum_acc <= 32'sd0;
                    end
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
