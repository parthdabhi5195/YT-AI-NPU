// =============================================================================
// 128-Bit AXI4 Burst Read DMA Master (yt_axi_dma_rd.sv)
// - Streams INT8 weights, KV-cache slices, LN gamma/beta, INT32 biases, or
//   Q7.8 activations from external DDR into WGT_SRAM, PARAM_SRAM, or ACT_SRAM
// - Automatically splits transfers at AXI4 4 KB (0x1000) address boundaries
//   and max 256-beat INCR bursts (1.6 GB/s @ 100 MHz)
// =============================================================================
`default_nettype none

module yt_axi_dma_rd
    import yt_npu_pkg::*;
    import yt_isa_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    // DMA Read Command
    input  wire                       cmd_valid,
    input  wire  [31:0]               cmd_ddr_addr,  // 16-byte aligned external DDR byte address
    input  wire  [23:0]               cmd_byte_len,  // Transfer byte length (multiple of 16)
    input  wire  [1:0]                cmd_target,    // DMA_TGT_WGT0, WGT1, PARAM, ACT
    input  wire  [15:0]               cmd_sram_base, // Beat addr (WGT) or word addr (PARAM/ACT)

    // AXI4 Read Address & Data Channels (128-bit)
    output logic [AXI_ID_W-1:0]       m_axi_arid,
    output logic [AXI_ADDR_W-1:0]     m_axi_araddr,
    output logic [7:0]                m_axi_arlen,
    output logic [2:0]                m_axi_arsize,
    output logic [1:0]                m_axi_arburst,
    output logic                      m_axi_arvalid,
    input  wire                       m_axi_arready,

    input  wire  [AXI_ID_W-1:0]       m_axi_rid,
    input  wire  [AXI_DATA_W-1:0]     m_axi_rdata,
    input  wire  [1:0]                m_axi_rresp,
    input  wire                       m_axi_rlast,
    input  wire                       m_axi_rvalid,
    output logic                      m_axi_rready,

    // WGT_SRAM Write Port (128-bit = 16 bytes/cycle)
    output logic                      wgt_wr_en,
    output logic [10:0]               wgt_wr_beat_addr,
    output logic [127:0]              wgt_wr_data,

    // PARAM_SRAM Write Port (32-bit = 4 words unpacked per 128-bit beat)
    output logic                      param_wr_en,
    output logic [PARAM_ADDR_W-1:0]   param_wr_addr,
    output logic [31:0]               param_wr_data,

    // ACT_SRAM Write Port (16-bit = 8 words unpacked per 128-bit beat)
    output logic                      act_wr_en,
    output logic [ACT_ADDR_W-1:0]     act_wr_addr,
    output logic signed [15:0]        act_wr_data,

    // Status
    output logic                      busy,
    output logic                      done,
    output logic                      err
);

    wire _unused = &{m_axi_rid, 1'b0};

    typedef enum logic [2:0] {
        S_IDLE,
        S_CALC_BURST,
        S_ISSUE_AR,
        S_RECV_BEAT,
        S_UNPACK,
        S_BURST_NEXT,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [31:0] r_ddr_addr;
    logic [19:0] r_beats_rem;   // Remaining 16-byte beats
    logic [1:0]  r_target;
    logic [15:0] r_sram_ptr;    // Beat ptr (WGT) or word ptr (PARAM/ACT)
    logic [8:0]  cur_burst_beats; // 1..256 beats in current AXI burst
    logic [8:0]  beat_in_burst;
    logic [2:0]  sub_idx;       // Unpack index: 0..3 (PARAM) or 0..7 (ACT)
    logic [127:0] beat_buf;
    logic        was_last_beat;
    logic        err_flag;

    wire is_wgt_tgt = (r_target == DMA_TGT_WGT0) || (r_target == DMA_TGT_WGT1);
    wire [2:0] sub_max = (r_target == DMA_TGT_PARAM) ? 3'd3 : 3'd7;

    // 4 KB boundary check: beats until next 0x1000 boundary = 256 - addr[11:4]
    logic [8:0] beats_to_4kb;
    assign beats_to_4kb = 9'd256 - {1'b0, r_ddr_addr[11:4]};

    // Fixed AXI4 constants
    assign m_axi_arid    = '0;
    assign m_axi_arsize  = 3'b100; // 16 bytes (128-bit)
    assign m_axi_arburst = 2'b01;  // INCR

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: begin
                if (cmd_valid)
                    state_nxt = (cmd_byte_len == 24'd0) ? S_DONE : S_CALC_BURST;
            end
            S_CALC_BURST: state_nxt = S_ISSUE_AR;
            S_ISSUE_AR:   if (m_axi_arready) state_nxt = S_RECV_BEAT;
            S_RECV_BEAT: begin
                if (m_axi_rvalid) begin
                    if (is_wgt_tgt) begin
                        if (m_axi_rlast || (beat_in_burst == cur_burst_beats - 9'd1))
                            state_nxt = S_BURST_NEXT;
                        else
                            state_nxt = S_RECV_BEAT;
                    end else begin
                        state_nxt = S_UNPACK;
                    end
                end
            end
            S_UNPACK: begin
                if (sub_idx == sub_max)
                    state_nxt = was_last_beat ? S_BURST_NEXT : S_RECV_BEAT;
            end
            S_BURST_NEXT: begin
                if (r_beats_rem == 20'd0)
                    state_nxt = S_DONE;
                else
                    state_nxt = S_CALC_BURST;
            end
            S_DONE:  state_nxt = S_IDLE;
            default: state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    // Combinational AXI & SRAM write outputs
    always_comb begin
        m_axi_araddr     = r_ddr_addr;
        m_axi_arlen      = 8'(cur_burst_beats - 9'd1);
        m_axi_arvalid    = (state == S_ISSUE_AR);
        m_axi_rready     = (state == S_RECV_BEAT);

        wgt_wr_en        = 1'b0;
        wgt_wr_beat_addr = '0;
        wgt_wr_data      = m_axi_rdata;

        param_wr_en      = 1'b0;
        param_wr_addr    = '0;
        param_wr_data    = '0;

        act_wr_en        = 1'b0;
        act_wr_addr      = '0;
        act_wr_data      = '0;

        if ((state == S_RECV_BEAT) && m_axi_rvalid) begin
            if (is_wgt_tgt) begin
                wgt_wr_en        = 1'b1;
                wgt_wr_beat_addr = r_sram_ptr[10:0];
                wgt_wr_data      = m_axi_rdata;
            end else if (r_target == DMA_TGT_PARAM) begin
                // Write word 0 immediately on beat arrival; words 1..3 in S_UNPACK
                param_wr_en   = 1'b1;
                param_wr_addr = r_sram_ptr[PARAM_ADDR_W-1:0];
                param_wr_data = m_axi_rdata[31:0];
            end else begin
                // Write word 0 immediately on beat arrival; words 1..7 in S_UNPACK
                act_wr_en   = 1'b1;
                act_wr_addr = r_sram_ptr[ACT_ADDR_W-1:0];
                act_wr_data = signed'(m_axi_rdata[15:0]);
            end
        end else if (state == S_UNPACK) begin
            if (r_target == DMA_TGT_PARAM) begin
                param_wr_en   = 1'b1;
                param_wr_addr = r_sram_ptr[PARAM_ADDR_W-1:0];
                param_wr_data = beat_buf[sub_idx[1:0]*32 +: 32];
            end else begin
                act_wr_en   = 1'b1;
                act_wr_addr = r_sram_ptr[ACT_ADDR_W-1:0];
                act_wr_data = signed'(beat_buf[sub_idx*16 +: 16]);
            end
        end
    end

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);
    assign err  = (state == S_DONE) && err_flag;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_ddr_addr      <= '0;
            r_beats_rem     <= '0;
            r_target        <= '0;
            r_sram_ptr      <= '0;
            cur_burst_beats <= '0;
            beat_in_burst   <= '0;
            sub_idx         <= '0;
            beat_buf        <= '0;
            was_last_beat   <= 1'b0;
            err_flag        <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        r_ddr_addr  <= {cmd_ddr_addr[31:4], 4'b0000};
                        r_beats_rem <= (cmd_byte_len + 24'd15) >> 4;
                        r_target    <= cmd_target;
                        if (cmd_target == DMA_TGT_WGT1)
                            r_sram_ptr <= {5'b0, 1'b1, cmd_sram_base[9:0]};
                        else
                            r_sram_ptr <= cmd_sram_base;
                        err_flag    <= 1'b0;
                    end
                end

                S_CALC_BURST: begin
                    if (r_beats_rem < 20'(beats_to_4kb))
                        cur_burst_beats <= r_beats_rem[8:0];
                    else
                        cur_burst_beats <= beats_to_4kb;
                    beat_in_burst <= 9'd0;
                end

                S_RECV_BEAT: begin
                    if (m_axi_rvalid) begin
                        if (m_axi_rresp != 2'b00) err_flag <= 1'b1;
                        beat_in_burst <= beat_in_burst + 9'd1;
                        r_sram_ptr    <= r_sram_ptr + 16'd1;
                        if (!is_wgt_tgt) begin
                            beat_buf      <= m_axi_rdata;
                            sub_idx       <= 3'd1;
                            was_last_beat <= m_axi_rlast || (beat_in_burst == cur_burst_beats - 9'd1);
                        end
                    end
                end

                S_UNPACK: begin
                    r_sram_ptr <= r_sram_ptr + 16'd1;
                    sub_idx    <= sub_idx + 3'd1;
                end

                S_BURST_NEXT: begin
                    r_ddr_addr  <= r_ddr_addr + ({23'b0, cur_burst_beats} << 4);
                    r_beats_rem <= r_beats_rem - 20'(cur_burst_beats);
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
