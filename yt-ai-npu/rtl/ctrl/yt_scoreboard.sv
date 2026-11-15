// =============================================================================
// 8-Engine Hardware Scoreboard (yt_scoreboard.sv)
// Tracks active operations across GEMM, Softmax, LayerNorm, GELU, Vec, DMA,
// Embed, and Top-K Sampler to prevent hazards and implement OP_BARRIER.
// =============================================================================
`default_nettype none

module yt_scoreboard
    import yt_npu_pkg::*;
(
    input  wire                   clk,
    input  wire                   rst_n,
    input  wire                   clear,

    // Dispatch from ucode decoder
    input  wire                   issue_valid,
    input  wire  [2:0]            issue_engine_id,

    // Completion pulses from all 8 engines
    input  wire  [NUM_ENGINES-1:0] engine_done,

    // Status outputs
    output logic [NUM_ENGINES-1:0] engine_busy,
    output wire                    all_idle
);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            engine_busy <= '0;
        end else if (clear) begin
            engine_busy <= '0;
        end else begin
            for (int i = 0; i < NUM_ENGINES; i++) begin
                if (issue_valid && (issue_engine_id == i[2:0]))
                    engine_busy[i] <= 1'b1;
                else if (engine_done[i])
                    engine_busy[i] <= 1'b0;
            end
        end
    end

    assign all_idle = (engine_busy == '0);

endmodule

`default_nettype wire
