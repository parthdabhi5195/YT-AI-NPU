// =============================================================================
// Synchronous Microcode Fetch Unit (yt_ucode_fetch.sv)
// - Reads 128-bit instructions from 1024x128b UCODE_SRAM (1-cycle SRAM latency)
// - Clean 2-state handshake (F_REQ -> F_PRESENT) supporting hardware loop
//   branches (OP_LOOP_END) and step termination (OP_END / prefill early-exit)
// =============================================================================
`default_nettype none

module yt_ucode_fetch
    import yt_npu_pkg::*;
(
    input  wire                       clk,
    input  wire                       rst_n,

    // Step control from Token Sequencer / Decoder
    input  wire                       step_start,
    input  wire                       step_abort,
    input  wire  [UCODE_ADDR_W:0]     cfg_ucode_len,

    // Branch interface from OP_LOOP_END in Decoder
    input  wire                       branch_valid,
    input  wire  [UCODE_ADDR_W-1:0]   branch_target,

    // UCODE_SRAM Read Port (1-cycle synchronous latency)
    output logic                      ucode_rd_en,
    output logic [UCODE_ADDR_W-1:0]   ucode_rd_addr,
    input  wire  [127:0]              ucode_rd_data,

    // Instruction handshake to Decoder
    output logic                      instr_valid,
    output logic [127:0]              instr_data,
    output logic [UCODE_ADDR_W-1:0]   instr_pc,
    input  wire                       decode_ready,

    // Status
    output logic                      fetch_eof_pulse,
    output logic                      fetch_active
);

    typedef enum logic [1:0] {
        F_IDLE,
        F_REQ,
        F_PRESENT
    } fstate_t;

    fstate_t fstate;
    logic [UCODE_ADDR_W-1:0] pc_q;

    assign ucode_rd_en   = (fstate == F_REQ);
    assign ucode_rd_addr = pc_q;

    assign instr_valid   = (fstate == F_PRESENT);
    assign instr_data    = ucode_rd_data;
    assign instr_pc      = pc_q;
    assign fetch_active  = (fstate != F_IDLE);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fstate          <= F_IDLE;
            pc_q            <= '0;
            fetch_eof_pulse <= 1'b0;
        end else begin
            fetch_eof_pulse <= 1'b0;

            if (step_abort) begin
                fstate <= F_IDLE;
            end else begin
                case (fstate)
                    F_IDLE: begin
                        if (step_start) begin
                            pc_q <= '0;
                            if (cfg_ucode_len == '0) begin
                                fetch_eof_pulse <= 1'b1;
                                fstate          <= F_IDLE;
                            end else begin
                                fstate          <= F_REQ;
                            end
                        end
                    end

                    F_REQ: begin
                        fstate <= F_PRESENT;
                    end

                    F_PRESENT: begin
                        if (decode_ready) begin
                            if (branch_valid) begin
                                pc_q   <= branch_target;
                                fstate <= F_REQ;
                            end else if (({1'b0, pc_q} + {{UCODE_ADDR_W{1'b0}}, 1'b1}) >= cfg_ucode_len) begin
                                fetch_eof_pulse <= 1'b1;
                                fstate          <= F_IDLE;
                            end else begin
                                pc_q   <= pc_q + {{(UCODE_ADDR_W-1){1'b0}}, 1'b1};
                                fstate <= F_REQ;
                            end
                        end
                    end

                    default: fstate <= F_IDLE;
                endcase
            end
        end
    end

endmodule

`default_nettype wire
