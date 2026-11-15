"""
YT-AI Custom NPU Hardware Memory Map & 128-Bit Microcode ISA Definitions.
100% bit-exact mirror of `rtl/pkg/yt_npu_pkg.sv` and `rtl/pkg/yt_isa_pkg.sv`.
"""

from __future__ import annotations
from dataclasses import dataclass

# =============================================================================
# YT-AI 51,213,824-Parameter Model Constants
# =============================================================================
YT_LAYERS      = 8
YT_HEADS       = 8
YT_HEAD_DIM    = 64
YT_HIDDEN      = 512
YT_HIDDEN_LOG2 = 9
YT_FFN_DIM     = 2048
YT_FFN_SLICE   = 512
YT_MAX_SEQ     = 512
YT_VOCAB_SIZE  = 50257
YT_VOCAB_PAD   = 50304   # 786 * 64
YT_EOT_TOKEN   = 50256   # <|endoftext|>

# =============================================================================
# On-Chip SRAM Capacities & ACT_SRAM / PARAM_SRAM Allocation Map
# =============================================================================
ACT_SRAM_WORDS   = 16384  # 16,384 x 16b = 32 KB
WGT_BANK_BEATS   = 1024   # 1,024 x 128b = 16 KB per bank (2 banks = 32 KB)
PARAM_SRAM_WORDS = 2048   # 2,048 x 32b  = 8 KB
UCODE_DEPTH      = 1024   # 1,024 x 128b = 16 KB
TOK_SRAM_DEPTH   = 512    # 512 x 16b    = 1 KB
TOPK_MAX_K       = 256

# ACT_SRAM Word Offsets (16-bit Q7.8 elements)
ACT_X       = 0x0000  # [M, 512] residual stream (up to M=4, 2048w)
ACT_NORM    = 0x0800  # [M, 512] LayerNorm output (2048w)
ACT_WORK    = 0x1000  # [M, 512] Attention concat / FFN slice / Logit tile (2048w)
ACT_PROJ    = 0x1800  # [M, 512] Scratch buffer (2048w)
ACT_QH      = 0x2000  # [M, 64]  Per-head Query (256w)
ACT_KH      = 0x2100  # [M, 64]  Per-head Key   (256w)
ACT_VH      = 0x2200  # [M, 64]  Per-head Value (256w)
ACT_ATTNH   = 0x2300  # [M, 64]  Per-head Ctx   (256w)
ACT_SCORES  = 0x2400  # [M, 512] Attention scores Q7.8 (2048w)
ACT_PROBS   = 0x2C00  # [M, 512] Attention probs Q0.15 (2048w)

# PARAM_SRAM Word Offsets (32-bit words)
# Phase 1 (Attention):
PARAM_LN1       = 0x0000  # 512w ({beta_q78, gamma_q4_12})
PARAM_Q_BIAS    = 0x0200  # 512w (8 heads x 64 INT32)
PARAM_K_BIAS    = 0x0400  # 512w (8 heads x 64 INT32)
PARAM_V_BIAS    = 0x0600  # 512w (8 heads x 64 INT32)
# Phase 2 (WO + FFN):
PARAM_LN2       = 0x0000  # 512w ({beta_q78, gamma_q4_12})
PARAM_WO_BIAS   = 0x0200  # 512w INT32
PARAM_PROJ_BIAS = 0x0400  # 512w INT32
PARAM_FC_BIAS   = 0x0600  # 512w INT32 (per FFN 512-slice)

# =============================================================================
# External DDR Memory Map Base Offsets (64-Byte Aligned)
# =============================================================================
DDR_OFFSET_WTE    = 0x0000_0000  # [50304, 512] INT8 = 25,755,648 B (0x0189_0000)
DDR_OFFSET_WPE    = 0x0189_0000  # [512, 512]   INT8 =    262,144 B (0x0004_0000)
DDR_OFFSET_BLOCKS = 0x018D_0000  # 8 blocks x 0x0030_6000 = 25,362,432 B
DDR_BLOCK_STRIDE  = 0x0030_6000  # 3,170,304 B per block
DDR_OFFSET_LNF    = 0x0310_0000  # Final LayerNorm gamma/beta (2048 B)
DDR_OFFSET_KV     = 0x0320_0000  # 4.00 MB KV cache [8][8][2][512][64]
DDR_OFFSET_OUT    = 0x0360_0000  # Generated story token output ring

# Intra-block byte offsets
BLK_OFF_LN1_PARAM = 0x0000_0000  #     2,048 B
BLK_OFF_LN2_PARAM = 0x0000_0800  #     2,048 B
BLK_OFF_QKV_BIAS  = 0x0000_1000  #     6,144 B (Q[512], K[512], V[512] INT32)
BLK_OFF_WO_BIAS   = 0x0000_2800  #     2,048 B
BLK_OFF_FC_BIAS   = 0x0000_3000  #     8,192 B (4 slices x 512 INT32)
BLK_OFF_PROJ_BIAS = 0x0000_5000  #     2,048 B
BLK_OFF_WQKV      = 0x0000_6000  #   786,432 B (8 heads x (WQ[64,512]+WK[64,512]+WV[64,512]))
BLK_OFF_WO        = 0x000C_6000  #   262,144 B ([512, 512] INT8)
BLK_OFF_WFC       = 0x0010_6000  # 1,048,576 B (4 slices x [512, 512] INT8)
BLK_OFF_WPROJ     = 0x0020_6000  # 1,048,576 B (4 slices x [512, 512] INT8, K-sliced!)

WEIGHT_BIN_BYTES  = DDR_OFFSET_LNF + 0x1000  # 51,384,320 bytes (~49.0 MB)

# =============================================================================
# AXI4-Lite Register Offsets
# =============================================================================
REG_CTRL           = 0x00
REG_STATUS         = 0x04
REG_UCODE_LEN      = 0x08
REG_DDR_BASE_WGT   = 0x0C
REG_DDR_BASE_KV    = 0x10
REG_DDR_BASE_OUT   = 0x14
REG_PROMPT_LEN     = 0x18
REG_MAX_NEW_TOKENS = 0x1C
REG_TEMP_INV_Q88   = 0x20
REG_TOP_K          = 0x24
REG_RNG_SEED_LO    = 0x28
REG_RNG_SEED_HI    = 0x2C
REG_WTE_DEQ_SCALE  = 0x30
REG_LM_QUANT_CFG   = 0x34
REG_PROMPT_PUSH    = 0x38
REG_TOKEN_POP      = 0x3C
REG_GEN_COUNT      = 0x40
REG_PERF_CYCLES_LO = 0x44
REG_PERF_CYCLES_HI = 0x48
REG_UCODE_WR_ADDR  = 0x4C
REG_UCODE_WR_DATA0 = 0x50
REG_UCODE_WR_DATA1 = 0x54
REG_UCODE_WR_DATA2 = 0x58
REG_UCODE_WR_DATA3 = 0x5C

# =============================================================================
# 128-Bit Microcode Opcodes & Flags (`yt_isa_pkg.sv`)
# =============================================================================
OP_NOP          = 0x00
OP_DMA_LOAD     = 0x01
OP_DMA_STORE    = 0x02
OP_GEMM         = 0x03
OP_VEC          = 0x04
OP_SOFTMAX      = 0x05
OP_LAYERNORM    = 0x06
OP_GELU         = 0x07
OP_KV_APPEND    = 0x08
OP_KV_READ      = 0x09
OP_BARRIER      = 0x0A
OP_EMBED        = 0x0B
OP_TOPK_FEED    = 0x0C
OP_TOPK_SAMPLE  = 0x0D
OP_LOOP_BEGIN   = 0x0E
OP_LOOP_END     = 0x0F
OP_END          = 0xFF

# GEMM Flags
FLAG_TRANSPOSE_B = (1 << 0)
FLAG_BIAS_EN     = (1 << 1)
FLAG_REQUANT     = (1 << 2)
FLAG_ACCUMULATE  = (1 << 3)
FLAG_PINGPONG_B  = (1 << 4)
FLAG_KV_PACK     = (1 << 5)
FLAG_ATTN_SCORE  = (1 << 6)
FLAG_ATTN_CTX    = (1 << 7)

# GEMM Immediate Loop-Offset Bits (imm[15:13])
GEMM_IMM_DST_LOOP64  = (1 << 13)
GEMM_IMM_SRC1_LOOP64 = (1 << 14)
GEMM_IMM_LOOP_SEL_L1 = (1 << 15)

# DMA Flags
DMA_TGT_WGT0  = 0
DMA_TGT_WGT1  = 1
DMA_TGT_PARAM = 2
DMA_TGT_ACT   = 3

DMA_REG_WTE   = 0
DMA_REG_WPE   = 1
DMA_REG_BLOCK = 2
DMA_REG_LNF   = 3
DMA_REG_KV    = 4
DMA_REG_OUT   = 5

DMA_LOOP_NONE       = 0
DMA_LOOP_L0         = 1
DMA_LOOP_L1         = 2
DMA_LOOP_L0_256K_L1 = 3
FLAG_DMA_DYN_INDEX  = (1 << 7)

# VEC Flags
VEC_OP_ADD         = 0
VEC_OP_MUL         = 1
VEC_OP_SCALE_SHIFT = 2
VEC_OP_CLAMP       = 3
FLAG_VEC_COPY2D    = (1 << 2)

# Softmax / KV / Barrier / Top-K Flags
FLAG_CAUSAL_MASK          = (1 << 4)
FLAG_KV_IS_V              = (1 << 0)
FLAG_KV_LOOP_HEAD         = (1 << 1)
FLAG_BARRIER_PREFILL_EXIT = (1 << 0)
FLAG_TOPK_RESET           = (1 << 0)
FLAG_TOPK_LOOP_L0         = (1 << 1)


def make_dma_flags(
    tgt: int,
    region: int,
    loop_mode: int = DMA_LOOP_NONE,
    dyn_index: bool = False,
) -> int:
    flags = (tgt & 0x3) | ((region & 0x7) << 2) | ((loop_mode & 0x3) << 5)
    if dyn_index:
        flags |= FLAG_DMA_DYN_INDEX
    return flags & 0xFF


def make_gemm_imm(
    mult_u8: int = 0,
    shift: int = 0,
    dst_loop64: bool = False,
    src1_loop64: bool = False,
    use_l1: bool = False,
) -> int:
    imm = (mult_u8 & 0xFF) | ((shift & 0x1F) << 8)
    if dst_loop64:
        imm |= GEMM_IMM_DST_LOOP64
    if src1_loop64:
        imm |= GEMM_IMM_SRC1_LOOP64
    if use_l1:
        imm |= GEMM_IMM_LOOP_SEL_L1
    return imm & 0xFFFF


@dataclass(frozen=True)
class UcodeInstr:
    opcode: int
    flags: int = 0
    dst_base: int = 0
    src0_base: int = 0
    src1_base: int = 0
    M: int = 0
    N: int = 0
    K: int = 0
    imm: int = 0
    comment: str = ""

    def to_u128(self) -> int:
        return (
            (self.opcode & 0xFF)
            | ((self.flags & 0xFF) << 8)
            | ((self.dst_base & 0xFFFF) << 16)
            | ((self.src0_base & 0xFFFF) << 32)
            | ((self.src1_base & 0xFFFF) << 48)
            | ((self.M & 0xFFFF) << 64)
            | ((self.N & 0xFFFF) << 80)
            | ((self.K & 0xFFFF) << 96)
            | ((self.imm & 0xFFFF) << 112)
        )

    def to_words32(self) -> tuple[int, int, int, int]:
        v = self.to_u128()
        return (
            v & 0xFFFF_FFFF,
            (v >> 32) & 0xFFFF_FFFF,
            (v >> 64) & 0xFFFF_FFFF,
            (v >> 96) & 0xFFFF_FFFF,
        )

    @staticmethod
    def from_u128(raw: int) -> "UcodeInstr":
        return UcodeInstr(
            opcode=raw & 0xFF,
            flags=(raw >> 8) & 0xFF,
            dst_base=(raw >> 16) & 0xFFFF,
            src0_base=(raw >> 32) & 0xFFFF,
            src1_base=(raw >> 48) & 0xFFFF,
            M=(raw >> 64) & 0xFFFF,
            N=(raw >> 80) & 0xFFFF,
            K=(raw >> 96) & 0xFFFF,
            imm=(raw >> 112) & 0xFFFF,
        )


def kv_cache_ddr_addr(
    ddr_base_kv: int,
    layer_id: int,
    head_id: int,
    is_v: int,
    seq_pos: int,
) -> int:
    offset = (
        ((layer_id & 0x7) << 19)
        | ((head_id & 0x7) << 16)
        | ((is_v & 0x1) << 15)
        | ((seq_pos & 0x1FF) << 6)
    )
    return (ddr_base_kv + offset) & 0xFFFF_FFFF
