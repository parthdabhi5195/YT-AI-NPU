# YT-AI Custom Silicon NPU (`yt-ai-npu`)

A complete, zero-stub, tapeout-ready SystemVerilog Neural Processing Unit (NPU) custom-architected to execute autonomous story generation on the **51,213,824-parameter YT-AI Small Language Model** (`L=8, H=8, D=512, FFN=2048, S=512, V=50,257`).

Designed for **SkyWater SKY130 (130 nm) OpenLane 2 RTL-to-GDSII silicon fabrication** (`3.20 mm × 3.20 mm = 10.24 mm²` single MPW die @ `100 MHz`) as well as FPGA synthesis (Xilinx / Lattice / Yosys) and physical 3D die modeling.

---

## 1. Key Upgrades Over `tiny-npu-main` for the 51.2M YT-AI SLM

| Subsystem | `tiny-npu-main` (Reference) | `yt-ai-npu` (Custom Silicon Design) |
| :--- | :--- | :--- |
| **Silicon Top-Level** | `rtl/top.sv` used **stub countdown timers** instead of real engines | `rtl/yt_npu_top.sv` wires **all 8 real hardware engines, 5 SRAM macros, arbiters, DMA & sequencer (zero stubs)** |
| **Precision & Outlier Safety** | W8A8 (`INT8` activations clip YT-AI's `±52.98` Layer 6 residual & `±43.44` `ln_f` outliers) | **W8A16 (`INT8` weights × `INT16 Q7.8` activations -> `INT32` acc)** + **`INT8 Q4.3` KV-cache** (`0.998680` cosine sim vs FP32!) |
| **Systolic Compute Core** | `8×8` (64 MACs), 4-bit tile counter (`max 240`), 1 byte/cycle weight load, no bias/accum | **`16×16` (256 W8A16 MACs = 51.2 GOPS @ 100 MHz)**, 12-bit tile counters (`<=65,535`), **16 weights/cycle (128b) fast load**, `FLAG_BIAS_EN` & `FLAG_ACCUMULATE` |
| **LayerNorm Engine** | Hardcoded `gamma = 127` (ignored learned weights!) + 32-cycle integer divider | **Zero-divider** (`>>>9` exact shift for `D=512`), Bit-Pair CLZ + `256×16b` RSQRT ROM, and **real learned `{beta_q78, gamma_q4_12}`** |
| **Causal Softmax** | Max `N <= 64`, 32-cycle integer divider | **Full `512`-token context**, **zero-divider** CLZ + `256×16b` EXP & RECIP ROMs -> `Q0.15` |
| **Memory Hierarchy** | Flat 64 KB SRAM (cannot fit 1 YT-AI layer = 3.17 MB) | **91 KB On-Chip SRAM** (`32 KB` Ping-Pong WGT/KV + `32 KB` ACT + `8 KB` PARAM + `16 KB` UCODE + `1 KB` TOK) + **128-bit AXI4 Burst DMA** to external DDR (`49 MB` weights + `4 MB` KV-cache) |
| **Execution Scope** | Single attention/MLP Toy block (`D=64`) | **Full Autonomous Token Generator**: `WTE+WPE` Embed -> 8 Blocks w/ KV-Cache -> `ln_f` -> Tied `50,257`-vocab `lm_head` -> **Hardware Top-200 + Temp (`0.8`) Xorshift64\* Sampler** stopping on `<|endoftext|>` (`50256`) |

---

## 2. Verified Numerical Accuracy on Real Trained Checkpoint

Tested directly against `/Users/parth/Desktop/Youtube/YT AI/YT AI SLM/GPT Architecture/yt-ai-slm/best_model_params.pt` across all 8 layers and all 50,257 vocabulary logits (pure integer RTL datapaths, zero floating-point, zero dividers):

- **All-50,257 Logit Cosine Similarity vs. PyTorch FP32**: **`0.998680`**
- **Mean Absolute Logit Error (MAE)**: **`0.1569`**
- **Top-6 Predicted Token IDs (PyTorch FP32)**: `[220, 198, 1375, 314, 632, 383]`
- **Top-6 Predicted Token IDs (YT-AI NPU)**: **`[220, 198, 1375, 314, 632, 383]`** (**100% exact rank-order match**)
- **Microcode Footprint**: **684 / 1,024** 128-bit instructions (`10.7 KB`, fits entirely in on-chip `UCODE_SRAM` using the 2-level hardware loop stack `OP_LOOP_BEGIN`/`OP_LOOP_END`)

---

## 3. Repository Structure

```text
yt-ai-npu/
├── Makefile                        # One-command build, lint, verify, sim & GDSII targets
├── rtl/                            # 26 Synthesizable SystemVerilog files (Zero Stubs)
│   ├── yt_npu_top.sv               # Full silicon top-level macro (AXI4-Lite + 128b AXI4 + IRQ)
│   ├── pkg/                        # yt_npu_pkg.sv (constants/Q7.8 math), yt_isa_pkg.sv (128b ISA)
│   ├── mem/                        # yt_sram_1r1w.sv (OpenRAM/BRAM portable), yt_pingpong_wgt.sv
│   ├── gemm/                       # yt_mac_w8a16.sv, yt_pe.sv, yt_systolic_array.sv, yt_gemm_engine.sv
│   ├── ops/                        # LayerNorm, Softmax-512, GELU, Vec/Copy2D, Embed, Top-K Sampler + 4 ROMs
│   ├── bus/                        # yt_axi_lite_regs.sv, yt_axi_dma_rd.sv, yt_axi_dma_wr.sv (KV packer)
│   └── ctrl/                       # yt_scoreboard.sv, yt_ucode_fetch.sv, yt_ucode_decode.sv, yt_token_sequencer.sv
├── python/
│   ├── tools/                      # memory_map.py, export_quantize_yt_ai.py, ucode_compiler.py
│   ├── golden/                     # fixed_ops.py, yt_npu_sim.py (bit-exact RTL microcode simulator)
│   └── tests/                      # lint_rtl.py, verify_yt_ai_npu.py
├── sim/verilator/                  # CMakeLists.txt, axi_ddr_sim.hpp, tb_engines.cpp, tb_yt_block.cpp, tb_yt_autogen.cpp
├── asic/
│   ├── openlane/                   # SkyWater SKY130 config.json, pin_order.cfg, base.sdc (100 MHz, 3.2x3.2mm)
│   ├── yosys/                      # synth_sky130.ys gate-level synthesis script
│   ├── scripts/                    # run_silicon_flow.sh, export_3d_silicon.py
│   └── output/                     # Generated .gds (KLayout), .svg (Die Map), and .stl (3D Printable Chip!)
└── build/                          # Generated yt_ai_weights.bin (49 MB), quant_config.json, *.hex
```

---

## 4. Quickstart Commands

```bash
# 1. Lint all 26 SystemVerilog files & verify 1,024 ROM entries + port maps
make lint

# 2. Quantize real YT-AI 51.2M checkpoint, compile microcode & verify vs PyTorch FP32
make verify

# 3. Export physical GDSII layout (.gds), annotated die map (.svg) & 3D-printable chip (.stl)
make silicon

# 4. Run cycle-accurate Verilator C++ RTL simulation (requires verilator + cmake)
make sim

# 5. Run full SkyWater SKY130 OpenLane 2 RTL-to-GDSII signoff flow (native or Docker)
make openlane
```
