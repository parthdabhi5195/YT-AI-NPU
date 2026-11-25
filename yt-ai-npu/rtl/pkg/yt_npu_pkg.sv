// =============================================================================
// YT-AI NPU Package (yt_npu_pkg.sv)
// Custom Silicon Inference Accelerator for the 51.2M-Parameter YT-AI SLM
// Target: SkyWater SKY130 (OpenLane 2 -> GDSII) & FPGA (Vivado / Yosys)
//
// Summary:
// master constants.py + math_helpers.py file for the hardware.
// It doesn not build any circuits by itself, but instead, every engine and controller 
// in rtl/ imports it, so the entire chip agrees on the same sizes, addresses,
// and math rules
// =============================================================================

// header guard so the file isn't compiled twice
`ifndef YT_NPU_PKG_SV
`define YT_NPU_PKG_SV

// bundles all shared constants, enums, and helper functions into one namespace
package yt_npu_pkg;

    // =========================================================================
    // YT-AI 51,213,824-Parameter Model Architecture Constants
    // =========================================================================
    parameter int YT_LAYERS      = 8;
    parameter int YT_HEADS       = 8;
    parameter int YT_HEAD_DIM    = 64;
    parameter int YT_HIDDEN      = 512;    // 8 heads x 64 dim
    parameter int YT_HIDDEN_LOG2 = 9;      // 2^9 = 512 (enables divider-free LayerNorm via shifting right 9 bits)
    parameter int YT_FFN_DIM     = 2048;   // 4 x 512 (executed in 4 fused 512-slices so intermediate vectors fit on-chip SRAM)
    parameter int YT_FFN_SLICE   = 512;
    parameter int YT_MAX_SEQ     = 512;    // Context window (stories cap ~500 tokens)
    parameter int YT_VOCAB_SIZE  = 50257;  // GPT-2 BPE vocabulary
    parameter int YT_VOCAB_PAD   = 50304;  // Padded to 64-token tile boundary (786 x 64)
    parameter logic [15:0] YT_EOT_TOKEN = 16'd50256; // <|endoftext|> = 50256

    // =========================================================================
    // Hardware Compute Array & Precision Parameters (W8A16 + INT8 KV-Cache)
    // =========================================================================
    parameter int ARRAY_M        = 16;     // Systolic rows (tokens / batch)
    parameter int ARRAY_N        = 16;     // Systolic cols (output channels)
    parameter int NUM_MACS       = ARRAY_M * ARRAY_N; // 256 W8A16 MACs

    parameter int WGT_W          = 8;      // INT8 signed weights & Q4.3 KV-cache
    parameter int ACT_W          = 16;     // INT16 signed Q7.8 activations
    parameter int ACC_W          = 32;     // INT32 signed accumulators & biases

    // Bus widths
    // AXI (Advanced eXtensible Interface) is basically like a USB inside chip
    // It lets different hardware blocks like CPU, NPU, and DDR memory talk to each other

    // 128 bit highway to external DDR RAM
    parameter int AXI_DATA_W     = 128;    // moves 16 INT8 weights or 8 INT16 activations from DDR RAM to NPU each cycle
    parameter int AXI_ADDR_W     = 32;     // capable of 4 GB byte address space in RAM (64 MB used by NPU)
    parameter int AXI_STRB_W     = AXI_DATA_W / 8;
    parameter int AXI_ID_W       = 4; // 4 bit transaction tag (0...15) used in AXI4 to match out of order responses to requests

    // 32 bit highway connecting to a host CPU
    parameter int AXIL_DATA_W    = 32; // every control register is 32 bits wide
    parameter int AXIL_ADDR_W    = 32; // 32 bit address bus used by host CPU to select which register inside yt_axi_lite_regs.sv to read/write

    // =========================================================================
    // On-Chip SRAM Sizing (83 KB Total - Fits Single SKY130 MPW Die!)
    // =========================================================================
    parameter int ACT_SRAM_WORDS   = 16384; // 16,384 x 16b words = 32 KB (activations)
    parameter int ACT_ADDR_W       = 14;
    parameter int WGT_BANK_BEATS   = 1024;  // 1,024 x 128b = 16 KB per ping-pong bank
    parameter int WGT_TOTAL_BYTES  = 32768; // 2 x 16 KB = 32 KB total weight/KV tile SRAM
    parameter int WGT_ADDR_W       = 15;
    parameter int PARAM_SRAM_WORDS = 2048;  // 2,048 x 32b = 8 KB (LN gamma/beta + INT32 bias)
    parameter int PARAM_ADDR_W     = 11;
    parameter int UCODE_DEPTH      = 1024;  // 1,024 x 128b = 16 KB microcode SRAM (fits full 8-layer program!)
    parameter int UCODE_ADDR_W     = 10;
    parameter int TOK_SRAM_DEPTH   = 512;   // 512 x 16b = 1 KB token context buffer
    parameter int TOPK_MAX_K       = 256;   // Up to Top-256 hardware sampling (YT-AI default: 200)

    // =========================================================================
    // External DDR Memory Map Base Offsets (64-Byte Aligned)
    // basically hardcoded pointers telling DMA where everything lives in external RAM
    // =========================================================================
    parameter logic [31:0] DDR_OFFSET_WTE    = 32'h0000_0000; // start address for token embeddings [50304, 512] INT8 (25.75 MB, tied w/ LM head)
    parameter logic [31:0] DDR_OFFSET_WPE    = 32'h0189_0000; // start address for position embeddings [512, 512]   INT8 (256 KB)
    parameter logic [31:0] DDR_OFFSET_BLOCKS = 32'h018D_0000; // start address for 8 transformer blocks. 8 blocks x 0x0030_6000 stride
    parameter logic [31:0] DDR_BLOCK_STRIDE  = 32'h0030_6000; // 3,170,304 B per block
    parameter logic [31:0] DDR_OFFSET_LNF    = 32'h0310_0000; // Final LN gamma/beta + scale table
    parameter logic [31:0] DDR_OFFSET_KV     = 32'h0320_0000; // 4.00 MB KV cache [8][8][2][512][64]
    parameter logic [31:0] DDR_OFFSET_OUT    = 32'h0360_0000; // Generated story token output ring

    // Byte offsets inside a single transformer block (LN1, LN2, QKV,...) to know where each section lives
    parameter logic [31:0] BLK_OFF_LN1_PARAM = 32'h0000_0000; // 2048 B
    parameter logic [31:0] BLK_OFF_LN2_PARAM = 32'h0000_0800; // 2048 B
    parameter logic [31:0] BLK_OFF_QKV_BIAS  = 32'h0000_1000; // 6144 B
    parameter logic [31:0] BLK_OFF_WO_BIAS   = 32'h0000_2800; // 2048 B
    parameter logic [31:0] BLK_OFF_FC_BIAS   = 32'h0000_3000; // 8192 B
    parameter logic [31:0] BLK_OFF_PROJ_BIAS = 32'h0000_5000; // 2048 B
    parameter logic [31:0] BLK_OFF_WQKV      = 32'h0000_6000; // 786,432 B (8 heads x 3 x 32 KB)
    parameter logic [31:0] BLK_OFF_WO        = 32'h000C_6000; // 262,144 B
    parameter logic [31:0] BLK_OFF_WFC       = 32'h0010_6000; // 1,048,576 B
    parameter logic [31:0] BLK_OFF_WPROJ     = 32'h0020_6000; // 1,048,576 B

    // =========================================================================
    // Engine IDs (8 Hardware Engines Tracked by Scoreboard)
    // =========================================================================
    parameter int NUM_ENGINES = 8;

    // enum assigning IDs 0 to 7 to the 8 hardware engines, so scoreboard can track while engine is currently busy
    typedef enum logic [2:0] {
        ENG_GEMM      = 3'd0,
        ENG_SOFTMAX   = 3'd1,
        ENG_LAYERNORM = 3'd2,
        ENG_GELU      = 3'd3,
        ENG_VEC       = 3'd4,
        ENG_DMA       = 3'd5,
        ENG_EMBED     = 3'd6,
        ENG_TOPK      = 3'd7
    } engine_id_t;

    // =========================================================================
    // AXI4-Lite Host Register Map (Memory Mapped I/O)
    // CPU is only able to read and write to addresses
    // In memory mapped IO, if CPU wants to read or write to a specific address (address, value),
    // it first goes through an address router, where each specific IO you want fits in a range of addresses.
    // Example, DDR may be from 0x0000... and NPU may be from 0x00.. 0x5C
    // if an CPU wants to write or read from an address anything between 0x00 to 0x5C, each specific address in this 
    // range corresponds to a specific command that is controlled by yt_axi_llite_regs.sv, where most addresses just 
    // save numbers to a flipflop 0x08 to 0x34, 0xh4c - 0xh5c send the 128 bit instruction, and so on
    // These are 24 named addresses that let the host do 4 things
    //      upload microcode program
    //      set config
    //      send input & read output tokens
    //      press start and monitor progress
    //   +-------------------------------------------------------------------------+
    //   |                              HOST CPU                                   |
    //   |  Only knows how to read/write 32-bit numbers to addresses (`addr, val`) |
    //   +-------------------+-----------------------------------+-----------------+
    //                       |                                   ^
    //                       v (CPU issues read/write to addr)   | `irq` wire (1 bit: "I'm done!")
    //            +----------+----------+                        |
    //            |   ADDRESS ROUTER    |                        |
    //            | (SoC Interconnect)  |                        |
    //            +----+------------+---+                        |
    //                 |            |                            |
    //      addr is in |            | addr is in NPU's           |
    //      RAM range  |            | range (base + 0x00..0x5C)  |
    //      (0x0000..) |            |  --> THIS IS MMIO!         |
    //                 v            v                            |
    //    +-------------+----+   +---+----------------------------+-----------------+
    //    |   EXTERNAL DDR   |   |  s_axil_* (32-bit AXI4-Lite Slave)               |
    //    |     (64 MB)      |   |  -> `yt_axi_lite_regs.sv` (24 control slots)     |
    //    |                  |   |                                                  |
    //    | - 49 MB weights  |<=>|  m_axi_* (128-bit AXI4 Master DMA)               |
    //    | - 4 MB KV-cache  |   |  -> `yt_axi_dma_rd/wr.sv` (1.6 GB/s bulk stream) |
    //    +------------------+   |                                                  |
    //                           |              YT-AI NPU (`yt_npu_top.sv`)         |
    //                           +--------------------------------------------------+

    // =========================================================================
    parameter logic [7:0] REG_CTRL           = 8'h00; // [0]=start, [1]=soft_rst, [2]=autogen_mode, [3]=irq_en
    parameter logic [7:0] REG_STATUS         = 8'h04; // [0]=done, [1]=busy, [2]=err, [3]=eot_hit, [15:8]=tok_avail
    parameter logic [7:0] REG_UCODE_LEN      = 8'h08; // Number of instructions in UCODE_SRAM
    parameter logic [7:0] REG_DDR_BASE_WGT   = 8'h0C; // External DDR base for weights.bin (default 0)
    parameter logic [7:0] REG_DDR_BASE_KV    = 8'h10; // External DDR base for KV cache (default 0x03200000)
    parameter logic [7:0] REG_DDR_BASE_OUT   = 8'h14; // External DDR base for output tokens
    parameter logic [7:0] REG_PROMPT_LEN     = 8'h18; // Number of prompt tokens loaded
    parameter logic [7:0] REG_MAX_NEW_TOKENS = 8'h1C; // Max tokens to generate (up to 512)
    parameter logic [7:0] REG_TEMP_INV_Q88   = 8'h20; // Inverse temperature in Q8.8 (e.g. 1/0.8 = 320; 0=greedy)
    parameter logic [7:0] REG_TOP_K          = 8'h24; // Top-K sampling pool (default 200, 1=greedy)
    parameter logic [7:0] REG_RNG_SEED_LO    = 8'h28; // 64-bit Xoroshiro PRNG seed low
    parameter logic [7:0] REG_RNG_SEED_HI    = 8'h2C; // 64-bit Xoroshiro PRNG seed high
    parameter logic [7:0] REG_WTE_DEQ_SCALE  = 8'h30; // [15:0]=wte_deq_u16, [31:16]=wpe_deq_u16
    parameter logic [7:0] REG_LM_QUANT_CFG   = 8'h34; // [7:0]=lm_mult_u8, [15:8]=lm_shift_u8
    parameter logic [7:0] REG_PROMPT_PUSH    = 8'h38; // Write prompt token ID into TOK_SRAM[wr_ptr++]
    parameter logic [7:0] REG_TOKEN_POP      = 8'h3C; // Read next generated story token ID
    parameter logic [7:0] REG_GEN_COUNT      = 8'h40; // Total tokens generated so far
    parameter logic [7:0] REG_PERF_CYCLES_LO = 8'h44; // 64-bit active cycle counter low
    parameter logic [7:0] REG_PERF_CYCLES_HI = 8'h48; // 64-bit active cycle counter high
    parameter logic [7:0] REG_UCODE_WR_ADDR  = 8'h4C; // Microcode load word pointer
    parameter logic [7:0] REG_UCODE_WR_DATA0 = 8'h50; // Microcode bits [31:0]
    parameter logic [7:0] REG_UCODE_WR_DATA1 = 8'h54; // Microcode bits [63:32]
    parameter logic [7:0] REG_UCODE_WR_DATA2 = 8'h58; // Microcode bits [95:64]
    parameter logic [7:0] REG_UCODE_WR_DATA3 = 8'h5C; // Microcode bits [127:96] (triggers write)

    // =========================================================================
    // Fixed-Point Helper Functions (Synthesizable)
    // =========================================================================

    // clamping INT8 integers to [-128, 127]
    function automatic logic signed [7:0] saturate_i8(input logic signed [31:0] val);
        if (val > 32'sd127)
            return 8'sd127;
        else if (val < -32'sd128)
            return -8'sd128;
        else
            return val[7:0];
    endfunction

    // Clamping INT16 integers [-32768, 32767]
    function automatic logic signed [15:0] saturate_i16(input logic signed [31:0] val);
        if (val > 32'sd32767)
            return 16'sd32767;
        else if (val < -32'sd32768)
            return -16'sd32768;
        else
            return val[15:0];
    endfunction

    // clamping INT64 integers into INT16 integers [-32768, 32767]
    function automatic logic signed [15:0] saturate_i16_64(input logic signed [63:0] val);
        if (val > 64'sd32767)
            return 16'sd32767;
        else if (val < -64'sd32768)
            return -16'sd32768;
        else
            return val[15:0];
    endfunction

    // Requantize INT32 accumulator (+ INT32 bias) -> INT16 Q7.8 activation:
    // result_q78 = clamp_i16(((acc + bias) * mult_u8 + (1 << (shift-1))) >>> shift)
    // INT32 -> INT16 (Q7.8)
    function automatic logic signed [15:0] requantize_q78(
        input logic signed [31:0] acc,
        input logic signed [31:0] bias,
        input logic        [7:0]  mult_u8,
        input logic        [4:0]  shift
    );
        logic signed [32:0] sum_ab;
        logic signed [63:0] prod;
        logic signed [63:0] rounded;
        logic signed [63:0] shifted;

        sum_ab = 33'(acc) + 33'(bias);
        prod   = 64'(sum_ab) * 64'(signed'({1'b0, mult_u8}));
        if (shift > 5'd0)
            rounded = prod + (64'sd1 <<< (shift - 5'd1));
        else
            rounded = prod;
        shifted = rounded >>> shift;
        return saturate_i16_64(shifted);
    endfunction

    // Q7.8: Q (fixed point), and 7.8 tells you how the 16 bits are split around an imaginary decimal point.
    //      It is a way to store decimals inside plain INT16, so NPU can do matrix multiplications using cheap 
    //      integer circuits instead of expensive floating-point hardware.
    // Pack Q7.8 INT16 activation into Q4.3 INT8 KV-cache format to halve KV-cache DDR bandwidth.
    // KV-cache is is Keys and Value matrixes stored during attention, which is stored in external DDR.
    // each clock cycle, we have to move those values from DDR to NPU via 128 bit channel. 128 / 8 bits = 16 bytes per cycle
    // halving it means that KV cache is halved so its 2x faster to move data compared to Q7.8
    // kv_i8 = clamp_i8((val_q78 + 16) >>> 5)
    // INT16 (Q7.8) -> INT8 (Q4.3)
    function automatic logic signed [7:0] pack_kv_q43(input logic signed [15:0] val_q78);
        logic signed [31:0] shifted;
        shifted = (32'(val_q78) + 32'sd16) >>> 5;
        return saturate_i8(shifted);
    endfunction

endpackage

`endif
