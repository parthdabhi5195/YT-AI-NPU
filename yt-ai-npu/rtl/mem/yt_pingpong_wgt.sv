// =============================================================================
// Ping-Pong Double-Buffered 128-bit Weight & KV-Cache Tile SRAM
// Total Capacity: 32 KB (Bank 0 = 16 KB [1024x128b], Bank 1 = 16 KB [1024x128b])
// Allows AXI4 DMA to prefetch the NEXT weight/KV tile into Bank ~sel while
// the GEMM/GEMV engine streams 16 INT8 weights/cycle out of Bank sel!
// Also supports unified 32 KB addressing (addr[10] selects bank) when full
// 512x64 (32 KB) KV-cache head slices are read.
// =============================================================================
`default_nettype none

module yt_pingpong_wgt (
    input  wire          clk,

    // DMA / KV-Read Write Port (128-bit = 16 INT8 elements/cycle)
    input  wire          dma_wr_en,
    input  wire  [10:0]  dma_wr_beat_addr, // [10] = bank select (0..2047 beats = 32 KB)
    input  wire  [127:0] dma_wr_data,

    // GEMM / Compute Read Port (128-bit = 16 INT8 elements/cycle, 1-cycle latency)
    input  wire          comp_rd_en,
    input  wire  [10:0]  comp_rd_beat_addr, // [10] = bank select
    output logic [127:0] comp_rd_data
);

    wire b0_wr = dma_wr_en  && !dma_wr_beat_addr[10];
    wire b1_wr = dma_wr_en  &&  dma_wr_beat_addr[10];
    wire b0_rd = comp_rd_en && !comp_rd_beat_addr[10];
    wire b1_rd = comp_rd_en &&  comp_rd_beat_addr[10];

    wire [127:0] b0_dout, b1_dout;
    logic        rd_bank_q;

    yt_sram_1r1w #(
        .DEPTH (1024),
        .WIDTH (128)
    ) u_wgt_bank0 (
        .clk     (clk),
        .rd_en   (b0_rd),
        .rd_addr (comp_rd_beat_addr[9:0]),
        .rd_data (b0_dout),
        .wr_en   (b0_wr),
        .wr_addr (dma_wr_beat_addr[9:0]),
        .wr_data (dma_wr_data)
    );

    yt_sram_1r1w #(
        .DEPTH (1024),
        .WIDTH (128)
    ) u_wgt_bank1 (
        .clk     (clk),
        .rd_en   (b1_rd),
        .rd_addr (comp_rd_beat_addr[9:0]),
        .rd_data (b1_dout),
        .wr_en   (b1_wr),
        .wr_addr (dma_wr_beat_addr[9:0]),
        .wr_data (dma_wr_data)
    );

    always_ff @(posedge clk) begin
        if (comp_rd_en)
            rd_bank_q <= comp_rd_beat_addr[10];
    end

    assign comp_rd_data = rd_bank_q ? b1_dout : b0_dout;

endmodule

`default_nettype wire
