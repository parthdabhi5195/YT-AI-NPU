// =============================================================================
// 128-Bit Microcode Instruction Decoder, Loop Stack & Dynamic Address Generator
// (yt_ucode_decode.sv)
// - Implements 2-level hardware loop counters (L0, L1) via OP_LOOP_BEGIN/END
// - Dynamically computes DDR & SRAM addresses for tiled GEMM, Head loops,
//   4x512 FFN slices, zero-adder KV-cache append/read, and 786-tile LM-head
// - Dispatches collision-free commands to all 8 hardware engines
// =============================================================================
`default_nettype none

module yt_ucode_decode
    import yt_npu_pkg::*;
    import yt_isa_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,
    input  wire                       soft_rst,

    // Fetch Handshake
    input  wire                       instr_valid,
    input  wire  [127:0]              instr_data,
    input  wire  [UCODE_ADDR_W-1:0]   instr_pc,
    output logic                      decode_ready,
    output logic                      branch_valid,
    output logic [UCODE_ADDR_W-1:0]   branch_target,
    output logic                      step_abort,
    input  wire                       fetch_eof_pulse,

    // Step Completion Output to Token Sequencer
    output logic                      step_done_pulse,
    output logic                      err_invalid_op,

    // Dynamic Context from Host / Token Sequencer
    input  wire  [31:0]               cfg_ddr_base_wgt,
    input  wire  [31:0]               cfg_ddr_base_kv,
    input  wire  [31:0]               cfg_ddr_base_out,
    input  wire  [7:0]                cfg_lm_mult_u8,
    input  wire  [7:0]                cfg_lm_shift_u8,
    input  wire  [8:0]                cur_pos,
    input  wire  [15:0]               cur_tok_id,
    input  wire                       is_prefill_skip_lm,

    // Scoreboard Interface
    input  wire  [NUM_ENGINES-1:0]    engine_busy,
    input  wire                       all_idle,
    output logic                      sb_issue_valid,
    output logic [2:0]                sb_issue_engine_id,

    // 0: GEMM Engine Dispatch
    output logic                      gemm_cmd_valid,
    output logic [15:0]               gemm_src0,
    output logic [15:0]               gemm_src1,
    output logic [15:0]               gemm_dst,
    output logic [15:0]               gemm_M,
    output logic [15:0]               gemm_N,
    output logic [15:0]               gemm_K,
    output logic [7:0]                gemm_flags,
    output logic [15:0]               gemm_imm,

    // 1: Softmax Engine Dispatch
    output logic                      sm_cmd_valid,
    output logic [15:0]               sm_rows,
    output logic [15:0]               sm_length,
    output logic [15:0]               sm_src_base,
    output logic [15:0]               sm_dst_base,
    output logic                      sm_causal_en,
    output logic [15:0]               sm_causal_base,

    // 2: LayerNorm Engine Dispatch
    output logic                      ln_cmd_valid,
    output logic [15:0]               ln_rows,
    output logic [15:0]               ln_length,
    output logic [15:0]               ln_src_base,
    output logic [15:0]               ln_dst_base,
    output logic [15:0]               ln_param_base,

    // 3: GELU Engine Dispatch
    output logic                      gelu_cmd_valid,
    output logic [15:0]               gelu_rows,
    output logic [15:0]               gelu_length,
    output logic [15:0]               gelu_src_base,
    output logic [15:0]               gelu_dst_base,

    // 4: Vector / Copy2D Engine Dispatch
    output logic                      vec_cmd_valid,
    output logic [7:0]                vec_flags,
    output logic [15:0]               vec_M,
    output logic [15:0]               vec_N,
    output logic [15:0]               vec_K,
    output logic [15:0]               vec_imm,
    output logic [15:0]               vec_src0,
    output logic [15:0]               vec_src1,
    output logic [15:0]               vec_dst,

    // 5A: DMA Read Dispatch (OP_DMA_LOAD & OP_KV_READ)
    output logic                      dma_rd_cmd_valid,
    output logic [31:0]               dma_rd_ddr_addr,
    output logic [23:0]               dma_rd_byte_len,
    output logic [1:0]                dma_rd_target,
    output logic [15:0]               dma_rd_sram_base,

    // 5B: DMA Write Dispatch (OP_DMA_STORE & OP_KV_APPEND)
    output logic                      dma_wr_cmd_valid,
    output logic [1:0]                dma_wr_mode,
    output logic [31:0]               dma_wr_ddr_addr,
    output logic [23:0]               dma_wr_byte_len,
    output logic [15:0]               dma_wr_act_base,

    // 6: Embedding Engine Dispatch
    output logic                      emb_cmd_valid,
    output logic [15:0]               emb_length,
    output logic [15:0]               emb_dst_base,

    // 7: Top-K Sampler Engine Dispatch
    output logic                      topk_cmd_valid,
    output logic                      topk_is_sample,
    output logic                      topk_reset_pool,
    output logic [15:0]               topk_src_base,
    output logic [15:0]               topk_length,
    output logic [15:0]               topk_vocab_base
);

    wire _unused = &{instr_pc, 1'b0};

    ucode_instr_t d;
    assign d = decode_ucode(instr_data);

    // 2-Level Hardware Loop Counters
    logic [15:0] loop_idx_0, loop_cnt_0;
    logic [15:0] loop_idx_1, loop_cnt_1;

    // Pending EOF wait if program hits ucode_len without explicit OP_END
    logic wait_eof_idle_q;

    // Dynamic sequence length = cur_pos + 1 (1..512)
    wire [15:0] cur_seq_len = {7'd0, cur_pos} + 16'd1;

    // =========================================================================
    // Dynamic Address & Parameter Calculations
    // =========================================================================

    // 1. DMA Region Base + Static Offset + Loop Offset + Tok/Pos Index Offset
    logic [31:0] dma_region_base;
    logic [31:0] dma_static_off;
    logic [31:0] dma_loop_off;
    logic [31:0] dma_tokpos_off;
    logic [31:0] dma_full_addr;

    always_comb begin
        case (d.flags[4:2])
            DMA_REG_WTE:   dma_region_base = cfg_ddr_base_wgt + DDR_OFFSET_WTE;
            DMA_REG_WPE:   dma_region_base = cfg_ddr_base_wgt + DDR_OFFSET_WPE;
            DMA_REG_BLOCK: dma_region_base = cfg_ddr_base_wgt + DDR_OFFSET_BLOCKS;
            DMA_REG_LNF:   dma_region_base = cfg_ddr_base_wgt + DDR_OFFSET_LNF;
            DMA_REG_KV:    dma_region_base = cfg_ddr_base_kv;
            DMA_REG_OUT:   dma_region_base = cfg_ddr_base_out;
            default:       dma_region_base = cfg_ddr_base_wgt;
        endcase

        dma_static_off = {d.K, d.src1_base};

        case (d.flags[6:5])
            DMA_LOOP_L0:         dma_loop_off = 32'(loop_idx_0) * ({6'd0, d.imm, 10'd0});
            DMA_LOOP_L1:         dma_loop_off = 32'(loop_idx_1) * ({6'd0, d.imm, 10'd0});
            DMA_LOOP_L0_256K_L1: dma_loop_off = ({14'd0, loop_idx_0[1:0], 18'd0}) +
                                                32'(loop_idx_1) * ({6'd0, d.imm, 10'd0});
            default:             dma_loop_off = 32'd0;
        endcase

        if (d.flags[FLAG_DMA_DYN_INDEX]) begin
            if (d.flags[4:2] == DMA_REG_WTE)
                dma_tokpos_off = {7'd0, cur_tok_id, 9'd0}; // cur_tok_id * 512
            else if (d.flags[4:2] == DMA_REG_WPE)
                dma_tokpos_off = {14'd0, cur_pos, 9'd0};   // cur_pos * 512
            else
                dma_tokpos_off = 32'd0;
        end else begin
            dma_tokpos_off = 32'd0;
        end

        dma_full_addr = dma_region_base + dma_static_off + dma_loop_off + dma_tokpos_off;
    end

    // 2. Zero-Adder KV-Cache DDR Address ({layer[2:0], head[2:0], is_v, seq[8:0], 6'b0})
    wire [2:0]  kv_layer_id   = d.M[2:0];
    wire [2:0]  kv_head_id    = d.flags[FLAG_KV_LOOP_HEAD] ? loop_idx_0[2:0] : d.src1_base[2:0];
    wire        kv_is_v       = d.flags[FLAG_KV_IS_V];
    wire [8:0]  kv_append_pos = (d.N == 16'd0) ? cur_pos : d.K[8:0];
    wire [15:0] kv_append_rows= (d.N == 16'd0) ? 16'd1   : d.N;
    wire [15:0] kv_read_rows  = (d.N == 16'd0) ? cur_seq_len : d.N;

    wire [31:0] kv_append_addr = cfg_ddr_base_kv + {10'd0, kv_layer_id, kv_head_id, kv_is_v, kv_append_pos, 6'd0};
    wire [31:0] kv_read_addr   = cfg_ddr_base_kv + {10'd0, kv_layer_id, kv_head_id, kv_is_v, 9'd0, 6'd0};

    // 3. GEMM Dynamic Loop Offsets & Dynamic Sequence Dimensions
    wire [15:0] gemm_loop_idx  = d.imm[GEMM_IMM_LOOP_SEL_L1] ? loop_idx_1 : loop_idx_0;
    wire [15:0] gemm_dst_eff   = d.imm[GEMM_IMM_DST_LOOP64]  ? (d.dst_base  + (gemm_loop_idx << 6)) : d.dst_base;
    wire [15:0] gemm_src1_eff  = d.imm[GEMM_IMM_SRC1_LOOP64] ? (d.src1_base + (gemm_loop_idx << 6)) : d.src1_base;
    wire [15:0] gemm_N_eff     = (d.N == 16'd0) ? cur_seq_len : d.N;
    wire [15:0] gemm_K_eff     = (d.K == 16'd0) ? cur_seq_len : d.K;
    wire [12:0] gemm_quant_eff = (d.flags[FLAG_REQUANT] && (d.imm[12:0] == 13'd0))
                                 ? {cfg_lm_shift_u8[4:0], cfg_lm_mult_u8}
                                 : d.imm[12:0];

    // 4. Top-K Dynamic Vocab Base
    wire [15:0] topk_vbase_eff = d.flags[FLAG_TOPK_LOOP_L0]
                                 ? (d.src1_base + (loop_idx_0 << 6))
                                 : d.src1_base;

    // Note on ACT_SRAM / PARAM_SRAM hazard prevention:
    // Any two compute engines sharing ACT_SRAM (GEMM, Softmax, LayerNorm, GELU, Vec, Embed, TopK)
    // wait if another compute engine is busy, while ENG_DMA (WGT_SRAM ping-pong) can overlap!
    wire compute_any_busy = engine_busy[ENG_GEMM]      | engine_busy[ENG_SOFTMAX] |
                            engine_busy[ENG_LAYERNORM] | engine_busy[ENG_GELU]    |
                            engine_busy[ENG_VEC]       | engine_busy[ENG_EMBED]   |
                            engine_busy[ENG_TOPK];

    // Combinational Decode & Dispatch
    logic loop_push_en, loop_pop_en;

    always_comb begin
        decode_ready       = 1'b0;
        branch_valid       = 1'b0;
        branch_target      = d.dst_base[UCODE_ADDR_W-1:0];
        step_abort         = 1'b0;
        step_done_pulse    = 1'b0;
        err_invalid_op     = 1'b0;

        sb_issue_valid     = 1'b0;
        sb_issue_engine_id = ENG_GEMM;

        gemm_cmd_valid     = 1'b0;
        gemm_src0          = d.src0_base;
        gemm_src1          = gemm_src1_eff;
        gemm_dst           = gemm_dst_eff;
        gemm_M             = d.M;
        gemm_N             = gemm_N_eff;
        gemm_K             = gemm_K_eff;
        gemm_flags         = d.flags;
        gemm_imm           = {3'b000, gemm_quant_eff};

        sm_cmd_valid       = 1'b0;
        sm_rows            = d.M;
        sm_length          = (d.N == 16'd0) ? cur_seq_len : d.N;
        sm_src_base        = d.src0_base;
        sm_dst_base        = d.dst_base;
        sm_causal_en       = d.flags[FLAG_CAUSAL_MASK];
        sm_causal_base     = d.K;

        ln_cmd_valid       = 1'b0;
        ln_rows            = d.M;
        ln_length          = d.N;
        ln_src_base        = d.src0_base;
        ln_dst_base        = d.dst_base;
        ln_param_base      = d.src1_base;

        gelu_cmd_valid     = 1'b0;
        gelu_rows          = d.M;
        gelu_length        = d.N;
        gelu_src_base      = d.src0_base;
        gelu_dst_base      = d.dst_base;

        vec_cmd_valid      = 1'b0;
        vec_flags          = d.flags;
        vec_M              = d.M;
        vec_N              = d.N;
        vec_K              = d.K;
        vec_imm            = d.imm;
        vec_src0           = d.src0_base;
        vec_src1           = d.src1_base;
        vec_dst            = d.dst_base;

        dma_rd_cmd_valid   = 1'b0;
        dma_rd_ddr_addr    = dma_full_addr;
        dma_rd_byte_len    = {8'd0, d.N};
        dma_rd_target      = d.flags[1:0];
        dma_rd_sram_base   = d.dst_base;

        dma_wr_cmd_valid   = 1'b0;
        dma_wr_mode        = 2'd0;
        dma_wr_ddr_addr    = dma_full_addr;
        dma_wr_byte_len    = {8'd0, d.N};
        dma_wr_act_base    = d.src0_base;

        emb_cmd_valid      = 1'b0;
        emb_length         = d.N;
        emb_dst_base       = d.dst_base;

        topk_cmd_valid     = 1'b0;
        topk_is_sample     = 1'b0;
        topk_reset_pool    = d.flags[FLAG_TOPK_RESET];
        topk_src_base      = d.src0_base;
        topk_length        = d.N;
        topk_vocab_base    = topk_vbase_eff;

        loop_push_en       = 1'b0;
        loop_pop_en        = 1'b0;

        if (wait_eof_idle_q && all_idle) begin
            step_done_pulse = 1'b1;
        end else if (instr_valid) begin
            case (opcode_t'(d.opcode))
                OP_NOP: begin
                    decode_ready = 1'b1;
                end

                OP_LOOP_BEGIN: begin
                    decode_ready = 1'b1;
                    loop_push_en = 1'b1;
                end

                OP_LOOP_END: begin
                    decode_ready = 1'b1;
                    loop_pop_en  = 1'b1;
                    if (!d.flags[0])
                        branch_valid = ((loop_idx_0 + 16'd1) < loop_cnt_0);
                    else
                        branch_valid = ((loop_idx_1 + 16'd1) < loop_cnt_1);
                end

                OP_BARRIER: begin
                    if (all_idle) begin
                        decode_ready = 1'b1;
                        if (d.flags[FLAG_BARRIER_PREFILL_EXIT] && is_prefill_skip_lm) begin
                            step_abort      = 1'b1;
                            step_done_pulse = 1'b1;
                        end
                    end
                end

                OP_END: begin
                    if (all_idle) begin
                        decode_ready    = 1'b1;
                        step_abort      = 1'b1;
                        step_done_pulse = 1'b1;
                    end
                end

                OP_DMA_LOAD: begin
                    // WGT_SRAM loads can overlap compute; PARAM/ACT loads wait for compute idle
                    if (!engine_busy[ENG_DMA] &&
                        ((d.flags[1:0] == DMA_TGT_WGT0) || (d.flags[1:0] == DMA_TGT_WGT1) || !compute_any_busy)) begin
                        decode_ready       = 1'b1;
                        dma_rd_cmd_valid   = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_DMA;
                    end
                end

                OP_KV_READ: begin
                    if (!engine_busy[ENG_DMA]) begin
                        decode_ready       = 1'b1;
                        dma_rd_cmd_valid   = 1'b1;
                        dma_rd_ddr_addr    = kv_read_addr;
                        dma_rd_byte_len    = {2'd0, kv_read_rows, 6'd0}; // rows * 64 bytes
                        dma_rd_target      = d.flags[2] ? DMA_TGT_WGT1 : DMA_TGT_WGT0;
                        dma_rd_sram_base   = d.dst_base;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_DMA;
                    end
                end

                OP_DMA_STORE: begin
                    if (!engine_busy[ENG_DMA] && !compute_any_busy) begin
                        decode_ready       = 1'b1;
                        dma_wr_cmd_valid   = 1'b1;
                        dma_wr_mode        = 2'd0;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_DMA;
                    end
                end

                OP_KV_APPEND: begin
                    if (!engine_busy[ENG_DMA] && !compute_any_busy) begin
                        decode_ready       = 1'b1;
                        dma_wr_cmd_valid   = 1'b1;
                        dma_wr_mode        = 2'd1;
                        dma_wr_ddr_addr    = kv_append_addr;
                        dma_wr_byte_len    = {2'd0, kv_append_rows, 6'd0}; // rows * 64 bytes
                        dma_wr_act_base    = d.src0_base;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_DMA;
                    end
                end

                OP_GEMM: begin
                    if (!compute_any_busy) begin
                        decode_ready       = 1'b1;
                        gemm_cmd_valid     = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_GEMM;
                    end
                end

                OP_SOFTMAX: begin
                    if (!compute_any_busy) begin
                        decode_ready       = 1'b1;
                        sm_cmd_valid       = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_SOFTMAX;
                    end
                end

                OP_LAYERNORM: begin
                    if (!compute_any_busy) begin
                        decode_ready       = 1'b1;
                        ln_cmd_valid       = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_LAYERNORM;
                    end
                end

                OP_GELU: begin
                    if (!compute_any_busy) begin
                        decode_ready       = 1'b1;
                        gelu_cmd_valid     = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_GELU;
                    end
                end

                OP_VEC: begin
                    if (!compute_any_busy) begin
                        decode_ready       = 1'b1;
                        vec_cmd_valid      = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_VEC;
                    end
                end

                OP_EMBED: begin
                    if (!compute_any_busy && !engine_busy[ENG_DMA]) begin
                        decode_ready       = 1'b1;
                        emb_cmd_valid      = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_EMBED;
                    end
                end

                OP_TOPK_FEED: begin
                    if (!compute_any_busy) begin
                        decode_ready       = 1'b1;
                        topk_cmd_valid     = 1'b1;
                        topk_is_sample     = 1'b0;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_TOPK;
                    end
                end

                OP_TOPK_SAMPLE: begin
                    if (!compute_any_busy) begin
                        decode_ready       = 1'b1;
                        topk_cmd_valid     = 1'b1;
                        topk_is_sample     = 1'b1;
                        sb_issue_valid     = 1'b1;
                        sb_issue_engine_id = ENG_TOPK;
                    end
                end

                default: begin
                    decode_ready   = 1'b1;
                    err_invalid_op = 1'b1;
                end
            endcase
        end
    end

    // Sequential Loop Stack & EOF Wait State
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            loop_idx_0      <= 16'd0;
            loop_cnt_0      <= 16'd0;
            loop_idx_1      <= 16'd0;
            loop_cnt_1      <= 16'd0;
            wait_eof_idle_q <= 1'b0;
        end else if (soft_rst || step_abort) begin
            loop_idx_0      <= 16'd0;
            loop_cnt_0      <= 16'd0;
            loop_idx_1      <= 16'd0;
            loop_cnt_1      <= 16'd0;
            wait_eof_idle_q <= 1'b0;
        end else begin
            if (fetch_eof_pulse)
                wait_eof_idle_q <= 1'b1;
            else if (wait_eof_idle_q && all_idle)
                wait_eof_idle_q <= 1'b0;

            if (loop_push_en) begin
                if (!d.flags[0]) begin
                    loop_idx_0 <= 16'd0;
                    loop_cnt_0 <= d.M;
                end else begin
                    loop_idx_1 <= 16'd0;
                    loop_cnt_1 <= d.M;
                end
            end else if (loop_pop_en) begin
                if (!d.flags[0]) begin
                    if ((loop_idx_0 + 16'd1) < loop_cnt_0)
                        loop_idx_0 <= loop_idx_0 + 16'd1;
                    else
                        loop_idx_0 <= 16'd0;
                end else begin
                    if ((loop_idx_1 + 16'd1) < loop_cnt_1)
                        loop_idx_1 <= loop_idx_1 + 16'd1;
                    else
                        loop_idx_1 <= 16'd0;
                end
            end
        end
    end

endmodule

`default_nettype wire
