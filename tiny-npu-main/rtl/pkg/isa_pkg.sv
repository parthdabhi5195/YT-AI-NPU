// =============================================================================
// ISA Package - Microcode instruction format and opcode definitions
// =============================================================================
`ifndef ISA_PKG_SV
`define ISA_PKG_SV

package isa_pkg;

    parameter int INSTR_W = 128;

    // =========================================================================
    // Opcodes
    // =========================================================================
    // Opcodes are the literal values inside a memory address that physically 
    // activate the circuits they are responsible for
    typedef enum logic [7:0] {
        OP_NOP        = 8'd0, // do nothing
        OP_DMA_LOAD   = 8'd1, // pull data from DDR to SRAM
        OP_DMA_STORE  = 8'd2, // push results back to DDR
        OP_GEMM       = 8'd3, // run matrix multiplication on systolic array
        OP_VEC        = 8'd4, // element-wise vector math like residual adds or scaling
        OP_SOFTMAX    = 8'd5,
        OP_LAYERNORM  = 8'd6,
        OP_GELU       = 8'd7,
        OP_KV_APPEND  = 8'd8,
        OP_KV_READ    = 8'd9,
        OP_BARRIER    = 8'd10, // pause until active engines finish
        OP_RMSNORM    = 8'd11,
        OP_ROPE       = 8'd12,
        OP_SILU       = 8'd13,
        OP_END        = 8'd255 // halt execution
    } opcode_t;

    // =========================================================================
    // Flag Bits [15:8]
    // =========================================================================
    // Flags basically tweak how an opcode behaves without needing extra opcodes
    // first 8 bits go to specific harware engine, then the next 8 bits are
    // read by that specific engine
    parameter int FLAG_TRANSPOSE_B = 0; // transpose matrix for multiplication
    parameter int FLAG_BIAS_EN     = 1;
    parameter int FLAG_REQUANT     = 2;
    parameter int FLAG_RELU        = 3;
    parameter int FLAG_CAUSAL_MASK = 4;
    parameter int FLAG_ACCUMULATE  = 5;
    parameter int FLAG_PINGPONG    = 6;

    // DMA sub-types (flags[2:0] for DMA_LOAD/DMA_STORE)
    // uses bottom 3 bits to select which DDR base address and which on-chip SRAM bufffer to connect
    parameter int DMA_ACT   = 0; // moves activations between DDR and SRAM banks
    parameter int DMA_WGT   = 1;
    parameter int DMA_KV    = 2;
    parameter int DMA_OUT   = 3; // writes final computed model results from on-chip SRAM out to DDR
    parameter int DMA_UCODE = 4; // loads the NPU's microcode from DDR to instruction memory

    // VEC sub-operations (flags[1:0] for VEC)
    parameter int VEC_ADD         = 0;
    parameter int VEC_MUL         = 1;
    parameter int VEC_SCALE_SHIFT = 2;
    parameter int VEC_CLAMP       = 3;

    // VEC mode selector (flags[2] for VEC)
    parameter int VEC_COPY2D      = 4;  // flags[2] selects 2D scatter/gather mode

    // =========================================================================
    // Decoded Instruction Struct
    // =========================================================================
    typedef struct packed {
        logic [15:0] imm;        // [127:112]
        logic [15:0] K;          // [111:96]
        logic [15:0] N;          // [95:80]
        logic [15:0] M;          // [79:64]
        logic [15:0] src1_base;  // [63:48]
        logic [15:0] src0_base;  // [47:32]
        logic [15:0] dst_base;   // [31:16]
        logic [7:0]  flags;      // [15:8]
        logic [7:0]  opcode;     // [7:0]
    } ucode_instr_t;

    // =========================================================================
    // Field Extraction Functions
    // =========================================================================
    function automatic logic [7:0] get_opcode(input logic [127:0] instr);
        return instr[7:0];
    endfunction

    function automatic logic [7:0] get_flags(input logic [127:0] instr);
        return instr[15:8];
    endfunction

    function automatic logic [15:0] get_dst_base(input logic [127:0] instr);
        return instr[31:16];
    endfunction

    function automatic logic [15:0] get_src0_base(input logic [127:0] instr);
        return instr[47:32];
    endfunction

    function automatic logic [15:0] get_src1_base(input logic [127:0] instr);
        return instr[63:48];
    endfunction

    function automatic logic [15:0] get_M(input logic [127:0] instr);
        return instr[79:64];
    endfunction

    function automatic logic [15:0] get_N(input logic [127:0] instr);
        return instr[95:80];
    endfunction

    function automatic logic [15:0] get_K(input logic [127:0] instr);
        return instr[111:96];
    endfunction

    function automatic logic [15:0] get_imm(input logic [127:0] instr);
        return instr[127:112];
    endfunction

    function automatic ucode_instr_t decode_instr(input logic [127:0] raw);
        ucode_instr_t d;
        d.opcode    = raw[7:0];
        d.flags     = raw[15:8];
        d.dst_base  = raw[31:16];
        d.src0_base = raw[47:32];
        d.src1_base = raw[63:48];
        d.M         = raw[79:64];
        d.N         = raw[95:80];
        d.K         = raw[111:96];
        d.imm       = raw[127:112];
        return d;
    endfunction

endpackage

`endif
