// =============================================================================
// Autonomous Story Token Generation Sequencer (yt_token_sequencer.sv)
// - Drives complete multi-token autoregressive story generation on-chip without
//   host CPU intervention!
// - Prefill Phase (cur_pos < prompt_len - 1): Executes Embeddings + 8 Blocks
//   to populate external DDR KV-cache while skipping the 50,257-vocab LM-head.
// - Generation Phase (cur_pos >= prompt_len - 1): Executes full model + Top-K
//   sampler, pushes generated token to host FIFO, appends to TOK_SRAM[cur_pos+1],
//   and stops automatically on <|endoftext|> (50256) or max_new_tokens!
// =============================================================================
`default_nettype none

module yt_token_sequencer
    import yt_npu_pkg::*;
(
    input  wire                   clk,
    input  wire                   rst_n,

    // Host Control & Config
    input  wire                   ctrl_start,
    input  wire                   ctrl_soft_rst,
    input  wire                   cfg_autogen_mode,
    input  wire  [9:0]            cfg_prompt_len,
    input  wire  [9:0]            cfg_max_new_tokens,

    // TOK_SRAM Interface (512 x 16-bit context token buffer)
    output logic                  seq_tok_rd_en,
    output logic [8:0]            seq_tok_rd_addr,
    input  wire  [15:0]           seq_tok_rd_data,

    output logic                  seq_tok_wr_en,
    output logic [8:0]            seq_tok_wr_addr,
    output logic [15:0]           seq_tok_wr_data,

    // Microcode Fetch / Decode Control
    output logic                  step_start,
    input  wire                   step_done_pulse,
    output logic                  prng_seed_load,

    // Dynamic Context Outputs to Decoder
    output logic [8:0]            cur_pos,
    output logic [15:0]           cur_tok_id,
    output logic                  is_prefill_skip_lm,

    // Top-K Sampler Result Input
    input  wire                   sample_valid,
    input  wire  [15:0]           sampled_token_id,

    // Generated Token Push -> Host AXI-Lite FIFO
    output logic                  gen_tok_push,
    output logic [15:0]           gen_tok_data,

    // Status Outputs
    output logic                  seq_busy,
    output logic                  seq_done_pulse,
    output logic                  seq_eot_hit,
    output logic [9:0]            seq_gen_count
);

    typedef enum logic [2:0] {
        SQ_IDLE,
        SQ_RD_TOK,
        SQ_LATCH_TOK,
        SQ_RUN_STEP,
        SQ_POST_STEP,
        SQ_DONE
    } sq_state_t;

    sq_state_t state;

    logic [9:0]  eff_prompt_len;
    logic        sample_seen_q;
    logic [15:0] last_sample_q;

    assign eff_prompt_len = (cfg_prompt_len == 10'd0) ? 10'd1 : cfg_prompt_len;

    assign seq_tok_rd_en   = (state == SQ_RD_TOK);
    assign seq_tok_rd_addr = cur_pos;
    assign seq_busy        = (state != SQ_IDLE);
    assign seq_done_pulse  = (state == SQ_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state              <= SQ_IDLE;
            step_start         <= 1'b0;
            prng_seed_load     <= 1'b0;
            cur_pos            <= 9'd0;
            cur_tok_id         <= 16'd0;
            is_prefill_skip_lm <= 1'b0;
            sample_seen_q      <= 1'b0;
            last_sample_q      <= 16'd0;
            seq_tok_wr_en      <= 1'b0;
            seq_tok_wr_addr    <= 9'd0;
            seq_tok_wr_data    <= 16'd0;
            gen_tok_push       <= 1'b0;
            gen_tok_data       <= 16'd0;
            seq_eot_hit        <= 1'b0;
            seq_gen_count      <= 10'd0;
        end else if (ctrl_soft_rst) begin
            state              <= SQ_IDLE;
            step_start         <= 1'b0;
            prng_seed_load     <= 1'b0;
            seq_tok_wr_en      <= 1'b0;
            gen_tok_push       <= 1'b0;
            seq_eot_hit        <= 1'b0;
            seq_gen_count      <= 10'd0;
        end else begin
            step_start     <= 1'b0;
            prng_seed_load <= 1'b0;
            seq_tok_wr_en  <= 1'b0;
            gen_tok_push   <= 1'b0;

            case (state)
                SQ_IDLE: begin
                    if (ctrl_start) begin
                        prng_seed_load <= 1'b1;
                        cur_pos        <= 9'd0;
                        seq_eot_hit    <= 1'b0;
                        seq_gen_count  <= 10'd0;
                        state          <= SQ_RD_TOK;
                    end
                end

                SQ_RD_TOK: begin
                    state <= SQ_LATCH_TOK;
                end

                SQ_LATCH_TOK: begin
                    cur_tok_id         <= seq_tok_rd_data;
                    is_prefill_skip_lm <= cfg_autogen_mode &&
                                          ({1'b0, cur_pos} < (eff_prompt_len - 10'd1));
                    sample_seen_q      <= 1'b0;
                    step_start         <= 1'b1;
                    state              <= SQ_RUN_STEP;
                end

                SQ_RUN_STEP: begin
                    if (sample_valid) begin
                        sample_seen_q <= 1'b1;
                        last_sample_q <= sampled_token_id;
                    end
                    if (step_done_pulse) begin
                        state <= SQ_POST_STEP;
                    end
                end

                SQ_POST_STEP: begin
                    if (!cfg_autogen_mode) begin
                        // Single-shot microcode co-processor execution
                        if (sample_seen_q) begin
                            gen_tok_push  <= 1'b1;
                            gen_tok_data  <= last_sample_q;
                            seq_gen_count <= 10'd1;
                            if (last_sample_q == YT_EOT_TOKEN)
                                seq_eot_hit <= 1'b1;
                        end
                        state <= SQ_DONE;
                    end else if (is_prefill_skip_lm) begin
                        // Prefill token completed -> advance to next prompt position
                        cur_pos <= cur_pos + 9'd1;
                        state   <= SQ_RD_TOK;
                    end else begin
                        // Newly sampled story token completed!
                        gen_tok_push  <= 1'b1;
                        gen_tok_data  <= last_sample_q;
                        seq_gen_count <= seq_gen_count + 10'd1;

                        if (last_sample_q == YT_EOT_TOKEN) begin
                            seq_eot_hit <= 1'b1;
                            state       <= SQ_DONE;
                        end else if (((seq_gen_count + 10'd1) >= cfg_max_new_tokens) ||
                                     (cur_pos == 9'd511)) begin
                            state       <= SQ_DONE;
                        end else begin
                            // Append generated token to context SRAM and run next step!
                            seq_tok_wr_en   <= 1'b1;
                            seq_tok_wr_addr <= cur_pos + 9'd1;
                            seq_tok_wr_data <= last_sample_q;
                            cur_pos         <= cur_pos + 9'd1;
                            state           <= SQ_RD_TOK;
                        end
                    end
                end

                SQ_DONE: begin
                    state <= SQ_IDLE;
                end

                default: state <= SQ_IDLE;
            endcase
        end
    end

endmodule

`default_nettype wire
