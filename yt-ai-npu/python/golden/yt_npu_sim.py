"""
Bit-Exact Microcode & Autonomous Sequencer Architectural Simulator (`yt_npu_sim.py`).
Executes compiled 128-bit microcode (`UcodeInstr`) directly against the binary DDR image
(`yt_ai_weights.bin`) and 4 MB DDR KV-cache using the exact integer datapaths of `rtl/`.
"""

from __future__ import annotations
import sys
from pathlib import Path
import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from golden.fixed_ops import (  # noqa: E402
    HardwareXorshift64Star,
    hw_embed_q78,
    hw_gelu_q78,
    hw_layernorm_q78,
    hw_softmax_q15,
    pack_kv_q43,
    requantize_q78,
    saturate_i16_arr,
    sfu_exp_q15,
)
from tools.memory_map import (  # noqa: E402
    ACT_SRAM_WORDS,
    DDR_OFFSET_BLOCKS,
    DDR_OFFSET_KV,
    DDR_OFFSET_LNF,
    DDR_OFFSET_OUT,
    DDR_OFFSET_WPE,
    DDR_OFFSET_WTE,
    DMA_LOOP_L0,
    DMA_LOOP_L0_256K_L1,
    DMA_LOOP_L1,
    DMA_REG_BLOCK,
    DMA_REG_KV,
    DMA_REG_LNF,
    DMA_REG_OUT,
    DMA_REG_WPE,
    DMA_REG_WTE,
    DMA_TGT_ACT,
    DMA_TGT_PARAM,
    DMA_TGT_WGT0,
    DMA_TGT_WGT1,
    FLAG_ACCUMULATE,
    FLAG_ATTN_CTX,
    FLAG_ATTN_SCORE,
    FLAG_BARRIER_PREFILL_EXIT,
    FLAG_BIAS_EN,
    FLAG_CAUSAL_MASK,
    FLAG_DMA_DYN_INDEX,
    FLAG_KV_IS_V,
    FLAG_KV_LOOP_HEAD,
    FLAG_PINGPONG_B,
    FLAG_REQUANT,
    FLAG_TOPK_LOOP_L0,
    FLAG_TOPK_RESET,
    FLAG_TRANSPOSE_B,
    FLAG_VEC_COPY2D,
    GEMM_IMM_DST_LOOP64,
    GEMM_IMM_LOOP_SEL_L1,
    GEMM_IMM_SRC1_LOOP64,
    OP_BARRIER,
    OP_DMA_LOAD,
    OP_DMA_STORE,
    OP_EMBED,
    OP_END,
    OP_GELU,
    OP_GEMM,
    OP_KV_APPEND,
    OP_KV_READ,
    OP_LAYERNORM,
    OP_LOOP_BEGIN,
    OP_LOOP_END,
    OP_NOP,
    OP_SOFTMAX,
    OP_TOPK_FEED,
    OP_TOPK_SAMPLE,
    OP_VEC,
    PARAM_SRAM_WORDS,
    TOPK_MAX_K,
    TOK_SRAM_DEPTH,
    UcodeInstr,
    VEC_OP_ADD,
    VEC_OP_CLAMP,
    VEC_OP_MUL,
    VEC_OP_SCALE_SHIFT,
    WGT_BANK_BEATS,
    YT_EOT_TOKEN,
    YT_VOCAB_SIZE,
    kv_cache_ddr_addr,
)


class YtAiNpuSimulator:
    """Bit-exact RTL-equivalent simulator of `yt_npu_top.sv`."""

    def __init__(self, weights_bin: bytes | bytearray, ddr_size_bytes: int = 64 * 1024 * 1024):
        self.ddr = bytearray(ddr_size_bytes)
        self.ddr[: len(weights_bin)] = weights_bin

        # On-Chip SRAMs (91 KB total)
        self.act_sram   = np.zeros(ACT_SRAM_WORDS, dtype=np.int16)
        self.wgt_sram   = bytearray(WGT_BANK_BEATS * 2 * 16)  # 32 KB unified ping-pong
        self.param_sram = np.zeros(PARAM_SRAM_WORDS, dtype=np.uint32)
        self.tok_sram   = np.zeros(TOK_SRAM_DEPTH, dtype=np.uint16)
        self.ucode_sram: list[UcodeInstr] = []

        # Host registers
        self.cfg_ddr_base_wgt = 0
        self.cfg_ddr_base_kv  = DDR_OFFSET_KV
        self.cfg_ddr_base_out = DDR_OFFSET_OUT
        self.cfg_wte_deq_u16  = 142
        self.cfg_wpe_deq_u16  = 39
        self.cfg_lm_mult_u8   = 142
        self.cfg_lm_shift_u8  = 16
        self.cfg_top_k        = 200
        self.cfg_temp_inv_q88 = 320  # 1 / 0.8 = 1.25 -> 320
        self.prng             = HardwareXorshift64Star(0xCAFE_BABE_DEAD_BEEF)

        # Top-K Sampler hardware pool (`yt_topk_sampler.sv`)
        self.topk_vals    = np.full(TOPK_MAX_K, -32768, dtype=np.int16)
        self.topk_ids     = np.zeros(TOPK_MAX_K, dtype=np.uint16)
        self.pool_min_val = -32768
        self.pool_min_idx = 0
        self.pool_max_val = -32768
        self.pool_max_id  = 0

        # Debug / verification capture of all 50,257 logits on last decode step
        self.last_full_logits_q78 = np.zeros(YT_VOCAB_SIZE, dtype=np.int16)
        self.est_cycles = 0

    def load_microcode(self, prog: list[UcodeInstr]) -> None:
        self.ucode_sram = list(prog)

    def configure_scales(self, quant_cfg: dict) -> None:
        self.cfg_wte_deq_u16 = int(quant_cfg["wte_deq_u16"])
        self.cfg_wpe_deq_u16 = int(quant_cfg["wpe_deq_u16"])
        self.cfg_lm_mult_u8  = int(quant_cfg["lm_head"]["mult_u8"])
        self.cfg_lm_shift_u8 = int(quant_cfg["lm_head"]["shift"])

    # -------------------------------------------------------------------------
    # Internal Engine Implementations (100% bit-exact with RTL)
    # -------------------------------------------------------------------------
    def _calc_dma_addr(
        self,
        ins: UcodeInstr,
        loop_idx_0: int,
        loop_idx_1: int,
        cur_pos: int,
        cur_tok_id: int,
    ) -> int:
        reg = (ins.flags >> 2) & 0x7
        if reg == DMA_REG_WTE:
            base = self.cfg_ddr_base_wgt + DDR_OFFSET_WTE
        elif reg == DMA_REG_WPE:
            base = self.cfg_ddr_base_wgt + DDR_OFFSET_WPE
        elif reg == DMA_REG_BLOCK:
            base = self.cfg_ddr_base_wgt + DDR_OFFSET_BLOCKS
        elif reg == DMA_REG_LNF:
            base = self.cfg_ddr_base_wgt + DDR_OFFSET_LNF
        elif reg == DMA_REG_KV:
            base = self.cfg_ddr_base_kv
        elif reg == DMA_REG_OUT:
            base = self.cfg_ddr_base_out
        else:
            base = self.cfg_ddr_base_wgt

        static_off = ((ins.K & 0xFFFF) << 16) | (ins.src1_base & 0xFFFF)
        lmode = (ins.flags >> 5) & 0x3
        if lmode == DMA_LOOP_L0:
            loop_off = loop_idx_0 * (ins.imm << 10)
        elif lmode == DMA_LOOP_L1:
            loop_off = loop_idx_1 * (ins.imm << 10)
        elif lmode == DMA_LOOP_L0_256K_L1:
            loop_off = ((loop_idx_0 & 0x3) << 18) + loop_idx_1 * (ins.imm << 10)
        else:
            loop_off = 0

        tokpos_off = 0
        if ins.flags & FLAG_DMA_DYN_INDEX:
            if reg == DMA_REG_WTE:
                tokpos_off = cur_tok_id * 512
            elif reg == DMA_REG_WPE:
                tokpos_off = cur_pos * 512

        return base + static_off + loop_off + tokpos_off

    def _exec_dma_load(self, ddr_addr: int, byte_len: int, tgt: int, dst_base: int) -> None:
        raw = self.ddr[ddr_addr : ddr_addr + byte_len]
        self.est_cycles += max(4, (byte_len + 15) // 16 + 6)
        if tgt == DMA_TGT_WGT0:
            off = dst_base * 16
            self.wgt_sram[off : off + byte_len] = raw
        elif tgt == DMA_TGT_WGT1:
            off = (1024 + (dst_base & 0x3FF)) * 16
            self.wgt_sram[off : off + byte_len] = raw
        elif tgt == DMA_TGT_PARAM:
            words = np.frombuffer(raw, dtype="<u4")
            self.param_sram[dst_base : dst_base + len(words)] = words
        elif tgt == DMA_TGT_ACT:
            words = np.frombuffer(raw, dtype="<i2")
            self.act_sram[dst_base : dst_base + len(words)] = words

    def _exec_gemm(
        self,
        src0: int,
        src1: int,
        dst: int,
        M: int,
        N: int,
        K: int,
        flags: int,
        imm: int,
    ) -> None:
        a = self.act_sram[src0 : src0 + M * K].reshape(M, K).astype(np.int64)
        bank_sel = 1 if (flags & FLAG_PINGPONG_B) else 0
        b_byte_off = bank_sel * 16384
        b_bytes = self.wgt_sram[b_byte_off : b_byte_off + N * K]
        if flags & FLAG_TRANSPOSE_B:
            b_mat = np.frombuffer(b_bytes, dtype=np.int8).reshape(N, K).T.astype(np.int64)
        else:
            b_mat = np.frombuffer(b_bytes, dtype=np.int8).reshape(K, N).astype(np.int64)

        acc = a @ b_mat  # INT32 exact
        if flags & FLAG_BIAS_EN:
            bias = self.param_sram[src1 : src1 + N].view(np.int32).astype(np.int64)[None, :]
        else:
            bias = np.zeros((1, N), dtype=np.int64)

        if flags & FLAG_ATTN_SCORE:
            post = saturate_i16_arr((acc + bias + 32) >> 6)
        elif flags & FLAG_ATTN_CTX:
            post = saturate_i16_arr((acc + bias + 512) >> 10)
        elif flags & FLAG_REQUANT:
            mult_u8 = imm & 0xFF
            shift = (imm >> 8) & 0x1F
            if mult_u8 == 0 and shift == 0:
                mult_u8 = self.cfg_lm_mult_u8
                shift = self.cfg_lm_shift_u8
            post = requantize_q78(acc, bias, mult_u8, shift)
        else:
            post = saturate_i16_arr(acc + bias)

        flat_post = post.reshape(-1)
        if flags & FLAG_ACCUMULATE:
            cur = self.act_sram[dst : dst + M * N].astype(np.int32)
            self.act_sram[dst : dst + M * N] = saturate_i16_arr(cur + flat_post.astype(np.int32))
        else:
            self.act_sram[dst : dst + M * N] = flat_post

        # Cycle estimate matching 16x16 systolic tiles
        mt = (M + 15) // 16
        nt = (N + 15) // 16
        kt = (K + 15) // 16
        self.est_cycles += mt * nt * kt * 68

    def _exec_topk_feed(self, src_base: int, length: int, vocab_base: int, reset_pool: bool) -> None:
        k_eff = min(max(1, self.cfg_top_k), TOPK_MAX_K)
        if reset_pool:
            self.topk_vals[:k_eff] = -32768
            self.topk_ids[:k_eff]  = 0
            self.pool_min_val      = -32768
            self.pool_min_idx      = 0
            self.pool_max_val      = -32768
            self.pool_max_id       = 0

        tile = self.act_sram[src_base : src_base + length]
        for i in range(length):
            vid = vocab_base + i
            if vid >= YT_VOCAB_SIZE:
                continue
            val = int(tile[i])
            self.last_full_logits_q78[vid] = tile[i]
            if val > self.pool_min_val:
                self.topk_vals[self.pool_min_idx] = val
                self.topk_ids[self.pool_min_idx]  = vid
                if val > self.pool_max_val:
                    self.pool_max_val = val
                    self.pool_max_id  = vid
                # Rescan min across active k_eff slots (exact match to S_RESCAN_CMP in RTL!)
                sub = self.topk_vals[:k_eff]
                min_i = int(np.argmin(sub))
                self.pool_min_idx = min_i
                self.pool_min_val = int(sub[min_i])
        self.est_cycles += length + 8

    def _exec_topk_sample(self) -> int:
        k_eff = min(max(1, self.cfg_top_k), TOPK_MAX_K)
        if k_eff <= 1 or self.cfg_temp_inv_q88 == 0:
            self.est_cycles += 4
            return int(self.pool_max_id)

        probs = np.zeros(k_eff, dtype=np.int64)
        for s in range(k_eff):
            logit = int(self.topk_vals[s])
            if logit == -32768:
                probs[s] = 0
            else:
                diff = self.pool_max_val - logit
                scaled = (diff * self.cfg_temp_inv_q88) >> 8
                clamped = min(max(0, scaled), 4095)
                probs[s] = int(sfu_exp_q15(np.array(clamped)))

        prob_sum = int(np.sum(probs))
        rand_u32 = self.prng.step_u32()
        threshold = (rand_u32 * prob_sum) >> 32

        cum = 0
        for s in range(k_eff):
            cum += int(probs[s])
            if cum > threshold or s == k_eff - 1:
                self.est_cycles += k_eff * 5
                return int(self.topk_ids[s])
        return int(self.pool_max_id)

    # -------------------------------------------------------------------------
    # Step & Full Autonomous Generation Execution
    # -------------------------------------------------------------------------
    def run_single_step(
        self,
        cur_pos: int,
        cur_tok_id: int,
        is_prefill_skip_lm: bool,
    ) -> int | None:
        pc = 0
        loop_idx = [0, 0]
        loop_cnt = [0, 0]
        sampled_tok: int | None = None
        cur_seq_len = cur_pos + 1

        while pc < len(self.ucode_sram):
            ins = self.ucode_sram[pc]
            op = ins.opcode

            if op == OP_NOP:
                pc += 1
            elif op == OP_LOOP_BEGIN:
                lid = ins.flags & 1
                loop_idx[lid] = 0
                loop_cnt[lid] = ins.M
                pc += 1
            elif op == OP_LOOP_END:
                lid = ins.flags & 1
                if loop_idx[lid] + 1 < loop_cnt[lid]:
                    loop_idx[lid] += 1
                    pc = ins.dst_base
                else:
                    loop_idx[lid] = 0
                    pc += 1
            elif op == OP_BARRIER:
                if (ins.flags & FLAG_BARRIER_PREFILL_EXIT) and is_prefill_skip_lm:
                    break
                pc += 1
            elif op == OP_END:
                break
            elif op == OP_DMA_LOAD:
                addr = self._calc_dma_addr(ins, loop_idx[0], loop_idx[1], cur_pos, cur_tok_id)
                self._exec_dma_load(addr, ins.N, ins.flags & 0x3, ins.dst_base)
                pc += 1
            elif op == OP_DMA_STORE:
                addr = self._calc_dma_addr(ins, loop_idx[0], loop_idx[1], cur_pos, cur_tok_id)
                n_words = ins.N // 2
                self.ddr[addr : addr + ins.N] = self.act_sram[ins.src0_base : ins.src0_base + n_words].astype("<i2").tobytes()
                pc += 1
            elif op == OP_KV_APPEND:
                lid = ins.M & 0x7
                hid = (loop_idx[0] & 0x7) if (ins.flags & FLAG_KV_LOOP_HEAD) else (ins.src1_base & 0x7)
                is_v = 1 if (ins.flags & FLAG_KV_IS_V) else 0
                pos = cur_pos if ins.N == 0 else ins.K
                rows = 1 if ins.N == 0 else ins.N
                addr = kv_cache_ddr_addr(self.cfg_ddr_base_kv, lid, hid, is_v, pos)
                packed = pack_kv_q43(self.act_sram[ins.src0_base : ins.src0_base + rows * 64])
                self.ddr[addr : addr + rows * 64] = packed.tobytes()
                self.est_cycles += rows * 68
                pc += 1
            elif op == OP_KV_READ:
                lid = ins.M & 0x7
                hid = (loop_idx[0] & 0x7) if (ins.flags & FLAG_KV_LOOP_HEAD) else (ins.src1_base & 0x7)
                is_v = 1 if (ins.flags & FLAG_KV_IS_V) else 0
                rows = cur_seq_len if ins.N == 0 else ins.N
                addr = kv_cache_ddr_addr(self.cfg_ddr_base_kv, lid, hid, is_v, 0)
                tgt = DMA_TGT_WGT1 if (ins.flags & 0x4) else DMA_TGT_WGT0
                self._exec_dma_load(addr, rows * 64, tgt, ins.dst_base)
                pc += 1
            elif op == OP_EMBED:
                wte_r = np.frombuffer(self.wgt_sram[0 : ins.N], dtype=np.int8)
                wpe_r = np.frombuffer(self.wgt_sram[16384 : 16384 + ins.N], dtype=np.int8)
                self.act_sram[ins.dst_base : ins.dst_base + ins.N] = hw_embed_q78(
                    wte_r, wpe_r, self.cfg_wte_deq_u16, self.cfg_wpe_deq_u16
                )
                self.est_cycles += ins.N + 16
                pc += 1
            elif op == OP_LAYERNORM:
                M = max(1, ins.M)
                N = ins.N
                x_in = self.act_sram[ins.src0_base : ins.src0_base + M * N].reshape(M, N)
                pwords = self.param_sram[ins.src1_base : ins.src1_base + N]
                gamma = (pwords & 0xFFFF).astype(np.uint16).view(np.int16)
                beta  = ((pwords >> 16) & 0xFFFF).astype(np.uint16).view(np.int16)
                self.act_sram[ins.dst_base : ins.dst_base + M * N] = hw_layernorm_q78(x_in, gamma, beta).reshape(-1)
                self.est_cycles += M * N * 6
                pc += 1
            elif op == OP_SOFTMAX:
                M = max(1, ins.M)
                N = cur_seq_len if ins.N == 0 else ins.N
                sc = self.act_sram[ins.src0_base : ins.src0_base + M * N].reshape(M, N)
                pr = hw_softmax_q15(sc, bool(ins.flags & FLAG_CAUSAL_MASK), ins.K)
                self.act_sram[ins.dst_base : ins.dst_base + M * N] = pr.reshape(-1)
                self.est_cycles += M * N * 7
                pc += 1
            elif op == OP_GELU:
                tot = max(1, ins.M) * ins.N
                self.act_sram[ins.dst_base : ins.dst_base + tot] = hw_gelu_q78(
                    self.act_sram[ins.src0_base : ins.src0_base + tot]
                )
                self.est_cycles += tot * 3
                pc += 1
            elif op == OP_VEC:
                if ins.flags & FLAG_VEC_COPY2D:
                    for r in range(ins.M):
                        s_i = ins.src0_base + r * ins.K
                        d_i = ins.dst_base + r * ins.imm
                        self.act_sram[d_i : d_i + ins.N] = self.act_sram[s_i : s_i + ins.N]
                else:
                    tot = max(1, ins.M) * ins.N
                    a = self.act_sram[ins.src0_base : ins.src0_base + tot].astype(np.int64)
                    b = self.act_sram[ins.src1_base : ins.src1_base + tot].astype(np.int64)
                    sub = ins.flags & 0x3
                    if sub == VEC_OP_ADD:
                        res = saturate_i16_arr(a + b)
                    elif sub == VEC_OP_MUL:
                        res = saturate_i16_arr((a * b + 128) >> 8)
                    elif sub == VEC_OP_SCALE_SHIFT:
                        sc_u8 = ins.imm & 0xFF
                        sh_u5 = (ins.imm >> 8) & 0x1F
                        p = a * sc_u8 + ((1 << (sh_u5 - 1)) if sh_u5 > 0 else 0)
                        res = saturate_i16_arr(p >> sh_u5)
                    else:
                        res = saturate_i16_arr(a)
                    self.act_sram[ins.dst_base : ins.dst_base + tot] = res
                pc += 1
            elif op == OP_GEMM:
                lidx = loop_idx[1] if (ins.imm & GEMM_IMM_LOOP_SEL_L1) else loop_idx[0]
                dst_eff  = ins.dst_base  + (lidx * 64 if (ins.imm & GEMM_IMM_DST_LOOP64) else 0)
                src1_eff = ins.src1_base + (lidx * 64 if (ins.imm & GEMM_IMM_SRC1_LOOP64) else 0)
                N_eff = cur_seq_len if ins.N == 0 else ins.N
                K_eff = cur_seq_len if ins.K == 0 else ins.K
                self._exec_gemm(ins.src0_base, src1_eff, dst_eff, ins.M, N_eff, K_eff, ins.flags, ins.imm & 0x1FFF)
                pc += 1
            elif op == OP_TOPK_FEED:
                vbase = ins.src1_base + (loop_idx[0] * 64 if (ins.flags & FLAG_TOPK_LOOP_L0) else 0)
                self._exec_topk_feed(ins.src0_base, ins.N, vbase, bool(ins.flags & FLAG_TOPK_RESET))
                pc += 1
            elif op == OP_TOPK_SAMPLE:
                sampled_tok = self._exec_topk_sample()
                pc += 1
            else:
                raise RuntimeError(f"Unknown opcode 0x{op:02x} at PC={pc}")

        return sampled_tok

    def generate_autonomous(
        self,
        prompt_tokens: list[int],
        max_new_tokens: int = 16,
        top_k: int = 200,
        temperature: float = 0.8,
        seed: int = 0xCAFE_BABE_DEAD_BEEF,
    ) -> list[int]:
        """Mirrors `yt_token_sequencer.sv` autonomous multi-token execution."""
        assert 1 <= len(prompt_tokens) <= 512
        self.cfg_top_k = top_k
        self.cfg_temp_inv_q88 = 0 if temperature <= 0.0 else int(round((1.0 / temperature) * 256.0))
        self.prng = HardwareXorshift64Star(seed)
        self.est_cycles = 0

        for i, tok in enumerate(prompt_tokens):
            self.tok_sram[i] = tok

        generated: list[int] = []
        cur_pos = 0
        prompt_len = len(prompt_tokens)

        while True:
            cur_tok = int(self.tok_sram[cur_pos])
            skip_lm = cur_pos < (prompt_len - 1)
            sampled = self.run_single_step(cur_pos, cur_tok, skip_lm)

            if skip_lm:
                cur_pos += 1
                continue

            assert sampled is not None
            generated.append(sampled)
            if sampled == YT_EOT_TOKEN:
                break
            if len(generated) >= max_new_tokens or cur_pos >= 511:
                break

            self.tok_sram[cur_pos + 1] = sampled
            cur_pos += 1

        return generated
