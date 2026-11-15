#!/usr/bin/env python3
"""
YT-AI 51.2M Checkpoint Quantizer & External DDR Binary Image Exporter.
Reads `/Users/parth/Desktop/Youtube/YT AI/YT AI SLM/GPT Architecture/yt-ai-slm/best_model_params.pt`
(read-only!) and exports:
  - `build/yt_ai_weights.bin` (~49.0 MB 64B-aligned external DDR binary image)
  - `build/quant_config.json` (exact per-layer `(mult_u8, shift)` & embedding scales)
"""

from __future__ import annotations
import argparse
import json
import os
import struct
import sys
from pathlib import Path
import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from tools.memory_map import (  # noqa: E402
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
    DDR_OFFSET_BLOCKS,
    DDR_OFFSET_LNF,
    DDR_OFFSET_WPE,
    DDR_OFFSET_WTE,
    WEIGHT_BIN_BYTES,
    YT_FFN_SLICE,
    YT_HEADS,
    YT_HEAD_DIM,
    YT_HIDDEN,
    YT_LAYERS,
    YT_MAX_SEQ,
    YT_VOCAB_PAD,
    YT_VOCAB_SIZE,
)

DEFAULT_CKPT = (
    "/Users/parth/Desktop/Youtube/YT AI/YT AI SLM/"
    "GPT Architecture/yt-ai-slm/best_model_params.pt"
)


def quantize_weight_w8(w_fp32: torch.Tensor) -> tuple[np.ndarray, int, int, float]:
    """Symmetric per-matrix INT8 weight quantization + (mult_u8, shift) requantizer."""
    amax = float(w_fp32.abs().max().item())
    if amax < 1e-12:
        return np.zeros(w_fp32.shape, dtype=np.int8), 128, 24, 1.0
    w_scale = 127.0 / amax
    w_q = torch.clamp(torch.round(w_fp32 * w_scale), -127, 127).to(torch.int8).cpu().numpy()

    # Output requantizer: y_q78 = round(acc * (amax / 127.0)) = (acc * mult_u8) >> shift
    real_mult = amax / 127.0
    shift = 0
    while real_mult * (1 << shift) < 128.0 and shift < 24:
        shift += 1
    mult_u8 = int(round(real_mult * (1 << shift)))
    if mult_u8 >= 256 and shift > 0:
        mult_u8 >>= 1
        shift -= 1
    mult_u8 = max(1, min(255, mult_u8))
    return w_q, mult_u8, shift, w_scale


def quantize_bias_i32(b_fp32: torch.Tensor, w_scale: float) -> np.ndarray:
    """Pre-scale bias to match INT16(Q7.8) x INT8(w_scale) accumulator domain."""
    b_q = torch.round(b_fp32 * (256.0 * w_scale)).to(torch.int64)
    assert int(b_q.abs().max().item()) < (1 << 30), "INT32 bias overflow"
    return b_q.to(torch.int32).cpu().numpy()


def pack_ln_params(gamma_fp32: torch.Tensor, beta_fp32: torch.Tensor) -> bytes:
    """Pack 512 x {beta_q78[31:16], gamma_q4_12[15:0]} 32-bit words (2048 bytes)."""
    gamma_q12 = torch.clamp(torch.round(gamma_fp32 * 4096.0), -32768, 32767).to(torch.int16).cpu().numpy()
    beta_q8   = torch.clamp(torch.round(beta_fp32 * 256.0), -32768, 32767).to(torch.int16).cpu().numpy()
    words = ((beta_q8.astype(np.uint32) & 0xFFFF) << 16) | (gamma_q12.astype(np.uint32) & 0xFFFF)
    return words.astype("<u4").tobytes()


def export_yt_ai_checkpoint(ckpt_path: str, out_dir: str) -> dict:
    os.makedirs(out_dir, exist_ok=True)
    print(f"[YT-AI Quantizer] Loading checkpoint: {ckpt_path}")
    sd = torch.load(ckpt_path, map_location="cpu", weights_only=True)

    image = bytearray(WEIGHT_BIN_BYTES)
    quant_cfg: dict = {
        "model": "YT-AI-51.2M-SLM",
        "total_params": int(sum(v.numel() for k, v in sd.items() if k != "lm_head.weight")),
        "layers": [],
    }

    # 1. Token Embeddings WTE [50257, 512] -> padded to [50304, 512] (tied with LM-Head!)
    wte_fp = sd["transformer.wte.weight"]
    assert wte_fp.shape == (YT_VOCAB_SIZE, YT_HIDDEN)
    assert torch.equal(wte_fp, sd["lm_head.weight"]), "Expected tied WTE == LM_HEAD"

    wte_q, lm_mult, lm_shift, wte_sc = quantize_weight_w8(wte_fp)
    wte_padded = np.zeros((YT_VOCAB_PAD, YT_HIDDEN), dtype=np.int8)
    wte_padded[:YT_VOCAB_SIZE, :] = wte_q
    wte_bytes = wte_padded.tobytes()
    image[DDR_OFFSET_WTE : DDR_OFFSET_WTE + len(wte_bytes)] = wte_bytes

    # 2. Position Embeddings WPE [512, 512]
    wpe_fp = sd["transformer.wpe.weight"]
    assert wpe_fp.shape == (YT_MAX_SEQ, YT_HIDDEN)
    wpe_q, _, _, wpe_sc = quantize_weight_w8(wpe_fp)
    wpe_bytes = wpe_q.tobytes()
    image[DDR_OFFSET_WPE : DDR_OFFSET_WPE + len(wpe_bytes)] = wpe_bytes

    wte_deq_u16 = int(round((1.0 / wte_sc) * 65536.0))
    wpe_deq_u16 = int(round((1.0 / wpe_sc) * 65536.0))
    quant_cfg["wte_deq_u16"] = wte_deq_u16
    quant_cfg["wpe_deq_u16"] = wpe_deq_u16
    quant_cfg["lm_head"] = {"mult_u8": lm_mult, "shift": lm_shift}

    # 3. 8 Transformer Blocks
    for l in range(YT_LAYERS):
        p = f"transformer.h.{l}."
        b_base = DDR_OFFSET_BLOCKS + l * DDR_BLOCK_STRIDE

        # LayerNorm 1 & 2 packed {beta_q78, gamma_q4_12}
        ln1_bytes = pack_ln_params(sd[p + "ln1.weight"], sd[p + "ln1.bias"])
        ln2_bytes = pack_ln_params(sd[p + "ln2.weight"], sd[p + "ln2.bias"])
        image[b_base + BLK_OFF_LN1_PARAM : b_base + BLK_OFF_LN1_PARAM + 2048] = ln1_bytes
        image[b_base + BLK_OFF_LN2_PARAM : b_base + BLK_OFF_LN2_PARAM + 2048] = ln2_bytes

        # QKV Weights [1536, 512] & Biases [1536] (quantized uniformly across c_attn to match test_lut_exact!)
        wqkv_q, qkv_mult, qkv_shift, qkv_sc = quantize_weight_w8(sd[p + "attn.c_attn.weight"])
        bqkv_i32 = quantize_bias_i32(sd[p + "attn.c_attn.bias"], qkv_sc)

        # Bias layout: Q[512], K[512], V[512] contiguous INT32 (6144 bytes)
        bqkv_bytes = bqkv_i32.astype("<i4").tobytes()
        image[b_base + BLK_OFF_QKV_BIAS : b_base + BLK_OFF_QKV_BIAS + 6144] = bqkv_bytes

        # Weight layout: Head-major! For h in 0..7: WQ[h] (32KB), WK[h] (32KB), WV[h] (32KB)
        wq_all = wqkv_q[0:512, :]
        wk_all = wqkv_q[512:1024, :]
        wv_all = wqkv_q[1024:1536, :]
        wqkv_ptr = b_base + BLK_OFF_WQKV
        for h in range(YT_HEADS):
            sl = slice(h * YT_HEAD_DIM, (h + 1) * YT_HEAD_DIM)
            for mat in (wq_all[sl, :], wk_all[sl, :], wv_all[sl, :]):
                raw = np.ascontiguousarray(mat).tobytes()
                image[wqkv_ptr : wqkv_ptr + 32768] = raw
                wqkv_ptr += 32768

        # Attention Output Projection WO [512, 512]
        wo_q, wo_mult, wo_shift, wo_sc = quantize_weight_w8(sd[p + "attn.c_proj.weight"])
        bo_i32 = quantize_bias_i32(sd[p + "attn.c_proj.bias"], wo_sc)
        image[b_base + BLK_OFF_WO_BIAS : b_base + BLK_OFF_WO_BIAS + 2048] = bo_i32.astype("<i4").tobytes()
        image[b_base + BLK_OFF_WO : b_base + BLK_OFF_WO + 262144] = np.ascontiguousarray(wo_q).tobytes()

        # MLP Up-Projection WFC [2048, 512] (4 contiguous [512, 512] slices)
        wfc_q, fc_mult, fc_shift, fc_sc = quantize_weight_w8(sd[p + "mlp.c_fc.weight"])
        bfc_i32 = quantize_bias_i32(sd[p + "mlp.c_fc.bias"], fc_sc)
        image[b_base + BLK_OFF_FC_BIAS : b_base + BLK_OFF_FC_BIAS + 8192] = bfc_i32.astype("<i4").tobytes()
        image[b_base + BLK_OFF_WFC : b_base + BLK_OFF_WFC + 1048576] = np.ascontiguousarray(wfc_q).tobytes()

        # MLP Down-Projection WPROJ [512, 2048] -> stored as 4 K-slices of [512, 512]!
        wproj_q, proj_mult, proj_shift, proj_sc = quantize_weight_w8(sd[p + "mlp.c_proj.weight"])
        bproj_i32 = quantize_bias_i32(sd[p + "mlp.c_proj.bias"], proj_sc)
        image[b_base + BLK_OFF_PROJ_BIAS : b_base + BLK_OFF_PROJ_BIAS + 2048] = bproj_i32.astype("<i4").tobytes()
        wproj_ptr = b_base + BLK_OFF_WPROJ
        for s in range(4):
            k_slice = np.ascontiguousarray(wproj_q[:, s * YT_FFN_SLICE : (s + 1) * YT_FFN_SLICE])
            assert k_slice.shape == (YT_HIDDEN, YT_FFN_SLICE)
            image[wproj_ptr : wproj_ptr + 262144] = k_slice.tobytes()
            wproj_ptr += 262144

        quant_cfg["layers"].append(
            {
                "layer": l,
                "qkv":  {"mult_u8": qkv_mult,  "shift": qkv_shift},
                "wo":   {"mult_u8": wo_mult,   "shift": wo_shift},
                "wfc":  {"mult_u8": fc_mult,   "shift": fc_shift},
                "wproj":{"mult_u8": proj_mult, "shift": proj_shift},
            }
        )

    # 4. Final LayerNorm LN_F
    lnf_bytes = pack_ln_params(sd["transformer.ln_f.weight"], sd["transformer.ln_f.bias"])
    image[DDR_OFFSET_LNF : DDR_OFFSET_LNF + 2048] = lnf_bytes

    bin_path = os.path.join(out_dir, "yt_ai_weights.bin")
    cfg_path = os.path.join(out_dir, "quant_config.json")
    with open(bin_path, "wb") as f:
        f.write(image)
    with open(cfg_path, "w", encoding="utf-8") as f:
        json.dump(quant_cfg, f, indent=2)

    print(f"[YT-AI Quantizer] Wrote {len(image):,} bytes -> {bin_path}")
    print(f"[YT-AI Quantizer] Wrote quantization metadata -> {cfg_path}")
    return quant_cfg


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--ckpt", default=DEFAULT_CKPT)
    parser.add_argument(
        "--out-dir",
        default=str(Path(__file__).resolve().parent.parent.parent / "build"),
    )
    args = parser.parse_args()
    export_yt_ai_checkpoint(args.ckpt, args.out_dir)
