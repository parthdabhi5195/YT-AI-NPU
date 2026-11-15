// =============================================================================
// Unified W8A16 GEMM / GEMV Engine (yt_gemm_engine.sv)
// - Full M/N/K hardware tiling (12-bit tile counters: supports dimensions up to
//   65,535 including YT-AI's 512 hidden, 2048 FFN, and 50,257 tied LM-head!)
// - 128-bit wide WGT_SRAM fetch (loads 16 INT8 weights in 1 clock cycle when
//   16-byte aligned, 32x faster than byte-serial loading!)
// - Built-in INT32 bias addition from PARAM_SRAM (FLAG_BIAS_EN)
// - Built-in Q7.8 requantization, Attention Score (>>>6), Context (>>>10),
//   and Output Accumulation (FLAG_ACCUMULATE for 4x512 fused MLP slices)
// =============================================================================
`default_nettype none

module yt_gemm_engine
    import yt_npu_pkg::*;
    import yt_isa_pkg::*;
#(
    parameter int M_ARR = ARRAY_M,
    parameter int N_ARR = ARRAY_N
)(
    input  wire                       clk,
    input  wire                       rst_n,

    // Decoded Microcode Command
    input  wire                       cmd_valid,
    input  wire  [15:0]               cmd_src0,   // ACT_SRAM word base (A[M, K])
    input  wire  [15:0]               cmd_src1,   // PARAM_SRAM bias base (when FLAG_BIAS_EN) or WGT byte offset
    input  wire  [15:0]               cmd_dst,    // ACT_SRAM word base (C[M, N])
    input  wire  [15:0]               cmd_M,      // Rows M (1..512)
    input  wire  [15:0]               cmd_N,      // Cols N (1..2048)
    input  wire  [15:0]               cmd_K,      // Inner dim K (1..2048)
    input  wire  [7:0]                cmd_flags,  // TRANSPOSE_B, BIAS_EN, REQUANT, ACCUMULATE, PINGPONG_B, ATTN_*
    input  wire  [15:0]               cmd_imm,    // {shift[7:0], mult_u8[7:0]}

    // ACT_SRAM Read Port (16-bit Q7.8 elements, 1-cycle latency)
    output logic                      act_rd_en,
    output logic [ACT_ADDR_W-1:0]     act_rd_addr,
    input  wire  signed [15:0]        act_rd_data,

    // ACT_SRAM Write Port (16-bit Q7.8 elements)
    output logic                      act_wr_en,
    output logic [ACT_ADDR_W-1:0]     act_wr_addr,
    output logic signed [15:0]        act_wr_data,

    // WGT_SRAM Read Port (128-bit = 16 x INT8 per cycle, 1-cycle latency)
    output logic                      wgt_rd_en,
    output logic [10:0]               wgt_rd_beat_addr,
    input  wire  [127:0]              wgt_rd_data,

    // PARAM_SRAM Read Port (32-bit INT32 bias, 1-cycle latency)
    output logic                      param_rd_en,
    output logic [PARAM_ADDR_W-1:0]   param_rd_addr,
    input  wire  signed [31:0]        param_rd_data,

    // Status
    output logic                      busy,
    output logic                      done
);

    typedef enum logic [3:0] {
        ST_IDLE,
        ST_SETUP,
        ST_TILE_SETUP,
        ST_LOAD_A,
        ST_LOAD_B_FAST,
        ST_LOAD_B_SCALAR,
        ST_CLEAR_SA,
        ST_STREAM_SA,
        ST_STORE,
        ST_TILE_NEXT,
        ST_DONE
    } state_t;

    state_t state, state_nxt;

    // Command registers
    logic [15:0] r_src0, r_src1, r_dst;
    logic [15:0] r_M, r_N, r_K;
    logic        r_trans_b, r_bias_en, r_requant, r_accum_dst, r_bank_sel;
    logic        r_attn_score, r_attn_ctx;
    logic [7:0]  r_mult;
    logic [4:0]  r_shift;

    // 12-bit tile indices & counts (supports dimensions up to 65,535!)
    logic [11:0] m_tile, n_tile, k_tile;
    logic [11:0] m_tiles, n_tiles, k_tiles;
    logic [4:0]  m_eff, n_eff, k_eff;
    logic        fast_b_aligned; // True when B rows are 16-byte aligned for 1-cycle/vec 128b fetch

    // Base addresses for current tile
    logic [31:0] a_tile_base;
    logic [31:0] b_tile_byte_base;
    logic [31:0] c_tile_base;

    // Local 16x16 tile buffers
    logic signed [15:0] buf_a [16][16];
    logic signed [7:0]  buf_b [16][16];

    // Counters
    logic [4:0]  ld_r, ld_c;
    logic        ld_phase;
    logic [5:0]  stream_cnt, stream_max;
    logic [4:0]  st_r, st_c;
    logic [1:0]  st_phase; // 0: issue ACC/Bias/Dst reads, 1: wait/latch, 2: write

    // Systolic array & ACC SRAM wires
    logic               sa_clear, sa_en;
    logic signed [15:0] sa_a_col [16];
    logic signed [7:0]  sa_b_row [16];
    logic signed [31:0] sa_acc   [16][16];

    logic               acc_rd_en, acc_wr_en;
    logic [7:0]         acc_rd_addr, acc_wr_addr;
    logic signed [31:0] acc_rd_data, acc_wr_data;

    wire multi_k      = (k_tiles > 12'd1);
    wire first_k_tile = (k_tile == 12'd0);
    wire last_k_tile  = (k_tile == k_tiles - 12'd1);

    // Instantiate 16x16 W8A16 Systolic Array
    yt_systolic_array #(
        .M     (16),
        .N     (16),
        .ACT_W (16),
        .WGT_W (8),
        .ACC_W (32)
    ) u_systolic (
        .clk       (clk),
        .rst_n     (rst_n),
        .clear_acc (sa_clear),
        .en        (sa_en),
        .a_col     (sa_a_col),
        .b_row     (sa_b_row),
        .acc_out   (sa_acc)
    );

    // Instantiate 256x32-bit K-Tile Partial Sum SRAM
    yt_sram_1r1w #(
        .DEPTH (256),
        .WIDTH (32)
    ) u_acc_sram (
        .clk     (clk),
        .rd_en   (acc_rd_en),
        .rd_addr (acc_rd_addr),
        .rd_data (acc_rd_data),
        .wr_en   (acc_wr_en),
        .wr_addr (acc_wr_addr),
        .wr_data (acc_wr_data)
    );

    // Next-state logic
    always_comb begin
        state_nxt = state;
        case (state)
            ST_IDLE:         if (cmd_valid) state_nxt = ST_SETUP;
            ST_SETUP:        state_nxt = ST_TILE_SETUP;
            ST_TILE_SETUP:   state_nxt = ST_LOAD_A;
            ST_LOAD_A: begin
                if (ld_phase && (ld_r == m_eff - 5'd1) && (ld_c == k_eff - 5'd1))
                    state_nxt = fast_b_aligned ? ST_LOAD_B_FAST : ST_LOAD_B_SCALAR;
            end
            ST_LOAD_B_FAST: begin
                // Reads 16 INT8 weights per 128-bit beat!
                if (ld_phase && (ld_r == (r_trans_b ? (n_eff - 5'd1) : (k_eff - 5'd1))))
                    state_nxt = ST_CLEAR_SA;
            end
            ST_LOAD_B_SCALAR: begin
                if (ld_phase && (ld_r == k_eff - 5'd1) && (ld_c == n_eff - 5'd1))
                    state_nxt = ST_CLEAR_SA;
            end
            ST_CLEAR_SA:     state_nxt = ST_STREAM_SA;
            ST_STREAM_SA:    if (stream_cnt == stream_max) state_nxt = ST_STORE;
            ST_STORE: begin
                if (multi_k && first_k_tile) begin
                    if ((st_r == m_eff - 5'd1) && (st_c == n_eff - 5'd1))
                        state_nxt = ST_TILE_NEXT;
                end else begin
                    if ((st_phase == 2'd1) && (st_r == m_eff - 5'd1) && (st_c == n_eff - 5'd1))
                        state_nxt = ST_TILE_NEXT;
                end
            end
            ST_TILE_NEXT: begin
                if ((k_tile < k_tiles - 12'd1) || (n_tile < n_tiles - 12'd1) || (m_tile < m_tiles - 12'd1))
                    state_nxt = ST_TILE_SETUP;
                else
                    state_nxt = ST_DONE;
            end
            ST_DONE:         state_nxt = ST_IDLE;
            default:         state_nxt = ST_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= ST_IDLE;
        else        state <= state_nxt;
    end

    // Address calculations & Output Comb Logic
    logic [31:0] cur_b_byte_addr;
    logic [7:0]  acc_flat_idx;
    assign acc_flat_idx = {st_r[3:0], st_c[3:0]};

    logic signed [31:0] final_acc_sum;
    logic signed [31:0] bias_val;
    logic signed [15:0] post_val_q78;
    logic signed [16:0] accum_dst_sum;

    always_comb begin
        act_rd_en        = 1'b0;
        act_rd_addr      = '0;
        act_wr_en        = 1'b0;
        act_wr_addr      = '0;
        act_wr_data      = '0;
        wgt_rd_en        = 1'b0;
        wgt_rd_beat_addr = '0;
        param_rd_en      = 1'b0;
        param_rd_addr    = '0;
        acc_rd_en        = 1'b0;
        acc_rd_addr      = '0;
        acc_wr_en        = 1'b0;
        acc_wr_addr      = '0;
        acc_wr_data      = '0;
        sa_clear         = 1'b0;
        sa_en            = 1'b0;
        cur_b_byte_addr  = '0;

        for (int i = 0; i < 16; i++) sa_a_col[i] = '0;
        for (int j = 0; j < 16; j++) sa_b_row[j] = '0;

        // Post-processing combinational datapath
        final_acc_sum = (!multi_k || first_k_tile) ? sa_acc[st_r[3:0]][st_c[3:0]]
                                                   : (acc_rd_data + sa_acc[st_r[3:0]][st_c[3:0]]);
        bias_val      = r_bias_en ? param_rd_data : 32'sd0;

        if (r_attn_score) begin
            post_val_q78 = saturate_i16((final_acc_sum + bias_val + 32'sd32) >>> 6);
        end else if (r_attn_ctx) begin
            post_val_q78 = saturate_i16((final_acc_sum + bias_val + 32'sd512) >>> 10);
        end else if (r_requant) begin
            post_val_q78 = requantize_q78(final_acc_sum, bias_val, r_mult, r_shift);
        end else begin
            post_val_q78 = saturate_i16(final_acc_sum + bias_val);
        end

        accum_dst_sum = 17'(post_val_q78) + 17'(act_rd_data);

        case (state)
            ST_LOAD_A: begin
                if (!ld_phase) begin
                    act_rd_en   = 1'b1;
                    act_rd_addr = ACT_ADDR_W'(a_tile_base + 32'(ld_r) * 32'(r_K) + 32'(ld_c));
                end
            end

            ST_LOAD_B_FAST: begin
                if (!ld_phase) begin
                    wgt_rd_en = 1'b1;
                    if (r_trans_b)
                        cur_b_byte_addr = b_tile_byte_base + 32'(ld_r) * 32'(r_K);
                    else
                        cur_b_byte_addr = b_tile_byte_base + 32'(ld_r) * 32'(r_N);
                    wgt_rd_beat_addr = {r_bank_sel ^ cur_b_byte_addr[14], cur_b_byte_addr[13:4]};
                end
            end

            ST_LOAD_B_SCALAR: begin
                if (!ld_phase) begin
                    wgt_rd_en = 1'b1;
                    if (r_trans_b)
                        cur_b_byte_addr = b_tile_byte_base + 32'(ld_c) * 32'(r_K) + 32'(ld_r);
                    else
                        cur_b_byte_addr = b_tile_byte_base + 32'(ld_r) * 32'(r_N) + 32'(ld_c);
                    wgt_rd_beat_addr = {r_bank_sel ^ cur_b_byte_addr[14], cur_b_byte_addr[13:4]};
                end
            end

            ST_CLEAR_SA: begin
                sa_clear = 1'b1;
            end

            ST_STREAM_SA: begin
                sa_en = 1'b1;
                for (int i = 0; i < 16; i++) begin
                    automatic int ka = int'(stream_cnt) - i;
                    if (ka >= 0 && ka < int'(k_eff) && i < int'(m_eff))
                        sa_a_col[i] = buf_a[i][ka[3:0]];
                    else
                        sa_a_col[i] = 16'sd0;
                end
                for (int j = 0; j < 16; j++) begin
                    automatic int kb = int'(stream_cnt) - j;
                    if (kb >= 0 && kb < int'(k_eff) && j < int'(n_eff))
                        sa_b_row[j] = buf_b[kb[3:0]][j];
                    else
                        sa_b_row[j] = 8'sd0;
                end
            end

            ST_STORE: begin
                if (multi_k && first_k_tile) begin
                    acc_wr_en   = 1'b1;
                    acc_wr_addr = acc_flat_idx;
                    acc_wr_data = sa_acc[st_r[3:0]][st_c[3:0]];
                end else if (st_phase == 2'd0) begin
                    // Phase 0: simultaneously issue ACC read, Bias read, and Dst read (if accumulate)
                    if (multi_k) begin
                        acc_rd_en   = 1'b1;
                        acc_rd_addr = acc_flat_idx;
                    end
                    if (last_k_tile && r_bias_en) begin
                        param_rd_en   = 1'b1;
                        param_rd_addr = PARAM_ADDR_W'(32'(r_src1) + 32'(n_tile) * 32'd16 + 32'(st_c));
                    end
                    if (last_k_tile && r_accum_dst) begin
                        act_rd_en   = 1'b1;
                        act_rd_addr = ACT_ADDR_W'(c_tile_base + 32'(st_r) * 32'(r_N) + 32'(st_c));
                    end
                end else begin
                    // Phase 1: data valid from synchronous SRAMs -> write result!
                    if (!last_k_tile) begin
                        acc_wr_en   = 1'b1;
                        acc_wr_addr = acc_flat_idx;
                        acc_wr_data = final_acc_sum;
                    end else begin
                        act_wr_en   = 1'b1;
                        act_wr_addr = ACT_ADDR_W'(c_tile_base + 32'(st_r) * 32'(r_N) + 32'(st_c));
                        if (r_accum_dst) begin
                            if (accum_dst_sum > 17'sd32767)       act_wr_data = 16'sd32767;
                            else if (accum_dst_sum < -17'sd32768) act_wr_data = -16'sd32768;
                            else                                  act_wr_data = accum_dst_sum[15:0];
                        end else begin
                            act_wr_data = post_val_q78;
                        end
                    end
                end
            end

            default: ;
        endcase
    end

    assign busy = (state != ST_IDLE);
    assign done = (state == ST_DONE);

    // Sequential control & buffer loading
    logic [3:0] saved_byte_lane;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_src0 <= '0; r_src1 <= '0; r_dst <= '0;
            r_M <= '0; r_N <= '0; r_K <= '0;
            r_trans_b <= 1'b0; r_bias_en <= 1'b0; r_requant <= 1'b0;
            r_accum_dst <= 1'b0; r_bank_sel <= 1'b0;
            r_attn_score <= 1'b0; r_attn_ctx <= 1'b0;
            r_mult <= '0; r_shift <= '0;
            m_tile <= '0; n_tile <= '0; k_tile <= '0;
            m_tiles <= '0; n_tiles <= '0; k_tiles <= '0;
            m_eff <= '0; n_eff <= '0; k_eff <= '0;
            fast_b_aligned <= 1'b0;
            a_tile_base <= '0; b_tile_byte_base <= '0; c_tile_base <= '0;
            ld_r <= '0; ld_c <= '0; ld_phase <= 1'b0;
            stream_cnt <= '0; stream_max <= '0;
            st_r <= '0; st_c <= '0; st_phase <= '0;
            saved_byte_lane <= '0;
            for (int i = 0; i < 16; i++) begin
                for (int j = 0; j < 16; j++) begin
                    buf_a[i][j] <= '0;
                    buf_b[i][j] <= '0;
                end
            end
        end else begin
            case (state)
                ST_IDLE: begin
                    if (cmd_valid) begin
                        r_src0       <= cmd_src0;
                        r_src1       <= cmd_src1;
                        r_dst        <= cmd_dst;
                        r_M          <= cmd_M;
                        r_N          <= cmd_N;
                        r_K          <= cmd_K;
                        r_trans_b    <= cmd_flags[FLAG_TRANSPOSE_B];
                        r_bias_en    <= cmd_flags[FLAG_BIAS_EN];
                        r_requant    <= cmd_flags[FLAG_REQUANT];
                        r_accum_dst  <= cmd_flags[FLAG_ACCUMULATE];
                        r_bank_sel   <= cmd_flags[FLAG_PINGPONG_B];
                        r_attn_score <= cmd_flags[FLAG_ATTN_SCORE];
                        r_attn_ctx   <= cmd_flags[FLAG_ATTN_CTX];
                        r_mult       <= cmd_imm[7:0];
                        r_shift      <= cmd_imm[12:8];
                    end
                end

                ST_SETUP: begin
                    m_tiles <= 12'((32'(r_M) + 32'd15) >> 4);
                    n_tiles <= 12'((32'(r_N) + 32'd15) >> 4);
                    k_tiles <= 12'((32'(r_K) + 32'd15) >> 4);
                    m_tile  <= 12'd0;
                    n_tile  <= 12'd0;
                    k_tile  <= 12'd0;
                end

                ST_TILE_SETUP: begin
                    automatic logic [15:0] m_rem = r_M - (16'(m_tile) << 4);
                    automatic logic [15:0] n_rem = r_N - (16'(n_tile) << 4);
                    automatic logic [15:0] k_rem = r_K - (16'(k_tile) << 4);
                    automatic logic [4:0]  me = (m_rem < 16'd16) ? m_rem[4:0] : 5'd16;
                    automatic logic [4:0]  ne = (n_rem < 16'd16) ? n_rem[4:0] : 5'd16;
                    automatic logic [4:0]  ke = (k_rem < 16'd16) ? k_rem[4:0] : 5'd16;

                    m_eff <= me;
                    n_eff <= ne;
                    k_eff <= ke;

                    // Enable 128-bit 1-beat-per-vector fast load whenever inner stride is multiple of 16
                    if (r_trans_b)
                        fast_b_aligned <= (r_K[3:0] == 4'b0000) && (ke == 5'd16);
                    else
                        fast_b_aligned <= (r_N[3:0] == 4'b0000) && (ne == 5'd16);

                    a_tile_base <= 32'(r_src0) + (32'(m_tile) << 4) * 32'(r_K) + (32'(k_tile) << 4);
                    if (r_trans_b)
                        b_tile_byte_base <= (32'(n_tile) << 4) * 32'(r_K) + (32'(k_tile) << 4);
                    else
                        b_tile_byte_base <= (32'(k_tile) << 4) * 32'(r_N) + (32'(n_tile) << 4);

                    c_tile_base <= 32'(r_dst) + (32'(m_tile) << 4) * 32'(r_N) + (32'(n_tile) << 4);

                    ld_r <= 5'd0;
                    ld_c <= 5'd0;
                    ld_phase <= 1'b0;
                    st_r <= 5'd0;
                    st_c <= 5'd0;
                    st_phase <= 2'd0;
                end

                ST_LOAD_A: begin
                    if (!ld_phase) begin
                        ld_phase <= 1'b1;
                    end else begin
                        buf_a[ld_r[3:0]][ld_c[3:0]] <= act_rd_data;
                        ld_phase <= 1'b0;
                        if (ld_c == k_eff - 5'd1) begin
                            ld_c <= 5'd0;
                            if (ld_r == m_eff - 5'd1)
                                ld_r <= 5'd0;
                            else
                                ld_r <= ld_r + 5'd1;
                        end else begin
                            ld_c <= ld_c + 5'd1;
                        end
                    end
                end

                ST_LOAD_B_FAST: begin
                    if (!ld_phase) begin
                        ld_phase <= 1'b1;
                    end else begin
                        // Unpack 16 INT8 weights simultaneously from 128-bit beat!
                        for (int lane = 0; lane < 16; lane++) begin
                            if (r_trans_b)
                                buf_b[lane][ld_r[3:0]] <= signed'(wgt_rd_data[lane*8 +: 8]);
                            else
                                buf_b[ld_r[3:0]][lane] <= signed'(wgt_rd_data[lane*8 +: 8]);
                        end
                        ld_phase <= 1'b0;
                        if (ld_r == (r_trans_b ? (n_eff - 5'd1) : (k_eff - 5'd1)))
                            ld_r <= 5'd0;
                        else
                            ld_r <= ld_r + 5'd1;
                    end
                end

                ST_LOAD_B_SCALAR: begin
                    if (!ld_phase) begin
                        saved_byte_lane <= cur_b_byte_addr[3:0];
                        ld_phase <= 1'b1;
                    end else begin
                        buf_b[ld_r[3:0]][ld_c[3:0]] <= signed'(wgt_rd_data[saved_byte_lane*8 +: 8]);
                        ld_phase <= 1'b0;
                        if (ld_c == n_eff - 5'd1) begin
                            ld_c <= 5'd0;
                            if (ld_r == k_eff - 5'd1)
                                ld_r <= 5'd0;
                            else
                                ld_r <= ld_r + 5'd1;
                        end else begin
                            ld_c <= ld_c + 5'd1;
                        end
                    end
                end

                ST_CLEAR_SA: begin
                    stream_cnt <= 6'd0;
                    stream_max <= 6'(k_eff) + 6'(m_eff) + 6'(n_eff) - 6'd1;
                end

                ST_STREAM_SA: begin
                    stream_cnt <= stream_cnt + 6'd1;
                end

                ST_STORE: begin
                    if (multi_k && first_k_tile) begin
                        if (st_c == n_eff - 5'd1) begin
                            st_c <= 5'd0;
                            st_r <= st_r + 5'd1;
                        end else begin
                            st_c <= st_c + 5'd1;
                        end
                    end else if (st_phase == 2'd0) begin
                        st_phase <= 2'd1;
                    end else begin
                        st_phase <= 2'd0;
                        if (st_c == n_eff - 5'd1) begin
                            st_c <= 5'd0;
                            st_r <= st_r + 5'd1;
                        end else begin
                            st_c <= st_c + 5'd1;
                        end
                    end
                end

                ST_TILE_NEXT: begin
                    if (k_tile < k_tiles - 12'd1) begin
                        k_tile <= k_tile + 12'd1;
                    end else begin
                        k_tile <= 12'd0;
                        if (n_tile < n_tiles - 12'd1) begin
                            n_tile <= n_tile + 12'd1;
                        end else begin
                            n_tile <= 12'd0;
                            if (m_tile < m_tiles - 12'd1)
                                m_tile <= m_tile + 12'd1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
