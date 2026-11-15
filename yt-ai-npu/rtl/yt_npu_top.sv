// =============================================================================
// YT-AI Custom Silicon NPU Top-Level SoC Macro (yt_npu_top.sv)
// - Autonomous Inference & Story-Generation Processor for the 51,213,824-Param
//   YT-AI Small Language Model (8 Layers, 8 Heads, 512 Hidden, 2048 FFN, 50257 Vocab)
// - 100% Synthesizable RTL — ZERO stub engines, ZERO floating-point, ZERO dividers!
// - Compute: 16x16 W8A16 Systolic Array (256 MACs = 51.2 GOPS @ 100 MHz SKY130)
// - On-Chip SRAM: 91 KB Total (32 KB ACT + 32 KB Ping-Pong WGT/KV + 8 KB PARAM
//   + 16 KB UCODE + 1 KB TOK + 3.5 KB Engine Scratch)
// - Interfaces: 32-bit AXI4-Lite Host Control + 128-bit AXI4 Burst DDR4/LPDDR4 Master
// =============================================================================
`default_nettype none

module yt_npu_top
    import yt_npu_pkg::*;
    import yt_isa_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    // =========================================================================
    // AXI4-Lite Slave Interface (Host CPU / Microcontroller Control & Token I/O)
    // =========================================================================
    input  wire  [AXIL_ADDR_W-1:0]    s_axil_awaddr,
    input  wire  [2:0]                s_axil_awprot,
    input  wire                       s_axil_awvalid,
    output wire                       s_axil_awready,

    input  wire  [AXIL_DATA_W-1:0]    s_axil_wdata,
    input  wire  [AXIL_DATA_W/8-1:0]  s_axil_wstrb,
    input  wire                       s_axil_wvalid,
    output wire                       s_axil_wready,

    output wire  [1:0]                s_axil_bresp,
    output wire                       s_axil_bvalid,
    input  wire                       s_axil_bready,

    input  wire  [AXIL_ADDR_W-1:0]    s_axil_araddr,
    input  wire  [2:0]                s_axil_arprot,
    input  wire                       s_axil_arvalid,
    output wire                       s_axil_arready,

    output wire  [AXIL_DATA_W-1:0]    s_axil_rdata,
    output wire  [1:0]                s_axil_rresp,
    output wire                       s_axil_rvalid,
    input  wire                       s_axil_rready,

    // =========================================================================
    // 128-Bit AXI4 Master Interface (External DDR Weights & 4 MB KV-Cache)
    // =========================================================================
    // Read Address Channel
    output wire  [AXI_ID_W-1:0]       m_axi_arid,
    output wire  [AXI_ADDR_W-1:0]     m_axi_araddr,
    output wire  [7:0]                m_axi_arlen,
    output wire  [2:0]                m_axi_arsize,
    output wire  [1:0]                m_axi_arburst,
    output wire                       m_axi_arvalid,
    input  wire                       m_axi_arready,

    // Read Data Channel
    input  wire  [AXI_ID_W-1:0]       m_axi_rid,
    input  wire  [AXI_DATA_W-1:0]     m_axi_rdata,
    input  wire  [1:0]                m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output wire                       m_axi_rready,

    // Write Address Channel
    output wire  [AXI_ID_W-1:0]       m_axi_awid,
    output wire  [AXI_ADDR_W-1:0]     m_axi_awaddr,
    output wire  [7:0]                m_axi_awlen,
    output wire  [2:0]                m_axi_awsize,
    output wire  [1:0]                m_axi_awburst,
    output wire                       m_axi_awvalid,
    input  wire                       m_axi_awready,

    // Write Data Channel
    output wire  [AXI_DATA_W-1:0]     m_axi_wdata,
    output wire  [AXI_STRB_W-1:0]     m_axi_wstrb,
    output wire                       m_axi_wlast,
    output wire                       m_axi_wvalid,
    input  wire                       m_axi_wready,

    // Write Response Channel
    input  wire  [AXI_ID_W-1:0]       m_axi_bid,
    input  wire  [1:0]                m_axi_bresp,
    input  wire                       m_axi_bvalid,
    output wire                       m_axi_bready,

    // =========================================================================
    // Host Completion Interrupt
    // =========================================================================
    output wire                       irq
);

    // =========================================================================
    // Internal Control & Configuration Wires
    // =========================================================================
    wire                      ctrl_start;
    wire                      ctrl_soft_rst;
    wire                      cfg_autogen_mode;
    wire [UCODE_ADDR_W:0]     cfg_ucode_len;
    wire [31:0]               cfg_ddr_base_wgt;
    wire [31:0]               cfg_ddr_base_kv;
    wire [31:0]               cfg_ddr_base_out;
    wire [9:0]                cfg_prompt_len;
    wire [9:0]                cfg_max_new_tokens;
    wire [15:0]               cfg_temp_inv_q88;
    wire [15:0]               cfg_top_k;
    wire [63:0]               cfg_rng_seed;
    wire [15:0]               cfg_wte_deq_u16;
    wire [15:0]               cfg_wpe_deq_u16;
    wire [7:0]                cfg_lm_mult_u8;
    wire [7:0]                cfg_lm_shift_u8;

    // Prompt & Microcode Host Load Ports
    wire                      prompt_wr_en;
    wire [8:0]                prompt_wr_addr;
    wire [15:0]               prompt_wr_data;

    wire                      ucode_wr_en;
    wire [UCODE_ADDR_W-1:0]   ucode_wr_addr;
    wire [127:0]              ucode_wr_data;

    // Token Sequencer <-> Fetch/Decode/FIFO Wires
    wire                      seq_busy;
    wire                      seq_done_pulse;
    wire                      seq_eot_hit;
    wire [9:0]                seq_gen_count;
    wire                      gen_tok_push;
    wire [15:0]               gen_tok_data;

    wire                      seq_tok_rd_en;
    wire [8:0]                seq_tok_rd_addr;
    wire [15:0]               seq_tok_rd_data;
    wire                      seq_tok_wr_en;
    wire [8:0]                seq_tok_wr_addr;
    wire [15:0]               seq_tok_wr_data;

    wire                      step_start;
    wire                      step_abort;
    wire                      step_done_pulse;
    wire                      prng_seed_load;
    wire [8:0]                cur_pos;
    wire [15:0]               cur_tok_id;
    wire                      is_prefill_skip_lm;

    // Fetch <-> Decode <-> Scoreboard Wires
    wire                      ucode_rd_en;
    wire [UCODE_ADDR_W-1:0]   ucode_rd_addr;
    wire [127:0]              ucode_rd_data;

    wire                      instr_valid;
    wire [127:0]              instr_data;
    wire [UCODE_ADDR_W-1:0]   instr_pc;
    wire                      decode_ready;
    wire                      branch_valid;
    wire [UCODE_ADDR_W-1:0]   branch_target;
    wire                      fetch_eof_pulse;
    wire                      fetch_active;
    wire                      err_invalid_op;

    wire                      sb_issue_valid;
    wire [2:0]                sb_issue_engine_id;
    wire [NUM_ENGINES-1:0]    engine_done;
    wire [NUM_ENGINES-1:0]    engine_busy;
    wire                      all_idle;

    wire _unused_top = &{fetch_active, 1'b0};

    // =========================================================================
    // Engine Command & Status Wires
    // =========================================================================
    // 0: GEMM
    wire                      gemm_cmd_valid;
    wire [15:0]               gemm_src0, gemm_src1, gemm_dst;
    wire [15:0]               gemm_M, gemm_N, gemm_K, gemm_imm;
    wire [7:0]                gemm_flags;
    wire                      gemm_busy, gemm_done;

    // 1: Softmax
    wire                      sm_cmd_valid, sm_causal_en;
    wire [15:0]               sm_rows, sm_length, sm_src_base, sm_dst_base, sm_causal_base;
    wire                      sm_busy, sm_done;

    // 2: LayerNorm
    wire                      ln_cmd_valid;
    wire [15:0]               ln_rows, ln_length, ln_src_base, ln_dst_base, ln_param_base;
    wire                      ln_busy, ln_done;

    // 3: GELU
    wire                      gelu_cmd_valid;
    wire [15:0]               gelu_rows, gelu_length, gelu_src_base, gelu_dst_base;
    wire                      gelu_busy, gelu_done;

    // 4: Vector / Copy2D
    wire                      vec_cmd_valid;
    wire [7:0]                vec_flags;
    wire [15:0]               vec_M, vec_N, vec_K, vec_imm, vec_src0, vec_src1, vec_dst;
    wire                      vec_busy, vec_done;

    // 5: DMA Read & Write
    wire                      dma_rd_cmd_valid;
    wire [31:0]               dma_rd_ddr_addr;
    wire [23:0]               dma_rd_byte_len;
    wire [1:0]                dma_rd_target;
    wire [15:0]               dma_rd_sram_base;
    wire                      dma_rd_busy, dma_rd_done, dma_rd_err;

    wire                      dma_wr_cmd_valid;
    wire [1:0]                dma_wr_mode;
    wire [31:0]               dma_wr_ddr_addr;
    wire [23:0]               dma_wr_byte_len;
    wire [15:0]               dma_wr_act_base;
    wire                      dma_wr_busy, dma_wr_done, dma_wr_err;

    // 6: Embedding
    wire                      emb_cmd_valid;
    wire [15:0]               emb_length, emb_dst_base;
    wire                      emb_busy, emb_done;

    // 7: Top-K Sampler
    wire                      topk_cmd_valid, topk_is_sample, topk_reset_pool;
    wire [15:0]               topk_src_base, topk_length, topk_vocab_base;
    wire                      sample_valid;
    wire [15:0]               sampled_token_id;
    wire                      topk_busy, topk_done;

    wire _unused_busy = &{gemm_busy, sm_busy, ln_busy, gelu_busy, vec_busy,
                          dma_rd_busy, dma_wr_busy, emb_busy, topk_busy, 1'b0};

    assign engine_done[ENG_GEMM]      = gemm_done;
    assign engine_done[ENG_SOFTMAX]   = sm_done;
    assign engine_done[ENG_LAYERNORM] = ln_done;
    assign engine_done[ENG_GELU]      = gelu_done;
    assign engine_done[ENG_VEC]       = vec_done;
    assign engine_done[ENG_DMA]       = dma_rd_done | dma_wr_done;
    assign engine_done[ENG_EMBED]     = emb_done;
    assign engine_done[ENG_TOPK]      = topk_done;

    wire status_err_pulse = err_invalid_op | dma_rd_err | dma_wr_err;

    // =========================================================================
    // Shared On-Chip SRAM Signals & Priority Multiplexers
    // =========================================================================

    // 1. ACT_SRAM (16,384 x 16-bit Q7.8 = 32 KB)
    logic                      act_rd_en, act_wr_en;
    logic [ACT_ADDR_W-1:0]     act_rd_addr, act_wr_addr;
    wire  signed [15:0]        act_rd_data;
    logic signed [15:0]        act_wr_data;

    wire                      gemm_act_rd_en, gemm_act_wr_en;
    wire [ACT_ADDR_W-1:0]     gemm_act_rd_addr, gemm_act_wr_addr;
    wire signed [15:0]        gemm_act_wr_data;

    wire                      sm_act_rd_en, sm_act_wr_en;
    wire [ACT_ADDR_W-1:0]     sm_act_rd_addr, sm_act_wr_addr;
    wire signed [15:0]        sm_act_wr_data;

    wire                      ln_act_rd_en, ln_act_wr_en;
    wire [ACT_ADDR_W-1:0]     ln_act_rd_addr, ln_act_wr_addr;
    wire signed [15:0]        ln_act_wr_data;

    wire                      gelu_act_rd_en, gelu_act_wr_en;
    wire [ACT_ADDR_W-1:0]     gelu_act_rd_addr, gelu_act_wr_addr;
    wire signed [15:0]        gelu_act_wr_data;

    wire                      vec_act_rd_en, vec_act_wr_en;
    wire [ACT_ADDR_W-1:0]     vec_act_rd_addr, vec_act_wr_addr;
    wire signed [15:0]        vec_act_wr_data;

    wire                      emb_act_wr_en;
    wire [ACT_ADDR_W-1:0]     emb_act_wr_addr;
    wire signed [15:0]        emb_act_wr_data;

    wire                      topk_act_rd_en;
    wire [ACT_ADDR_W-1:0]     topk_act_rd_addr;

    wire                      dmard_act_wr_en;
    wire [ACT_ADDR_W-1:0]     dmard_act_wr_addr;
    wire signed [15:0]        dmard_act_wr_data;

    wire                      dmawr_act_rd_en;
    wire [ACT_ADDR_W-1:0]     dmawr_act_rd_addr;

    always_comb begin
        // ACT_SRAM Read Arbiter
        if (gemm_act_rd_en) begin
            act_rd_en   = 1'b1;
            act_rd_addr = gemm_act_rd_addr;
        end else if (sm_act_rd_en) begin
            act_rd_en   = 1'b1;
            act_rd_addr = sm_act_rd_addr;
        end else if (ln_act_rd_en) begin
            act_rd_en   = 1'b1;
            act_rd_addr = ln_act_rd_addr;
        end else if (gelu_act_rd_en) begin
            act_rd_en   = 1'b1;
            act_rd_addr = gelu_act_rd_addr;
        end else if (vec_act_rd_en) begin
            act_rd_en   = 1'b1;
            act_rd_addr = vec_act_rd_addr;
        end else if (topk_act_rd_en) begin
            act_rd_en   = 1'b1;
            act_rd_addr = topk_act_rd_addr;
        end else if (dmawr_act_rd_en) begin
            act_rd_en   = 1'b1;
            act_rd_addr = dmawr_act_rd_addr;
        end else begin
            act_rd_en   = 1'b0;
            act_rd_addr = '0;
        end

        // ACT_SRAM Write Arbiter
        if (gemm_act_wr_en) begin
            act_wr_en   = 1'b1;
            act_wr_addr = gemm_act_wr_addr;
            act_wr_data = gemm_act_wr_data;
        end else if (sm_act_wr_en) begin
            act_wr_en   = 1'b1;
            act_wr_addr = sm_act_wr_addr;
            act_wr_data = sm_act_wr_data;
        end else if (ln_act_wr_en) begin
            act_wr_en   = 1'b1;
            act_wr_addr = ln_act_wr_addr;
            act_wr_data = ln_act_wr_data;
        end else if (gelu_act_wr_en) begin
            act_wr_en   = 1'b1;
            act_wr_addr = gelu_act_wr_addr;
            act_wr_data = gelu_act_wr_data;
        end else if (vec_act_wr_en) begin
            act_wr_en   = 1'b1;
            act_wr_addr = vec_act_wr_addr;
            act_wr_data = vec_act_wr_data;
        end else if (emb_act_wr_en) begin
            act_wr_en   = 1'b1;
            act_wr_addr = emb_act_wr_addr;
            act_wr_data = emb_act_wr_data;
        end else if (dmard_act_wr_en) begin
            act_wr_en   = 1'b1;
            act_wr_addr = dmard_act_wr_addr;
            act_wr_data = dmard_act_wr_data;
        end else begin
            act_wr_en   = 1'b0;
            act_wr_addr = '0;
            act_wr_data = '0;
        end
    end

    // 2. WGT_SRAM (2 x 1,024 x 128-bit = 32 KB Ping-Pong Weight / KV-Cache SRAM)
    wire         wgt_dma_wr_en;
    wire [10:0]  wgt_dma_wr_addr;
    wire [127:0] wgt_dma_wr_data;

    wire         gemm_wgt_rd_en, emb_wgt_rd_en;
    wire [10:0]  gemm_wgt_rd_addr, emb_wgt_rd_addr;
    wire         wgt_comp_rd_en   = gemm_wgt_rd_en | emb_wgt_rd_en;
    wire [10:0]  wgt_comp_rd_addr = gemm_wgt_rd_en ? gemm_wgt_rd_addr : emb_wgt_rd_addr;
    wire [127:0] wgt_comp_rd_data;

    // 3. PARAM_SRAM (2,048 x 32-bit = 8 KB LN Gamma/Beta & INT32 Bias SRAM)
    wire                      param_wr_en;
    wire [PARAM_ADDR_W-1:0]   param_wr_addr;
    wire [31:0]               param_wr_data;

    wire                      gemm_param_rd_en, ln_param_rd_en;
    wire [PARAM_ADDR_W-1:0]   gemm_param_rd_addr, ln_param_rd_addr;
    wire                      param_rd_en   = gemm_param_rd_en | ln_param_rd_en;
    wire [PARAM_ADDR_W-1:0]   param_rd_addr = gemm_param_rd_en ? gemm_param_rd_addr : ln_param_rd_addr;
    wire [31:0]               param_rd_data;

    // 4. TOK_SRAM (512 x 16-bit = 1 KB Context Token Buffer)
    wire        tok_wr_en   = seq_tok_wr_en ? 1'b1            : prompt_wr_en;
    wire [8:0]  tok_wr_addr = seq_tok_wr_en ? seq_tok_wr_addr : prompt_wr_addr;
    wire [15:0] tok_wr_data = seq_tok_wr_en ? seq_tok_wr_data : prompt_wr_data;

    // =========================================================================
    // Submodule Instantiations
    // =========================================================================

    // 1. AXI4-Lite Host Registers & Token FIFO
    yt_axi_lite_regs u_axil_regs (
        .clk                (clk),
        .rst_n              (rst_n),
        .s_axil_awaddr      (s_axil_awaddr),
        .s_axil_awprot      (s_axil_awprot),
        .s_axil_awvalid     (s_axil_awvalid),
        .s_axil_awready     (s_axil_awready),
        .s_axil_wdata       (s_axil_wdata),
        .s_axil_wstrb       (s_axil_wstrb),
        .s_axil_wvalid      (s_axil_wvalid),
        .s_axil_wready      (s_axil_wready),
        .s_axil_bresp       (s_axil_bresp),
        .s_axil_bvalid      (s_axil_bvalid),
        .s_axil_bready      (s_axil_bready),
        .s_axil_araddr      (s_axil_araddr),
        .s_axil_arprot      (s_axil_arprot),
        .s_axil_arvalid     (s_axil_arvalid),
        .s_axil_arready     (s_axil_arready),
        .s_axil_rdata       (s_axil_rdata),
        .s_axil_rresp       (s_axil_rresp),
        .s_axil_rvalid      (s_axil_rvalid),
        .s_axil_rready      (s_axil_rready),
        .ctrl_start         (ctrl_start),
        .ctrl_soft_rst      (ctrl_soft_rst),
        .cfg_autogen_mode   (cfg_autogen_mode),
        .cfg_ucode_len      (cfg_ucode_len),
        .cfg_ddr_base_wgt   (cfg_ddr_base_wgt),
        .cfg_ddr_base_kv    (cfg_ddr_base_kv),
        .cfg_ddr_base_out   (cfg_ddr_base_out),
        .cfg_prompt_len     (cfg_prompt_len),
        .cfg_max_new_tokens (cfg_max_new_tokens),
        .cfg_temp_inv_q88   (cfg_temp_inv_q88),
        .cfg_top_k          (cfg_top_k),
        .cfg_rng_seed       (cfg_rng_seed),
        .cfg_wte_deq_u16    (cfg_wte_deq_u16),
        .cfg_wpe_deq_u16    (cfg_wpe_deq_u16),
        .cfg_lm_mult_u8     (cfg_lm_mult_u8),
        .cfg_lm_shift_u8    (cfg_lm_shift_u8),
        .prompt_wr_en       (prompt_wr_en),
        .prompt_wr_addr     (prompt_wr_addr),
        .prompt_wr_data     (prompt_wr_data),
        .ucode_wr_en        (ucode_wr_en),
        .ucode_wr_addr      (ucode_wr_addr),
        .ucode_wr_data      (ucode_wr_data),
        .status_busy        (seq_busy),
        .status_done_pulse  (seq_done_pulse),
        .status_err_pulse   (status_err_pulse),
        .status_eot_hit     (seq_eot_hit),
        .status_gen_count   (seq_gen_count),
        .gen_tok_push       (gen_tok_push),
        .gen_tok_data       (gen_tok_data),
        .irq                (irq)
    );

    // 2. Autonomous Story Token Sequencer
    yt_token_sequencer u_token_seq (
        .clk                (clk),
        .rst_n              (rst_n),
        .ctrl_start         (ctrl_start),
        .ctrl_soft_rst      (ctrl_soft_rst),
        .cfg_autogen_mode   (cfg_autogen_mode),
        .cfg_prompt_len     (cfg_prompt_len),
        .cfg_max_new_tokens (cfg_max_new_tokens),
        .seq_tok_rd_en      (seq_tok_rd_en),
        .seq_tok_rd_addr    (seq_tok_rd_addr),
        .seq_tok_rd_data    (seq_tok_rd_data),
        .seq_tok_wr_en      (seq_tok_wr_en),
        .seq_tok_wr_addr    (seq_tok_wr_addr),
        .seq_tok_wr_data    (seq_tok_wr_data),
        .step_start         (step_start),
        .step_done_pulse    (step_done_pulse),
        .prng_seed_load     (prng_seed_load),
        .cur_pos            (cur_pos),
        .cur_tok_id         (cur_tok_id),
        .is_prefill_skip_lm (is_prefill_skip_lm),
        .sample_valid       (sample_valid),
        .sampled_token_id   (sampled_token_id),
        .gen_tok_push       (gen_tok_push),
        .gen_tok_data       (gen_tok_data),
        .seq_busy           (seq_busy),
        .seq_done_pulse     (seq_done_pulse),
        .seq_eot_hit        (seq_eot_hit),
        .seq_gen_count      (seq_gen_count)
    );

    // 3. Microcode Fetch, Decode & Scoreboard
    yt_ucode_fetch u_ucode_fetch (
        .clk             (clk),
        .rst_n           (rst_n),
        .step_start      (step_start),
        .step_abort      (step_abort | ctrl_soft_rst),
        .cfg_ucode_len   (cfg_ucode_len),
        .branch_valid    (branch_valid),
        .branch_target   (branch_target),
        .ucode_rd_en     (ucode_rd_en),
        .ucode_rd_addr   (ucode_rd_addr),
        .ucode_rd_data   (ucode_rd_data),
        .instr_valid     (instr_valid),
        .instr_data      (instr_data),
        .instr_pc        (instr_pc),
        .decode_ready    (decode_ready),
        .fetch_eof_pulse (fetch_eof_pulse),
        .fetch_active    (fetch_active)
    );

    yt_scoreboard u_scoreboard (
        .clk             (clk),
        .rst_n           (rst_n),
        .clear           (ctrl_soft_rst | step_start),
        .issue_valid     (sb_issue_valid),
        .issue_engine_id (sb_issue_engine_id),
        .engine_done     (engine_done),
        .engine_busy     (engine_busy),
        .all_idle        (all_idle)
    );

    yt_ucode_decode u_ucode_decode (
        .clk                (clk),
        .rst_n              (rst_n),
        .soft_rst           (ctrl_soft_rst),
        .instr_valid        (instr_valid),
        .instr_data         (instr_data),
        .instr_pc           (instr_pc),
        .decode_ready       (decode_ready),
        .branch_valid       (branch_valid),
        .branch_target      (branch_target),
        .step_abort         (step_abort),
        .fetch_eof_pulse    (fetch_eof_pulse),
        .step_done_pulse    (step_done_pulse),
        .err_invalid_op     (err_invalid_op),
        .cfg_ddr_base_wgt   (cfg_ddr_base_wgt),
        .cfg_ddr_base_kv    (cfg_ddr_base_kv),
        .cfg_ddr_base_out   (cfg_ddr_base_out),
        .cfg_lm_mult_u8     (cfg_lm_mult_u8),
        .cfg_lm_shift_u8    (cfg_lm_shift_u8),
        .cur_pos            (cur_pos),
        .cur_tok_id         (cur_tok_id),
        .is_prefill_skip_lm (is_prefill_skip_lm),
        .engine_busy        (engine_busy),
        .all_idle           (all_idle),
        .sb_issue_valid     (sb_issue_valid),
        .sb_issue_engine_id (sb_issue_engine_id),
        .gemm_cmd_valid     (gemm_cmd_valid),
        .gemm_src0          (gemm_src0),
        .gemm_src1          (gemm_src1),
        .gemm_dst           (gemm_dst),
        .gemm_M             (gemm_M),
        .gemm_N             (gemm_N),
        .gemm_K             (gemm_K),
        .gemm_flags         (gemm_flags),
        .gemm_imm           (gemm_imm),
        .sm_cmd_valid       (sm_cmd_valid),
        .sm_rows            (sm_rows),
        .sm_length          (sm_length),
        .sm_src_base        (sm_src_base),
        .sm_dst_base        (sm_dst_base),
        .sm_causal_en       (sm_causal_en),
        .sm_causal_base     (sm_causal_base),
        .ln_cmd_valid       (ln_cmd_valid),
        .ln_rows            (ln_rows),
        .ln_length          (ln_length),
        .ln_src_base        (ln_src_base),
        .ln_dst_base        (ln_dst_base),
        .ln_param_base      (ln_param_base),
        .gelu_cmd_valid     (gelu_cmd_valid),
        .gelu_rows          (gelu_rows),
        .gelu_length        (gelu_length),
        .gelu_src_base      (gelu_src_base),
        .gelu_dst_base      (gelu_dst_base),
        .vec_cmd_valid      (vec_cmd_valid),
        .vec_flags          (vec_flags),
        .vec_M              (vec_M),
        .vec_N              (vec_N),
        .vec_K              (vec_K),
        .vec_imm            (vec_imm),
        .vec_src0           (vec_src0),
        .vec_src1           (vec_src1),
        .vec_dst            (vec_dst),
        .dma_rd_cmd_valid   (dma_rd_cmd_valid),
        .dma_rd_ddr_addr    (dma_rd_ddr_addr),
        .dma_rd_byte_len    (dma_rd_byte_len),
        .dma_rd_target      (dma_rd_target),
        .dma_rd_sram_base   (dma_rd_sram_base),
        .dma_wr_cmd_valid   (dma_wr_cmd_valid),
        .dma_wr_mode        (dma_wr_mode),
        .dma_wr_ddr_addr    (dma_wr_ddr_addr),
        .dma_wr_byte_len    (dma_wr_byte_len),
        .dma_wr_act_base    (dma_wr_act_base),
        .emb_cmd_valid      (emb_cmd_valid),
        .emb_length         (emb_length),
        .emb_dst_base       (emb_dst_base),
        .topk_cmd_valid     (topk_cmd_valid),
        .topk_is_sample     (topk_is_sample),
        .topk_reset_pool    (topk_reset_pool),
        .topk_src_base      (topk_src_base),
        .topk_length        (topk_length),
        .topk_vocab_base    (topk_vocab_base)
    );

    // =========================================================================
    // On-Chip SRAM Macro Array (91 KB Total)
    // =========================================================================

    // UCODE_SRAM: 1024 x 128-bit (16 KB)
    yt_sram_1r1w #(
        .DEPTH (UCODE_DEPTH),
        .WIDTH (128)
    ) u_ucode_sram (
        .clk     (clk),
        .rd_en   (ucode_rd_en),
        .rd_addr (ucode_rd_addr),
        .rd_data (ucode_rd_data),
        .wr_en   (ucode_wr_en),
        .wr_addr (ucode_wr_addr),
        .wr_data (ucode_wr_data)
    );

    // TOK_SRAM: 512 x 16-bit (1 KB)
    yt_sram_1r1w #(
        .DEPTH (TOK_SRAM_DEPTH),
        .WIDTH (16)
    ) u_tok_sram (
        .clk     (clk),
        .rd_en   (seq_tok_rd_en),
        .rd_addr (seq_tok_rd_addr),
        .rd_data (seq_tok_rd_data),
        .wr_en   (tok_wr_en),
        .wr_addr (tok_wr_addr),
        .wr_data (tok_wr_data)
    );

    // ACT_SRAM: 16384 x 16-bit Q7.8 (32 KB)
    yt_sram_1r1w #(
        .DEPTH (ACT_SRAM_WORDS),
        .WIDTH (16)
    ) u_act_sram (
        .clk     (clk),
        .rd_en   (act_rd_en),
        .rd_addr (act_rd_addr),
        .rd_data (act_rd_data),
        .wr_en   (act_wr_en),
        .wr_addr (act_wr_addr),
        .wr_data (act_wr_data)
    );

    // WGT_SRAM: 2 x 1024 x 128-bit Ping-Pong Weight & KV-Cache SRAM (32 KB)
    yt_pingpong_wgt u_wgt_sram (
        .clk               (clk),
        .dma_wr_en         (wgt_dma_wr_en),
        .dma_wr_beat_addr  (wgt_dma_wr_addr),
        .dma_wr_data       (wgt_dma_wr_data),
        .comp_rd_en        (wgt_comp_rd_en),
        .comp_rd_beat_addr (wgt_comp_rd_addr),
        .comp_rd_data      (wgt_comp_rd_data)
    );

    // PARAM_SRAM: 2048 x 32-bit LN Gamma/Beta & INT32 Bias SRAM (8 KB)
    yt_sram_1r1w #(
        .DEPTH (PARAM_SRAM_WORDS),
        .WIDTH (32)
    ) u_param_sram (
        .clk     (clk),
        .rd_en   (param_rd_en),
        .rd_addr (param_rd_addr),
        .rd_data (param_rd_data),
        .wr_en   (param_wr_en),
        .wr_addr (param_wr_addr),
        .wr_data (param_wr_data)
    );

    // =========================================================================
    // 8 Dedicated Hardware Engines
    // =========================================================================

    // Engine 0: 16x16 W8A16 Systolic GEMM / Fast 128b GEMV Engine
    yt_gemm_engine u_gemm (
        .clk              (clk),
        .rst_n            (rst_n),
        .cmd_valid        (gemm_cmd_valid),
        .cmd_src0         (gemm_src0),
        .cmd_src1         (gemm_src1),
        .cmd_dst          (gemm_dst),
        .cmd_M            (gemm_M),
        .cmd_N            (gemm_N),
        .cmd_K            (gemm_K),
        .cmd_flags        (gemm_flags),
        .cmd_imm          (gemm_imm),
        .act_rd_en        (gemm_act_rd_en),
        .act_rd_addr      (gemm_act_rd_addr),
        .act_rd_data      (act_rd_data),
        .act_wr_en        (gemm_act_wr_en),
        .act_wr_addr      (gemm_act_wr_addr),
        .act_wr_data      (gemm_act_wr_data),
        .wgt_rd_en        (gemm_wgt_rd_en),
        .wgt_rd_beat_addr (gemm_wgt_rd_addr),
        .wgt_rd_data      (wgt_comp_rd_data),
        .param_rd_en      (gemm_param_rd_en),
        .param_rd_addr    (gemm_param_rd_addr),
        .param_rd_data    (signed'(param_rd_data)),
        .busy             (gemm_busy),
        .done             (gemm_done)
    );

    // Engine 1: 512-Context Divider-Free Causal Softmax Engine
    yt_softmax_engine u_softmax (
        .clk            (clk),
        .rst_n          (rst_n),
        .cmd_valid      (sm_cmd_valid),
        .cmd_rows       (sm_rows),
        .cmd_length     (sm_length),
        .cmd_src_base   (sm_src_base),
        .cmd_dst_base   (sm_dst_base),
        .causal_mask_en (sm_causal_en),
        .causal_base    (sm_causal_base),
        .act_rd_en      (sm_act_rd_en),
        .act_rd_addr    (sm_act_rd_addr),
        .act_rd_data    (act_rd_data),
        .act_wr_en      (sm_act_wr_en),
        .act_wr_addr    (sm_act_wr_addr),
        .act_wr_data    (sm_act_wr_data),
        .busy           (sm_busy),
        .done           (sm_done)
    );

    // Engine 2: Divider-Free Q7.8 LayerNorm Engine w/ Learned Gamma/Beta
    yt_layernorm_engine u_layernorm (
        .clk            (clk),
        .rst_n          (rst_n),
        .cmd_valid      (ln_cmd_valid),
        .cmd_rows       (ln_rows),
        .cmd_length     (ln_length),
        .cmd_src_base   (ln_src_base),
        .cmd_dst_base   (ln_dst_base),
        .cmd_param_base (ln_param_base),
        .act_rd_en      (ln_act_rd_en),
        .act_rd_addr    (ln_act_rd_addr),
        .act_rd_data    (act_rd_data),
        .act_wr_en      (ln_act_wr_en),
        .act_wr_addr    (ln_act_wr_addr),
        .act_wr_data    (ln_act_wr_data),
        .param_rd_en    (ln_param_rd_en),
        .param_rd_addr  (ln_param_rd_addr),
        .param_rd_data  (param_rd_data),
        .busy           (ln_busy),
        .done           (ln_done)
    );

    // Engine 3: Piecewise + 256-LUT Q7.8 GELU Engine
    yt_gelu_engine u_gelu (
        .clk          (clk),
        .rst_n        (rst_n),
        .cmd_valid    (gelu_cmd_valid),
        .cmd_rows     (gelu_rows),
        .cmd_length   (gelu_length),
        .cmd_src_base (gelu_src_base),
        .cmd_dst_base (gelu_dst_base),
        .act_rd_en    (gelu_act_rd_en),
        .act_rd_addr  (gelu_act_rd_addr),
        .act_rd_data  (act_rd_data),
        .act_wr_en    (gelu_act_wr_en),
        .act_wr_addr  (gelu_act_wr_addr),
        .act_wr_data  (gelu_act_wr_data),
        .busy         (gelu_busy),
        .done         (gelu_done)
    );

    // Engine 4: Q7.8 Vector ALU & 2D Head Scatter/Gather Engine
    yt_vec_engine u_vec (
        .clk         (clk),
        .rst_n       (rst_n),
        .cmd_valid   (vec_cmd_valid),
        .cmd_flags   (vec_flags),
        .cmd_M       (vec_M),
        .cmd_N       (vec_N),
        .cmd_K       (vec_K),
        .cmd_imm     (vec_imm),
        .cmd_src0    (vec_src0),
        .cmd_src1    (vec_src1),
        .cmd_dst     (vec_dst),
        .act_rd_en   (vec_act_rd_en),
        .act_rd_addr (vec_act_rd_addr),
        .act_rd_data (act_rd_data),
        .act_wr_en   (vec_act_wr_en),
        .act_wr_addr (vec_act_wr_addr),
        .act_wr_data (vec_act_wr_data),
        .busy        (vec_busy),
        .done        (vec_done)
    );

    // Engine 5A: 128-Bit AXI4 Burst Read DMA Master
    yt_axi_dma_rd u_dma_rd (
        .clk              (clk),
        .rst_n            (rst_n),
        .cmd_valid        (dma_rd_cmd_valid),
        .cmd_ddr_addr     (dma_rd_ddr_addr),
        .cmd_byte_len     (dma_rd_byte_len),
        .cmd_target       (dma_rd_target),
        .cmd_sram_base    (dma_rd_sram_base),
        .m_axi_arid       (m_axi_arid),
        .m_axi_araddr     (m_axi_araddr),
        .m_axi_arlen      (m_axi_arlen),
        .m_axi_arsize     (m_axi_arsize),
        .m_axi_arburst    (m_axi_arburst),
        .m_axi_arvalid    (m_axi_arvalid),
        .m_axi_arready    (m_axi_arready),
        .m_axi_rid        (m_axi_rid),
        .m_axi_rdata      (m_axi_rdata),
        .m_axi_rresp      (m_axi_rresp),
        .m_axi_rlast      (m_axi_rlast),
        .m_axi_rvalid     (m_axi_rvalid),
        .m_axi_rready     (m_axi_rready),
        .wgt_wr_en        (wgt_dma_wr_en),
        .wgt_wr_beat_addr (wgt_dma_wr_addr),
        .wgt_wr_data      (wgt_dma_wr_data),
        .param_wr_en      (param_wr_en),
        .param_wr_addr    (param_wr_addr),
        .param_wr_data    (param_wr_data),
        .act_wr_en        (dmard_act_wr_en),
        .act_wr_addr      (dmard_act_wr_addr),
        .act_wr_data      (dmard_act_wr_data),
        .busy             (dma_rd_busy),
        .done             (dma_rd_done),
        .err              (dma_rd_err)
    );

    // Engine 5B: 128-Bit AXI4 Burst Write & Q4.3 KV-Packer DMA Master
    yt_axi_dma_wr u_dma_wr (
        .clk           (clk),
        .rst_n         (rst_n),
        .cmd_valid     (dma_wr_cmd_valid),
        .cmd_mode      (dma_wr_mode),
        .cmd_ddr_addr  (dma_wr_ddr_addr),
        .cmd_byte_len  (dma_wr_byte_len),
        .cmd_act_base  (dma_wr_act_base),
        .cmd_imm_beat  (128'd0),
        .m_axi_awid    (m_axi_awid),
        .m_axi_awaddr  (m_axi_awaddr),
        .m_axi_awlen   (m_axi_awlen),
        .m_axi_awsize  (m_axi_awsize),
        .m_axi_awburst (m_axi_awburst),
        .m_axi_awvalid (m_axi_awvalid),
        .m_axi_awready (m_axi_awready),
        .m_axi_wdata   (m_axi_wdata),
        .m_axi_wstrb   (m_axi_wstrb),
        .m_axi_wlast   (m_axi_wlast),
        .m_axi_wvalid  (m_axi_wvalid),
        .m_axi_wready  (m_axi_wready),
        .m_axi_bid     (m_axi_bid),
        .m_axi_bresp   (m_axi_bresp),
        .m_axi_bvalid  (m_axi_bvalid),
        .m_axi_bready  (m_axi_bready),
        .act_rd_en     (dmawr_act_rd_en),
        .act_rd_addr   (dmawr_act_rd_addr),
        .act_rd_data   (act_rd_data),
        .busy          (dma_wr_busy),
        .done          (dma_wr_done),
        .err           (dma_wr_err)
    );

    // Engine 6: Hardware WTE + WPE Token/Position Embedding Engine
    yt_embed_engine u_embed (
        .clk              (clk),
        .rst_n            (rst_n),
        .cmd_valid        (emb_cmd_valid),
        .cmd_length       (emb_length),
        .cmd_dst_base     (emb_dst_base),
        .wte_deq_u16      (cfg_wte_deq_u16),
        .wpe_deq_u16      (cfg_wpe_deq_u16),
        .wgt_rd_en        (emb_wgt_rd_en),
        .wgt_rd_beat_addr (emb_wgt_rd_addr),
        .wgt_rd_data      (wgt_comp_rd_data),
        .act_wr_en        (emb_act_wr_en),
        .act_wr_addr      (emb_act_wr_addr),
        .act_wr_data      (emb_act_wr_data),
        .busy             (emb_busy),
        .done             (emb_done)
    );

    // Engine 7: Streaming 50,257-Vocab Top-K + Temperature PRNG Sampler
    yt_topk_sampler u_topk (
        .clk              (clk),
        .rst_n            (rst_n),
        .seed_load        (prng_seed_load),
        .seed_val         (cfg_rng_seed),
        .cfg_top_k        (cfg_top_k),
        .cfg_temp_inv_q88 (cfg_temp_inv_q88),
        .cmd_valid        (topk_cmd_valid),
        .cmd_is_sample    (topk_is_sample),
        .cmd_reset_pool   (topk_reset_pool),
        .cmd_src_base     (topk_src_base),
        .cmd_length       (topk_length),
        .cmd_vocab_base   (topk_vocab_base),
        .act_rd_en        (topk_act_rd_en),
        .act_rd_addr      (topk_act_rd_addr),
        .act_rd_data      (act_rd_data),
        .sample_valid     (sample_valid),
        .sampled_token_id (sampled_token_id),
        .busy             (topk_busy),
        .done             (topk_done)
    );

endmodule

`default_nettype wire
