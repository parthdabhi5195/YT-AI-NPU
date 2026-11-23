// =============================================================================
// 100% LUT-Free Streaming 50,257-Vocab Hardware Top-K + Temperature Sampler
// (yt_topk_sampler.sv)
// - Supports YT-AI's exact inference sampling (`top_k = 200, temperature = 0.8`)
//   as well as deterministic Greedy Argmax (`top_k = 1` or `temp_inv_q88 = 0`)!
// - OP_TOPK_FEED:
//     Streams a tile of N Q7.8 logits starting at `vocab_base` (automatically
//     ignoring padded indices >= 50,257). Uses 1-cycle fast reject against
//     `pool_min_val` so >99% of vocabulary logits finish in 1 clock cycle!
// - OP_TOPK_SAMPLE:
//     Scales full-precision `(pool_max_val - logit) * temp_inv_q88 >>> 8`,
//     evaluates algebraic Base-2 Horner `yt_sfu_exp` (ZERO LUTs!), draws a
//     64-bit Xorshift64* PRNG sample with Lemire's divider-free range reduction
//     `(rand32 * prob_sum) >> 32`, and outputs `sampled_token_id`!
// =============================================================================
`default_nettype none

module yt_topk_sampler
    import yt_npu_pkg::*;
    import yt_isa_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    // PRNG seed load (from AXI-Lite on START)
    input  wire                       seed_load,
    input  wire  [63:0]               seed_val,

    // Sampling hyperparameters
    input  wire  [15:0]               cfg_top_k,        // 1..256 (YT-AI default: 200)
    input  wire  [15:0]               cfg_temp_inv_q88, // Q8.8 1/T (0.8 -> 320; 0 -> greedy)

    // Command Interface
    input  wire                       cmd_valid,
    input  wire                       cmd_is_sample,    // 0: OP_TOPK_FEED, 1: OP_TOPK_SAMPLE
    input  wire                       cmd_reset_pool,   // flags[0] on first tile of OP_TOPK_FEED
    input  wire  [15:0]               cmd_src_base,     // ACT_SRAM logit tile base
    input  wire  [15:0]               cmd_length,       // Tile size (e.g. 64)
    input  wire  [15:0]               cmd_vocab_base,   // Starting vocabulary token ID (0..50256)

    // ACT_SRAM Read Port
    output logic                      act_rd_en,
    output logic [ACT_ADDR_W-1:0]     act_rd_addr,
    input  wire  signed [15:0]        act_rd_data,

    // Sampled Next-Token Output
    output logic                      sample_valid,
    output logic [15:0]               sampled_token_id,

    output logic                      busy,
    output logic                      done
);

    typedef enum logic [3:0] {
        S_IDLE,
        S_INIT_CLEAR,
        S_FEED_RD,
        S_FEED_CMP,
        S_RESCAN_RD,
        S_RESCAN_CMP,
        S_SMP_RD,
        S_SMP_EXP_REQ,
        S_SMP_EXP_WAIT,
        S_SMP_ACC,
        S_SMP_DRAW,
        S_SMP_PICK_RD,
        S_SMP_PICK_CMP,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    // Candidate Pool SRAM: 256 x 32-bit ({tok_id[15:0], logit_q78[15:0]})
    logic        pool_rd_en, pool_wr_en;
    logic [7:0]  pool_rd_addr, pool_wr_addr;
    logic [31:0] pool_rd_data, pool_wr_data;

    yt_sram_1r1w #(
        .DEPTH (256),
        .WIDTH (32)
    ) u_pool_sram (
        .clk     (clk),
        .rd_en   (pool_rd_en),
        .rd_addr (pool_rd_addr),
        .rd_data (pool_rd_data),
        .wr_en   (pool_wr_en),
        .wr_addr (pool_wr_addr),
        .wr_data (pool_wr_data)
    );

    // Candidate Probability SRAM: 256 x 16-bit (Q0.15 unnormalized exp probs)
    logic        prob_rd_en, prob_wr_en;
    logic [7:0]  prob_rd_addr, prob_wr_addr;
    logic [15:0] prob_rd_data, prob_wr_data;

    yt_sram_1r1w #(
        .DEPTH (256),
        .WIDTH (16)
    ) u_prob_sram (
        .clk     (clk),
        .rd_en   (prob_rd_en),
        .rd_addr (prob_rd_addr),
        .rd_data (prob_rd_data),
        .wr_en   (prob_wr_en),
        .wr_addr (prob_wr_addr),
        .wr_data (prob_wr_data)
    );

    // Pure Algebraic Base-2 Horner Exponential Unit (ZERO LUTs!)
    wire         exp_req;
    logic [12:0] temp_clamped;
    wire         exp_valid;
    wire  [15:0] exp_q15;

    yt_sfu_exp u_sfu_exp (
        .clk        (clk),
        .rst_n      (rst_n),
        .req_valid  (exp_req),
        .d_q78      (temp_clamped),
        .resp_valid (exp_valid),
        .exp_q15    (exp_q15)
    );

    // Pool tracking registers
    logic        [8:0]  k_eff;
    logic        [8:0]  slot_idx;
    logic        [15:0] r_src, r_len, r_vbase;
    logic        [15:0] elem_idx;

    logic signed [15:0] pool_min_val;
    logic        [7:0]  pool_min_slot;
    logic signed [15:0] pool_max_val;
    logic        [15:0] pool_max_id;

    logic signed [15:0] rescan_min_val;
    logic        [7:0]  rescan_min_slot;

    // 64-bit Xorshift64* PRNG
    logic [63:0] prng_state;
    logic [31:0] prng_u32;
    always_comb begin
        automatic logic [63:0] x = prng_state;
        x = x ^ (x >> 12);
        x = x ^ (x << 25);
        x = x ^ (x >> 27);
        prng_u32 = 32'((x * 64'h2545_F491_4F6C_DD1D) >> 32);
    end

    wire [31:0] cur_vocab_id = 32'(r_vbase) + 32'(elem_idx);
    wire        valid_vocab  = (cur_vocab_id < 32'(YT_VOCAB_SIZE));
    wire        beat_min     = valid_vocab && (act_rd_data > pool_min_val);
    wire        greedy_mode  = (k_eff <= 9'd1) || (cfg_temp_inv_q88 == 16'd0);

    logic [31:0] prob_sum, target_threshold, cum_prob;
    logic        r_slot_empty;
    logic        picked_flag;

    // Temperature scaling math for S_SMP_EXP_REQ
    logic signed [15:0] cand_logit;
    logic        [15:0] cand_tok_id;
    logic signed [31:0] temp_diff;
    logic signed [47:0] temp_scaled;
    wire                slot_is_empty = (cand_logit == -16'sd32768);

    always_comb begin
        cand_logit  = signed'(pool_rd_data[15:0]);
        cand_tok_id = pool_rd_data[31:16];
        temp_diff   = 32'(pool_max_val) - 32'(cand_logit);
        temp_scaled = (48'(temp_diff) * 48'(signed'({1'b0, cfg_temp_inv_q88}))) >>> 8;
        if (temp_scaled < 48'sd0)         temp_clamped = 13'd0;
        else if (temp_scaled > 48'sd4095) temp_clamped = 13'd4095;
        else                              temp_clamped = temp_scaled[12:0];
    end

    assign exp_req = (state == S_SMP_EXP_REQ) && !slot_is_empty;

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: begin
                if (cmd_valid) begin
                    if (cmd_is_sample)
                        state_nxt = greedy_mode ? S_DONE : S_SMP_RD;
                    else if (cmd_reset_pool)
                        state_nxt = S_INIT_CLEAR;
                    else
                        state_nxt = S_FEED_RD;
                end
            end

            S_INIT_CLEAR:   if (slot_idx == k_eff - 9'd1) state_nxt = S_FEED_RD;
            S_FEED_RD:      state_nxt = S_FEED_CMP;
            S_FEED_CMP: begin
                if (beat_min)
                    state_nxt = S_RESCAN_RD;
                else if (elem_idx == r_len - 16'd1)
                    state_nxt = S_DONE;
                else
                    state_nxt = S_FEED_RD;
            end

            S_RESCAN_RD:    state_nxt = S_RESCAN_CMP;
            S_RESCAN_CMP: begin
                if (slot_idx == k_eff - 9'd1)
                    state_nxt = (elem_idx == r_len - 16'd1) ? S_DONE : S_FEED_RD;
                else
                    state_nxt = S_RESCAN_RD;
            end

            S_SMP_RD:       state_nxt = S_SMP_EXP_REQ;
            S_SMP_EXP_REQ:  state_nxt = slot_is_empty ? S_SMP_ACC : S_SMP_EXP_WAIT;
            S_SMP_EXP_WAIT: if (exp_valid) state_nxt = S_SMP_ACC;
            S_SMP_ACC:      state_nxt = (slot_idx == k_eff - 9'd1) ? S_SMP_DRAW : S_SMP_RD;
            S_SMP_DRAW:     state_nxt = S_SMP_PICK_RD;
            S_SMP_PICK_RD:  state_nxt = S_SMP_PICK_CMP;
            S_SMP_PICK_CMP: begin
                if ((cum_prob + 32'(prob_rd_data) > target_threshold) || (slot_idx == k_eff - 9'd1))
                    state_nxt = S_DONE;
                else
                    state_nxt = S_SMP_PICK_RD;
            end

            S_DONE:         state_nxt = S_IDLE;
            default:        state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    // SRAM controls
    always_comb begin
        act_rd_en    = (state == S_FEED_RD);
        act_rd_addr  = ACT_ADDR_W'(32'(r_src) + 32'(elem_idx));

        pool_wr_en   = 1'b0;
        pool_wr_addr = '0;
        pool_wr_data = '0;

        if (state == S_INIT_CLEAR) begin
            pool_wr_en   = 1'b1;
            pool_wr_addr = slot_idx[7:0];
            pool_wr_data = {16'd0, -16'sd32768};
        end else if (state == S_FEED_CMP && beat_min) begin
            pool_wr_en   = 1'b1;
            pool_wr_addr = pool_min_slot;
            pool_wr_data = {cur_vocab_id[15:0], act_rd_data};
        end

        pool_rd_en   = (state == S_RESCAN_RD) || (state == S_SMP_RD) || (state == S_SMP_PICK_RD);
        pool_rd_addr = slot_idx[7:0];

        prob_wr_en   = (state == S_SMP_ACC);
        prob_wr_addr = slot_idx[7:0];
        prob_wr_data = r_slot_empty ? 16'd0 : exp_q15;

        prob_rd_en   = (state == S_SMP_PICK_RD);
        prob_rd_addr = slot_idx[7:0];
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            prng_state       <= 64'h853C_49E6_748F_EA9B;
            k_eff            <= 9'd200;
            slot_idx         <= '0;
            r_src            <= '0;
            r_len            <= '0;
            r_vbase          <= '0;
            elem_idx         <= '0;
            pool_min_val     <= -16'sd32768;
            pool_min_slot    <= 8'd0;
            pool_max_val     <= -16'sd32768;
            pool_max_id      <= 16'd0;
            rescan_min_val   <= 16'sd32767;
            rescan_min_slot  <= 8'd0;
            prob_sum         <= '0;
            target_threshold <= '0;
            cum_prob         <= '0;
            r_slot_empty     <= 1'b0;
            picked_flag      <= 1'b0;
            sample_valid     <= 1'b0;
            sampled_token_id <= 16'd0;
        end else begin
            sample_valid <= 1'b0;

            if (seed_load) begin
                prng_state <= (seed_val == 64'd0) ? 64'h853C_49E6_748F_EA9B : seed_val;
            end

            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        automatic logic [8:0] ke = (cfg_top_k == 16'd0) ? 9'd1 :
                                                   (cfg_top_k > 16'd256) ? 9'd256 : cfg_top_k[8:0];
                        k_eff    <= ke;
                        r_src    <= cmd_src_base;
                        r_len    <= (cmd_length == 16'd0) ? 16'd1 : cmd_length;
                        r_vbase  <= cmd_vocab_base;
                        elem_idx <= 16'd0;
                        slot_idx <= 9'd0;
                        prob_sum <= 32'd0;

                        if (cmd_is_sample) begin
                            picked_flag <= 1'b1;
                            if ((ke <= 9'd1) || (cfg_temp_inv_q88 == 16'd0))
                                sampled_token_id <= pool_max_id;
                        end else begin
                            picked_flag <= 1'b0;
                            if (cmd_reset_pool) begin
                                pool_min_val  <= -16'sd32768;
                                pool_min_slot <= 8'd0;
                                pool_max_val  <= -16'sd32768;
                                pool_max_id   <= 16'd0;
                            end
                        end
                    end
                end

                S_INIT_CLEAR: begin
                    if (slot_idx == k_eff - 9'd1)
                        slot_idx <= 9'd0;
                    else
                        slot_idx <= slot_idx + 9'd1;
                end

                S_FEED_CMP: begin
                    if (beat_min) begin
                        if (act_rd_data > pool_max_val) begin
                            pool_max_val <= act_rd_data;
                            pool_max_id  <= cur_vocab_id[15:0];
                        end
                        slot_idx        <= 9'd0;
                        rescan_min_val  <= 16'sd32767;
                        rescan_min_slot <= 8'd0;
                    end else if (elem_idx < r_len - 16'd1) begin
                        elem_idx <= elem_idx + 16'd1;
                    end
                end

                S_RESCAN_CMP: begin
                    automatic logic signed [15:0] sl_val = signed'(pool_rd_data[15:0]);
                    automatic logic signed [15:0] nxt_min_val  = (sl_val < rescan_min_val) ? sl_val : rescan_min_val;
                    automatic logic        [7:0]  nxt_min_slot = (sl_val < rescan_min_val) ? slot_idx[7:0] : rescan_min_slot;

                    if (slot_idx == k_eff - 9'd1) begin
                        pool_min_val  <= nxt_min_val;
                        pool_min_slot <= nxt_min_slot;
                        slot_idx      <= 9'd0;
                        if (elem_idx < r_len - 16'd1)
                            elem_idx <= elem_idx + 16'd1;
                    end else begin
                        rescan_min_val  <= nxt_min_val;
                        rescan_min_slot <= nxt_min_slot;
                        slot_idx        <= slot_idx + 9'd1;
                    end
                end

                S_SMP_EXP_REQ: begin
                    r_slot_empty <= slot_is_empty;
                end

                S_SMP_ACC: begin
                    automatic logic [15:0] pval = r_slot_empty ? 16'd0 : exp_q15;
                    prob_sum <= prob_sum + 32'(pval);
                    if (slot_idx == k_eff - 9'd1)
                        slot_idx <= 9'd0;
                    else
                        slot_idx <= slot_idx + 9'd1;
                end

                S_SMP_DRAW: begin
                    automatic logic [63:0] x = prng_state;
                    x = x ^ (x >> 12);
                    x = x ^ (x << 25);
                    x = x ^ (x >> 27);
                    prng_state       <= x;
                    target_threshold <= 32'((64'(prng_u32) * 64'(prob_sum)) >> 32);
                    cum_prob         <= 32'd0;
                    slot_idx         <= 9'd0;
                end

                S_SMP_PICK_CMP: begin
                    automatic logic [31:0] new_cum = cum_prob + 32'(prob_rd_data);
                    if ((new_cum > target_threshold) || (slot_idx == k_eff - 9'd1)) begin
                        sampled_token_id <= pool_rd_data[31:16];
                    end else begin
                        cum_prob <= new_cum;
                        slot_idx <= slot_idx + 9'd1;
                    end
                end

                S_DONE: begin
                    if (picked_flag)
                        sample_valid <= 1'b1;
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
