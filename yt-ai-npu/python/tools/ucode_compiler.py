#!/usr/bin/env python3
"""
YT-AI 128-Bit Microcode Compiler (`ucode_compiler.py`).
Compiles the complete autonomous 8-Layer YT-AI 51.2M SLM + Embeddings +
Tied 50,257-Vocab LM-Head + Top-K Hardware Sampler into `< 600` 128-bit
microcode instructions (fitting inside on-chip `1024 x 128b` `UCODE_SRAM`!).
"""

from __future__ import annotations
import json
import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tools.memory_map import (  # noqa: E402
    ACT_KH,
    ACT_NORM,
    ACT_PROBS,
    ACT_QH,
    ACT_SCORES,
    ACT_VH,
    ACT_WORK,
    ACT_X,
    BLK_OFF_FC_BIAS,
    BLK_OFF_LN1_PARAM,
    BLK_OFF_LN2_PARAM,
    BLK_OFF_PROJ_BIAS,
    BLK_OFF_QKV_BIAS,
    BLK_OFF_WFC,
    BLK_OFF_WO,
    BLK_OFF_WO_BIAS,
    BLK_OFF_WPROJ,
    BLK_OFF_WQKV,
    DDR_BLOCK_STRIDE,
    DMA_LOOP_L0,
    DMA_LOOP_L0_256K_L1,
    DMA_LOOP_L1,
    DMA_LOOP_NONE,
    DMA_REG_BLOCK,
    DMA_REG_LNF,
    DMA_REG_WPE,
    DMA_REG_WTE,
    DMA_TGT_PARAM,
    DMA_TGT_WGT0,
    DMA_TGT_WGT1,
    FLAG_ACCUMULATE,
    FLAG_ATTN_CTX,
    FLAG_ATTN_SCORE,
    FLAG_BARRIER_PREFILL_EXIT,
    FLAG_BIAS_EN,
    FLAG_KV_IS_V,
    FLAG_KV_LOOP_HEAD,
    FLAG_REQUANT,
    FLAG_TOPK_LOOP_L0,
    FLAG_TOPK_RESET,
    FLAG_TRANSPOSE_B,
    OP_BARRIER,
    OP_DMA_LOAD,
    OP_EMBED,
    OP_END,
    OP_GELU,
    OP_GEMM,
    OP_KV_APPEND,
    OP_KV_READ,
    OP_LAYERNORM,
    OP_LOOP_BEGIN,
    OP_LOOP_END,
    OP_SOFTMAX,
    OP_TOPK_FEED,
    OP_TOPK_SAMPLE,
    PARAM_FC_BIAS,
    PARAM_K_BIAS,
    PARAM_LN1,
    PARAM_LN2,
    PARAM_PROJ_BIAS,
    PARAM_Q_BIAS,
    PARAM_V_BIAS,
    PARAM_WO_BIAS,
    UCODE_DEPTH,
    UcodeInstr,
    YT_HEADS,
    YT_HEAD_DIM,
    YT_HIDDEN,
    YT_LAYERS,
    make_dma_flags,
    make_gemm_imm,
)


class MicrocodeBuilder:
    def __init__(self) -> None:
        self.prog: list[UcodeInstr] = []

    def emit(self, instr: UcodeInstr) -> int:
        pc = len(self.prog)
        self.prog.append(instr)
        return pc

    def barrier(self, prefill_exit: bool = False, comment: str = "barrier") -> int:
        fl = FLAG_BARRIER_PREFILL_EXIT if prefill_exit else 0
        return self.emit(UcodeInstr(OP_BARRIER, flags=fl, comment=comment))

    def dma_load(
        self,
        *,
        tgt: int,
        region: int,
        ddr_offset: int = 0,
        byte_len: int,
        dst_sram: int = 0,
        loop_mode: int = DMA_LOOP_NONE,
        stride_kb: int = 0,
        dyn_index: bool = False,
        comment: str = "",
    ) -> int:
        lo16 = ddr_offset & 0xFFFF
        hi16 = (ddr_offset >> 16) & 0xFFFF
        return self.emit(
            UcodeInstr(
                opcode=OP_DMA_LOAD,
                flags=make_dma_flags(tgt, region, loop_mode, dyn_index),
                dst_base=dst_sram,
                src1_base=lo16,
                K=hi16,
                N=byte_len,
                imm=stride_kb,
                comment=comment,
            )
        )

    def loop_begin(self, loop_id: int, count: int, comment: str = "") -> int:
        self.emit(UcodeInstr(OP_LOOP_BEGIN, flags=loop_id & 1, M=count, comment=comment))
        return len(self.prog)  # Target PC of first instruction inside loop body

    def loop_end(self, loop_id: int, body_start_pc: int, comment: str = "") -> int:
        return self.emit(
            UcodeInstr(
                OP_LOOP_END,
                flags=loop_id & 1,
                dst_base=body_start_pc,
                comment=comment,
            )
        )


def compile_yt_ai_full_program(quant_cfg: dict, num_layers: int = YT_LAYERS) -> list[UcodeInstr]:
    """
    Compiles the complete YT-AI autonomous token step microcode program:
      - Step 0: WTE[cur_tok_id] + WPE[cur_pos] -> ACT_X
      - Step 1: Transformer Blocks 0..num_layers-1 (Attention w/ KV-Cache + 4x512 FFN)
      - Step 2: Early-exit barrier during prompt prefill (`cur_pos < prompt_len - 1`)
      - Step 3: Final LayerNorm + 786-tile Tied LM-Head + Top-K Multinomial Sampler
    """
    b = MicrocodeBuilder()

    # =========================================================================
    # 0. Hardware Token + Position Embedding
    # =========================================================================
    b.dma_load(
        tgt=DMA_TGT_WGT0,
        region=DMA_REG_WTE,
        byte_len=512,
        dst_sram=0,
        dyn_index=True,
        comment="Load WTE[cur_tok_id] -> WGT Bank 0",
    )
    b.barrier()
    b.dma_load(
        tgt=DMA_TGT_WGT1,
        region=DMA_REG_WPE,
        byte_len=512,
        dst_sram=0,
        dyn_index=True,
        comment="Load WPE[cur_pos] -> WGT Bank 1",
    )
    b.barrier()
    b.emit(UcodeInstr(OP_EMBED, dst_base=ACT_X, N=YT_HIDDEN, comment="Embed WTE+WPE -> ACT_X"))
    b.barrier()

    # =========================================================================
    # 1. Transformer Layers 0 .. num_layers - 1
    # =========================================================================
    for l in range(num_layers):
        lcfg = quant_cfg["layers"][l]
        blk_base = l * DDR_BLOCK_STRIDE

        qkv_m, qkv_s   = lcfg["qkv"]["mult_u8"],   lcfg["qkv"]["shift"]
        wo_m,  wo_s    = lcfg["wo"]["mult_u8"],    lcfg["wo"]["shift"]
        fc_m,  fc_s    = lcfg["wfc"]["mult_u8"],   lcfg["wfc"]["shift"]
        prj_m, prj_s   = lcfg["wproj"]["mult_u8"], lcfg["wproj"]["shift"]

        # --- 1A. Attention Setup: Load LN1 + QKV Biases & Run LN1 ---
        b.dma_load(
            tgt=DMA_TGT_PARAM,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_LN1_PARAM,
            byte_len=2048,
            dst_sram=PARAM_LN1,
            comment=f"L{l}: Load LN1 gamma/beta",
        )
        b.barrier()
        b.dma_load(
            tgt=DMA_TGT_PARAM,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_QKV_BIAS,
            byte_len=6144,
            dst_sram=PARAM_Q_BIAS,
            comment=f"L{l}: Load QKV INT32 biases",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_LAYERNORM,
                src0_base=ACT_X,
                src1_base=PARAM_LN1,
                dst_base=ACT_NORM,
                M=1,
                N=YT_HIDDEN,
                comment=f"L{l}: LN1(ACT_X) -> ACT_NORM",
            )
        )
        b.barrier()

        # --- 1B. Hardware Loop L0 over 8 Attention Heads (h = 0..7) ---
        head_pc = b.loop_begin(0, YT_HEADS, comment=f"L{l}: Head loop h=0..7")

        # Q_h = LN1 @ WQ[h]^T + b_Q[h]
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WQKV + 0,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L0,
            stride_kb=96,
            comment=f"L{l}: Load WQ[h] (32KB)",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_BIAS_EN | FLAG_REQUANT,
                src0_base=ACT_NORM,
                src1_base=PARAM_Q_BIAS,
                dst_base=ACT_QH,
                M=1,
                N=YT_HEAD_DIM,
                K=YT_HIDDEN,
                imm=make_gemm_imm(qkv_m, qkv_s, src1_loop64=True),
                comment=f"L{l}: Q_h GEMV",
            )
        )
        b.barrier()

        # K_h = LN1 @ WK[h]^T + b_K[h], then append Q4.3 to DDR KV-cache
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WQKV + 32768,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L0,
            stride_kb=96,
            comment=f"L{l}: Load WK[h] (32KB)",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_BIAS_EN | FLAG_REQUANT,
                src0_base=ACT_NORM,
                src1_base=PARAM_K_BIAS,
                dst_base=ACT_KH,
                M=1,
                N=YT_HEAD_DIM,
                K=YT_HIDDEN,
                imm=make_gemm_imm(qkv_m, qkv_s, src1_loop64=True),
                comment=f"L{l}: K_h GEMV",
            )
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_KV_APPEND,
                flags=FLAG_KV_LOOP_HEAD,
                src0_base=ACT_KH,
                M=l,
                N=0,  # Dynamic cur_pos
                comment=f"L{l}: Append K_h -> DDR KV-cache",
            )
        )
        b.barrier()

        # V_h = LN1 @ WV[h]^T + b_V[h], then append Q4.3 to DDR KV-cache
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WQKV + 65536,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L0,
            stride_kb=96,
            comment=f"L{l}: Load WV[h] (32KB)",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_BIAS_EN | FLAG_REQUANT,
                src0_base=ACT_NORM,
                src1_base=PARAM_V_BIAS,
                dst_base=ACT_VH,
                M=1,
                N=YT_HEAD_DIM,
                K=YT_HIDDEN,
                imm=make_gemm_imm(qkv_m, qkv_s, src1_loop64=True),
                comment=f"L{l}: V_h GEMV",
            )
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_KV_APPEND,
                flags=FLAG_KV_IS_V | FLAG_KV_LOOP_HEAD,
                src0_base=ACT_VH,
                M=l,
                N=0,
                comment=f"L{l}: Append V_h -> DDR KV-cache",
            )
        )
        b.barrier()

        # Read K_cache[0..cur_pos] -> Scores = (Q_h @ K_cache^T) >>> 6 -> Softmax
        b.emit(
            UcodeInstr(
                OP_KV_READ,
                flags=FLAG_KV_LOOP_HEAD,
                dst_base=0,
                M=l,
                N=0,  # Dynamic seq_len = cur_pos + 1
                comment=f"L{l}: Read K_cache[0..T]",
            )
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_ATTN_SCORE,
                src0_base=ACT_QH,
                dst_base=ACT_SCORES,
                M=1,
                N=0,  # Dynamic seq_len = cur_pos + 1
                K=YT_HEAD_DIM,
                comment=f"L{l}: Scores = Q_h @ K_cache^T / 8",
            )
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_SOFTMAX,
                src0_base=ACT_SCORES,
                dst_base=ACT_PROBS,
                M=1,
                N=0,  # Dynamic seq_len = cur_pos + 1
                comment=f"L{l}: Softmax(Scores) -> Q0.15",
            )
        )
        b.barrier()

        # Read V_cache[0..cur_pos] -> Ctx_h = (Probs @ V_cache) >>> 10 -> ACT_WORK[h*64]
        b.emit(
            UcodeInstr(
                OP_KV_READ,
                flags=FLAG_KV_IS_V | FLAG_KV_LOOP_HEAD,
                dst_base=0,
                M=l,
                N=0,
                comment=f"L{l}: Read V_cache[0..T]",
            )
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_ATTN_CTX,
                src0_base=ACT_PROBS,
                dst_base=ACT_WORK,
                M=1,
                N=YT_HEAD_DIM,
                K=0,  # Dynamic seq_len = cur_pos + 1
                imm=make_gemm_imm(dst_loop64=True),
                comment=f"L{l}: Ctx_h = Probs @ V_cache -> ACT_WORK[h*64]",
            )
        )
        b.barrier()
        b.loop_end(0, head_pc, comment=f"L{l}: End head loop")

        # --- 1C. Load LN2 + WO_BIAS + PROJ_BIAS & Run WO Residual Projection ---
        b.dma_load(
            tgt=DMA_TGT_PARAM,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_LN2_PARAM,
            byte_len=2048,
            dst_sram=PARAM_LN2,
            comment=f"L{l}: Load LN2 gamma/beta",
        )
        b.barrier()
        b.dma_load(
            tgt=DMA_TGT_PARAM,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WO_BIAS,
            byte_len=2048,
            dst_sram=PARAM_WO_BIAS,
            comment=f"L{l}: Load WO INT32 bias",
        )
        b.barrier()
        b.dma_load(
            tgt=DMA_TGT_PARAM,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_PROJ_BIAS,
            byte_len=2048,
            dst_sram=PARAM_PROJ_BIAS,
            comment=f"L{l}: Load PROJ INT32 bias",
        )
        b.barrier()

        # WO [512, 512] in 8 tiles of [64, 512] (32 KB), accumulating directly onto ACT_X!
        wo_pc = b.loop_begin(0, 8, comment=f"L{l}: WO tile loop t=0..7")
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WO,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L0,
            stride_kb=32,
            comment=f"L{l}: Load WO tile",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_BIAS_EN | FLAG_REQUANT | FLAG_ACCUMULATE,
                src0_base=ACT_WORK,
                src1_base=PARAM_WO_BIAS,
                dst_base=ACT_X,
                M=1,
                N=64,
                K=YT_HIDDEN,
                imm=make_gemm_imm(wo_m, wo_s, dst_loop64=True, src1_loop64=True),
                comment=f"L{l}: ACT_X += Ctx @ WO^T + b_WO",
            )
        )
        b.barrier()
        b.loop_end(0, wo_pc, comment=f"L{l}: End WO loop")

        # --- 1D. LayerNorm 2 + Fused 4x512 MLP ---
        b.emit(
            UcodeInstr(
                OP_LAYERNORM,
                src0_base=ACT_X,
                src1_base=PARAM_LN2,
                dst_base=ACT_NORM,
                M=1,
                N=YT_HIDDEN,
                comment=f"L{l}: LN2(ACT_X) -> ACT_NORM",
            )
        )
        b.barrier()

        # FFN Slice 0 (includes PROJ_BIAS once!)
        b.dma_load(
            tgt=DMA_TGT_PARAM,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_FC_BIAS,
            byte_len=2048,
            dst_sram=PARAM_FC_BIAS,
            comment=f"L{l}: Load FC_BIAS[0]",
        )
        b.barrier()

        fc0_pc = b.loop_begin(1, 8, comment=f"L{l}: WFC[0] tile loop")
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WFC,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L1,
            stride_kb=32,
            comment=f"L{l}: Load WFC[0,t]",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_BIAS_EN | FLAG_REQUANT,
                src0_base=ACT_NORM,
                src1_base=PARAM_FC_BIAS,
                dst_base=ACT_WORK,
                M=1,
                N=64,
                K=YT_HIDDEN,
                imm=make_gemm_imm(fc_m, fc_s, dst_loop64=True, src1_loop64=True, use_l1=True),
                comment=f"L{l}: WFC[0,t] GEMV",
            )
        )
        b.barrier()
        b.loop_end(1, fc0_pc)

        b.emit(UcodeInstr(OP_GELU, src0_base=ACT_WORK, dst_base=ACT_WORK, M=1, N=YT_HIDDEN, comment=f"L{l}: GELU[0]"))
        b.barrier()

        prj0_pc = b.loop_begin(1, 8, comment=f"L{l}: WPROJ[0] tile loop")
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WPROJ,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L1,
            stride_kb=32,
            comment=f"L{l}: Load WPROJ[0,t]",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_BIAS_EN | FLAG_REQUANT | FLAG_ACCUMULATE,
                src0_base=ACT_WORK,
                src1_base=PARAM_PROJ_BIAS,
                dst_base=ACT_X,
                M=1,
                N=64,
                K=YT_HIDDEN,
                imm=make_gemm_imm(prj_m, prj_s, dst_loop64=True, src1_loop64=True, use_l1=True),
                comment=f"L{l}: ACT_X += WPROJ[0] + b_PROJ",
            )
        )
        b.barrier()
        b.loop_end(1, prj0_pc)

        # FFN Slices 1..3 (L0 = 0..2 -> slice = 1 + L0, BIAS_EN=0 on WPROJ!)
        ffn_rem_pc = b.loop_begin(0, 3, comment=f"L{l}: FFN slices 1..3")
        b.dma_load(
            tgt=DMA_TGT_PARAM,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_FC_BIAS + 2048,
            byte_len=2048,
            dst_sram=PARAM_FC_BIAS,
            loop_mode=DMA_LOOP_L0,
            stride_kb=2,
            comment=f"L{l}: Load FC_BIAS[1+s]",
        )
        b.barrier()

        fcs_pc = b.loop_begin(1, 8, comment=f"L{l}: WFC[1+s] tile loop")
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WFC + 262144,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L0_256K_L1,
            stride_kb=32,
            comment=f"L{l}: Load WFC[1+s,t]",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_BIAS_EN | FLAG_REQUANT,
                src0_base=ACT_NORM,
                src1_base=PARAM_FC_BIAS,
                dst_base=ACT_WORK,
                M=1,
                N=64,
                K=YT_HIDDEN,
                imm=make_gemm_imm(fc_m, fc_s, dst_loop64=True, src1_loop64=True, use_l1=True),
                comment=f"L{l}: WFC[1+s,t] GEMV",
            )
        )
        b.barrier()
        b.loop_end(1, fcs_pc)

        b.emit(UcodeInstr(OP_GELU, src0_base=ACT_WORK, dst_base=ACT_WORK, M=1, N=YT_HIDDEN, comment=f"L{l}: GELU[1+s]"))
        b.barrier()

        prjs_pc = b.loop_begin(1, 8, comment=f"L{l}: WPROJ[1+s] tile loop")
        b.dma_load(
            tgt=DMA_TGT_WGT0,
            region=DMA_REG_BLOCK,
            ddr_offset=blk_base + BLK_OFF_WPROJ + 262144,
            byte_len=32768,
            dst_sram=0,
            loop_mode=DMA_LOOP_L0_256K_L1,
            stride_kb=32,
            comment=f"L{l}: Load WPROJ[1+s,t]",
        )
        b.barrier()
        b.emit(
            UcodeInstr(
                OP_GEMM,
                flags=FLAG_TRANSPOSE_B | FLAG_REQUANT | FLAG_ACCUMULATE,
                src0_base=ACT_WORK,
                dst_base=ACT_X,
                M=1,
                N=64,
                K=YT_HIDDEN,
                imm=make_gemm_imm(prj_m, prj_s, dst_loop64=True, use_l1=True),
                comment=f"L{l}: ACT_X += WPROJ[1+s]",
            )
        )
        b.barrier()
        b.loop_end(1, prjs_pc)
        b.loop_end(0, ffn_rem_pc)

    # =========================================================================
    # 2. Early-Exit Barrier for Prompt Prefill (`cur_pos < prompt_len - 1`)
    # =========================================================================
    b.barrier(prefill_exit=True, comment="Skip LM-Head during prompt prefill")

    # =========================================================================
    # 3. Final LayerNorm + 786-Tile Tied LM-Head + Top-K Sampler
    # =========================================================================
    lm_m = quant_cfg["lm_head"]["mult_u8"]
    lm_s = quant_cfg["lm_head"]["shift"]

    b.dma_load(
        tgt=DMA_TGT_PARAM,
        region=DMA_REG_LNF,
        ddr_offset=0,
        byte_len=2048,
        dst_sram=PARAM_LN1,
        comment="Load LN_F gamma/beta",
    )
    b.barrier()
    b.emit(
        UcodeInstr(
            OP_LAYERNORM,
            src0_base=ACT_X,
            src1_base=PARAM_LN1,
            dst_base=ACT_NORM,
            M=1,
            N=YT_HIDDEN,
            comment="LN_F(ACT_X) -> ACT_NORM",
        )
    )
    b.barrier()

    # Tile 0 (vocab 0..63, resets Top-K pool!)
    b.dma_load(
        tgt=DMA_TGT_WGT0,
        region=DMA_REG_WTE,
        ddr_offset=0,
        byte_len=32768,
        dst_sram=0,
        comment="LM_HEAD Tile 0 (vocab 0..63)",
    )
    b.barrier()
    b.emit(
        UcodeInstr(
            OP_GEMM,
            flags=FLAG_TRANSPOSE_B | FLAG_REQUANT,
            src0_base=ACT_NORM,
            dst_base=ACT_WORK,
            M=1,
            N=64,
            K=YT_HIDDEN,
            imm=make_gemm_imm(lm_m, lm_s),
            comment="LM_HEAD GEMV Tile 0",
        )
    )
    b.barrier()
    b.emit(
        UcodeInstr(
            OP_TOPK_FEED,
            flags=FLAG_TOPK_RESET,
            src0_base=ACT_WORK,
            src1_base=0,
            N=64,
            comment="Top-K Reset + Feed vocab 0..63",
        )
    )
    b.barrier()

    # Remaining 785 tiles (vocab 64..50303; indices >= 50257 auto-masked in RTL!)
    lm_pc = b.loop_begin(0, 785, comment="LM_HEAD loop tiles 1..785")
    b.dma_load(
        tgt=DMA_TGT_WGT0,
        region=DMA_REG_WTE,
        ddr_offset=32768,
        byte_len=32768,
        dst_sram=0,
        loop_mode=DMA_LOOP_L0,
        stride_kb=32,
        comment="Load LM_HEAD Tile 1+t",
    )
    b.barrier()
    b.emit(
        UcodeInstr(
            OP_GEMM,
            flags=FLAG_TRANSPOSE_B | FLAG_REQUANT,
            src0_base=ACT_NORM,
            dst_base=ACT_WORK,
            M=1,
            N=64,
            K=YT_HIDDEN,
            imm=make_gemm_imm(lm_m, lm_s),
            comment="LM_HEAD GEMV Tile 1+t",
        )
    )
    b.barrier()
    b.emit(
        UcodeInstr(
            OP_TOPK_FEED,
            flags=FLAG_TOPK_LOOP_L0,
            src0_base=ACT_WORK,
            src1_base=64,
            N=64,
            comment="Top-K Feed vocab 64+t*64",
        )
    )
    b.barrier()
    b.loop_end(0, lm_pc, comment="End LM_HEAD loop")

    # Hardware Top-K + Temperature PRNG Sample!
    b.emit(UcodeInstr(OP_TOPK_SAMPLE, comment="Sample next story token -> TOK_SRAM"))
    b.barrier()
    b.emit(UcodeInstr(OP_END, comment="End of token step"))

    assert len(b.prog) <= UCODE_DEPTH, f"Program length {len(b.prog)} exceeds UCODE_DEPTH {UCODE_DEPTH}"
    return b.prog


def save_ucode_hex(prog: list[UcodeInstr], hex_path: str) -> None:
    os.makedirs(os.path.dirname(hex_path), exist_ok=True)
    with open(hex_path, "w", encoding="utf-8") as f:
        for ins in prog:
            f.write(f"{ins.to_u128():032x}\n")


if __name__ == "__main__":
    build_dir = Path(__file__).resolve().parent.parent.parent / "build"
    with open(build_dir / "quant_config.json", "r", encoding="utf-8") as f:
        qcfg = json.load(f)
    program = compile_yt_ai_full_program(qcfg)
    out_hex = build_dir / "yt_ai_full_program.hex"
    save_ucode_hex(program, str(out_hex))
    print(f"[YT-AI Compiler] Compiled {len(program)}/{UCODE_DEPTH} 128-bit instructions -> {out_hex}")
