// =============================================================================
// Full 512-Context 3-Pass Causal Softmax Engine (yt_softmax_engine.sv)
// - Processes M rows x N sequence columns (up to N = 512!)
// - Pass 1: Row max of Q7.8 scores (with optional causal mask col > K + row)
// - Pass 2: diff = clamp(max - score, 0, 4080), exp_u15 = EXP_LUT[diff >> 4],
//           writes 512x16b internal scratch SRAM and accumulates sum_exp
// - Pass 3: CLZ Normalization + 256x16b RECIP_LUT -> Q0.15 probabilities [0..32767]
//           (ZERO hardware divider!)
// =============================================================================
`default_nettype none

module yt_softmax_engine
    import yt_npu_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       cmd_valid,
    input  wire  [15:0]               cmd_rows,        // M rows
    input  wire  [15:0]               cmd_length,      // N columns (1..512)
    input  wire  [15:0]               cmd_src_base,    // ACT_SRAM input Q7.8 scores
    input  wire  [15:0]               cmd_dst_base,    // ACT_SRAM output Q0.15 probs
    input  wire                       causal_mask_en,  // Mask col > causal_base + row
    input  wire  [15:0]               causal_base,     // Starting causal index (K)

    // ACT_SRAM Read Port
    output logic                      act_rd_en,
    output logic [ACT_ADDR_W-1:0]     act_rd_addr,
    input  wire  signed [15:0]        act_rd_data,

    // ACT_SRAM Write Port
    output logic                      act_wr_en,
    output logic [ACT_ADDR_W-1:0]     act_wr_addr,
    output logic signed [15:0]        act_wr_data,

    output logic                      busy,
    output logic                      done
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_P1_RD,
        S_P1_MAX,
        S_P2_RD,
        S_P2_LUT,
        S_P2_SUM,
        S_NORM_SUM,
        S_RECIP_WAIT,
        S_P3_RD,
        S_P3_WR,
        S_NEXT_ROW,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [15:0] r_rows, r_len, r_src, r_dst, r_cbase;
    logic        r_cmask;
    logic [15:0] row_idx, col_idx;

    logic signed [15:0] r_max;
    logic        [31:0] r_sum;
    logic        [7:0]  exp_addr;
    wire         [15:0] exp_dout;
    logic        [7:0]  recip_addr;
    wire         [15:0] recip_dout;
    logic        [15:0] r_recip_val;
    logic signed [6:0]  r_rshift; // signed shift: >=0 right shift, <0 left shift
    logic               p2_masked_q;

    // Internal 512x16-bit Scratch SRAM for row exp values
    logic        scr_rd_en, scr_wr_en;
    logic [8:0]  scr_rd_addr, scr_wr_addr;
    logic [15:0] scr_rd_data, scr_wr_data;

    yt_sram_1r1w #(
        .DEPTH (512),
        .WIDTH (16)
    ) u_exp_scratch (
        .clk     (clk),
        .rd_en   (scr_rd_en),
        .rd_addr (scr_rd_addr),
        .rd_data (scr_rd_data),
        .wr_en   (scr_wr_en),
        .wr_addr (scr_wr_addr),
        .wr_data (scr_wr_data)
    );

    yt_exp_lut u_exp_rom (
        .clk      (clk),
        .addr     (exp_addr),
        .data_out (exp_dout)
    );

    yt_recip_lut u_recip_rom (
        .clk      (clk),
        .addr     (recip_addr),
        .data_out (recip_dout)
    );

    // CLZ normalization of r_sum into m in [128..255]
    logic [7:0]         calc_m;
    logic signed [6:0]  calc_rshift;
    always_comb begin
        automatic logic [31:0] s = (r_sum == 32'd0) ? 32'd1 : r_sum;
        calc_m      = 8'd128;
        calc_rshift = 7'sd7;
        if (s < 32'd128) begin
            for (int sh = 7; sh >= 1; sh--) begin
                if ((s << sh) >= 32'd128 && (s << sh) < 32'd256) begin
                    calc_m      = 8'((s << sh) & 32'hFF);
                    calc_rshift = 7'sd7 - 7'(signed'(sh));
                end
            end
        end else begin
            for (int sh = 24; sh >= 0; sh--) begin
                if ((s >> sh) >= 32'd128 && (s >> sh) < 32'd256) begin
                    calc_m      = 8'((s >> sh) & 32'hFF);
                    calc_rshift = 7'sd7 + 7'(signed'(sh));
                end
            end
        end
    end

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE:       if (cmd_valid) state_nxt = S_P1_RD;
            S_P1_RD:      state_nxt = S_P1_MAX;
            S_P1_MAX:     state_nxt = (col_idx == r_len - 16'd1) ? S_P2_RD : S_P1_RD;
            S_P2_RD:      state_nxt = S_P2_LUT;
            S_P2_LUT:     state_nxt = S_P2_SUM;
            S_P2_SUM:     state_nxt = (col_idx == r_len - 16'd1) ? S_NORM_SUM : S_P2_RD;
            S_NORM_SUM:   state_nxt = S_RECIP_WAIT;
            S_RECIP_WAIT: state_nxt = S_P3_RD;
            S_P3_RD:      state_nxt = S_P3_WR;
            S_P3_WR:      state_nxt = (col_idx == r_len - 16'd1) ? S_NEXT_ROW : S_P3_RD;
            S_NEXT_ROW:   state_nxt = (row_idx == r_rows - 16'd1) ? S_DONE : S_P1_RD;
            S_DONE:       state_nxt = S_IDLE;
            default:      state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE_SAFE;
        else        state <= state_nxt;
    end
    localparam state_t ST_IDLE_SAFE = S_IDLE;

    wire [31:0] row_src_base = 32'(r_src) + 32'(row_idx) * 32'(r_len);
    wire [31:0] row_dst_base = 32'(r_dst) + 32'(row_idx) * 32'(r_len);
    wire        is_masked    = r_cmask && (col_idx > (r_cbase + row_idx));

    // Pass 2 diff calculation
    logic signed [31:0] raw_diff;
    logic        [11:0] clamped_diff;
    always_comb begin
        raw_diff = 32'(r_max) - 32'(act_rd_data);
        if (raw_diff < 32'sd0)         clamped_diff = 12'd0;
        else if (raw_diff > 32'sd4080) clamped_diff = 12'd4080;
        else                           clamped_diff = raw_diff[11:0];
    end

    // Pass 3 normalization math
    logic [47:0] p3_prod;
    logic [47:0] p3_shifted;
    logic [15:0] p3_prob_u15;
    always_comb begin
        p3_prod = 48'(scr_rd_data) * 48'(r_recip_val);
        if (r_rshift >= 7'sd0)
            p3_shifted = p3_prod >> r_rshift;
        else
            p3_shifted = p3_prod << (-r_rshift);
        p3_prob_u15 = (p3_shifted > 48'd32767) ? 16'd32767 : p3_shifted[15:0];
    end

    always_comb begin
        act_rd_en   = (state == S_P1_RD) || (state == S_P2_RD);
        act_rd_addr = ACT_ADDR_W'(row_src_base + 32'(col_idx));
        act_wr_en   = (state == S_P3_WR);
        act_wr_addr = ACT_ADDR_W'(row_dst_base + 32'(col_idx));
        act_wr_data = signed'(p3_prob_u15);

        exp_addr    = clamped_diff[11:4];
        recip_addr  = calc_m;

        scr_wr_en   = (state == S_P2_SUM);
        scr_wr_addr = col_idx[8:0];
        scr_wr_data = p2_masked_q ? 16'd0 : exp_dout;

        scr_rd_en   = (state == S_P3_RD);
        scr_rd_addr = col_idx[8:0];
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_rows <= '0; r_len <= '0; r_src <= '0; r_dst <= '0; r_cbase <= '0;
            r_cmask <= 1'b0; row_idx <= '0; col_idx <= '0;
            r_max <= -16'sd32768; r_sum <= '0;
            r_recip_val <= '0; r_rshift <= '0; p2_masked_q <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        r_rows  <= (cmd_rows == 16'd0) ? 16'd1 : cmd_rows;
                        r_len   <= cmd_length;
                        r_src   <= cmd_src_base;
                        r_dst   <= cmd_dst_base;
                        r_cmask <= causal_mask_en;
                        r_cbase <= causal_base;
                        row_idx <= 16'd0;
                        col_idx <= 16'd0;
                        r_max   <= -16'sd32768;
                    end
                end

                S_P1_MAX: begin
                    automatic logic signed [15:0] v = is_masked ? -16'sd32768 : act_rd_data;
                    if (v > r_max) r_max <= v;
                    if (col_idx == r_len - 16'd1) begin
                        col_idx <= 16'd0;
                        r_sum   <= 32'd0;
                    end else begin
                        col_idx <= col_idx + 16'd1;
                    end
                end

                S_P2_LUT: begin
                    p2_masked_q <= is_masked;
                end

                S_P2_SUM: begin
                    automatic logic [15:0] ev = p2_masked_q ? 16'd0 : exp_dout;
                    r_sum <= r_sum + 32'(ev);
                    if (col_idx == r_len - 16'd1)
                        col_idx <= 16'd0;
                    else
                        col_idx <= col_idx + 16'd1;
                end

                S_NORM_SUM: begin
                    r_rshift <= calc_rshift;
                end

                S_RECIP_WAIT: begin
                    r_recip_val <= recip_dout;
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
                        r_max   <= -16'sd32768;
                    end
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
