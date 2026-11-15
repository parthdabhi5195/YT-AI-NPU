// =============================================================================
// Q7.8 Piecewise + LUT GELU Activation Engine (yt_gelu_engine.sv)
// - Exact asymptotes outside [-4.0, +4.0):
//     x >= +1024 (+4.0 in Q7.8) -> y = x
//     x <  -1024 (-4.0 in Q7.8) -> y = 0
// - 256-entry Q7.8 GELU ROM inside [-4.0, +4.0) indexed by (x >>> 3) & 0xFF
// =============================================================================
`default_nettype none

module yt_gelu_engine
    import yt_npu_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    input  wire                       cmd_valid,
    input  wire  [15:0]               cmd_rows,     // M rows
    input  wire  [15:0]               cmd_length,   // N cols
    input  wire  [15:0]               cmd_src_base, // ACT_SRAM input base
    input  wire  [15:0]               cmd_dst_base, // ACT_SRAM output base

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
        S_RD,
        S_LUT,
        S_WR,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [31:0] r_total, r_idx;
    logic [15:0] r_src, r_dst;
    logic signed [15:0] x_latched;
    logic        [7:0]  lut_addr;
    wire  signed [15:0] lut_dout;

    yt_gelu_lut u_gelu_rom (
        .clk      (clk),
        .addr     (lut_addr),
        .data_out (lut_dout)
    );

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: if (cmd_valid) state_nxt = S_RD;
            S_RD:   state_nxt = S_LUT;
            S_LUT:  state_nxt = S_WR;
            S_WR:   state_nxt = (r_idx == r_total - 32'd1) ? S_DONE : S_RD;
            S_DONE: state_nxt = S_IDLE;
            default: state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    wire signed [15:0] shifted_idx = act_rd_data >>> 3;
    assign lut_addr    = shifted_idx[7:0];
    assign act_rd_en   = (state == S_RD);
    assign act_rd_addr = ACT_ADDR_W'(32'(r_src) + r_idx);
    assign act_wr_en   = (state == S_WR);
    assign act_wr_addr = ACT_ADDR_W'(32'(r_dst) + r_idx);
    assign act_wr_data = (x_latched >= 16'sd1024) ? x_latched :
                         (x_latched < -16'sd1024) ? 16'sd0    : lut_dout;

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_total   <= '0;
            r_idx     <= '0;
            r_src     <= '0;
            r_dst     <= '0;
            x_latched <= '0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        automatic logic [15:0] m_eff = (cmd_rows == 16'd0) ? 16'd1 : cmd_rows;
                        r_total <= 32'(m_eff) * 32'(cmd_length);
                        r_idx   <= 32'd0;
                        r_src   <= cmd_src_base;
                        r_dst   <= cmd_dst_base;
                    end
                end
                S_LUT: begin
                    x_latched <= act_rd_data;
                end
                S_WR: begin
                    if (r_idx < r_total - 32'd1)
                        r_idx <= r_idx + 32'd1;
                end
                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
