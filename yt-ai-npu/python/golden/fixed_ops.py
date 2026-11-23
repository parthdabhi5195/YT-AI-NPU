"""
100% LUT-Free Bit-Exact Integer Hardware Arithmetic Mirror (`fixed_ops.py`).
Matches `yt_npu_pkg.sv`, `yt_sfu_exp.sv`, `yt_sfu_recip.sv`, `yt_sfu_rsqrt.sv`,
`yt_gemm_engine.sv`, `yt_layernorm_engine.sv`, `yt_softmax_engine.sv`,
`yt_gelu_engine.sv`, `yt_embed_engine.sv`, and `yt_topk_sampler.sv`
to the exact bit (ZERO lookup tables, ZERO floating-point, ZERO dividers!).
"""

from __future__ import annotations
import math
import numpy as np


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
# Algebraic SFU 1: Base-2 Horner Polynomial Exponential (`yt_sfu_exp.sv`)
# =============================================================================
def sfu_exp_q15(d_q78: np.ndarray) -> np.ndarray:
    """Computes exp(-d) in Q0.15 [0..32767] for unsigned Q7.8 input d_q78 (ZERO LUTs!)."""
    d = np.clip(np.asarray(d_q78, dtype=np.int64), 0, 4095)
    z_q22 = d * 23637
    z_q15 = (z_q22 + 64) >> 7
    k = np.minimum(z_q15 >> 15, 16)
    u = z_q15 & 0x7FFF

    t1 = 7563 + ((u * (-1294)) >> 15)
    t2 = -22653 + ((u * t1) >> 15)
    p_u15 = np.clip(32766 + ((u * t2) >> 15), 0, 32767)
    return np.where(k >= 16, 0, p_u15 >> k)


# =============================================================================
# Algebraic SFU 2: Minimax + 2x Newton-Raphson Reciprocal (`yt_sfu_recip.sv`)
# =============================================================================
def sfu_recip_q14(m_u16: np.ndarray) -> np.ndarray:
    """Computes round((1.0 / m_real) * 16384) for m_u16 in [32768..65535] (ZERO LUTs!)."""
    m = np.maximum(np.asarray(m_u16, dtype=np.int64), 32768)
    y = 46260 - ((m * 30840) >> 16)
    for _ in range(2):
        two_minus_my = 32768 - ((m * y) >> 16)
        y = np.minimum((y * two_minus_my) >> 14, 32768)
    return y


# =============================================================================
# Algebraic SFU 3: Piecewise Seed + 2x Coupled NR RSQRT (`yt_sfu_rsqrt.sv`)
# =============================================================================
def sfu_rsqrt_q14(m_u16: np.ndarray) -> np.ndarray:
    """Computes round((1.0 / sqrt(m_real)) * 16384) for m_u16 in [16384..65535] (ZERO LUTs!)."""
    m = np.maximum(np.asarray(m_u16, dtype=np.int64), 16384)
    slope = np.where(m >= 32768, 13353, 37028)
    inter = np.where(m >= 32768, 29573, 41779)
    y = inter - ((m * slope) >> 16)
    for _ in range(2):
        y2 = (y * y + 8192) >> 14
        three_minus = 49152 - ((m * y2 + 32768) >> 16)
        y = np.minimum((y * three_minus + 16384) >> 15, 32768)
    return y


# =============================================================================
# Engine 2: LUT-Free Divider-Free Q7.8 LayerNorm (`yt_layernorm_engine.sv`)
# =============================================================================
def clz_rsqrt_q12(var_q16: int) -> int:
    v8 = (max(0, int(var_q16)) + 1) << 8
    k = 16
    for cand_k in range(15, 0, -1):
        if (v8 >> (2 * cand_k)) < 256:
            k = cand_k
    if k == 1:
        m16 = (v8 << 6) & 0xFFFF
    elif k == 2:
        m16 = (v8 << 4) & 0xFFFF
    elif k == 3:
        m16 = (v8 << 2) & 0xFFFF
    else:
        m16 = (v8 >> (2 * k - 8)) & 0xFFFF

    rsqrt_val = int(sfu_rsqrt_q14(np.array(m16)))
    raw_inv = (rsqrt_val << 6) >> k
    return min(raw_inv, 0x0F_FFFF)


def hw_layernorm_q78(
    x_q78: np.ndarray,
    gamma_q4_12: np.ndarray,
    beta_q78: np.ndarray,
) -> np.ndarray:
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
# Engine 1: LUT-Free 512-Context Causal Softmax (`yt_softmax_engine.sv`)
# =============================================================================
def clz_recip_norm_row(exp_row: np.ndarray, sum_val: int) -> np.ndarray:
    s = max(1, int(sum_val))
    m16 = 32768
    rshift = 15
    if s < 32768:
        for sh in range(15, 0, -1):
            if 32768 <= (s << sh) < 65536:
                m16 = (s << sh) & 0xFFFF
                rshift = 15 - sh
    else:
        for sh in range(16, -1, -1):
            if 32768 <= (s >> sh) < 65536:
                m16 = (s >> sh) & 0xFFFF
                rshift = 15 + sh
    recip = int(sfu_recip_q14(np.array(m16)))
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
        diffs = np.clip(row_max - row, 0, 4095)
        exp_vals = sfu_exp_q15(diffs).copy()
        exp_vals[~valid_mask] = 0
        sum_exp = int(np.sum(exp_vals))
        out[r] = clz_recip_norm_row(exp_vals, sum_exp)
    return out


# =============================================================================
# Engine 3: LUT-Free Analytic GPT-2 Q7.8 GELU (`yt_gelu_engine.sv`)
# =============================================================================
def hw_gelu_q78(x_q78: np.ndarray, fast_quad_mode: bool = False) -> np.ndarray:
    x = x_q78.astype(np.int64)
    if fast_quad_mode:
        abs_x = np.minimum(np.abs(x), 642)
        delta = 642 - abs_x
        om_erf = np.clip(((delta * delta) * 20841) >> 18, 0, 32768)
        erf_abs = 32768 - om_erf
        erf_sgn = np.where(x >= 0, erf_abs, -erf_abs)
        res = np.where(
            x >= 1280, x,
            np.where(x <= -1280, 0, ((x * (32768 + erf_sgn)) + 32768) >> 16)
        )
        return saturate_i16_arr(res)

    xc = np.clip(x, -1280, 1280)
    x2_q8 = (xc * xc) >> 8
    x3_q8 = (x2_q8 * xc) >> 8
    u_q78 = ((xc * 26145) + (x3_q8 * 1169)) >> 14
    abs_u = np.clip(np.abs(u_q78), 0, 4095)
    exp_neg = sfu_exp_q15(abs_u)
    sig_abs = sfu_recip_q14(32768 + exp_neg)
    sig_q15 = np.where(u_q78 < 0, 32768 - sig_abs, sig_abs)
    core = ((xc * sig_q15) + 16384) >> 15
    res = np.where(x >= 1280, x, np.where(x <= -1280, 0, core))
    return saturate_i16_arr(res)


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
# Engine 7: 64-Bit Xorshift64* PRNG (`yt_topk_sampler.sv`)
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
