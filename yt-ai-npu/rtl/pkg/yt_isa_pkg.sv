// =============================================================================
// YT-AI NPU Microcode ISA Package (yt_isa_pkg.sv)
// 128-bit Fixed-Width Microcode Instruction Set with Hardware Loops,
// Tiled Weight Streaming, KV-Cache Management, & Top-K Token Sampling
// =============================================================================
`ifndef YT_ISA_PKG_SV
`define YT_ISA_PKG_SV

package yt_isa_pkg;

    parameter int INSTR_W = 128; // instruction size in bits

    // =========================================================================
    // Opcodes (8-bit)
    // Basically what engine to run
    // =========================================================================
    typedef enum logic [7:0] {
        OP_NOP          = 8'h00, // do nothing
        OP_DMA_LOAD     = 8'h01, // AXI4 burst DDR -> WGT_SRAM / PARAM_SRAM / ACT_SRAM
        OP_DMA_STORE    = 8'h02, // AXI4 burst ACT_SRAM -> DDR
        OP_GEMM         = 8'h03, // W8A16 16x16 Systolic GEMM (M>1) / Fast 128b GEMV (M=1)
        OP_VEC          = 8'h04, // Q7.8 Elementwise ADD, MUL, SCALE_SHIFT, COPY2D
        OP_SOFTMAX      = 8'h05, // 3-pass 512-context Causal Softmax -> Q0.15
        OP_LAYERNORM    = 8'h06, // Divider-free Q7.8 LayerNorm w/ learned Q4.12 gamma & Q7.8 beta
        OP_GELU         = 8'h07, // Piecewise + 256-entry LUT Q7.8 GELU
        OP_KV_APPEND    = 8'h08, // Pack Q7.8 K/V -> Q4.3 INT8 and burst write to DDR KV-cache
        OP_KV_READ      = 8'h09, // Burst read cached Q4.3 INT8 K/V [0..T] into WGT_SRAM
        OP_BARRIER      = 8'h0A, // Wait until scoreboard all_idle
        OP_EMBED        = 8'h0B, // Lookup WTE[tok] + WPE[pos] from DDR, dequant & sum -> ACT_SRAM
        OP_TOPK_FEED    = 8'h0C, // Stream Q7.8 logit tile into 256-entry Hardware Top-K tracker
        OP_TOPK_SAMPLE  = 8'h0D, // Temperature + exp_lut + Xoroshiro64** PRNG sample -> TOK_SRAM
        OP_LOOP_BEGIN   = 8'h0E, // Push loop counter (M=iterations, flags[0]=loop_id 0..1)
        OP_LOOP_END     = 8'h0F, // Decrement loop counter & branch to dst_base if > 0
        OP_END          = 8'hFF  // End of microcode program
    } opcode_t;

    // =========================================================================
    // OP_GEMM Flag Bits (instr.flags[7:0])
    // 8 on/off mode switches specific to that opcode
    // You can have multiple flags per opcoded
    // =========================================================================
    parameter int FLAG_TRANSPOSE_B = 0; // 1: B stored as [N, K] (row-per-output, fast 128b GEMV!)
    parameter int FLAG_BIAS_EN     = 1; // 1: Add INT32 bias from PARAM_SRAM[K_bias_base + n]
    parameter int FLAG_REQUANT     = 2; // 1: Apply (acc * mult_u8) >>> shift -> Q7.8
    parameter int FLAG_ACCUMULATE  = 3; // 1: Add output to existing Q7.8 value in ACT_SRAM[dst]
    parameter int FLAG_PINGPONG_B  = 4; // 0: Read WGT_SRAM bank 0, 1: Read WGT_SRAM bank 1
    parameter int FLAG_KV_PACK     = 5; // 1: Also pack Q4.3 INT8 output to WGT_SRAM scratch
    parameter int FLAG_ATTN_SCORE  = 6; // 1: Attention score scaling ((acc + 32) >>> 6)
    parameter int FLAG_ATTN_CTX    = 7; // 1: Attention context scaling ((acc + 512) >>> 10)

    // =========================================================================
    // OP_DMA (Direct Memory Access) Flag Bits (instr.flags[7:0])
    // =========================================================================
    // flags[1:0]: Target on-chip memory
    // picks destination SRAm
    parameter logic [1:0] DMA_TGT_WGT0  = 2'd0; // WGT_SRAM Bank 0 (16 KB)
    parameter logic [1:0] DMA_TGT_WGT1  = 2'd1; // WGT_SRAM Bank 1 (16 KB)
    parameter logic [1:0] DMA_TGT_PARAM = 2'd2; // PARAM_SRAM (8 KB, 32-bit words)
    parameter logic [1:0] DMA_TGT_ACT   = 2'd3; // ACT_SRAM (32 KB, 16-bit words)

    // flags[4:2]: External DDR region selector
    // Picks DDR region
    parameter logic [2:0] DMA_REG_WTE    = 3'd0; // DDR_BASE_WGT + DDR_OFFSET_WTE
    parameter logic [2:0] DMA_REG_WPE    = 3'd1; // DDR_BASE_WGT + DDR_OFFSET_WPE
    parameter logic [2:0] DMA_REG_BLOCK  = 3'd2; // DDR_BASE_WGT + DDR_OFFSET_BLOCKS + layer*STRIDE
    parameter logic [2:0] DMA_REG_LNF    = 3'd3; // DDR_BASE_WGT + DDR_OFFSET_LNF
    parameter logic [2:0] DMA_REG_KV     = 3'd4; // DDR_BASE_KV
    parameter logic [2:0] DMA_REG_OUT    = 3'd5; // DDR_BASE_OUT

    // flags[6:5]: Dynamic loop stride mode (adds loop_idx * stride to DDR offset)
    // auto add loop stride offset
    // When this OP_DMA_LOAD sits inside a hardware for loop (OP_LOOP_BEGIN /OP_LOOP_END),
    // how many bytes should the DDR address jump formward on each iteration.
    parameter logic [1:0] DMA_LOOP_NONE       = 2'd0;
    parameter logic [1:0] DMA_LOOP_L0         = 2'd1; // Add loop_counter[0] * {imm, 10'b0} (basically imm * 1024) imm is bits[127:112] used for 8 attention heads
    parameter logic [1:0] DMA_LOOP_L1         = 2'd2; // Add loop_counter[1] * {imm, 10'b0}
    parameter logic [1:0] DMA_LOOP_L0_256K_L1 = 2'd3; // Add loop_counter[0] * 262144 (512x512 INT8 weight matrix) + loop_counter[1]* (imm * 1024). 2d array to loop over [slice][title] like MLP weights
    parameter int         FLAG_DMA_DYN_INDEX  = 7;    // Add cur_tok_id*512 (WTE) or cur_pos*512 (WPE)

    // =========================================================================
    // GEMM Loop-Offset Immediate Bits (instr.imm[15:13])
    // =========================================================================
    parameter int GEMM_IMM_DST_LOOP64  = 13; // Add active_loop_idx * 64 to cmd_dst
    parameter int GEMM_IMM_SRC1_LOOP64 = 14; // Add active_loop_idx * 64 to cmd_src1
    parameter int GEMM_IMM_LOOP_SEL_L1 = 15; // 0: active_loop_idx = L0, 1: active_loop_idx = L1

    // =========================================================================
    // VEC Sub-Operations (instr.flags[2:0])
    // =========================================================================
    parameter logic [1:0] VEC_OP_ADD         = 2'd0;
    parameter logic [1:0] VEC_OP_MUL         = 2'd1;
    parameter logic [1:0] VEC_OP_SCALE_SHIFT = 2'd2;
    parameter logic [1:0] VEC_OP_CLAMP       = 2'd3;
    parameter int         FLAG_VEC_COPY2D    = 2;    // flags[2] = 1 -> 2D strided copy

    // =========================================================================
    // Softmax / KV / Barrier / Top-K Flag Bits
    // =========================================================================
    parameter int FLAG_CAUSAL_MASK          = 4; // Softmax: mask col > causal_limit
    parameter int FLAG_KV_IS_V              = 0; // KV_APPEND / KV_READ: 0=K-cache, 1=V-cache
    parameter int FLAG_KV_LOOP_HEAD         = 1; // KV_APPEND / KV_READ: head_id = loop_idx_0[2:0]
    parameter int FLAG_BARRIER_PREFILL_EXIT = 0; // BARRIER: end step early if prefill (cur_pos < prompt_len-1)
    parameter int FLAG_TOPK_RESET           = 0; // TOPK_FEED: reset Top-K buffer before feeding tile
    parameter int FLAG_TOPK_LOOP_L0         = 1; // TOPK_FEED: add loop_idx_0 * 64 to vocab_base

    // =========================================================================
    // 128-bit Instruction Packed Struct
    // =========================================================================
    // [127:112] imm       : GEMM {shift[7:0], mult[7:0]} | COPY2D dst_stride | DMA loop_stride_kb
    // [111:96]  K         : GEMM inner dim | Softmax causal_limit | COPY2D src_stride | DMA ddr_hi16
    // [95:80]   N         : GEMM cols | Vec/LN/Softmax/GELU length | DMA byte_len
    // [79:64]   M         : GEMM rows | Softmax/LN rows | Loop count | KV layer_id
    // [63:48]   src1_base : GEMM weight/bias addr | LN param_base | Vec src1 | DMA ddr_lo16
    // [47:32]   src0_base : Input ACT_SRAM base
    // [31:16]   dst_base  : Output ACT_SRAM / SRAM base | LOOP_END target PC
    // [15:8]    flags     : Operation mode flags
    // [7:0]     opcode    : Engine opcode
    typedef struct packed {
        logic [15:0] imm;
        logic [15:0] K;
        logic [15:0] N;
        logic [15:0] M;
        logic [15:0] src1_base;
        logic [15:0] src0_base;
        logic [15:0] dst_base;
        logic [7:0]  flags;
        logic [7:0]  opcode;
    } ucode_instr_t;

    function automatic ucode_instr_t decode_ucode(input logic [127:0] raw);
        ucode_instr_t d;
        d.opcode    = raw[7:0];
        d.flags     = raw[15:8];
        d.dst_base  = raw[31:16];
        d.src0_base = raw[47:32];
        d.src1_base = raw[63:48];
        d.M         = raw[79:64];
        d.N         = raw[95:80];
        d.K         = raw[111:96];
        d.imm       = raw[127:112];
        return d;
    endfunction

endpackage

`endif
