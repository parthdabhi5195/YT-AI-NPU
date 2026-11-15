"""
Bit-Exact Integer Hardware Arithmetic & ROM LUT Mirror (`fixed_ops.py`).
Matches `yt_npu_pkg.sv`, `yt_*_lut.sv`, `yt_gemm_engine.sv`, `yt_layernorm_engine.sv`,
`yt_softmax_engine.sv`, `yt_gelu_engine.sv`, `yt_embed_engine.sv`, and `yt_topk_sampler.sv`
to the exact bit (ZERO floating-point at runtime!).
"""

from __future__ import annotations
import math
import numpy as np


# =============================================================================
# Hardware ROM LUTs (4 x 256 x 16-bit = 2.0 KB Total ROM)
# =============================================================================
def _build_rsqrt_lut() -> np.ndarray:
    lut = np.zeros(256, dtype=np.int64)
    lut[0] = 0xFFFF
    for m in range(1, 256):
        lut[m] = min(65535, int(round(65536.0 / math.sqrt(float(m)))))
    return lut


def _build_exp_lut() -> np.ndarray:
    return np.array(
        [int(round(math.exp(-i / 16.0) * 32767.0)) for i in range(256)],
        dtype=np.int64,
    )


def _build_recip_lut() -> np.ndarray:
    lut = np.zeros(256, dtype=np.int64)
    lut[0] = 0xFFFF
    for m in range(1, 256):
        lut[m] = min(65535, int(round(float(1 << 22) / float(m))))
    return lut


def _build_gelu_lut() -> np.ndarray:
    lut = np.zeros(256, dtype=np.int16)
    for u in range(256):
        s = u - 256 if u >= 128 else u
        x = (s + 0.5) / 32.0
        g = 0.5 * x * (1.0 + math.erf(x / math.sqrt(2.0)))
        lut[u] = np.int16(int(round(g * 256.0)))
    return lut


RSQRT_LUT = _build_rsqrt_lut()
EXP_LUT   = _build_exp_lut()
RECIP_LUT = _build_recip_lut()
GELU_LUT  = _build_gelu_lut()


# =============================================================================
# Fixed-Point Helper Functions (`yt_npu_pkg.sv`)
# =============================================================================
def saturate_i8_arr(x: np.ndarray) -> np.ndarray:
    return np.clip(x, -128, 127).astype(np.int8)


def saturate_i16_arr(x: np.ndarray) -> np.ndarray:
    return np.clip(x, -32768, 32767).astype(np.int16)


def pack_kv_q43(val_q78: np.ndarray) -> np.ndarray:
    shifted = (val_q78.astype(np.int64) + 16) >> 5
    return saturate_i8_arr(shifted)


def requantize_q78(
    acc_i32: np.ndarray,
    bias_i32: np.ndarray | None,
    mult_u8: int,
    shift: int,
) -> np.ndarray:
    s = acc_i32.astype(np.int64)
    if bias_i32 is not None:
        s = s + bias_i32.astype(np.int64)
    prod = s * int(mult_u8)
    if shift > 0:
        prod = prod + (1 << (shift - 1))
        prod = prod >> shift
    return saturate_i16_arr(prod)


# =============================================================================
# Engine 2: Divider-Free Q7.8 LayerNorm (`yt_layernorm_engine.sv`)
# =============================================================================
def clz_rsqrt_q12(var_q16: int) -> int:
    v8 = (max(0, int(var_q16)) + 1) << 8
    k = 0
    for cand_k in range(16, -1, -1):
        shifted = v8 >> (2 * cand_k)
        if 64 <= shifted < 256:
            k = cand_k
            break
    m = (v8 >> (2 * k)) & 0xFF
    raw_inv = (int(RSQRT_LUT[m]) << 8) >> k
    return min(raw_inv, 0x0F_FFFF)


def hw_layernorm_q78(
    x_q78: np.ndarray,
    gamma_q4_12: np.ndarray,
    beta_q78: np.ndarray,
) -> np.ndarray:
    """x_q78: [M, N] int16, gamma_q4_12: [N] int16, beta_q78: [N] int16 -> [M, N] int16."""
    M, N = x_q78.shape
    log2_n = int(round(math.log2(N)))
    assert (1 << log2_n) == N, f"LayerNorm N={N} must be power of 2"
    out = np.zeros((M, N), dtype=np.int16)
    g64 = gamma_q4_12.astype(np.int64)
    b64 = beta_q78.astype(np.int64)

    for r in range(M):
        row = x_q78[r].astype(np.int64)
        mean = int(np.sum(row)) >> log2_n
        diff = row - mean
        var_q16 = int(np.sum(diff * diff)) >> log2_n
        inv_std_q12 = clz_rsqrt_q12(var_q16)
        normed = (diff * inv_std_q12) >> 12
        scaled = ((normed * g64) >> 12) + b64
        out[r] = saturate_i16_arr(scaled)
    return out


# =============================================================================
# Engine 1: 512-Context Divider-Free Causal Softmax (`yt_softmax_engine.sv`)
# =============================================================================
def clz_recip_norm_row(exp_row: np.ndarray, sum_val: int) -> np.ndarray:
    s = max(1, int(sum_val))
    m = 128
    rshift = 7
    if s < 128:
        for sh in range(7, 0, -1):
            if 128 <= (s << sh) < 256:
                m = (s << sh) & 0xFF
                rshift = 7 - sh
    else:
        for sh in range(24, -1, -1):
            if 128 <= (s >> sh) < 256:
                m = (s >> sh) & 0xFF
                rshift = 7 + sh
    recip = int(RECIP_LUT[m])
    prod = exp_row.astype(np.int64) * recip
    if rshift >= 0:
        shifted = prod >> rshift
    else:
        shifted = prod << (-rshift)
    return np.clip(shifted, 0, 32767).astype(np.int16)


def hw_softmax_q15(
    scores_q78: np.ndarray,
    causal_mask: bool = False,
    causal_base: int = 0,
) -> np.ndarray:
    """scores_q78: [M, N] int16 -> [M, N] int16 Q0.15 in [0..32767]."""
    M, N = scores_q78.shape
    out = np.zeros((M, N), dtype=np.int16)
    for r in range(M):
        row = scores_q78[r].astype(np.int64)
        if causal_mask:
            limit = causal_base + r
            valid_mask = np.arange(N) <= limit
        else:
            valid_mask = np.ones(N, dtype=bool)

        if not np.any(valid_mask):
            continue

        row_max = int(np.max(row[valid_mask]))
        diffs = np.clip(row_max - row, 0, 4080)
        lut_idx = (diffs >> 4).astype(np.int64)
        exp_vals = EXP_LUT[lut_idx].copy()
        exp_vals[~valid_mask] = 0
        sum_exp = int(np.sum(exp_vals))
        out[r] = clz_recip_norm_row(exp_vals, sum_exp)
    return out


# =============================================================================
# Engine 3: Piecewise + 256-LUT Q7.8 GELU (`yt_gelu_engine.sv`)
# =============================================================================
def hw_gelu_q78(x_q78: np.ndarray) -> np.ndarray:
    x = x_q78.astype(np.int64)
    idx = ((x >> 3) & 0xFF).astype(np.int64)
    lut_vals = GELU_LUT[idx].astype(np.int64)
    res = np.where(x >= 1024, x, np.where(x < -1024, 0, lut_vals))
    return res.astype(np.int16)


# =============================================================================
# Engine 6: Hardware Token + Position Embedding (`yt_embed_engine.sv`)
# =============================================================================
def hw_embed_q78(
    wte_row_i8: np.ndarray,
    wpe_row_i8: np.ndarray,
    wte_deq_u16: int,
    wpe_deq_u16: int,
) -> np.ndarray:
    t = (wte_row_i8.astype(np.int64) * int(wte_deq_u16)) >> 8
    p = (wpe_row_i8.astype(np.int64) * int(wpe_deq_u16)) >> 8
    return saturate_i16_arr(t + p)


# =============================================================================
# Engine 7: 64-Bit Xorshift64* PRNG + Top-K Sampler (`yt_topk_sampler.sv`)
# =============================================================================
class HardwareXorshift64Star:
    """Bit-exact match to `yt_topk_sampler.sv` PRNG."""

    def __init__(self, seed: int = 0xCAFE_BABE_DEAD_BEEF):
        self.state = seed & 0xFFFF_FFFF_FFFF_FFFF
        if self.state == 0:
            self.state = 0xCAFE_BABE_DEAD_BEEF

    def step_u32(self) -> int:
        x = self.state
        x ^= (x >> 12) & 0xFFFF_FFFF_FFFF_FFFF
        x ^= (x << 25) & 0xFFFF_FFFF_FFFF_FFFF
        x ^= (x >> 27) & 0xFFFF_FFFF_FFFF_FFFF
        self.state = x
        prod = (x * 0x2545_F491_4F6C_DD1D) & 0xFFFF_FFFF_FFFF_FFFF
        return (prod >> 32) & 0xFFFF_FFFF
