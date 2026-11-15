// =============================================================================
// AXI4-Lite Host Control, Status, Microcode Loader & Token FIFO Slave
// (yt_axi_lite_regs.sv)
// - Implements full YT-AI NPU MMIO Register Map (0x00 .. 0x5C)
// - Built-in 128-bit Microcode SRAM write port (auto-increment on DATA3 write)
// - Built-in Prompt Push port (-> TOK_SRAM) & 512-deep Generated Token Pop FIFO
// - 64-bit Hardware Cycle Counter & Maskable Completion Interrupt (irq)
// =============================================================================
`default_nettype none

module yt_axi_lite_regs
    import yt_npu_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    // AXI4-Lite Slave Interface
    input  wire  [AXIL_ADDR_W-1:0]    s_axil_awaddr,
    input  wire  [2:0]                s_axil_awprot,
    input  wire                       s_axil_awvalid,
    output logic                      s_axil_awready,

    input  wire  [AXIL_DATA_W-1:0]    s_axil_wdata,
    input  wire  [AXIL_DATA_W/8-1:0]  s_axil_wstrb,
    input  wire                       s_axil_wvalid,
    output logic                      s_axil_wready,

    output logic [1:0]                s_axil_bresp,
    output logic                      s_axil_bvalid,
    input  wire                       s_axil_bready,

    input  wire  [AXIL_ADDR_W-1:0]    s_axil_araddr,
    input  wire  [2:0]                s_axil_arprot,
    input  wire                       s_axil_arvalid,
    output logic                      s_axil_arready,

    output logic [AXIL_DATA_W-1:0]    s_axil_rdata,
    output logic [1:0]                s_axil_rresp,
    output logic                      s_axil_rvalid,
    input  wire                       s_axil_rready,

    // Control Pulses & Configuration Outputs
    output logic                      ctrl_start,
    output logic                      ctrl_soft_rst,
    output logic                      cfg_autogen_mode,
    output logic [UCODE_ADDR_W:0]     cfg_ucode_len,
    output logic [31:0]               cfg_ddr_base_wgt,
    output logic [31:0]               cfg_ddr_base_kv,
    output logic [31:0]               cfg_ddr_base_out,
    output logic [9:0]                cfg_prompt_len,
    output logic [9:0]                cfg_max_new_tokens,
    output logic [15:0]               cfg_temp_inv_q88,
    output logic [15:0]               cfg_top_k,
    output logic [63:0]               cfg_rng_seed,
    output logic [15:0]               cfg_wte_deq_u16,
    output logic [15:0]               cfg_wpe_deq_u16,
    output logic [7:0]                cfg_lm_mult_u8,
    output logic [7:0]                cfg_lm_shift_u8,

    // Prompt Write Port -> TOK_SRAM
    output logic                      prompt_wr_en,
    output logic [8:0]                prompt_wr_addr,
    output logic [15:0]               prompt_wr_data,

    // Microcode Write Port -> UCODE_SRAM (128-bit)
    output logic                      ucode_wr_en,
    output logic [UCODE_ADDR_W-1:0]   ucode_wr_addr,
    output logic [127:0]              ucode_wr_data,

    // Sequencer / Core Status Inputs
    input  wire                       status_busy,
    input  wire                       status_done_pulse,
    input  wire                       status_err_pulse,
    input  wire                       status_eot_hit,
    input  wire  [9:0]                status_gen_count,

    // Generated Story Token Push Port (from Autonomous Token Sequencer)
    input  wire                       gen_tok_push,
    input  wire  [15:0]               gen_tok_data,

    // Interrupt Output
    output logic                      irq
);

    wire _unused = &{s_axil_awprot, s_axil_arprot, s_axil_wstrb, 1'b0};

    // AXI-Lite Write Handshake Latches
    logic        aw_latched, w_latched;
    logic [7:0]  aw_addr_q;
    logic [31:0] w_data_q;

    wire wr_fire = (aw_latched || s_axil_awvalid) && (w_latched || s_axil_wvalid) && !s_axil_bvalid;
    wire [7:0]  wr_addr_eff = aw_latched ? aw_addr_q : s_axil_awaddr[7:0];
    wire [31:0] wr_data_eff = w_latched  ? w_data_q  : s_axil_wdata;

    assign s_axil_awready = !aw_latched && !s_axil_bvalid;
    assign s_axil_wready  = !w_latched  && !s_axil_bvalid;
    assign s_axil_bresp   = 2'b00; // OKAY

    //Sticky status & counters
    logic        irq_en_q;
    logic        done_sticky_q;
    logic        err_sticky_q;
    logic [63:0] perf_cycles_q;

    // Prompt & Microcode staging pointers
    logic [8:0]            prompt_ptr_q;
    logic [UCODE_ADDR_W-1:0] ucode_ptr_q;
    logic [95:0]           ucode_stage_q;

    // 512-entry Generated Token Ring FIFO (synthesizable array)
    logic [15:0] gen_fifo_mem [512];
    logic [8:0]  fifo_wr_ptr_q, fifo_rd_ptr_q;
    logic [9:0]  fifo_count_q;

    wire rd_fire = s_axil_arvalid && s_axil_arready;
    wire pop_tok = rd_fire && (s_axil_araddr[7:0] == REG_TOKEN_POP) && (fifo_count_q != 10'd0);

    assign s_axil_arready = !s_axil_rvalid;
    assign s_axil_rresp   = 2'b00;
    assign irq            = irq_en_q && done_sticky_q;

    // Sequential Register & FIFO Logic
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aw_latched         <= 1'b0;
            w_latched          <= 1'b0;
            aw_addr_q          <= 8'd0;
            w_data_q           <= 32'd0;
            s_axil_bvalid      <= 1'b0;
            s_axil_rvalid      <= 1'b0;
            s_axil_rdata       <= 32'd0;

            ctrl_start         <= 1'b0;
            ctrl_soft_rst      <= 1'b0;
            cfg_autogen_mode   <= 1'b1;
            irq_en_q           <= 1'b0;
            done_sticky_q      <= 1'b0;
            err_sticky_q       <= 1'b0;

            cfg_ucode_len      <= '0;
            cfg_ddr_base_wgt   <= 32'h0000_0000;
            cfg_ddr_base_kv    <= DDR_OFFSET_KV;
            cfg_ddr_base_out   <= DDR_OFFSET_OUT;
            cfg_prompt_len     <= 10'd1;
            cfg_max_new_tokens <= 10'd64;
            cfg_temp_inv_q88   <= 16'd320; // 1 / 0.8 = 1.25 -> 320 in Q8.8
            cfg_top_k          <= 16'd200; // YT-AI default top_k = 200
            cfg_rng_seed       <= 64'hCAFE_BABE_DEAD_BEEF;
            cfg_wte_deq_u16    <= 16'd712; // Exact YT-AI 51.2M WTE dequant scale
            cfg_wpe_deq_u16    <= 16'd722; // Exact YT-AI 51.2M WPE dequant scale
            cfg_lm_mult_u8     <= 8'd178;  // Exact YT-AI 51.2M LM-head mult
            cfg_lm_shift_u8    <= 8'd14;   // Exact YT-AI 51.2M LM-head shift

            prompt_wr_en       <= 1'b0;
            prompt_wr_addr     <= 9'd0;
            prompt_wr_data     <= 16'd0;
            prompt_ptr_q       <= 9'd0;

            ucode_wr_en        <= 1'b0;
            ucode_wr_addr      <= '0;
            ucode_wr_data      <= '0;
            ucode_ptr_q        <= '0;
            ucode_stage_q      <= '0;

            perf_cycles_q      <= 64'd0;
            fifo_wr_ptr_q      <= 9'd0;
            fifo_rd_ptr_q      <= 9'd0;
            fifo_count_q       <= 10'd0;
        end else begin
            // Single-cycle pulse defaults
            ctrl_start    <= 1'b0;
            ctrl_soft_rst <= 1'b0;
            prompt_wr_en  <= 1'b0;
            ucode_wr_en   <= 1'b0;

            // Performance cycle counter
            if (ctrl_start)
                perf_cycles_q <= 64'd0;
            else if (status_busy)
                perf_cycles_q <= perf_cycles_q + 64'd1;

            // Sticky status updates
            if (status_done_pulse) done_sticky_q <= 1'b1;
            if (status_err_pulse)  err_sticky_q  <= 1'b1;

            // Generated Token Ring FIFO push/pop
            if (ctrl_soft_rst) begin
                fifo_wr_ptr_q <= 9'd0;
                fifo_rd_ptr_q <= 9'd0;
                fifo_count_q  <= 10'd0;
            end else begin
                if (gen_tok_push && (fifo_count_q < 10'd512)) begin
                    gen_fifo_mem[fifo_wr_ptr_q] <= gen_tok_data;
                    fifo_wr_ptr_q               <= fifo_wr_ptr_q + 9'd1;
                end
                if (pop_tok) begin
                    fifo_rd_ptr_q <= fifo_rd_ptr_q + 9'd1;
                end
                case ({gen_tok_push && (fifo_count_q < 10'd512), pop_tok})
                    2'b10:   fifo_count_q <= fifo_count_q + 10'd1;
                    2'b01:   fifo_count_q <= fifo_count_q - 10'd1;
                    default: ;
                endcase
            end

            // AXI-Lite Write Capture
            if (s_axil_awvalid && s_axil_awready) begin
                aw_latched <= 1'b1;
                aw_addr_q  <= s_axil_awaddr[7:0];
            end
            if (s_axil_wvalid && s_axil_wready) begin
                w_latched <= 1'b1;
                w_data_q  <= s_axil_wdata;
            end

            if (wr_fire) begin
                aw_latched    <= 1'b0;
                w_latched     <= 1'b0;
                s_axil_bvalid <= 1'b1;

                case (wr_addr_eff)
                    REG_CTRL: begin
                        if (wr_data_eff[0]) begin
                            ctrl_start    <= 1'b1;
                            done_sticky_q <= 1'b0;
                            err_sticky_q  <= 1'b0;
                        end
                        if (wr_data_eff[1]) begin
                            ctrl_soft_rst <= 1'b1;
                            prompt_ptr_q  <= 9'd0;
                        end
                        cfg_autogen_mode <= wr_data_eff[2];
                        irq_en_q         <= wr_data_eff[3];
                        if (wr_data_eff[4]) begin
                            prompt_ptr_q  <= 9'd0;
                            fifo_wr_ptr_q <= 9'd0;
                            fifo_rd_ptr_q <= 9'd0;
                            fifo_count_q  <= 10'd0;
                        end
                    end
                    REG_STATUS: begin
                        if (wr_data_eff[0]) done_sticky_q <= 1'b0;
                        if (wr_data_eff[2]) err_sticky_q  <= 1'b0;
                    end
                    REG_UCODE_LEN:      cfg_ucode_len      <= wr_data_eff[UCODE_ADDR_W:0];
                    REG_DDR_BASE_WGT:   cfg_ddr_base_wgt   <= wr_data_eff;
                    REG_DDR_BASE_KV:    cfg_ddr_base_kv    <= wr_data_eff;
                    REG_DDR_BASE_OUT:   cfg_ddr_base_out   <= wr_data_eff;
                    REG_PROMPT_LEN:     cfg_prompt_len     <= wr_data_eff[9:0];
                    REG_MAX_NEW_TOKENS: cfg_max_new_tokens <= wr_data_eff[9:0];
                    REG_TEMP_INV_Q88:   cfg_temp_inv_q88   <= wr_data_eff[15:0];
                    REG_TOP_K:          cfg_top_k          <= wr_data_eff[15:0];
                    REG_RNG_SEED_LO:    cfg_rng_seed[31:0] <= wr_data_eff;
                    REG_RNG_SEED_HI:    cfg_rng_seed[63:32]<= wr_data_eff;
                    REG_WTE_DEQ_SCALE: begin
                        cfg_wte_deq_u16 <= wr_data_eff[15:0];
                        cfg_wpe_deq_u16 <= wr_data_eff[31:16];
                    end
                    REG_LM_QUANT_CFG: begin
                        cfg_lm_mult_u8  <= wr_data_eff[7:0];
                        cfg_lm_shift_u8 <= wr_data_eff[15:8];
                    end
                    REG_PROMPT_PUSH: begin
                        prompt_wr_en   <= 1'b1;
                        prompt_wr_addr <= prompt_ptr_q;
                        prompt_wr_data <= wr_data_eff[15:0];
                        prompt_ptr_q   <= prompt_ptr_q + 9'd1;
                    end
                    REG_UCODE_WR_ADDR:  ucode_ptr_q        <= wr_data_eff[UCODE_ADDR_W-1:0];
                    REG_UCODE_WR_DATA0: ucode_stage_q[31:0]  <= wr_data_eff;
                    REG_UCODE_WR_DATA1: ucode_stage_q[63:32] <= wr_data_eff;
                    REG_UCODE_WR_DATA2: ucode_stage_q[95:64] <= wr_data_eff;
                    REG_UCODE_WR_DATA3: begin
                        ucode_wr_en   <= 1'b1;
                        ucode_wr_addr <= ucode_ptr_q;
                        ucode_wr_data <= {wr_data_eff, ucode_stage_q};
                        ucode_ptr_q   <= ucode_ptr_q + {{(UCODE_ADDR_W-1){1'b0}}, 1'b1};
                    end
                    default: ;
                endcase
            end else if (s_axil_bvalid && s_axil_bready) begin
                s_axil_bvalid <= 1'b0;
            end

            // AXI-Lite Read Response
            if (rd_fire) begin
                s_axil_rvalid <= 1'b1;
                case (s_axil_araddr[7:0])
                    REG_CTRL:           s_axil_rdata <= {28'd0, irq_en_q, cfg_autogen_mode, 2'b00};
                    REG_STATUS:         s_axil_rdata <= {14'd0, fifo_count_q, 4'd0, status_eot_hit, err_sticky_q, status_busy, done_sticky_q};
                    REG_UCODE_LEN:      s_axil_rdata <= {{(31-UCODE_ADDR_W){1'b0}}, cfg_ucode_len};
                    REG_DDR_BASE_WGT:   s_axil_rdata <= cfg_ddr_base_wgt;
                    REG_DDR_BASE_KV:    s_axil_rdata <= cfg_ddr_base_kv;
                    REG_DDR_BASE_OUT:   s_axil_rdata <= cfg_ddr_base_out;
                    REG_PROMPT_LEN:     s_axil_rdata <= {22'd0, cfg_prompt_len};
                    REG_MAX_NEW_TOKENS: s_axil_rdata <= {22'd0, cfg_max_new_tokens};
                    REG_TEMP_INV_Q88:   s_axil_rdata <= {16'd0, cfg_temp_inv_q88};
                    REG_TOP_K:          s_axil_rdata <= {16'd0, cfg_top_k};
                    REG_RNG_SEED_LO:    s_axil_rdata <= cfg_rng_seed[31:0];
                    REG_RNG_SEED_HI:    s_axil_rdata <= cfg_rng_seed[63:32];
                    REG_WTE_DEQ_SCALE:  s_axil_rdata <= {cfg_wpe_deq_u16, cfg_wte_deq_u16};
                    REG_LM_QUANT_CFG:   s_axil_rdata <= {16'd0, cfg_lm_shift_u8, cfg_lm_mult_u8};
                    REG_TOKEN_POP:      s_axil_rdata <= (fifo_count_q != 10'd0)
                                                        ? {1'b1, 15'd0, gen_fifo_mem[fifo_rd_ptr_q]}
                                                        : 32'd0;
                    REG_GEN_COUNT:      s_axil_rdata <= {22'd0, status_gen_count};
                    REG_PERF_CYCLES_LO: s_axil_rdata <= perf_cycles_q[31:0];
                    REG_PERF_CYCLES_HI: s_axil_rdata <= perf_cycles_q[63:32];
                    REG_UCODE_WR_ADDR:  s_axil_rdata <= {{(32-UCODE_ADDR_W){1'b0}}, ucode_ptr_q};
                    default:            s_axil_rdata <= 32'd0;
                endcase
            end else if (s_axil_rvalid && s_axil_rready) begin
                s_axil_rvalid <= 1'b0;
            end
        end
    end

endmodule

`default_nettype wire
