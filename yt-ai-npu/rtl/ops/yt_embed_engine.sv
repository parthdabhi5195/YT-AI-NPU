// =============================================================================
// Hardware Token + Learned Position Embedding Engine (yt_embed_engine.sv)
// - Reads INT8 WTE[tok_id] from WGT_SRAM Bank 0 (beats 0..31 = 512 bytes)
// - Reads INT8 WPE[pos_id] from WGT_SRAM Bank 1 (beats 1024..1055 = 512 bytes)
// - Dequantizes both to Q7.8 using host-configured scales and writes
//   x[i] = clamp_i16(((wte[i]*wte_deq) >>> 8) + ((wpe[i]*wpe_deq) >>> 8))
//   into ACT_SRAM[dst_base + 0..N-1]!
// =============================================================================
`default_nettype none

module yt_embed_engine
    import yt_npu_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       cmd_valid,
    input  wire  [15:0]               cmd_length,   // Hidden dim (default 512)
    input  wire  [15:0]               cmd_dst_base, // ACT_SRAM destination word base
    input  wire  [15:0]               wte_deq_u16,  // round((1/wte_scale) * 65536)
    input  wire  [15:0]               wpe_deq_u16,  // round((1/wpe_scale) * 65536)

    // WGT_SRAM Read Port (128-bit = 16 INT8 elements/beat)
    output logic                      wgt_rd_en,
    output logic [10:0]               wgt_rd_beat_addr,
    input  wire  [127:0]              wgt_rd_data,

    // ACT_SRAM Write Port (16-bit Q7.8 elements)
    output logic                      act_wr_en,
    output logic [ACT_ADDR_W-1:0]     act_wr_addr,
    output logic signed [15:0]        act_wr_data,

    output logic                      busy,
    output logic                      done
);

    typedef enum logic [2:0] {
        S_IDLE,
        S_RD_WTE,
        S_RD_WPE,
        S_LATCH_WPE,
        S_WRITE_16,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [15:0] r_len, r_dst;
    logic [9:0]  beat_idx, total_beats;
    logic [3:0]  lane_idx;
    logic [127:0] wte_beat_buf, wpe_beat_buf;

    wire last_lane = (lane_idx == 4'd15) ||
                     (({6'b0, beat_idx, lane_idx}) == (r_len - 16'd1));
    wire last_beat = (beat_idx == total_beats - 10'd1);

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE:      if (cmd_valid) state_nxt = S_RD_WTE;
            S_RD_WTE:    state_nxt = S_RD_WPE;
            S_RD_WPE:    state_nxt = S_LATCH_WPE;
            S_LATCH_WPE: state_nxt = S_WRITE_16;
            S_WRITE_16:  if (last_lane) state_nxt = last_beat ? S_DONE : S_RD_WTE;
            S_DONE:      state_nxt = S_IDLE;
            default:     state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    // Dequantize & sum combinational math for current lane
    logic signed [7:0]  cur_wte_i8, cur_wpe_i8;
    logic signed [31:0] wte_q78, wpe_q78;
    logic signed [15:0] sum_q78;

    always_comb begin
        cur_wte_i8 = signed'(wte_beat_buf[lane_idx*8 +: 8]);
        cur_wpe_i8 = signed'(wpe_beat_buf[lane_idx*8 +: 8]);
        wte_q78    = (32'(cur_wte_i8) * 32'(signed'({1'b0, wte_deq_u16}))) >>> 8;
        wpe_q78    = (32'(cur_wpe_i8) * 32'(signed'({1'b0, wpe_deq_u16}))) >>> 8;
        sum_q78    = saturate_i16(wte_q78 + wpe_q78);
    end

    always_comb begin
        wgt_rd_en        = 1'b0;
        wgt_rd_beat_addr = '0;
        act_wr_en        = 1'b0;
        act_wr_addr      = '0;
        act_wr_data      = sum_q78;

        if (state == S_RD_WTE) begin
            wgt_rd_en        = 1'b1;
            wgt_rd_beat_addr = {1'b0, beat_idx}; // Bank 0
        end else if (state == S_RD_WPE) begin
            wgt_rd_en        = 1'b1;
            wgt_rd_beat_addr = {1'b1, beat_idx}; // Bank 1
        end else if (state == S_WRITE_16) begin
            act_wr_en   = 1'b1;
            act_wr_addr = ACT_ADDR_W'(32'(r_dst) + {18'b0, beat_idx, lane_idx});
        end
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_len <= '0; r_dst <= '0;
            beat_idx <= '0; total_beats <= '0; lane_idx <= '0;
            wte_beat_buf <= '0; wpe_beat_buf <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        r_len       <= cmd_length;
                        r_dst       <= cmd_dst_base;
                        total_beats <= 10'((32'(cmd_length) + 32'd15) >> 4);
                        beat_idx    <= 10'd0;
                        lane_idx    <= 4'd0;
                    end
                end

                S_RD_WPE: begin
                    wte_beat_buf <= wgt_rd_data;
                end

                S_LATCH_WPE: begin
                    wpe_beat_buf <= wgt_rd_data;
                    lane_idx     <= 4'd0;
                end

                S_WRITE_16: begin
                    if (last_lane) begin
                        lane_idx <= 4'd0;
                        if (!last_beat)
                            beat_idx <= beat_idx + 10'd1;
                    end else begin
                        lane_idx <= lane_idx + 4'd1;
                    end
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
