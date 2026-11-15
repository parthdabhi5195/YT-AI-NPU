// =============================================================================
// 128-Bit AXI4 Burst Write DMA & KV-Cache Q4.3 Packer Master (yt_axi_dma_wr.sv)
// - Mode 0 (OP_DMA_STORE): Reads 8 x INT16 Q7.8 elements/beat from ACT_SRAM and
//   burst-writes 128-bit beats to external DDR (with 4 KB boundary split)
// - Mode 1 (OP_KV_APPEND): Reads 16 x INT16 Q7.8 elements/beat from ACT_SRAM,
//   packs each into INT8 Q4.3 via `pack_kv_q43`, and bursts 4 beats (64 bytes)
//   per head row directly to the external DDR KV-cache!
// - Mode 2 (Single-Word Token Log): Writes 128-bit single-beat token record to
//   external DDR output buffer (`DDR_BASE_OUT + gen_idx * 16`)
// =============================================================================
`default_nettype none

module yt_axi_dma_wr
    import yt_npu_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    // Write Command Interface
    input  wire                       cmd_valid,
    input  wire  [1:0]                cmd_mode,      // 0: ACT Q7.8 store, 1: KV Q4.3 pack, 2: Imm128 single beat
    input  wire  [31:0]               cmd_ddr_addr,  // 16-byte aligned external DDR byte address
    input  wire  [23:0]               cmd_byte_len,  // Output byte length in DDR (multiple of 16)
    input  wire  [15:0]               cmd_act_base,  // Source ACT_SRAM word base
    input  wire  [127:0]              cmd_imm_beat,  // Used when cmd_mode == 2

    // AXI4 Write Address, Data & Response Channels (128-bit)
    output logic [AXI_ID_W-1:0]       m_axi_awid,
    output logic [AXI_ADDR_W-1:0]     m_axi_awaddr,
    output logic [7:0]                m_axi_awlen,
    output logic [2:0]                m_axi_awsize,
    output logic [1:0]                m_axi_awburst,
    output logic                      m_axi_awvalid,
    input  wire                       m_axi_awready,

    output logic [AXI_DATA_W-1:0]     m_axi_wdata,
    output logic [AXI_STRB_W-1:0]     m_axi_wstrb,
    output logic                      m_axi_wlast,
    output logic                      m_axi_wvalid,
    input  wire                       m_axi_wready,

    input  wire  [AXI_ID_W-1:0]       m_axi_bid,
    input  wire  [1:0]                m_axi_bresp,
    input  wire                       m_axi_bvalid,
    output logic                      m_axi_bready,

    // ACT_SRAM Read Port (16-bit Q7.8 elements, 1-cycle latency)
    output logic                      act_rd_en,
    output logic [ACT_ADDR_W-1:0]     act_rd_addr,
    input  wire  signed [15:0]        act_rd_data,

    // Status
    output logic                      busy,
    output logic                      done,
    output logic                      err
);

    wire _unused = &{m_axi_bid, 1'b0};

    typedef enum logic [3:0] {
        S_IDLE,
        S_CALC_BURST,
        S_ISSUE_AW,
        S_GATHER_RD,
        S_GATHER_LATCH,
        S_SEND_W,
        S_WAIT_B,
        S_DONE
    } state_t;

    state_t state, state_nxt;

    logic [1:0]   r_mode;
    logic [31:0]  r_ddr_addr;
    logic [19:0]  r_beats_rem;
    logic [15:0]  r_act_ptr;
    logic [127:0] r_wbuf;
    logic [8:0]   cur_burst_beats;
    logic [8:0]   beat_in_burst;
    logic [3:0]   elem_idx;
    logic         err_flag;

    wire [3:0] elems_per_beat_m1 = (r_mode == 2'd1) ? 4'd15 : 4'd7;
    logic [8:0] beats_to_4kb;
    assign beats_to_4kb = 9'd256 - {1'b0, r_ddr_addr[11:4]};

    assign m_axi_awid    = '0;
    assign m_axi_awsize  = 3'b100; // 16 bytes
    assign m_axi_awburst = 2'b01;  // INCR
    assign m_axi_wstrb   = 16'hFFFF;

    always_comb begin
        state_nxt = state;
        case (state)
            S_IDLE: begin
                if (cmd_valid)
                    state_nxt = (cmd_byte_len == 24'd0) ? S_DONE : S_CALC_BURST;
            end
            S_CALC_BURST:   state_nxt = S_ISSUE_AW;
            S_ISSUE_AW: begin
                if (m_axi_awready)
                    state_nxt = (r_mode == 2'd2) ? S_SEND_W : S_GATHER_RD;
            end
            S_GATHER_RD:    state_nxt = S_GATHER_LATCH;
            S_GATHER_LATCH: begin
                if (elem_idx == elems_per_beat_m1)
                    state_nxt = S_SEND_W;
                else
                    state_nxt = S_GATHER_RD;
            end
            S_SEND_W: begin
                if (m_axi_wready) begin
                    if (beat_in_burst == cur_burst_beats - 9'd1)
                        state_nxt = S_WAIT_B;
                    else
                        state_nxt = (r_mode == 2'd2) ? S_SEND_W : S_GATHER_RD;
                end
            end
            S_WAIT_B: begin
                if (m_axi_bvalid) begin
                    if (r_beats_rem == 20'(cur_burst_beats))
                        state_nxt = S_DONE;
                    else
                        state_nxt = S_CALC_BURST;
                end
            end
            S_DONE:  state_nxt = S_IDLE;
            default: state_nxt = S_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) state <= S_IDLE;
        else        state <= state_nxt;
    end

    assign m_axi_awaddr  = r_ddr_addr;
    assign m_axi_awlen   = 8'(cur_burst_beats - 9'd1);
    assign m_axi_awvalid = (state == S_ISSUE_AW);

    assign m_axi_wdata   = r_wbuf;
    assign m_axi_wlast   = (beat_in_burst == cur_burst_beats - 9'd1);
    assign m_axi_wvalid  = (state == S_SEND_W);

    assign m_axi_bready  = (state == S_WAIT_B);

    assign act_rd_en     = (state == S_GATHER_RD);
    assign act_rd_addr   = r_act_ptr[ACT_ADDR_W-1:0];

    assign busy = (state != S_IDLE);
    assign done = (state == S_DONE);
    assign err  = (state == S_DONE) && err_flag;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r_mode          <= '0;
            r_ddr_addr      <= '0;
            r_beats_rem     <= '0;
            r_act_ptr       <= '0;
            r_wbuf          <= '0;
            cur_burst_beats <= '0;
            beat_in_burst   <= '0;
            elem_idx        <= '0;
            err_flag        <= 1'b0;
        end else begin
            case (state)
                S_IDLE: begin
                    if (cmd_valid) begin
                        r_mode      <= cmd_mode;
                        r_ddr_addr  <= {cmd_ddr_addr[31:4], 4'b0000};
                        r_beats_rem <= (cmd_byte_len + 24'd15) >> 4;
                        r_act_ptr   <= cmd_act_base;
                        r_wbuf      <= cmd_imm_beat;
                        err_flag    <= 1'b0;
                    end
                end

                S_CALC_BURST: begin
                    if (r_beats_rem < 20'(beats_to_4kb))
                        cur_burst_beats <= r_beats_rem[8:0];
                    else
                        cur_burst_beats <= beats_to_4kb;
                    beat_in_burst <= 9'd0;
                    elem_idx      <= 4'd0;
                end

                S_GATHER_LATCH: begin
                    if (r_mode == 2'd1) begin
                        // Pack Q7.8 -> Q4.3 INT8 into lane elem_idx[3:0]
                        r_wbuf[elem_idx*8 +: 8] <= pack_kv_q43(act_rd_data);
                    end else begin
                        // Store raw Q7.8 INT16 into lane elem_idx[2:0]
                        r_wbuf[elem_idx[2:0]*16 +: 16] <= act_rd_data;
                    end
                    r_act_ptr <= r_act_ptr + 16'd1;
                    if (elem_idx == elems_per_beat_m1)
                        elem_idx <= 4'd0;
                    else
                        elem_idx <= elem_idx + 4'd1;
                end

                S_SEND_W: begin
                    if (m_axi_wready)
                        beat_in_burst <= beat_in_burst + 9'd1;
                end

                S_WAIT_B: begin
                    if (m_axi_bvalid) begin
                        if (m_axi_bresp != 2'b00) err_flag <= 1'b1;
                        r_ddr_addr  <= r_ddr_addr + ({23'b0, cur_burst_beats} << 4);
                        r_beats_rem <= r_beats_rem - 20'(cur_burst_beats);
                    end
                end

                default: ;
            endcase
        end
    end

endmodule

`default_nettype wire
