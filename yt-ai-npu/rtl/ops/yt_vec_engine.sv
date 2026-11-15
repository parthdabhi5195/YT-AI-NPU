// =============================================================================
// Q7.8 Vector ALU & 2D Head Scatter/Gather Engine (yt_vec_engine.sv)
// - Operations: VEC_OP_ADD, VEC_OP_MUL, VEC_OP_SCALE_SHIFT, VEC_OP_CLAMP
// - COPY2D Mode: Strided 2D copy [M, N] from src0 (stride K) to dst (stride imm)
// - Operates cleanly on single 1R1W ACT_SRAM (sequences src0 & src1 reads)
// =============================================================================
`default_nettype none

module yt_vec_engine
    import yt_npu_pkg::*;
    import yt_isa_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       cmd_valid,
    input  wire  [7:0]                cmd_flags,
    input  wire  [15:0]               cmd_M,        // Rows
    input  wire  [15:0]               cmd_N,        // Cols / Length
    input  wire  [15:0]               cmd_K,        // COPY2D src stride
    input  wire  [15:0]               cmd_imm,      // COPY2D dst stride or {shift, scale}
    input  wire  [15:0]               cmd_src0,
    input  wire  [15:0]               cmd_src1,
    input  wire  [15:0]               cmd_dst,

    output logic                      act_rd_en,
    output logic [ACT_ADDR_W-1:0]     act_rd_addr,
    input  wire  signed [15:0]        act_rd_data,

    output logic                      act_wr_en,
    output logic [ACT_ADDR_W-1:0]     act_wr_addr,
    output logic signed [15:0]        act_wr_data,

    output logic                      busy,
    output logic                      done
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_RD0,
        S_RD1,
        S_WR,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [1:0]  r_op;
    logic        r_copy2d;
    logic [15:0] r_rows, r_cols, r_src_stride, r_dst_stride;
    logic [15:0] r_src0, r_src1, r_dst;
    logic [7:0]  r_scale;
    logic [4:0]  r_shift;

    logic [31:0] r_total, r_idx;
    logic [15:0] r_row, r_col;
    logic signed [15:0] val_a, val_b;

    wire need_src1 = !r_copy2d && ((r_op == VEC_OP_ADD) || (r_op == VEC_OP_MUL));
    wire last_elem = r_copy2d ? ((r_row == r_rows - 16'd1) && (r_col == r_cols - 16'd1))
                              : (r_idx == r_total - 32'd1);

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: if (cmd_valid) state_nxt = S_RD0;
            S_RD0:  state_nxt = S_RD1;
            S_RD1:  state_nxt = S_WR;
            S_WR:   state_nxt = last_elem ? S_DONE : S_RD0;
            S_DONE: state_nxt = S_IDLE;
            default: state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    logic signed [15:0] alu_out;
    always_comb begin
        automatic logic signed [31:0] sum32  = 32'(val_a) + 32'(act_rd_data);
        automatic logic signed [31:0] prod32 = (32'(val_a) * 32'(act_rd_data) + 32'sd128) >>> 8;
        automatic logic signed [31:0] scl32  = (32'(val_a) * 32'(signed'({1'b0, r_scale}))) >>> r_shift;

        if (r_copy2d) begin
            alu_out = val_a;
        end else begin
            case (r_op)
                VEC_OP_ADD:         alu_out = saturate_i16(sum32);
                VEC_OP_MUL:         alu_out = saturate_i16(prod32);
                VEC_OP_SCALE_SHIFT: alu_out = saturate_i16(scl32);
                default:            alu_out = val_a;
            endcase
        end
    end

    always_comb begin
        act_rd_en   = 1'b0;
        act_rd_addr = '0;
        act_wr_en   = 1'b0;
        act_wr_addr = '0;
        act_wr_data = alu_out;

        if (state == S_RD0) begin
            act_rd_en   = 1'b1;
            act_rd_addr = r_copy2d ? ACT_ADDR_W'(32'(r_src0) + 32'(r_row) * 32'(r_src_stride) + 32'(r_col))
                                   : ACT_ADDR_W'(32'(r_src0) + r_idx);
        end else if (state == S_RD1 && need_src1) begin
            act_rd_en   = 1'b1;
            act_rd_addr = ACT_ADDR_W'(32'(r_src1) + r_idx);
        end else if (state == S_WR) begin
            act_wr_en   = 1'b1;
            act_wr_addr = r_copy2d ? ACT_ADDR_W'(32'(r_dst) + 32'(r_row) * 32'(r_dst_stride) + 32'(r_col))
                                   : ACT_ADDR_W'(32'(r_dst) + r_idx);
        end
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_op <= '0; r_copy2d <= 1'b0;
            r_rows <= '0; r_cols <= '0; r_src_stride <= '0; r_dst_stride <= '0;
            r_src0 <= '0; r_src1 <= '0; r_dst <= '0;
            r_scale <= '0; r_shift <= '0;
            r_total <= '0; r_idx <= '0; r_row <= '0; r_col <= '0;
            val_a <= '0; val_b <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        automatic logic [15:0] m_eff = (cmd_M == 16'd0) ? 16'd1 : cmd_M;
                        r_op         <= cmd_flags[1:0];
                        r_copy2d     <= cmd_flags[FLAG_VEC_COPY2D];
                        r_rows       <= m_eff;
                        r_cols       <= cmd_N;
                        r_src_stride <= cmd_K;
                        r_dst_stride <= cmd_imm;
                        r_scale      <= cmd_imm[7:0];
                        r_shift      <= cmd_imm[12:8];
                        r_src0       <= cmd_src0;
                        r_src1       <= cmd_src1;
                        r_dst        <= cmd_dst;
                        r_total      <= 32'(m_eff) * 32'(cmd_N);
                        r_idx        <= 32'd0;
                        r_row        <= 16'd0;
                        r_col        <= 16'd0;
                    end
                end

                S_RD1: begin
                    val_a <= act_rd_data;
                end

                S_WR: begin
                    if (!last_elem) begin
                        if (r_copy2d) begin
                            if (r_col == r_cols - 16'd1) begin
                                r_col <= 16'd0;
                                r_row <= r_row + 16'd1;
                            end else begin
                                r_col <= r_col + 16'd1;
                            end
                        end else begin
                            r_idx <= r_idx + 32'd1;
                        end
                    end
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
